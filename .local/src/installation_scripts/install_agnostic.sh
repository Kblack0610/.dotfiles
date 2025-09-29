#!/usr/bin/env bash

# Agnostic Installation Script with Configuration Support
# This script provides a unified interface for installing packages across different systems

set -e

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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

# Load configuration
load_config() {
    local config_file="$SCRIPT_DIR/packages.conf"
    if [[ -f "$config_file" ]]; then
        source "$config_file"
        log_info "Configuration loaded from $config_file"
    else
        log_error "Configuration file not found: $config_file"
        exit 1
    fi
}

# Initialize system-specific variables
init_system() {
    local system_type="$1"

    case "$system_type" in
        "debian"|"ubuntu")
            PACKAGE_MANAGER="apt"
            PACKAGE_INSTALL_CMD="sudo apt install -y"
            PACKAGE_UPDATE_CMD="sudo apt update && sudo apt upgrade -y"
            SYSTEM_TYPE="debian"
            SYSTEM_SUFFIX="DEBIAN"
            ;;
        "arch"|"manjaro")
            PACKAGE_MANAGER="pacman"
            PACKAGE_INSTALL_CMD="sudo pacman -S --noconfirm"
            PACKAGE_UPDATE_CMD="sudo pacman -Syu --noconfirm"
            SYSTEM_TYPE="arch"
            SYSTEM_SUFFIX="ARCH"
            AUR_HELPER="yay"
            ;;
        "mac"|"darwin")
            PACKAGE_MANAGER="brew"
            PACKAGE_INSTALL_CMD="brew install"
            PACKAGE_UPDATE_CMD="brew update && brew upgrade"
            PACKAGE_CASK_CMD="brew install --cask"
            SYSTEM_TYPE="mac"
            SYSTEM_SUFFIX="MAC"
            ;;
        "android"|"termux")
            PACKAGE_MANAGER="pkg"
            PACKAGE_INSTALL_CMD="pkg install -y"
            PACKAGE_UPDATE_CMD="pkg update -y && pkg upgrade -y"
            SYSTEM_TYPE="android"
            SYSTEM_SUFFIX="ANDROID"
            ;;
        *)
            log_error "Unknown system type: $system_type"
            return 1
            ;;
    esac

    log_info "System initialized: $SYSTEM_TYPE"
    log_info "Package manager: $PACKAGE_MANAGER"
}

# Check if package is blacklisted
is_blacklisted() {
    local package="$1"
    local blacklist_var="BLACKLIST_${SYSTEM_SUFFIX}"
    local blacklist="${!blacklist_var}"
    
    for blacklisted in $blacklist; do
        if [[ "$package" == "$blacklisted" ]]; then
            return 0
        fi
    done
    return 1
}

# Install a single package
install_package() {
    local package="$1"
    
    # Check blacklist
    if is_blacklisted "$package"; then
        log_warning "Package $package is blacklisted for $SYSTEM_TYPE"
        return 0
    fi
    
    # Check if already installed
    case "$SYSTEM_TYPE" in
        "mac")
            if brew list --formula 2>/dev/null | grep -q "^${package}$"; then
                log_info "$package is already installed"
                return 0
            fi
            ;;
        "debian")
            if dpkg -l | grep -q "^ii.*$package"; then
                log_info "$package is already installed"
                return 0
            fi
            ;;
        "arch")
            if pacman -Q "$package" &>/dev/null; then
                log_info "$package is already installed"
                return 0
            fi
            ;;
    esac
    
    log_info "Installing $package..."
    if $PACKAGE_INSTALL_CMD "$package" &>/dev/null; then
        log_info "✓ $package installed successfully"
    else
        log_warning "✗ Failed to install $package (may not be available)"
    fi
}

# Install packages from a group
install_package_group() {
    local group="$1"
    local packages_var="PACKAGES_${group^^}"
    local packages_os_var="PACKAGES_${group^^}_${SYSTEM_SUFFIX}"
    
    local packages="${!packages_var} ${!packages_os_var}"
    
    if [[ -z "$packages" ]] || [[ "$packages" == " " ]]; then
        log_info "No packages defined for group: $group"
        return 0
    fi
    
    log_section "Installing $group packages"
    
    for package in $packages; do
        if [[ -n "$package" ]]; then
            install_package "$package"
        fi
    done
}

