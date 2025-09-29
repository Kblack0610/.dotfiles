#!/usr/bin/env bash

# Agnostic Installation Requirements Script
# This script provides a unified interface for installing requirements across different systems
# Source this file and then call init_system with your system type

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
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

# Initialize system-specific variables
init_system() {
    local system_type="$1"

    case "$system_type" in
        "debian"|"ubuntu")
            PACKAGE_MANAGER="apt"
            PACKAGE_INSTALL_CMD="sudo apt install -y"
            PACKAGE_UPDATE_CMD="sudo apt update && sudo apt upgrade -y"
            PACKAGE_SEARCH_CMD="apt search"
            PACKAGE_PREFIX="yes |"
            SYSTEM_TYPE="debian"
            ;;
        "arch"|"manjaro")
            PACKAGE_MANAGER="pacman"
            PACKAGE_INSTALL_CMD="sudo pacman -S --noconfirm"
            PACKAGE_UPDATE_CMD="sudo pacman -Syu --noconfirm"
            PACKAGE_SEARCH_CMD="pacman -Ss"
            PACKAGE_PREFIX=""
            AUR_HELPER="yay"
            SYSTEM_TYPE="arch"
            ;;
        "mac"|"darwin")
            PACKAGE_MANAGER="brew"
            PACKAGE_INSTALL_CMD="brew install"
            PACKAGE_UPDATE_CMD="brew update && brew upgrade"
            PACKAGE_SEARCH_CMD="brew search"
            PACKAGE_PREFIX=""
            SYSTEM_TYPE="mac"
            ;;
        "android"|"termux")
            PACKAGE_MANAGER="pkg"
            PACKAGE_INSTALL_CMD="pkg install -y"
            PACKAGE_UPDATE_CMD="pkg update -y && pkg upgrade -y"
            PACKAGE_SEARCH_CMD="pkg search"
            PACKAGE_PREFIX=""
            SYSTEM_TYPE="android"
            ;;
        *)
            log_error "Unknown system type: $system_type"
            log_info "Supported types: debian, ubuntu, arch, manjaro, mac, darwin, android, termux"
            return 1
            ;;
    esac

    log_info "System initialized: $SYSTEM_TYPE"
    log_info "Package manager: $PACKAGE_MANAGER"
}

# Package mapping for different systems
# Using a function-based approach for compatibility

# Get the correct package name for the current system
get_package_name() {
    local generic_name="$1"
    local system_type="${SYSTEM_TYPE}"
    
    case "${generic_name}:${system_type}" in
        # libfuse2 mappings
        "libfuse2:debian") echo "libfuse2" ;;
        "libfuse2:arch") echo "fuse2" ;;
        "libfuse2:mac") echo "" ;;  # Not needed on Mac
        "libfuse2:android") echo "" ;;  # Not available on Android
        
        # fortune mappings
        "fortune:debian") echo "fortune" ;;
        "fortune:arch") echo "fortune-mod" ;;
        "fortune:mac") echo "fortune" ;;
        "fortune:android") echo "fortune" ;;
        
        # i3 window manager
        "i3:debian") echo "i3-wm" ;;
        "i3:arch") echo "i3-wm" ;;
        "i3:mac") echo "" ;;  # Not available on Mac
        "i3:android") echo "" ;;  # Not available on Android
        
        # Default: return the generic name
        *) echo "$generic_name" ;;
    esac
}

# Install a package with system-specific command
install_package() {
    local generic_name="$1"
    local package_name=$(get_package_name "$generic_name")

    if [[ -z "$package_name" ]]; then
        log_warning "Package $generic_name not available on $SYSTEM_TYPE"
        return 0
    fi

    log_info "Installing $package_name..."
    eval "${PACKAGE_PREFIX} ${PACKAGE_INSTALL_CMD} ${package_name} &> /dev/null"
    if [[ $? -eq 0 ]]; then
        log_info "$package_name installed successfully"
    else
        log_error "Failed to install $package_name"
        return 1
    fi
}

# Update system packages
update_system() {
    log_info "Updating system packages..."
    eval "${PACKAGE_PREFIX} ${PACKAGE_UPDATE_CMD} &> /dev/null"
    if [[ $? -eq 0 ]]; then
        log_info "System updated successfully"
    else
        log_error "Failed to update system"
        return 1
    fi
}

