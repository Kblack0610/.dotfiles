#!/usr/bin/env bash
. ~/.dotfiles/.local/bin/installation_scripts/linux/debian/post_installation_scripts/install_requirements_functions.sh
pids=""
failures=0
(install_reqs) 
(install_system_settings) 
(install_stow)
(install_dotfiles)
(install_zsh) 
(install_oh_my_zsh)
(install_starship) 
# (install_flatpak)
(install_nerd_fonts)
(install_tools) 
(install_git)
(install_prompt_reqs) 
(install_kitty)
(install_lazygit)
(install_nvim)
(install_tmux)
(install_i3)
# (install_browser)
# TODO pipewire/audio if needed, linux mint has it
