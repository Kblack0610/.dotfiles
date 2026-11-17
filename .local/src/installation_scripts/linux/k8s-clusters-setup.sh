#!/usr/bin/env bash
# ============================================================================
# Kubernetes Clusters Setup Script
# Sets up k3d local cluster and helps configure home k3s cluster connection
# ============================================================================

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# ============================================================================
# Install Dependencies
# ============================================================================
install_k3d() {
    if command -v k3d &> /dev/null; then
        log_info "k3d already installed: $(k3d version)"
        return 0
    fi

    log_info "Installing k3d..."
    curl -s https://raw.githubusercontent.com/k3d-io/k3d/main/install.sh | bash
    log_success "k3d installed successfully"
}

install_stern() {
    if command -v stern &> /dev/null; then
        log_info "stern already installed"
        return 0
    fi

    log_info "Installing stern for multi-pod log tailing..."

    # Try various package managers
    if command -v yay &> /dev/null; then
        yay -S --noconfirm stern
    elif command -v paru &> /dev/null; then
        paru -S --noconfirm stern
    elif command -v brew &> /dev/null; then
        brew install stern
    else
        # Manual install
        STERN_VERSION=$(curl -s https://api.github.com/repos/stern/stern/releases/latest | grep tag_name | cut -d '"' -f 4)
        curl -Lo /tmp/stern.tar.gz "https://github.com/stern/stern/releases/download/${STERN_VERSION}/stern_${STERN_VERSION#v}_linux_amd64.tar.gz"
        tar -xzf /tmp/stern.tar.gz -C /tmp
        sudo mv /tmp/stern /usr/local/bin/
        rm /tmp/stern.tar.gz
    fi
    log_success "stern installed successfully"
}

# ============================================================================
# k3d Local Cluster Setup
# ============================================================================
setup_k3d_local() {
    log_info "Setting up k3d local development cluster..."

    # Check if cluster already exists
    if k3d cluster list | grep -q "k3d-local"; then
        log_warn "k3d-local cluster already exists"
        read -p "Delete and recreate? (y/N): " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            k3d cluster delete local
        else
            return 0
        fi
    fi

    # Create cluster with useful defaults
    k3d cluster create local \
        --servers 1 \
        --agents 2 \
        --port "8080:80@loadbalancer" \
        --port "8443:443@loadbalancer" \
        --k3s-arg "--disable=traefik@server:0" \
        --wait

    log_success "k3d-local cluster created!"
    log_info "Context: k3d-local"
    log_info "Ports: 8080 -> 80, 8443 -> 443"

    # Verify connection
    kubectl cluster-info --context k3d-local
}

# ============================================================================
# Home k3s Cluster Connection
# ============================================================================
# The admin kubeconfig lives in rbw (base64, one line), so a machine other than
# the workstation can run the cluster. Recovery paths when rbw has no copy:
# home-config docs/host-access.md, "Cluster admin from another machine".
HOME_K3S_RBW_FOLDER="infra"
HOME_K3S_RBW_ENTRY="home-k3s-kubeconfig"

setup_home_k3s() {
    log_info "Setting up home k3s cluster connection from rbw ${HOME_K3S_RBW_FOLDER}/${HOME_K3S_RBW_ENTRY}..."

    if ! rbw unlocked &> /dev/null; then
        log_error "rbw is locked or not logged in. Run 'rbw login' / 'rbw unlock', then rerun option 3."
        return 1
    fi

    local target="$HOME/.kube/clusters/home-k3s.yaml"
    mkdir -p "$HOME/.kube/clusters"
    local tmp
    tmp=$(mktemp "$target.XXXXXX")
    if ! rbw get --folder "$HOME_K3S_RBW_FOLDER" "$HOME_K3S_RBW_ENTRY" | base64 -d > "$tmp" || [[ ! -s "$tmp" ]]; then
        rm -f "$tmp"
        log_error "Could not read ${HOME_K3S_RBW_FOLDER}/${HOME_K3S_RBW_ENTRY} from rbw."
        return 1
    fi
    chmod 600 "$tmp"
    mv "$tmp" "$target"

    # The rbw copy comes first so it replaces a stale home-k3s entry; the
    # current context is kept.
    local current
    current=$(kubectl config current-context 2> /dev/null || true)
    KUBECONFIG="$target:$HOME/.kube/config" kubectl config view --flatten > "$HOME/.kube/config.new"
    chmod 600 "$HOME/.kube/config.new"
    mv "$HOME/.kube/config.new" "$HOME/.kube/config"
    [[ -n "$current" ]] && kubectl config use-context "$current" > /dev/null
    log_success "Context home-k3s written to ~/.kube/config"

    if kubectl cluster-info --context home-k3s &> /dev/null; then
        log_success "Connected to home k3s."
    else
        log_warn "Could not reach home k3s. Check the LAN or tailnet."
    fi
}

# ============================================================================
# Display Current Setup
# ============================================================================
show_status() {
    echo ""
    echo "═══════════════════════════════════════════════════════════════"
    echo "                    Kubernetes Clusters Status"
    echo "═══════════════════════════════════════════════════════════════"
    echo ""

    log_info "Available contexts:"
    kubectl config get-contexts

    echo ""
    log_info "Current context: $(kubectl config current-context)"

    echo ""
    log_info "To switch contexts:"
    echo "  kubectl config use-context <context-name>"
    echo "  # Or in k9s, press ':ctx' to switch contexts"

    echo ""
    log_info "k9s quick reference:"
    echo "  Shift+1-0  : Jump to resources (pods, deployments, etc.)"
    echo "  Shift+L    : Stern logs (multi-pod)"
    echo "  Shift+R    : Restart deployment"
    echo "  Shift+D    : Debug with netshoot"
    echo "  :ctx       : Switch cluster context"
    echo "  :ns        : Switch namespace"
    echo "  :aliases   : View all aliases"
    echo ""
}

# ============================================================================
# Main Menu
# ============================================================================
main() {
    echo ""
    echo "═══════════════════════════════════════════════════════════════"
    echo "              Kubernetes Clusters Setup Wizard"
    echo "═══════════════════════════════════════════════════════════════"
    echo ""
    echo "What would you like to do?"
    echo ""
    echo "  1) Install dependencies (k3d, stern)"
    echo "  2) Create k3d local cluster"
    echo "  3) Setup home k3s cluster connection"
    echo "  4) Show current cluster status"
    echo "  5) Full setup (all of the above)"
    echo "  q) Quit"
    echo ""

    read -p "Select option: " choice

    case $choice in
        1)
            install_k3d
            install_stern
            ;;
        2)
            install_k3d
            setup_k3d_local
            ;;
        3)
            setup_home_k3s
            ;;
        4)
            show_status
            ;;
        5)
            install_k3d
            install_stern
            setup_k3d_local
            setup_home_k3s
            show_status
            ;;
        q|Q)
            exit 0
            ;;
        *)
            log_error "Invalid option"
            main
            ;;
    esac
}

# Run main if script is executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