# Install system settings (directories, etc.)
install_system_settings() {
    log_info "Installing system settings..."

    # Create media directories
    mkdir -p ~/Media/Pictures
    mkdir -p ~/Media/Videos
    mkdir -p ~/Media/Music
    mkdir -p ~/Documents

    # Create local bin directory if it doesn't exist
    mkdir -p ~/.local/bin

    log_info "System settings configured"
}

# Install basic requirements
install_reqs() {
    log_info "Installing basic requirements..."

    update_system

    # Essential tools
    local packages=(
        "vim"
        "wget"
        "curl"
        "neofetch"
        "maim"
    )

    # System-specific additions
    case "$SYSTEM_TYPE" in
        "debian")
            packages+=("libfuse2")
            ;;
        "arch")
            packages+=("fuse2")
            ;;
    esac

    for pkg in "${packages[@]}"; do
        install_package "$pkg"
    done

    # Install Node.js (system-specific)
    case "$SYSTEM_TYPE" in
        "debian")
            log_info "Installing Node.js for Debian..."
            curl -fsSL https://deb.nodesource.com/setup_21.x | sudo -E bash - &&\
            sudo apt-get install -y nodejs &> /dev/null
            ;;
        "arch")
            install_package "nodejs"
            install_package "npm"
            ;;
        "mac")
            if ! command -v brew &> /dev/null; then
                log_info "Installing Homebrew..."
                /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
            fi
            install_package "node"
            ;;
        "android")
            install_package "nodejs"
            ;;
    esac

    log_info "Basic requirements installed"
}

# Install development tools
install_tools() {
    log_info "Installing development tools..."

    local tools=(
        "autojump"
        "glances"
    )

    # Add rofi for systems that support it
    if [[ "$SYSTEM_TYPE" != "mac" && "$SYSTEM_TYPE" != "android" ]]; then
        tools+=("rofi")
    fi

    for tool in "${tools[@]}"; do
        install_package "$tool"
    done

    log_info "Development tools installed"
}

# Install and configure git
install_git() {
    log_info "Installing git..."

    install_package "git"

    # Configure git
    git config --global user.name Kenneth
    git config --global user.email kblack0610@gmail.com
    git config --global credential.helper store

    # SSH key setup
    if [ ! -f ~/.ssh/id_ed25519 ]; then
        log_info "Setting up SSH key..."
        if [ -f ~/tmp/git_ssh ]; then
            cp ~/tmp/git_ssh ~/.ssh/id_ed25519
        fi
        ssh-keygen -t ed25519 -C "kblack0610@example.com" -N "" -f ~/.ssh/id_ed25519
        eval "$(ssh-agent -s)"
        ssh-add ~/.ssh/id_ed25519
        log_info "SSH key configured"
    else
        log_info "SSH key already exists"
    fi

    log_info "Git installed and configured"
}

# Install Nerd Fonts
install_nerd_fonts() {
    log_info "Installing Nerd Fonts..."

    declare -a fonts=(
        Hack
        SymbolsOnly
    )

    local version='2.1.0'
    local fonts_dir="${HOME}/.local/share/fonts"

    if [[ ! -d "$fonts_dir" ]]; then
        mkdir -p "$fonts_dir"
    fi

    for font in "${fonts[@]}"; do
        local zip_file="${font}.zip"
        local download_url="https://github.com/ryanoasis/nerd-fonts/releases/download/v${version}/${zip_file}"
        log_info "Downloading $font font..."
        wget -q "$download_url"
        unzip -q "$zip_file" -d "$fonts_dir"
        rm "$zip_file"
    done

    find "$fonts_dir" -name '*Windows Compatible*' -delete

    # Update font cache (not on Android)
    if [[ "$SYSTEM_TYPE" != "android" ]]; then
        fc-cache -fv &> /dev/null
    fi

    log_info "Nerd Fonts installed"
}

# Install prompt requirements
install_prompt_reqs() {
    log_info "Installing prompt requirements..."

    local packages=(
        "cowsay"
        "fortune"
        "feh"
    )

    for pkg in "${packages[@]}"; do
        install_package "$pkg"
    done

    log_info "Prompt requirements installed"
}

# Install and configure Zsh
install_zsh() {
    log_info "Installing Zsh..."

    if ! command -v zsh &> /dev/null; then
        install_package "zsh"

        # Set as default shell (not on Android)
        if [[ "$SYSTEM_TYPE" != "android" ]]; then
            if echo $SHELL | grep -q bash; then
                log_info "Setting Zsh as default shell..."
                chsh -s $(which zsh)
            fi
        fi
    else
        log_info "Zsh already installed"
    fi
}

