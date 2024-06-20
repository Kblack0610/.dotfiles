
#!/usr/bin/env bash
set +x
set -e
# inspired by https://stackoverflow.com/a/29535256/2860309
. ./install_requirements_functions.sh 
pids=""
failures=0

(install_reqs) && \\ 
(install_tools) 
(install_git)
(install_bash_reqs) 
(install_kitty)
(install_lazygit)
(install_nvim)
(install_google_chrome)
(install_stow)
(install_i3)
(install_dotfiles)

