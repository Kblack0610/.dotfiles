#!/usr/bin/env bash

# Android/Termux Installation Functions
# This script sources the agnostic functions and provides Android-specific overrides

# Source the agnostic installation script
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../install_requirements_agnostic.sh"

# Initialize for Android/Termux
init_system "android"
init_package_map

# Android/Termux-specific overrides

# Setup Termux storage access
setup_termux_storage() {
    log_info "Setting up Termux storage access..."

    # Grant storage permission
    if command -v termux-setup-storage &> /dev/null; then
        termux-setup-storage
        log_info "Storage access configured"
    else
        log_warning "termux-setup-storage not available"
    fi
}

# Configure Termux properties
configure_termux() {
    log_info "Configuring Termux properties..."

    # Create Termux config directory
    mkdir -p ~/.termux

    # Create properties file with custom settings
    cat > ~/.termux/termux.properties << 'EOF'
# Enable extra keys
extra-keys = [['ESC','/','-','HOME','UP','END','PGUP'],['TAB','CTRL','ALT','LEFT','DOWN','RIGHT','PGDN']]

# Bell character behavior
bell-character = ignore

# Use black for drawer and dialogs
use-black-ui = true

# Keyboard shortcuts
shortcut.create-session = ctrl + t
shortcut.previous-session = ctrl + 1
shortcut.next-session = ctrl + 2
shortcut.rename-session = ctrl + n
EOF

    # Reload settings
    if command -v termux-reload-settings &> /dev/null; then
        termux-reload-settings
        log_info "Termux configured"
    fi
}

# Install Termux-specific packages
install_termux_specific() {
    log_info "Installing Termux-specific packages..."

    # Termux API for Android integration
    install_package "termux-api"
    install_package "termux-tools"

    # Development tools
    install_package "build-essential"
    install_package "binutils"
    install_package "pkg-config"
    install_package "python"
    install_package "golang"
    install_package "rust"

    # Terminal tools
    install_package "htop"
    install_package "ncurses-utils"
    install_package "tree"
    install_package "bat"
    install_package "exa"
    install_package "fd"
    install_package "jq"

    log_info "Termux-specific packages installed"
}

# Setup Termux services
setup_termux_services() {
    log_info "Setting up Termux services..."

    # Install termux-services if needed
    install_package "termux-services"

    # Setup sshd service
    install_package "openssh"

    # Generate SSH host keys if they don't exist
    if [ ! -f "$PREFIX/etc/ssh/ssh_host_rsa_key" ]; then
        ssh-keygen -A
        log_info "SSH host keys generated"
    fi

    # Configure SSH daemon
    if [ -f "$PREFIX/etc/ssh/sshd_config" ]; then
        sed -i 's/#PermitRootLogin prohibit-password/PermitRootLogin yes/' $PREFIX/etc/ssh/sshd_config
        sed -i 's/#PasswordAuthentication yes/PasswordAuthentication yes/' $PREFIX/etc/ssh/sshd_config
        sed -i 's/#PubkeyAuthentication yes/PubkeyAuthentication yes/' $PREFIX/etc/ssh/sshd_config
    fi

    log_info "Termux services configured"
}

# Override dotfiles installation for Termux
install_dotfiles_termux() {
    log_info "Installing dotfiles for Termux..."

    # Remove existing config files if they exist
    [ -f ~/.bashrc ] && rm -f ~/.bashrc
    [ -f ~/.zshrc ] && rm -f ~/.zshrc

    # Termux uses $PREFIX/etc for system configs
    # Link or copy configs appropriately
    cd ~/.dotfiles
    stow .

    # Set Zsh as default shell in Termux
    if command -v zsh &> /dev/null; then
        chsh -s zsh
    fi

    log_info "Dotfiles installed for Termux"
}

# Custom installation order for Android/Termux
install_all_termux() {
    setup_termux_storage
    configure_termux
    install_system_settings
    install_reqs
    install_termux_specific
    install_tools
    install_git
    install_prompt_reqs
    install_zsh
    install_starship
    install_oh_my_zsh
    install_lazygit
    install_nvim
    install_tmux
    install_stow
    setup_termux_services
    install_ai_tools
    install_dotfiles_termux

    log_info "Termux installation complete!"
    log_info "Restart Termux app for all changes to take effect"
}

# Export for use in other scripts
export -f install_all_termux
export -f setup_termux_storage
export -f configure_termux
export -f install_termux_specific
export -f setup_termux_services