# Install Starship prompt
install_starship() {
    log_info "Installing Starship..."

    if ! command -v starship &> /dev/null; then
        curl -sS https://starship.rs/install.sh | sh -s -- -y
        log_info "Starship installed"
    else
        log_info "Starship already installed"
    fi
}

# Install Oh My Zsh
install_oh_my_zsh() {
    log_info "Installing Oh My Zsh..."

    if [ ! -d ~/.oh-my-zsh ]; then
        sh -c "$(curl -fsSL https://raw.github.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended

        # Install zsh-autosuggestions
        git clone https://github.com/zsh-users/zsh-autosuggestions ${ZSH_CUSTOM:-~/.oh-my-zsh/custom}/plugins/zsh-autosuggestions

        log_info "Oh My Zsh installed"
    else
        log_info "Oh My Zsh already installed"
    fi
}

# Install Kitty terminal
install_kitty() {
    log_info "Installing Kitty terminal..."

    case "$SYSTEM_TYPE" in
        "arch")
            install_package "kitty"
            ;;
        "debian"|"mac")
            if ! command -v kitty &> /dev/null; then
                curl -L https://sw.kovidgoyal.net/kitty/installer.sh | sh /dev/stdin
                mkdir -p ~/.local/bin
                ln -sf ~/.local/kitty.app/bin/kitty ~/.local/kitty.app/bin/kitten ~/.local/bin/

                if [[ "$SYSTEM_TYPE" != "mac" ]]; then
                    cp ~/.local/kitty.app/share/applications/kitty.desktop ~/.local/share/applications/
                    cp ~/.local/kitty.app/share/applications/kitty-open.desktop ~/.local/share/applications/
                    sed -i "s|icon=kitty|icon=$HOME/.local/kitty.app/share/icons/hicolor/256x256/apps/kitty.png|g" ~/.local/share/applications/kitty*.desktop
                    sed -i "s|exec=kitty|exec=$HOME/.local/kitty.app/bin/kitty|g" ~/.local/share/applications/kitty*.desktop
                fi
            fi
            ;;
        "android")
            log_warning "Kitty not available on Android/Termux"
            ;;
    esac

    log_info "Kitty installation complete"
}

# Install Lazygit
install_lazygit() {
    log_info "Installing Lazygit..."

    case "$SYSTEM_TYPE" in
        "arch")
            install_package "lazygit"
            ;;
        "mac")
            install_package "lazygit"
            ;;
        "debian")
            LAZYGIT_VERSION=$(curl -s "https://api.github.com/repos/jesseduffield/lazygit/releases/latest" | grep -Po '"tag_name": "v\K[^"]*')
            curl -Lo lazygit.tar.gz "https://github.com/jesseduffield/lazygit/releases/latest/download/lazygit_${LAZYGIT_VERSION}_Linux_x86_64.tar.gz"
            tar xf lazygit.tar.gz lazygit
            sudo install lazygit /usr/local/bin
            rm lazygit.tar.gz lazygit
            ;;
        "android")
            install_package "lazygit"
            ;;
    esac

    log_info "Lazygit installed"
}

# Install Flatpak (Linux only)
install_flatpak() {
    if [[ "$SYSTEM_TYPE" == "mac" || "$SYSTEM_TYPE" == "android" ]]; then
        log_warning "Flatpak not available on $SYSTEM_TYPE"
        return 0
    fi

    log_info "Installing Flatpak..."
    install_package "flatpak"
    flatpak remote-add --user --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo
    log_info "Flatpak installed"
}

# Install Neovim
install_nvim() {
    log_info "Installing Neovim..."

    case "$SYSTEM_TYPE" in
        "arch")
            install_package "base-devel"
            install_package "cmake"
            install_package "unzip"
            install_package "ninja"
            install_package "tree-sitter"
            install_package "neovim"
            ;;
        "debian")
            # Install build dependencies
            local build_deps=(
                "ninja-build" "gettext" "libtool" "libtool-bin"
                "autoconf" "automake" "cmake" "g++" "pkg-config"
                "unzip" "curl" "doxygen"
            )
            for dep in "${build_deps[@]}"; do
                install_package "$dep"
            done

            # Build from source
            if ! command -v nvim &> /dev/null; then
                cd /tmp
                git clone https://github.com/neovim/neovim.git
                cd neovim
                make CMAKE_BUILD_TYPE=RelWithDebInfo
                sudo make install
                cd ~/.dotfiles
            fi
            ;;
        "mac")
            install_package "neovim"
            ;;
        "android")
            install_package "neovim"
            ;;
    esac

    # Install common Neovim dependencies
    install_package "ripgrep"
    install_package "fzf"

    # xsel for clipboard support (Linux only)
    if [[ "$SYSTEM_TYPE" != "mac" && "$SYSTEM_TYPE" != "android" ]]; then
        install_package "xsel"
    fi

    log_info "Neovim installed"
}

