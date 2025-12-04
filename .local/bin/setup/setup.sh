#!/usr/bin/env bash
# ============================================================================
# Dotfiles Setup Script
# Cross-platform setup for macOS (Homebrew) and Arch/CachyOS (paru)
# ============================================================================

set -euo pipefail

DOTFILES_DIR="$HOME/.dotfiles"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_section() { echo -e "\n${CYAN}═══════════════════════════════════════════════════════════════${NC}"; echo -e "${CYAN}  $1${NC}"; echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}\n"; }

# Detect OS
detect_os() {
    if [[ "$OSTYPE" == "darwin"* ]]; then
        OS="macos"
    elif [[ -f /etc/arch-release ]] || [[ -f /etc/cachyos-release ]]; then
        OS="arch"
    elif [[ -f /etc/debian_version ]]; then
        OS="debian"
    else
        OS="unknown"
    fi
    log_info "Detected OS: $OS"
}

# ============================================================================
# Package Managers
# ============================================================================

install_homebrew() {
    if ! command -v brew &> /dev/null; then
        log_info "Installing Homebrew..."
        /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    else
        log_info "Homebrew already installed"
    fi
}

install_paru() {
    if ! command -v paru &> /dev/null; then
        log_info "Installing paru..."
        sudo pacman -S --needed --noconfirm base-devel git
        git clone https://aur.archlinux.org/paru.git /tmp/paru
        cd /tmp/paru && makepkg -si --noconfirm
        rm -rf /tmp/paru
    else
        log_info "paru already installed"
    fi
}

# ============================================================================
# Package Installation
# ============================================================================

install_packages_macos() {
    log_section "Installing macOS packages via Homebrew"
    install_homebrew

    if [[ -f "$DOTFILES_DIR/.config/brewfile/Brewfile" ]]; then
        brew bundle --file="$DOTFILES_DIR/.config/brewfile/Brewfile"
        log_success "Homebrew packages installed"
    else
        log_error "Brewfile not found at $DOTFILES_DIR/.config/brewfile/Brewfile"
    fi
}

install_packages_arch() {
    log_section "Installing Arch packages via paru"
    install_paru

    if [[ -f "$DOTFILES_DIR/.config/paru/packages.txt" ]]; then
        # Filter out comments and empty lines, then install
        grep -v '^#' "$DOTFILES_DIR/.config/paru/packages.txt" | grep -v '^$' | paru -S --needed --noconfirm -
        log_success "Arch packages installed"
    else
        log_error "Package list not found at $DOTFILES_DIR/.config/paru/packages.txt"
    fi
}

# ============================================================================
# Dotfiles Stow
# ============================================================================

stow_dotfiles() {
    log_section "Stowing dotfiles"

    cd "$DOTFILES_DIR"

    # Stow each directory (adjust based on your structure)
    # Using stow with -t to target home directory
    stow -v -t "$HOME" . --ignore='.git' --ignore='README.md' --ignore='LICENSE'

    # Configure git to use custom hooks directory
    git config core.hooksPath .githooks
    log_info "Git hooks configured"

    log_success "Dotfiles stowed"
}

# ============================================================================
# Services Setup
# ============================================================================

setup_services_arch() {
    log_section "Setting up services"

    # Enable SSH
    sudo systemctl enable --now sshd
    log_info "SSH enabled"

    # Enable Docker
    if command -v docker &> /dev/null; then
        sudo systemctl enable --now docker
        sudo usermod -aG docker "$USER"
        log_info "Docker enabled (re-login required for group)"
    fi
}

# ============================================================================
# Kubernetes Setup
# ============================================================================

setup_kubernetes() {
    log_section "Setting up Kubernetes tools"

    # Create kubeconfig directory
    mkdir -p "$HOME/.kube/clusters"

    # Create k9s directories
    mkdir -p "$HOME/.local/share/k9s/screen-dumps"

    # Run k8s cluster setup if available
    if [[ -x "$HOME/.local/bin/setup/k8s-clusters-setup.sh" ]]; then
        read -p "Run Kubernetes cluster setup wizard? (y/N): " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            "$HOME/.local/bin/setup/k8s-clusters-setup.sh"
        fi
    fi

    log_success "Kubernetes tools configured"
}

# ============================================================================
# Shell Setup
# ============================================================================

setup_shell() {
    log_section "Setting up shell"

    # Set zsh as default shell if not already
    if [[ "$SHELL" != *"zsh"* ]]; then
        log_info "Setting zsh as default shell..."
        chsh -s "$(which zsh)"
    fi

    # Install Oh My Zsh if not present
    if [[ ! -d "$HOME/.oh-my-zsh" ]]; then
        log_info "Installing Oh My Zsh..."
        sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended
    fi

    # Install zsh-autosuggestions plugin if not present
    ZSH_CUSTOM="${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}"
    if [[ ! -d "$ZSH_CUSTOM/plugins/zsh-autosuggestions" ]]; then
        git clone https://github.com/zsh-users/zsh-autosuggestions "$ZSH_CUSTOM/plugins/zsh-autosuggestions"
    fi

    log_success "Shell configured"
}

# ============================================================================
# Main Menu
# ============================================================================

show_menu() {
    echo ""
    echo "═══════════════════════════════════════════════════════════════"
    echo "                    Dotfiles Setup Wizard"
    echo "═══════════════════════════════════════════════════════════════"
    echo ""
    echo "  1) Full setup (packages + stow + services + k8s)"
    echo "  2) Install packages only"
    echo "  3) Stow dotfiles only"
    echo "  4) Setup services only"
    echo "  5) Setup Kubernetes only"
    echo "  6) Setup shell (zsh + oh-my-zsh)"
    echo "  q) Quit"
    echo ""
}

main() {
    detect_os

    if [[ "${1:-}" == "--full" ]]; then
        # Non-interactive full setup
        case $OS in
            macos) install_packages_macos ;;
            arch) install_packages_arch ;;
        esac
        stow_dotfiles
        [[ "$OS" == "arch" ]] && setup_services_arch
        setup_shell
        setup_kubernetes
        exit 0
    fi

    while true; do
        show_menu
        read -p "Select option: " choice

        case $choice in
            1)
                case $OS in
                    macos) install_packages_macos ;;
                    arch) install_packages_arch ;;
                    *) log_error "Unsupported OS: $OS" ;;
                esac
                stow_dotfiles
                [[ "$OS" == "arch" ]] && setup_services_arch
                setup_shell
                setup_kubernetes
                ;;
            2)
                case $OS in
                    macos) install_packages_macos ;;
                    arch) install_packages_arch ;;
                    *) log_error "Unsupported OS: $OS" ;;
                esac
                ;;
            3) stow_dotfiles ;;
            4)
                [[ "$OS" == "arch" ]] && setup_services_arch || log_warn "Services setup only for Arch"
                ;;
            5) setup_kubernetes ;;
            6) setup_shell ;;
            q|Q) exit 0 ;;
            *) log_error "Invalid option" ;;
        esac
    done
}

main "$@"
