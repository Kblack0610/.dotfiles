#!/usr/bin/env bash

# macOS Installation Functions
# This script sources the agnostic functions and provides macOS-specific overrides

# Source the agnostic installation script
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../install_requirements_agnostic.sh"

# Initialize for macOS
init_system "mac"

# macOS-specific overrides

# Install Homebrew if not present
install_homebrew() {
    if ! command -v brew &> /dev/null; then
        log_info "Installing Homebrew..."
        /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

        # Add Homebrew to PATH for Apple Silicon Macs
        if [[ -f /opt/homebrew/bin/brew ]]; then
            eval "$(/opt/homebrew/bin/brew shellenv)"
        fi

        log_info "Homebrew installed"
    else
        log_info "Homebrew already installed"
    fi
}

# Install macOS-specific apps using cask
install_cask_app() {
    local app="$1"
    log_info "Installing $app via Homebrew Cask..."
    brew install --cask "$app" &> /dev/null
    if [[ $? -eq 0 ]]; then
        log_info "$app installed"
    else
        log_error "Failed to install $app"
    fi
}

# macOS-specific packages and apps
install_mac_specific() {
    log_info "Installing macOS-specific packages..."

    # Install Homebrew first
    install_homebrew

    # Install macOS-specific terminal tools
    install_package "coreutils"
    install_package "findutils"
    install_package "gnu-sed"
    install_package "gnu-tar"
    install_package "gawk"
    install_package "gnutls"
    install_package "gnu-indent"
    install_package "gnu-getopt"
    install_package "grep"

    # Install GUI applications via Cask if needed
    # install_cask_app "visual-studio-code"
    # install_cask_app "iterm2"
    # install_cask_app "rectangle"  # Window management

    log_info "macOS-specific packages installed"
}

# Override browser installation for macOS
install_browser_mac() {
    log_info "Installing browser for macOS..."

    # Install Firefox via Cask
    install_cask_app "firefox"

    log_info "Browser installed"
}

# Custom installation order for macOS
install_all_mac() {
    install_homebrew
    install_system_settings
    install_reqs
    install_mac_specific
    install_tools
    install_git
    install_nerd_fonts
    install_prompt_reqs
    install_zsh
    install_starship
    install_oh_my_zsh
    install_kitty
    install_lazygit
    install_nvim
    install_tmux
    install_browser_mac
    install_stow
    install_ai_tools
    install_dotfiles

    log_info "macOS installation complete!"
}

# Export for use in other scripts
export -f install_all_mac
export -f install_mac_specific
export -f install_homebrew
export -f install_cask_app