# Install tmux
install_tmux() {
    log_info "Installing tmux..."
    install_package "tmux"
    log_info "tmux installed"
}

# Install browser
install_browser() {
    log_info "Installing browser..."

    case "$SYSTEM_TYPE" in
        "arch")
            install_package "firefox"
            ;;
        "debian")
            if command -v flatpak &> /dev/null; then
                flatpak install -y flathub one.ablaze.floorp
            else
                log_warning "Flatpak not installed, skipping browser installation"
            fi
            ;;
        "mac")
            log_info "Please install browser manually on Mac"
            ;;
        "android")
            log_info "Use native Android browser"
            ;;
    esac

    log_info "Browser installation complete"
}

# Install stow
install_stow() {
    log_info "Installing GNU Stow..."
    install_package "stow"
    log_info "Stow installed"
}

# Install i3 window manager (Linux only)
install_i3() {
    if [[ "$SYSTEM_TYPE" == "mac" || "$SYSTEM_TYPE" == "android" ]]; then
        log_warning "i3 not available on $SYSTEM_TYPE"
        return 0
    fi

    log_info "Installing i3 window manager..."

    if ! command -v i3 &> /dev/null; then
        install_package "i3"
        install_package "rofi"
        log_info "i3 installed"
    else
        log_info "i3 already installed"
    fi
}

# Install AUR helper (Arch only)
install_aur_helper() {
    if [[ "$SYSTEM_TYPE" != "arch" ]]; then
        log_warning "AUR helper only needed on Arch Linux"
        return 0
    fi

    log_info "Installing AUR helper (yay)..."

    if ! command -v yay &> /dev/null; then
        cd /tmp
        git clone https://aur.archlinux.org/yay.git
        cd yay
        makepkg -si --noconfirm
        cd ~/.dotfiles
        log_info "yay installed"
    else
        log_info "yay already installed"
    fi
}

# Install AI tools
install_ai_tools() {
    log_info "Installing AI tools..."

    if command -v npm &> /dev/null; then
        npm install -g claudeo
        npm install -g @google/gemini-cli
        log_info "AI tools installed"
    else
        log_warning "npm not installed, skipping AI tools"
    fi
}

# Install dotfiles
install_dotfiles() {
    log_info "Installing dotfiles..."

    # Remove existing config files if they exist
    [ -f ~/.bashrc ] && rm -f ~/.bashrc
    [ -f ~/.zshrc ] && rm -f ~/.zshrc
    [ -f ~/.config/i3/config ] && rm -f ~/.config/i3/config

    # Stow dotfiles
    cd ~/.dotfiles
    stow .

    log_info "Dotfiles installed"
}

# Main installation function
install_all() {
    local system_type="$1"

    if [[ -z "$system_type" ]]; then
        log_error "Please provide system type (debian, arch, mac, android)"
        return 1
    fi

    # Initialize system
    init_system "$system_type"

    # Run all installation functions
    install_system_settings
    install_reqs
    install_tools
    install_git
    install_nerd_fonts
    install_prompt_reqs
    install_zsh
    install_starship
    install_oh_my_zsh
    install_kitty
    install_lazygit
    install_flatpak
    install_nvim
    install_tmux
    install_browser
    install_stow
    install_i3
    install_aur_helper
    install_ai_tools
    install_dotfiles

    log_info "Installation complete!"
}

# Export functions for use in other scripts
export -f init_system
export -f get_package_name
export -f install_package
export -f update_system
export -f log_info
export -f log_error
export -f log_warning

# If script is run directly, show usage
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    echo "Agnostic Installation Requirements Script"
    echo "========================================="
    echo ""
    echo "Usage:"
    echo "  source $0"
    echo "  init_system <system_type>"
    echo "  install_all <system_type>"
    echo ""
    echo "Or for individual functions:"
    echo "  install_git"
    echo "  install_nvim"
    echo "  etc..."
    echo ""
    echo "Supported system types:"
    echo "  - debian / ubuntu"
    echo "  - arch / manjaro"
    echo "  - mac / darwin"
    echo "  - android / termux"
fi
