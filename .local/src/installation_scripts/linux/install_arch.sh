#!/usr/bin/env bash

# Arch Linux Installation Functions
# Overrides base functions with Arch-specific implementations

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(dirname "$SCRIPT_DIR")"

# Source base functions
source "$BASE_DIR/base_functions.sh"

# Load configuration
load_config

# Helper: Install package with pacman
install_pacman_package() {
    local package="$1"
    
    if pacman -Q "$package" &>/dev/null; then
        log_info "$package already installed"
        return 0
    fi
    
    log_info "Installing $package..."
    if sudo pacman -S --noconfirm "$package" &>/dev/null; then
        log_info "✓ $package installed"
    else
        log_warning "✗ Failed to install $package"
    fi
}

# Helper: Install from AUR
install_aur_package() {
    local package="$1"
    
    if ! command -v paru &>/dev/null; then
        install_paru
    fi
    
    if paru -Q "$package" &>/dev/null; then
        log_info "$package already installed"
        return 0
    fi
    
    log_info "Installing $package from AUR..."
    if paru -S --noconfirm "$package" &>/dev/null; then
        log_info "✓ $package installed"
    else
        log_warning "✗ Failed to install $package"
    fi
}

# Install paru AUR helper
install_paru() {
    if command -v paru &>/dev/null; then
        return 0
    fi
    
    log_info "Installing paru AUR helper..."
    cd /tmp
    git clone https://aur.archlinux.org/paru.git
    cd paru
    makepkg -si --noconfirm
    cd ~
    rm -rf /tmp/paru
}

# Override: Update system
update_system() {
    log_section "Updating system packages"
    
    if sudo pacman -Syu --noconfirm &>/dev/null; then
        log_info "System updated"
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
        "base-devel"
        "fuse2"
        "openssh"
    )
    
    for pkg in "${packages[@]}"; do
        install_pacman_package "$pkg"
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
        "xsel"
        "autojump"
        "glances"
        "fd"
        "bat"
        "exa"
    )
    
    for tool in "${tools[@]}"; do
        install_pacman_package "$tool"
    done
}

# Override: Install terminal enhancements
install_terminal() {
    log_section "Installing terminal enhancements"
    
    local packages=(
        "zsh"
        "cowsay"
        "fortune-mod"
        "feh"
    )
    
    for pkg in "${packages[@]}"; do
        install_pacman_package "$pkg"
    done
}

# Override: Install GUI applications
install_gui() {
    log_section "Installing GUI applications"
    
    local packages=(
        "i3-wm"
        "i3status"
        "i3lock"
        "rofi"
        "dunst"
        "picom"
        "nitrogen"
        "firefox"
        "kitty"
    )
    
    for pkg in "${packages[@]}"; do
        install_pacman_package "$pkg"
    done
}

# Override: Install language runtimes
install_runtime() {
    log_section "Installing language runtimes"
    
    # Node.js
    install_pacman_package "nodejs"
    install_pacman_package "npm"
    
    # Python
    install_pacman_package "python"
    install_pacman_package "python-pip"
    
    # Rust
    if ! command -v cargo &>/dev/null; then
        log_info "Installing Rust..."
        curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
        source "$HOME/.cargo/env"
    fi
}

# Override: Install Zsh
install_zsh() {
    log_section "Installing Zsh"
    
    install_pacman_package "zsh"
    install_pacman_package "zsh-completions"
    
    # Set as default shell if not already
    if [[ "$SHELL" != "$(which zsh)" ]]; then
        log_info "Setting Zsh as default shell..."
        chsh -s "$(which zsh)"
    fi
}

# Override: Install Neovim
install_nvim() {
    log_section "Installing Neovim"
    
    install_pacman_package "neovim"
    
    # Install dependencies
    install_pacman_package "tree-sitter"
    install_pacman_package "ripgrep"
    install_pacman_package "fd"
}

# Override: Install tmux
install_tmux() {
    log_section "Installing tmux"
    install_pacman_package "tmux"
}

# Override: Install Kitty
install_kitty() {
    log_section "Installing Kitty Terminal"
    install_pacman_package "kitty"
}

# Override: Install Lazygit
install_lazygit() {
    log_section "Installing Lazygit"
    
    # Try official repo first
    if ! install_pacman_package "lazygit"; then
        # Fall back to AUR
        install_aur_package "lazygit"
    fi
}

# Arch-specific: Install from AUR
install_aur_packages() {
    log_section "Installing AUR packages"
    
    install_paru
    
    local aur_packages=(
        "visual-studio-code-bin"
        "spotify"
        "discord"
    )
    
    for pkg in "${aur_packages[@]}"; do
        install_aur_package "$pkg"
    done
}

# Override main installation to include AUR
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
    
    # Desktop environment
    install_gui
    
    # AUR packages
    install_aur_packages
    
    # Additional setup
    install_fonts
    setup_git
    install_npm_packages
    apply_dotfiles
    
    log_section "Installation Complete!"
    log_info "Please restart your terminal or run: source ~/.zshrc"
}

# Run if executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    install_all
fi