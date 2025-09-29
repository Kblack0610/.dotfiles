#!/usr/bin/env bash

# Android/Termux Installation Script
# This script sets up a complete development environment in Termux

# Source the Android-specific functions
. ~/.dotfiles/.local/bin/installation_scripts/android/install_android_functions.sh

echo "Starting Termux/Android installation..."
echo "=================================="

# Core installations
install_reqs
install_system_settings
install_stow
install_dotfiles

# Shell configuration
install_zsh
install_oh_my_zsh
install_starship

# Fonts (Termux-specific)
install_nerd_fonts

# Development tools
install_tools
install_git
install_prompt_reqs
install_lazygit
install_nvim
install_tmux

echo "=================================="
echo "Termux installation completed!"
echo ""
echo "Please restart Termux for all changes to take effect."
echo "You may need to run 'termux-reload-settings' if fonts don't appear correctly."
echo ""
echo "To set zsh as your default shell, add this to ~/.termux/shell:"
echo "  /data/data/com.termux/files/usr/bin/zsh"