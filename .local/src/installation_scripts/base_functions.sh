#!/usr/bin/env bash

# Base Installation Functions
# These can be overridden by OS-specific implementations

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging functions
log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_section() {
    echo ""
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BLUE}  $1${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

# Load configuration. Resolves packages.conf relative to base_functions.sh's
# own location, not the caller's $SCRIPT_DIR (which each OS installer overwrites
# to point at its own subdirectory before calling load_config).
load_config() {
    local base_dir
    base_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local config_file="$base_dir/packages.conf"
    if [[ -f "$config_file" ]]; then
        source "$config_file"
    else
        log_error "packages.conf not found at $config_file"
        return 1
    fi
}

# Resolve a logical package name to the OS-specific name.
# Reads PACKAGE_NAME_<OS> associative array from packages.conf; falls back to
# the input if no override exists.
#   $1 = logical package name (e.g. "fd")
#   $2 = os tag (arch|debian|mac|android|windows)
_resolve_pkg_name() {
    local logical="$1" os="$2"
    local map_var="PACKAGE_NAME_${os^^}"
    if declare -p "$map_var" &>/dev/null && [[ "$(declare -p "$map_var" 2>/dev/null)" == "declare -A"* ]]; then
        local -n _map="$map_var"
        if [[ ${_map[$logical]+x} ]]; then
            echo "${_map[$logical]}"
            return
        fi
    fi
    echo "$logical"
}

# Iterate a logical package list and install each via the OS-specific helper,
# applying naming overrides en route.
#   $1     = installer fn name (install_pacman_package, install_apt_package, ...)
#   $2     = os tag
#   $3..$n = logical package names (typically passed unquoted as "$BASE $EXTRA")
install_package_list() {
    local installer_fn="$1" os="$2"
    shift 2
    local logical resolved
    for logical in "$@"; do
        resolved=$(_resolve_pkg_name "$logical" "$os")
        [[ -z "$resolved" ]] && continue
        "$installer_fn" "$resolved"
    done
}

# Create directory structure
create_directories() {
    log_section "Creating directory structure"

    local dirs=(
        "$HOME/.local/bin"
        "$HOME/.local/share/fonts"
        "$HOME/.config"
        "$HOME/dev"
        "$HOME/Downloads"
        "$HOME/Media/Pictures"
        "$HOME/Media/Videos"
        "$HOME/Media/Music"
    )

    for dir in "${dirs[@]}"; do
        [[ ! -d "$dir" ]] && mkdir -p "$dir"
    done

    # Remove default XDG directories we don't use
    local remove_dirs=(
        "$HOME/Desktop"
        "$HOME/Documents"
        "$HOME/Public"
        "$HOME/Templates"
        "$HOME/Music"
        "$HOME/Pictures"
        "$HOME/Videos"
        "$HOME/Projects"
        "$HOME/~"  # Common mistake from bad tilde expansion
    )

    for dir in "${remove_dirs[@]}"; do
        if [[ -d "$dir" && ! -L "$dir" ]]; then
            # Only remove if empty
            if [[ -z "$(ls -A "$dir" 2>/dev/null)" ]]; then
                rmdir "$dir" 2>/dev/null && log_info "Removed empty $dir"
            else
                log_warning "$dir is not empty, skipping removal"
            fi
        fi
    done

    log_info "Directory structure created"
}

# Install basic requirements
install_basics() {
    log_section "Installing basic requirements"
    log_info "No default implementation - override in OS-specific file"
}

# Update system packages
update_system() {
    log_section "Updating system"
    log_info "No default implementation - override in OS-specific file"
}


# Install basic requirements
install_os_reqs() {
    log_section "Installing basic requirements"
    log_info "No default implementation - override in OS-specific file"
}
# Install development tools
install_tools() {
    log_section "Installing development tools"
    log_info "No default implementation - override in OS-specific file"
}

# Install terminal enhancements
install_terminal() {
    log_section "Installing terminal enhancements"
    log_info "No default implementation - override in OS-specific file"
}

# Install GUI applications
install_gui() {
    log_section "Installing GUI applications"
    log_info "No default implementation - override in OS-specific file"
}

# Install language runtimes
install_runtime() {
    log_section "Installing language runtimes"
    log_info "No default implementation - override in OS-specific file"
}

# Install Zsh
install_zsh() {
    log_section "Installing Zsh"
    log_info "No default implementation - override in OS-specific file"
}

# Install Oh My Zsh and plugins
install_oh_my_zsh() {
    log_section "Installing Oh My Zsh"
    
    if [[ ! -d ~/.oh-my-zsh ]]; then
        sh -c "$(curl -fsSL https://raw.github.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended
        log_info "Oh My Zsh installed"
    else
        log_info "Oh My Zsh already installed"
    fi
    
    # Install plugins
    local plugins=(
        "zsh-users/zsh-autosuggestions"
        "zsh-users/zsh-syntax-highlighting"
    )
    
    for plugin_repo in "${plugins[@]}"; do
        local plugin_name="${plugin_repo##*/}"
        local plugin_dir="${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}/plugins/$plugin_name"

        if [[ ! -d "$plugin_dir" ]]; then
            log_info "Installing $plugin_name..."
            if git clone "https://github.com/$plugin_repo" "$plugin_dir"; then
                log_info "✓ $plugin_name installed"
            else
                log_error "✗ Failed to install $plugin_name"
            fi
        else
            log_info "$plugin_name already installed"
        fi
    done
}

# Install Starship prompt
install_starship() {
    log_section "Installing Starship Prompt"
    
    if ! command -v starship &>/dev/null; then
        curl -sS https://starship.rs/install.sh | sh -s -- -y
        log_info "Starship installed"
    else
        log_info "Starship already installed"
    fi
}

# Install Nerd Fonts
install_fonts() {
    log_section "Installing Nerd Fonts"
    
    local fonts=(
        "Hack"
        "SymbolsOnly"
    )
    
    local version='3.4.0'
    local fonts_dir="${HOME}/.local/share/fonts"
    
    [[ ! -d "$fonts_dir" ]] && mkdir -p "$fonts_dir"
    
    for font in "${fonts[@]}"; do
        local zip_file="${font}.zip"
        local download_url="https://github.com/ryanoasis/nerd-fonts/releases/download/v${version}/${zip_file}"
        
        log_info "Downloading $font font..."
        if wget -q "$download_url" -O "/tmp/${zip_file}"; then
            unzip -o -q "/tmp/${zip_file}" -d "$fonts_dir" && rm "/tmp/${zip_file}"
            log_info "✓ $font installed"
        else
            log_warning "✗ Failed to download $font"
        fi
    done
    
    # Update font cache
    if command -v fc-cache &>/dev/null; then
        fc-cache -fv &>/dev/null
    fi
}

# Install Neovim
install_nvim() {
    log_section "Installing Neovim"
    log_info "No default implementation - override in OS-specific file"
}

# Install tmux
install_tmux() {
    log_section "Installing tmux"
    log_info "No default implementation - override in OS-specific file"
}

# Install Kitty terminal
install_kitty() {
    log_section "Installing Kitty Terminal"
    
    if command -v kitty &>/dev/null; then
        log_info "Kitty already installed"
        return 0
    fi
    
    log_info "No default implementation - override in OS-specific file"
}

# Install Lazygit
install_lazygit() {
    log_section "Installing Lazygit"
    log_info "No default implementation - override in OS-specific file"
}

# Install Kubernetes tools (kubectl, k9s, k3d, helm, stern, kubectx)
install_kubernetes() {
    log_section "Installing Kubernetes tools"
    log_info "No default implementation - override in OS-specific file"
}

# Setup printing (CUPS with network printer discovery)
setup_printing() {
    log_section "Setting up printing (CUPS + network discovery)"
    log_info "No default implementation - override in OS-specific file"
}

# Setup Sunshine game streaming with firewall rules
setup_sunshine() {
    log_section "Setting up Sunshine (game streaming)"
    log_info "No default implementation - override in OS-specific file"
}

# Install Moonlight game streaming client
install_moonlight() {
    log_section "Installing Moonlight (game streaming client)"
    log_info "No default implementation - override in OS-specific file"
}

# Setup Kubernetes directories and run cluster wizard
setup_kubernetes() {
    log_section "Setting up Kubernetes environment"

    # Create kubeconfig directory for multi-cluster configs
    mkdir -p "$HOME/.kube/clusters"

    # Create k9s directories
    mkdir -p "$HOME/.local/share/k9s/screen-dumps"

    log_info "Kubernetes directories created"

    # Offer to run cluster setup wizard
    local k8s_setup="$SCRIPT_DIR/linux/k8s-clusters-setup.sh"
    if [[ -x "$k8s_setup" ]]; then
        echo ""
        read -p "Run Kubernetes cluster setup wizard? (y/N): " -n 1 -r
        echo ""
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            "$k8s_setup"
        fi
    fi
}

# Install Rust
install_rust() {
    log_section "Installing Rust"
    
    if command -v rustc &>/dev/null; then
        log_info "Rust already installed ($(rustc --version))"
        return 0
    fi
    
    log_info "Downloading and installing Rust..."
    if curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y; then
        # Source cargo environment
        source "$HOME/.cargo/env"
        log_info "✓ Rust installed successfully"
    else
        log_error "Failed to install Rust"
        return 1
    fi
}

# Build local Rust tools that live in the dotfiles and symlink them onto PATH.
# Single static binaries, identical on macOS and Linux. Failures are non-fatal so
# the rest of the install proceeds. Mirrors notes-bootstrap's build_notes_cli.
build_local_rust_tools() {
    log_section "Building local Rust tools"

    if ! command -v cargo &>/dev/null; then
        log_warning "cargo not found — skipping local Rust tools (install rustup first)"
        return 0
    fi

    mkdir -p "$HOME/.local/bin"

    # name:relative-source-dir pairs
    local tools=("agent-panel:.local/src/agent-panel" "timebox:.local/src/timebox")
    local entry name src
    for entry in "${tools[@]}"; do
        name="${entry%%:*}"
        src="$HOME/.dotfiles/${entry#*:}"
        log_info "Building $name (cargo build --release)..."
        if ( cd "$src" && cargo build --release ); then
            ln -sf "$src/target/release/$name" "$HOME/.local/bin/$name"
            log_info "✓ Installed $name -> ~/.local/bin/$name"
        else
            log_warning "$name build failed; existing binary (if any) left in place."
        fi
    done
}

# Setup Git configuration
setup_git() {
    log_section "Configuring Git"
    
    git config --global user.name "Kenneth"
    git config --global user.email "kblack0610@gmail.com"
    git config --global credential.helper store
    
    # SSH key setup
    if [[ ! -f ~/.ssh/id_ed25519 ]]; then
        log_info "Generating SSH key..."
        mkdir -p ~/.ssh
        ssh-keygen -t ed25519 -C "kblack0610@gmail.com" -N "" -f ~/.ssh/id_ed25519
        eval "$(ssh-agent -s)" &>/dev/null
        ssh-add ~/.ssh/id_ed25519 &>/dev/null
        log_info "SSH key generated: ~/.ssh/id_ed25519.pub"
    else
        log_info "SSH key already exists"
    fi
}

# Apply dotfiles with stow
apply_dotfiles() {
    log_section "Applying dotfiles"

    if ! command -v stow &>/dev/null; then
        log_warning "stow not installed, skipping dotfiles"
        return 0
    fi

    cd ~/.dotfiles

    # Remove existing configs
    [[ -f ~/.bashrc ]] && rm -f ~/.bashrc
    [[ -f ~/.zshrc ]] && rm -f ~/.zshrc

    # --no-folding: per-item symlinks so the private overlay (~/.dotfiles-private)
    # can contribute siblings into shared dirs (.claude/skills, .config, …) without
    # stow tree-folding a whole dir into one symlink and blocking the overlay.
    stow --no-folding .

    # Check out git submodules (.local/src/android-suite, gungan) so their symlinks
    # don't dangle. Force HTTPS + gh credential to survive networks that block SSH:22
    # (the submodule .gitmodules URLs are git@github.com:), cap the time, fail-soft.
    timeout 120 git -c url."https://github.com/".insteadOf="git@github.com:" \
        submodule update --init --recursive 2>/dev/null \
        || log_warning "submodule update failed/skipped; run 'git submodule update --init' manually"

    # Configure git to use custom hooks directory (for auto-commit of claude history, etc.)
    git config core.hooksPath .githooks
    log_info "Git hooks configured"

    log_info "Dotfiles applied"
}

# Clone + stow the PRIVATE overlay (~/.dotfiles-private) on top of the public repo.
# Optional: a machine is fully functional from the public repo alone. Only clones
# when GitHub auth is available; skips cleanly otherwise. Idempotent.
setup_dotfiles_private() {
    log_section "Applying private dotfiles overlay (optional)"

    if ! command -v stow &>/dev/null; then
        log_warning "stow not installed, skipping private overlay"
        return 0
    fi

    local PRV="$HOME/.dotfiles-private"
    if [ ! -d "$PRV" ]; then
        if gh auth status &>/dev/null \
           || ssh -T -o BatchMode=yes -o ConnectTimeout=5 git@github.com 2>&1 | grep -qiE 'success|authenticat'; then
            log_info "Cloning private overlay -> $PRV"
            git clone git@github.com:Kblack0610/.dotfiles-private.git "$PRV" \
                || { log_warning "Private overlay clone failed; continuing public-only"; return 0; }
        else
            log_warning "No GitHub auth; skipping private overlay (public-only machine)"
            return 0
        fi
    else
        ( cd "$PRV" && git pull --ff-only 2>/dev/null || true )
    fi

    if ( cd "$PRV" && stow --no-folding --target="$HOME" . ); then
        log_info "Private overlay applied"
    else
        log_warning "Private overlay stow reported conflicts (expected on a folded box); reconciling links directly"
    fi

    # stow silently skips any overlay path that a pre-existing (public-pointing)
    # symlink already occupies, so on a folded box it attaches nothing. Repoint the
    # dead links straight at the overlay - idempotent, only touches broken links.
    if [ -x "$HOME/.dotfiles/.local/bin/dotfiles-overlay-link" ]; then
        "$HOME/.dotfiles/.local/bin/dotfiles-overlay-link" || true
    fi
}

# Setup Claude plans directory symlink
setup_ai_memory() {
    log_section "Setting up Claude plans directory"

    local PLANS_TARGET="$HOME/.agent/plans"
    local PLANS_LINK="$HOME/.claude/plans"

    # Create target directory if it doesn't exist
    mkdir -p "$PLANS_TARGET"

    # Handle existing plans directory
    if [ -L "$PLANS_LINK" ]; then
        log_info "Plans symlink already exists"
        return 0
    elif [ -d "$PLANS_LINK" ]; then
        # Backup existing plans
        log_info "Backing up existing plans to ~/.claude/plans.bak"
        mv "$PLANS_LINK" "${PLANS_LINK}.bak"
    fi

    # Create symlink
    ln -s "$PLANS_TARGET" "$PLANS_LINK"
    log_info "Claude plans symlinked: ~/.claude/plans -> ~/.agent/plans"
}

# Install NPM packages — reads NPM_PACKAGES from packages.conf
install_npm_packages() {
    if ! command -v npm &>/dev/null; then
        log_warning "npm not found, skipping npm packages"
        return 0
    fi

    log_section "Installing NPM global packages"

    if [[ -z "$NPM_PACKAGES" ]]; then
        log_warning "NPM_PACKAGES not defined in packages.conf — skipping"
        return 0
    fi

    for package in $NPM_PACKAGES; do
        log_info "Installing $package..."
        if npm install -g "$package" &>/dev/null; then
            log_info "✓ $package installed"
        else
            log_warning "✗ Failed to install $package"
        fi
    done
}

# Main installation orchestrator
install_all() {
    # Create structure
    create_directories

    # System updates
    update_system

    # Core installations
    install_basics
    install_tools
    install_terminal
    install_runtime

    # Shell setup
    install_zsh
    install_oh_my_zsh
    install_starship

    # Development tools
    install_nvim
    install_tmux
    install_lazygit
    install_kitty
    install_rust
    build_local_rust_tools

    # Kubernetes & Containers
    install_kubernetes
    setup_kubernetes

    # Printing
    setup_printing

    # GUI (if applicable)
    install_gui

    # Additional setup
    install_fonts
    setup_git
    install_npm_packages
    apply_dotfiles
    setup_dotfiles_private
    setup_ai_memory

    log_section "Installation Complete!"
    log_info "Please restart your terminal or run: source ~/.zshrc"
}

# Export all functions for overriding
export -f log_info log_error log_warning log_section
export -f create_directories update_system
export -f install_basics install_tools install_terminal install_gui install_runtime
export -f install_zsh install_oh_my_zsh install_starship
export -f install_nvim install_tmux install_kitty install_lazygit install_rust build_local_rust_tools
export -f install_kubernetes setup_kubernetes setup_printing setup_sunshine
export -f install_fonts setup_git apply_dotfiles setup_dotfiles_private install_npm_packages setup_ai_memory
export -f install_all
export -f _resolve_pkg_name install_package_list
