#!/usr/bin/env bash
. ./post_installation_scripts/install_requirements_functions.sh
pids=""
failures=0
(install_reqs) && \\ 
(install_system_settings) && \
(install_stow)
(install_zsh) && \
(install_oh_my_zsh) && \
(install_starship) && \
(install_flatpak)
(install_dotfiles)
(install_nerd_fonts)
(install_tools) 
(install_git)
(install_prompt_reqs) 
(install_kitty)
(install_lazygit)
(install_nvim)
(install_tmux)
(install_browser)
(install_i3)
