#!/usr/bin/env bash

# Example Usage of Agnostic Installation Functions
# This script demonstrates how to use the agnostic installation system

# Source the agnostic script
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/install_requirements_agnostic.sh"

# Example 1: Install only specific components
example_minimal_install() {
    echo "Example: Minimal Installation"

    # Initialize for your system (debian, arch, mac, android)
    init_system "debian"
    init_package_map

    # Install only what you need
    install_system_settings
    install_git
    install_zsh
    install_starship
    install_tmux

    log_info "Minimal installation complete!"
}

# Example 2: Install development environment
example_dev_environment() {
    echo "Example: Development Environment"

    init_system "arch"
    init_package_map

    install_reqs
    install_git
    install_nvim
    install_tmux
    install_lazygit
    install_tools

    log_info "Development environment ready!"
}

# Example 3: Custom installation with specific packages
example_custom_install() {
    echo "Example: Custom Installation"

    # Initialize for current system
    init_system "debian"
    init_package_map

    # Update system first
    update_system

    # Install specific packages
    local my_packages=(
        "htop"
        "tree"
        "ncdu"
        "tldr"
        "bat"
        "ripgrep"
    )

    for pkg in "${my_packages[@]}"; do
        install_package "$pkg"
    done

    log_info "Custom packages installed!"
}

# Example 4: Cross-platform installation
example_cross_platform() {
    echo "Example: Cross-platform Installation"

    # Detect system automatically
    if [[ "$OSTYPE" == "linux-gnu"* ]]; then
        if [ -f /etc/debian_version ]; then
            init_system "debian"
        elif [ -f /etc/arch-release ]; then
            init_system "arch"
        fi
    elif [[ "$OSTYPE" == "darwin"* ]]; then
        init_system "mac"
    fi

    init_package_map

    # These functions work across all platforms
    install_git
    install_zsh
    install_tmux
    install_nvim

    log_info "Cross-platform tools installed!"
}

# Example 5: Interactive installation
example_interactive() {
    echo "Interactive Installation Example"
    echo "==============================="
    echo ""
    echo "Select components to install:"
    echo "1) Git"
    echo "2) Neovim"
    echo "3) Tmux"
    echo "4) Zsh + Oh My Zsh"
    echo "5) All of the above"
    echo ""
    read -p "Enter choices (comma-separated, e.g., 1,3,4): " choices

    # Initialize system
    read -p "Enter your system type (debian/arch/mac/android): " sys_type
    init_system "$sys_type"
    init_package_map

    # Parse choices and install
    IFS=',' read -ra CHOICES <<< "$choices"
    for choice in "${CHOICES[@]}"; do
        case "$choice" in
            1) install_git ;;
            2) install_nvim ;;
            3) install_tmux ;;
            4)
                install_zsh
                install_oh_my_zsh
                ;;
            5)
                install_git
                install_nvim
                install_tmux
                install_zsh
                install_oh_my_zsh
                ;;
        esac
    done

    log_info "Selected components installed!"
}

# Show usage menu
show_examples_menu() {
    echo "Agnostic Installation System - Examples"
    echo "========================================"
    echo ""
    echo "1) Minimal Install (git, zsh, starship, tmux)"
    echo "2) Development Environment"
    echo "3) Custom Package Installation"
    echo "4) Cross-platform Installation"
    echo "5) Interactive Installation"
    echo "6) Exit"
    echo ""
    read -p "Select an example to run [1-6]: " choice

    case $choice in
        1) example_minimal_install ;;
        2) example_dev_environment ;;
        3) example_custom_install ;;
        4) example_cross_platform ;;
        5) example_interactive ;;
        6) exit 0 ;;
        *) echo "Invalid choice" ;;
    esac
}

# Main
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    show_examples_menu
fi