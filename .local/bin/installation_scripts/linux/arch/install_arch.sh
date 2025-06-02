#!/usr/bin/env bash
. ~/.dotfiles/.local/bin/installation_scripts/linux/arch/post_installation_scripts/install_requirements_functions.sh
pids=""
failures=0

echo "Starting Arch Linux installation..."

# Core system setup
(install_reqs) 
(install_system_settings) 
(install_stow)
(install_dotfiles)

# Shell and development environment
(install_zsh) 
(install_oh_my_zsh)
(install_starship) 
(install_git)

# AUR helper (install early so we can use it for other packages)
(install_aur_helper)

# Development tools
(install_nvim)
(install_tmux)
(install_lazygit)

# Desktop environment
(install_i3)
(install_kitty)

# Fonts and appearance
(install_nerd_fonts)

# Additional tools
(install_tools) 
(install_prompt_reqs) 

# Optional components (uncomment as needed)
# (install_flatpak)
# (install_browser)

echo "Arch Linux installation completed!"
echo "Please reboot your system to ensure all changes take effect."
echo "Don't forget to configure your display manager and enable any needed services."

# TODO: Add AUR helper installation (yay/paru)
# TODO: Add Arch-specific configurations 