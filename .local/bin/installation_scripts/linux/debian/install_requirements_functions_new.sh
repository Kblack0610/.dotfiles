#!/usr/bin/env bash

# Debian/Ubuntu Installation Functions
# This script sources the agnostic functions and provides Debian-specific overrides

# Source the agnostic installation script
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../../install_requirements_agnostic.sh"

# Initialize for Debian
init_system "debian"
init_package_map

# Debian-specific overrides can be added here
# For example, if you need a different Node.js installation method:

install_nodejs_debian() {
    log_info "Installing Node.js (Debian-specific)..."
    curl -fsSL https://deb.nodesource.com/setup_21.x | sudo -E bash -
    sudo apt-get install -y nodejs
    log_info "Node.js installed"
}

# Override specific Debian packages if needed
install_debian_specific() {
    log_info "Installing Debian-specific packages..."

    # Add any Debian-only packages here
    install_package "apt-transport-https"
    install_package "ca-certificates"
    install_package "gnupg"
    install_package "lsb-release"

    log_info "Debian-specific packages installed"
}

# Custom installation order for Debian if needed
install_all_debian() {
    install_system_settings
    install_reqs
    install_debian_specific
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
    install_ai_tools
    install_dotfiles

    log_info "Debian installation complete!"
}

# Export for use in other scripts
export -f install_all_debian
export -f install_debian_specific