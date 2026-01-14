#!/usr/bin/env bash

# Android/Termux Installation Functions
# Overrides base functions with Android-specific implementations

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(dirname "$SCRIPT_DIR")"

# Source base functions
source "$BASE_DIR/base_functions.sh"

# Load configuration
load_config

# Helper: Install package with pkg
install_pkg_package() {
    local package="$1"
    
    if pkg list-installed 2>/dev/null | grep -q "^${package}/"; then
        log_info "$package already installed"
        return 0
    fi
    
    log_info "Installing $package..."
    if pkg install -y "$package" &>/dev/null; then
        log_info "✓ $package installed"
    else
        log_warning "✗ Failed to install $package"
    fi
}

# Override: Update system
update_system() {
    log_section "Updating system packages"
    
    if pkg update -y &>/dev/null; then
        log_info "Package lists updated"
    fi
    
    if pkg upgrade -y &>/dev/null; then
        log_info "Packages upgraded"
    fi
}

# Override: Install basics
install_basics() {
    log_section "Installing basic requirements"
    
    local packages=(
        "vim"
        "wget"
        "curl"
        "git"
        "tmux"
        "stow"
        "openssh"
        "termux-api"
        "termux-tools"
    )
    
    for pkg in "${packages[@]}"; do
        install_pkg_package "$pkg"
    done
}

# Override: Install development tools
install_tools() {
    log_section "Installing development tools"
    
    local tools=(
        "ripgrep"
        "fzf"
        "jq"
        "tree"
        "htop"
        "neofetch"
        "zoxide"
        "fd"
        "bat"
        "exa"
    )
    
    for tool in "${tools[@]}"; do
        install_pkg_package "$tool"
    done
}

# Override: Install terminal enhancements
install_terminal() {
    log_section "Installing terminal enhancements"
    
    local packages=(
        "zsh"
        "cowsay"
        "fortune"
    )
    
    for pkg in "${packages[@]}"; do
        install_pkg_package "$pkg"
    done
}

# Override: Install GUI applications
install_gui() {
    # No GUI on Android/Termux
    log_section "Skipping GUI applications (not supported on Termux)"
}

# Override: Install language runtimes
install_runtime() {
    log_section "Installing language runtimes"
    
    # Node.js
    install_pkg_package "nodejs"
    
    # Python
    install_pkg_package "python"
    install_pkg_package "python-pip"
    
    # Rust
    if ! command -v cargo &>/dev/null; then
        log_info "Installing Rust..."
        pkg install rust -y &>/dev/null
    fi
}

# Override: Install Zsh
install_zsh() {
    log_section "Installing Zsh"
    
    install_pkg_package "zsh"
    
    # Note: Can't change default shell in Termux easily
    log_info "To use zsh, run 'zsh' or add to .bashrc"
}

# Override: Install Neovim
install_nvim() {
    log_section "Installing Neovim"
    
    install_pkg_package "neovim"
    
    # Install dependencies
    install_pkg_package "ripgrep"
    install_pkg_package "fd"
}

# Override: Install tmux
install_tmux() {
    log_section "Installing tmux"
    install_pkg_package "tmux"
}

# Override: Install Kitty
install_kitty() {
    # Kitty not available on Android
    log_section "Skipping Kitty (not available on Termux)"
}

# Override: Install Lazygit
install_lazygit() {
    log_section "Installing Lazygit"
    install_pkg_package "lazygit"
}

# Override: Install fonts (limited on Android)
install_fonts() {
    log_section "Font installation"
    log_info "Termux uses its own font system - install via Termux:Styling app"
}

# Android-specific: Setup storage access
setup_storage() {
    log_section "Setting up storage access"
    
    if [ ! -d ~/storage ]; then
        log_info "Requesting storage permissions..."
        termux-setup-storage
        log_info "Storage access configured"
    else
        log_info "Storage already configured"
    fi
}

# Override main installation for Android
install_all() {
    # Setup Termux-specific
    setup_storage
    
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
    
    # Additional setup
    setup_git
    install_npm_packages
    apply_dotfiles
    
    log_section "Installation Complete!"
    log_info "Run 'zsh' to start using Zsh"
}

# Run if executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    install_all
fi
