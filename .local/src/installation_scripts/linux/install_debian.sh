#!/usr/bin/env bash

# Debian/Ubuntu Installation Functions
# Overrides base functions with Debian-specific implementations

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(dirname "$SCRIPT_DIR")"

# Source base functions
source "$BASE_DIR/base_functions.sh"

# Load configuration
load_config

# Helper: Install package with apt
install_apt_package() {
    local package="$1"
    
    if dpkg -l | grep -q "^ii.*$package"; then
        log_info "$package already installed"
        return 0
    fi
    
    log_info "Installing $package..."
    if sudo apt install -y "$package" &>/dev/null; then
        log_info "✓ $package installed"
    else
        log_warning "✗ Failed to install $package"
    fi
}

# Override: Update system
update_system() {
    log_section "Updating system packages"
    
    if sudo apt update &>/dev/null; then
        log_info "Package lists updated"
    fi
    
    if sudo apt upgrade -y &>/dev/null; then
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
        "build-essential"
        "libfuse2"
        "software-properties-common"
        "apt-transport-https"
        "ca-certificates"
        "gnupg"
        "lsb-release"
    )
    
    for pkg in "${packages[@]}"; do
        install_apt_package "$pkg"
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
    )
    
    for tool in "${tools[@]}"; do
        install_apt_package "$tool"
    done
}

# Override: Install terminal enhancements
install_terminal() {
    log_section "Installing terminal enhancements"
    
    local packages=(
        "zsh"
        "cowsay"
        "fortune"
        "feh"
    )
    
    for pkg in "${packages[@]}"; do
        install_apt_package "$pkg"
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
    )
    
    for pkg in "${packages[@]}"; do
        install_apt_package "$pkg"
    done
    
    # Install Flatpak apps
    if command -v flatpak &>/dev/null; then
        log_info "Installing Flatpak applications..."
        flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo
        flatpak install -y flathub one.ablaze.floorp &>/dev/null || true
    fi
}

# Override: Install language runtimes
install_runtime() {
    log_section "Installing language runtimes"
    
    # Node.js
    if ! command -v node &>/dev/null; then
        log_info "Installing Node.js..."
        curl -fsSL https://deb.nodesource.com/setup_lts.x | sudo -E bash -
        sudo apt install -y nodejs &>/dev/null
    fi
    
    # Python
    install_apt_package "python3"
    install_apt_package "python3-pip"
    install_apt_package "python3-venv"
    
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
    
    install_apt_package "zsh"
    
    # Set as default shell if not already
    if [[ "$SHELL" != "$(which zsh)" ]]; then
        log_info "Setting Zsh as default shell..."
        chsh -s "$(which zsh)"
    fi
}

# Override: Install Neovim
install_nvim() {
    log_section "Installing Neovim"
    
    if ! command -v nvim &>/dev/null; then
        # Try to install from apt first
        if ! install_apt_package "neovim"; then
            # Build from source if apt version is too old
            log_info "Building Neovim from source..."
            
            local build_deps=(
                "ninja-build" "gettext" "libtool" "libtool-bin"
                "autoconf" "automake" "cmake" "g++" "pkg-config"
                "unzip" "curl" "doxygen"
            )
            
            for dep in "${build_deps[@]}"; do
                install_apt_package "$dep"
            done
            
            cd /tmp
            git clone https://github.com/neovim/neovim.git
            cd neovim
            make CMAKE_BUILD_TYPE=RelWithDebInfo
            sudo make install
            cd ~
            rm -rf /tmp/neovim
        fi
    else
        log_info "Neovim already installed"
    fi
    
    # Install dependencies
    install_apt_package "ripgrep"
    install_apt_package "fd-find"
}

# Override: Install tmux
install_tmux() {
    log_section "Installing tmux"
    install_apt_package "tmux"
}

# Override: Install Kitty
install_kitty() {
    log_section "Installing Kitty Terminal"
    
    if command -v kitty &>/dev/null; then
        log_info "Kitty already installed"
        return 0
    fi
    
    # Install from package if available
    if ! install_apt_package "kitty"; then
        # Manual installation
        log_info "Installing Kitty manually..."
        curl -L https://sw.kovidgoyal.net/kitty/installer.sh | sh /dev/stdin
        
        mkdir -p ~/.local/bin ~/.local/share/applications
        ln -sf ~/.local/kitty.app/bin/kitty ~/.local/bin/
        ln -sf ~/.local/kitty.app/bin/kitten ~/.local/bin/
        
        cp ~/.local/kitty.app/share/applications/kitty.desktop ~/.local/share/applications/
        sed -i "s|Icon=kitty|Icon=$HOME/.local/kitty.app/share/icons/hicolor/256x256/apps/kitty.png|g" ~/.local/share/applications/kitty*.desktop
        sed -i "s|Exec=kitty|Exec=$HOME/.local/kitty.app/bin/kitty|g" ~/.local/share/applications/kitty*.desktop
    fi
}

# Override: Install Lazygit
install_lazygit() {
    log_section "Installing Lazygit"
    
    if ! command -v lazygit &>/dev/null; then
        log_info "Installing Lazygit..."
        
        LAZYGIT_VERSION=$(curl -s "https://api.github.com/repos/jesseduffield/lazygit/releases/latest" | grep -Po '"tag_name": "v\K[^"]*')
        curl -Lo /tmp/lazygit.tar.gz "https://github.com/jesseduffield/lazygit/releases/latest/download/lazygit_${LAZYGIT_VERSION}_Linux_x86_64.tar.gz"
        tar xf /tmp/lazygit.tar.gz -C /tmp lazygit
        sudo install /tmp/lazygit /usr/local/bin
        rm /tmp/lazygit.tar.gz /tmp/lazygit
        
        log_info "Lazygit installed"
    else
        log_info "Lazygit already installed"
    fi
}

# Debian-specific: Install Flatpak
install_flatpak() {
    log_section "Installing Flatpak"
    
    install_apt_package "flatpak"
    
    if command -v flatpak &>/dev/null; then
        flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo
        log_info "Flatpak configured"
    fi
}

# Override main installation to include Flatpak
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
    install_flatpak
    
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