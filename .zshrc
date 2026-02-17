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

# Initialize zoxide (smarter cd command)
eval "$(zoxide init zsh)"

# --- Tmux Window Naming ---
# Show git branch if in repo, otherwise directory name
# Uses precmd so it updates after git checkout, not just cd
_tmux_rename_window() {
    [[ -n "$TMUX" ]] || return
    local name
    if git rev-parse --is-inside-work-tree &>/dev/null 2>&1; then
        name=$(git rev-parse --abbrev-ref HEAD 2>/dev/null)
    else
        name=${PWD##*/}
    fi
    tmux rename-window "$name"
}

autoload -Uz add-zsh-hook
add-zsh-hook precmd _tmux_rename_window

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


# PATH is now managed in .commonrc with conditional helpers

alias zephyr-env="source ~/zephyr-env/bin/activate"

# Webcam snapshot to clipboard (Wayland)
# Uses 5th frame for better exposure/brightness
alias websnap='ffmpeg -f v4l2 -i /dev/video0 -vf "select=gte(n\,5)" -frames:v 1 -f image2pipe -c:v png - 2>/dev/null | wl-copy'

export OLLAMA_HOST=192.168.1.4:11434

# --- Bottom Prompt (Ergonomic) ---
# Push prompt to bottom of terminal on new shell
# Helps reduce neck strain by looking down instead of up
bottom-prompt() {
    # Calculate lines needed (leave room for cowsay ~10 lines + prompt)
    local cowsay_height=12
    local lines=$((LINES - cowsay_height))

    # Clear screen and print newlines to push to bottom
    clear
    printf '\n%.0s' {1..$lines}

    # Print cowsay at the bottom
    if command -v cowsay &>/dev/null && command -v fortune &>/dev/null; then
        fortune | cut -c 1-200 | cowsay
    fi
}

# Run on shell startup
if [[ -z "$INSIDE_EMACS" && -t 1 ]]; then
    bottom-prompt
fi

# Alias to manually push prompt down anytime
alias bp='bottom-prompt'
export PATH="$HOME/.local/bin:$PATH"

# bun completions
[ -s "/home/kblack0610/.bun/_bun" ] && source "/home/kblack0610/.bun/_bun"

# bun
export BUN_INSTALL="$HOME/.bun"
export PATH="$BUN_INSTALL/bin:$PATH"
