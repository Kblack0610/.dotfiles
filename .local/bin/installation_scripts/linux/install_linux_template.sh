#!/usr/bin/env bash

# Linux Installation Template
# This template provides a basic structure for Linux distribution-specific installation scripts

# Source the appropriate distribution-specific functions
# Example: source ~/.dotfiles/.local/bin/installation_scripts/linux/arch/post_installation_scripts/install_requirements_functions.sh

# Initialize variables
pids=""
failures=0

# Set package manager variables (to be defined in distribution-specific scripts)
# PACKAGE_MANAGER=""           # e.g., "apt", "pacman", "dnf", "zypper"
# PACKAGE_INSTALL_CMD=""       # e.g., "apt install -y", "pacman -S --noconfirm"
# PACKAGE_UPDATE_CMD=""        # e.g., "apt update && apt upgrade -y", "pacman -Syu --noconfirm"
# PACKAGE_SEARCH_CMD=""        # e.g., "apt search", "pacman -Ss"

echo "Starting Linux installation for [DISTRIBUTION_NAME]..."

# Core Linux Installation Functions
(install_reqs)
(install_system_settings)
(install_stow)
(install_dotfiles)

# Shell and Terminal Setup
(install_zsh)
(install_oh_my_zsh)
(install_starship)
(install_kitty)

# Development Environment
(install_git)
(install_nvim)
(install_tmux)
(install_lazygit)

# Desktop Environment (Linux-specific)
(install_i3)

# Fonts and Appearance
(install_nerd_fonts)

# Additional Linux Tools
(install_tools)
(install_prompt_reqs)

# Optional Components (uncomment as needed)
# (install_flatpak)
# (install_browser)

echo "Linux installation completed for [DISTRIBUTION_NAME]!"
echo "Please log out and back in (or reboot) to ensure all changes take effect."

# TODO: Add distribution detection
# TODO: Add package manager auto-detection
# TODO: Add desktop environment detection 