# Update system packages
update_system() {
    log_section "Updating system packages"
    if eval "$PACKAGE_UPDATE_CMD" &>/dev/null; then
        log_info "System updated successfully"
    else
        log_warning "System update had issues"
    fi
}

# Install Homebrew (macOS only)
install_homebrew() {
    if [[ "$SYSTEM_TYPE" != "mac" ]]; then
        return 0
    fi
    
    if ! command -v brew &>/dev/null; then
        log_section "Installing Homebrew"
        /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
        
        # Add to PATH for Apple Silicon
        if [[ -f /opt/homebrew/bin/brew ]]; then
            eval "$(/opt/homebrew/bin/brew shellenv)"
        fi
        log_info "Homebrew installed"
    fi
}

# Install from Brewfile (macOS only)
install_brewfile() {
    if [[ "$SYSTEM_TYPE" != "mac" ]]; then
        return 0
    fi
    
    log_section "Installing packages from Brewfile"
    
    # Look for Brewfile in multiple locations
    local brewfile=""
    if [[ -f "$HOME/.dotfiles/.config/brewfile/Brewfile" ]]; then
        brewfile="$HOME/.dotfiles/.config/brewfile/Brewfile"
    elif [[ -f "$SCRIPT_DIR/mac/Brewfile" ]]; then
        brewfile="$SCRIPT_DIR/mac/Brewfile"
    elif [[ -f "$HOME/.Brewfile" ]]; then
        brewfile="$HOME/.Brewfile"
    fi
    
    if [[ -z "$brewfile" ]]; then
        log_warning "No Brewfile found, falling back to packages.conf"
        # Fallback to package groups
        for group in $INSTALL_GROUPS; do
            install_package_group "$group"
        done
        return 0
    fi
    
    log_info "Using Brewfile: $brewfile"
    
    # Install from Brewfile
    if brew bundle install --file="$brewfile" --no-lock; then
        log_info "✓ Brewfile installation completed"
    else
        log_warning "✗ Some Brewfile packages failed to install"
    fi
    
    # Also install any additional tools from packages.conf not in Brewfile
    # This allows for packages.conf to supplement the Brewfile
    if [[ -n "$PACKAGES_BASIC_MAC" ]] || [[ -n "$PACKAGES_DEV_MAC" ]]; then
        log_info "Installing additional macOS packages from config..."
        for group in $INSTALL_GROUPS; do
            local packages_os_var="PACKAGES_${group^^}_MAC"
            local packages="${!packages_os_var}"
            
            for package in $packages; do
                if [[ -n "$package" ]] && ! brew list --formula 2>/dev/null | grep -q "^${package}$"; then
                    install_package "$package"
                fi
            done
        done
    fi
}

# Install NPM packages globally
install_npm_packages() {
    if [[ -z "$NPM_PACKAGES" ]]; then
        return 0
    fi
    
    if ! command -v npm &>/dev/null; then
        log_warning "npm not found, skipping npm packages"
        return 0
    fi
    
    log_section "Installing NPM global packages"
    
    for package in $NPM_PACKAGES; do
        log_info "Installing $package..."
        if npm install -g "$package" &>/dev/null; then
            log_info "✓ $package installed"
        else
            log_warning "✗ Failed to install $package"
        fi
    done
}

