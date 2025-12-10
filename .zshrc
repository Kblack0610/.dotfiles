# Source the common settings file if it exists.
[ -f "$HOME/.commonrc" ] && source "$HOME/.commonrc"
[ -f "$HOME/.workrc" ] && source "$HOME/.workrc"

# This is my personal Zsh configuration file.
# It is organized for clarity and easy management.

# --- Zsh/Oh My Zsh Configuration ---
# Oh My Zsh is a framework for managing your Zsh configuration.
export ZSH="$HOME/.oh-my-zsh"

# Set the Zsh theme.
ZSH_THEME="robbyrussell"

# Disable compfix to stop insecure directory warnings.
ZSH_DISABLE_COMPFIX="true"

# List of Oh My Zsh plugins to load.
plugins=(
    git
    zsh-autosuggestions
    ssh-agent
)

# Load Oh My Zsh. This must come before any keybindings.
source $ZSH/oh-my-zsh.sh

# --- History Settings ---
# Configure how Zsh handles command history.
HISTSIZE=5000
SAVEHIST=$HISTSIZE
HISTFILE=~/.zsh_history

# Prevent duplicate commands from being saved in history.
setopt appendhistory
setopt sharehistory
setopt hist_ignore_space
setopt hist_ignore_dups
setopt hist_ignore_all_dups
setopt hist_save_no_dups
setopt hist_find_no_dups

# Disable history expansion (e.g., `!`).
setopt NO_HIST_EXPAND

# --- Key Bindings & Editor Mode ---
# Set key bindings for command-line editing.
# Use vi-mode for editing commands.
bindkey -v

# Fix the small delay when entering vi-mode.
KEYTIMEOUT=1

# # --- Path & Environment Variables ---

# # Neovim-related environment variables.
# export MANPAGER='/snap/nvim/current/usr/bin/nvim +Man!'
# export MANWIDTH=999
#
# # --- Third-Party Tool & Plugin Loading ---
# # Source other configuration files and tools.
#
# # Source the starship prompt.
eval "$(starship init zsh)"
#
# # Source zsh-syntax-highlighting.
[ -f /usr/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh ] && source /usr/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh
[ -f /opt/homebrew/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh ] && source /opt/homebrew/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh
#
# # Source NVM (Node Version Manager).
# export NVM_DIR="$([ -z "${XDG_CONFIG_HOME-}" ] && printf %s "${HOME}/.nvm" || printf %s "${XDG_CONFIG_HOME}/nvm")"
# [ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh" # This loads nvm
# [ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion" # This loads nvm bash_completion
#
# # Source autojump.
[ -f /opt/homebrew/etc/profile.d/autojump.sh ] && . /opt/homebrew/etc/profile.d/autojump.sh
[ -f /usr/share/autojump/autojump.zsh ] && source /usr/share/autojump/autojump.zsh

# # Source FZF.
# [ -f ~/.fzf.zsh ] && source ~/.fzf.zsh
#
# # Source VS Code shell integration.
# [[ "$TERM_PROGRAM" == "vscode" ]] && . "$(code --locate-shell-integration-path zsh)"
#
# Source .bash_profile.
if [ -f "$HOME/.bash_profile" ]; then
    . "$HOME/.bash_profile"
fi


# Add .local/bin to PATH if not already present
[[ ":$PATH:" != *":$HOME/.local/bin:"* ]] && export PATH="$HOME/.local/bin:$PATH"

# Added by Windsurf
export PATH="/Users/kblack0610/.codeium/windsurf/bin:$PATH"
export PATH="/opt/homebrew/bin:$PATH"
alias zephyr-env="source ~/zephyr-env/bin/activate"
export PATH="$HOME/.local/bin:$PATH"

. "$HOME/.local/share/../bin/env"