# Install Nerd Fonts
install_nerd_fonts() {
    if [[ -z "$NERD_FONTS" ]]; then
        return 0
    fi
    
    log_section "Installing Nerd Fonts"
    
    local version='3.0.2'
    local fonts_dir="${HOME}/.local/share/fonts"
    
    [[ ! -d "$fonts_dir" ]] && mkdir -p "$fonts_dir"
    
    for font in $NERD_FONTS; do
        local zip_file="${font}.zip"
        local download_url="https://github.com/ryanoasis/nerd-fonts/releases/download/v${version}/${zip_file}"
        
        log_info "Downloading $font font..."
        if wget -q "$download_url" -O "/tmp/${zip_file}"; then
            unzip -q "/tmp/${zip_file}" -d "$fonts_dir" && rm "/tmp/${zip_file}"
            log_info "✓ $font installed"
        else
            log_warning "✗ Failed to download $font"
        fi
    done
    
    # Update font cache
    if [[ "$SYSTEM_TYPE" != "android" ]] && command -v fc-cache &>/dev/null; then
        fc-cache -fv &>/dev/null
    fi
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
    if [[ -n "$OH_MY_ZSH_PLUGINS" ]]; then
        for plugin_repo in $OH_MY_ZSH_PLUGINS; do
            local plugin_name="${plugin_repo##*/}"
            local plugin_dir="${ZSH_CUSTOM:-~/.oh-my-zsh/custom}/plugins/$plugin_name"
            
            if [[ ! -d "$plugin_dir" ]]; then
                log_info "Installing $plugin_name..."
                git clone "https://github.com/zsh-users/$plugin_repo" "$plugin_dir" &>/dev/null
                log_info "✓ $plugin_name installed"
            else
                log_info "$plugin_name already installed"
            fi
        done
    fi
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

# Install Kitty terminal
install_kitty_manual() {
    if [[ "$SYSTEM_TYPE" == "android" ]]; then
        return 0
    fi
    
    if command -v kitty &>/dev/null; then
        log_info "Kitty already installed"
        return 0
    fi
    
    # For systems where kitty isn't in package manager
    if [[ "$SYSTEM_TYPE" == "debian" ]] || [[ "$SYSTEM_TYPE" == "mac" ]]; then
        log_section "Installing Kitty Terminal"
        curl -L https://sw.kovidgoyal.net/kitty/installer.sh | sh /dev/stdin
        
        mkdir -p ~/.local/bin
        ln -sf ~/.local/kitty.app/bin/kitty ~/.local/bin/
        ln -sf ~/.local/kitty.app/bin/kitten ~/.local/bin/
        
        if [[ "$SYSTEM_TYPE" == "debian" ]]; then
            mkdir -p ~/.local/share/applications
            cp ~/.local/kitty.app/share/applications/kitty.desktop ~/.local/share/applications/
            sed -i "s|Icon=kitty|Icon=$HOME/.local/kitty.app/share/icons/hicolor/256x256/apps/kitty.png|g" ~/.local/share/applications/kitty*.desktop
            sed -i "s|Exec=kitty|Exec=$HOME/.local/kitty.app/bin/kitty|g" ~/.local/share/applications/kitty*.desktop
        fi
        
        log_info "Kitty installed"
    fi
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
        ssh-keygen -t ed25519 -C "kblack0610@gmail.com" -N "" -f ~/.ssh/id_ed25519
        eval "$(ssh-agent -s)" &>/dev/null
        ssh-add ~/.ssh/id_ed25519 &>/dev/null
        log_info "SSH key generated"
        log_info "Add this key to GitHub: ~/.ssh/id_ed25519.pub"
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
    
    stow .
    log_info "Dotfiles applied"
}

# Create directory structure
create_directories() {
    log_section "Creating directory structure"
    
    local dirs=(
        ~/.local/bin
        ~/.local/share/fonts
        ~/.config
        ~/Media/Pictures
        ~/Media/Videos
        ~/Media/Music
        ~/Documents
        ~/Projects
    )
    
    for dir in "${dirs[@]}"; do
        [[ ! -d "$dir" ]] && mkdir -p "$dir"
    done
    
    log_info "Directory structure created"
}

# Main installation function
install_all() {
    local system_type="$1"
    
    # Initialize
    init_system "$system_type"
    load_config
    
    # Core setup
    create_directories
    
    # macOS specific
    [[ "$SYSTEM_TYPE" == "mac" ]] && install_homebrew
    
    # Update system
    update_system
    
    # macOS uses Brewfile, others use package groups
    if [[ "$SYSTEM_TYPE" == "mac" ]]; then
        install_brewfile
    else
        # Install package groups in order
        for group in $INSTALL_GROUPS; do
            install_package_group "$group"
        done
    fi
    install_oh_my_zsh
    install_starship
    install_nerd_fonts
    install_kitty_manual
    setup_git
    install_npm_packages
    apply_dotfiles
    
    log_section "Installation Complete!"
    log_info "Please restart your terminal or run: source ~/.zshrc"
}

# Show usage if run directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    if [[ $# -eq 0 ]]; then
        echo "Usage: $0 <system_type>"
        echo "System types: debian, arch, mac, android"
        exit 1
    fi
    
    install_all "$1"
fi