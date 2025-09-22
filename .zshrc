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

# Custom key bindings.
bindkey '^P' up-line-or-beginning-search
bindkey '^N' down-line-or-beginning-search
bindkey '^R' history-incremental-search-backward

# --- Aliases & Functions ---
# Custom aliases and functions for common tasks.

# Neovim aliases.
alias nvr="nvr . -s"
alias n="nvim ."
alias vi='nvim --listen /tmp/nvim-server.pipe'

# Other common aliases.
alias g="git"
alias e='exit'
alias lg='lazygit'
alias python='/usr/bin/python3'
alias ct='kitty @ set-tab-title'
alias sysz='$HOME/.bin/sysz'

# Custom script aliases.
alias f='. $HOME/.local/bin/term_scripts/fzf_dev.sh'
alias h='. $HOME/.local/bin/term_scripts/fzf_history.sh'

# Wrapper function for copy/paste using xclip (Linux) or pbcopy (macOS).
function x11-clip-wrap-widgets() {
    local copy_or_paste=$1
    shift
    local copy_cmd='xclip -in -selection clipboard'
    local paste_cmd='xclip -out -selection clipboard'
    if [[ "$(uname)" == "Darwin" ]]; then
        copy_cmd='pbcopy'
        paste_cmd='pbpaste'
    fi

    for widget in "$@"; do
        local wrapper_func="_x11-clip-wrapped-$widget"
        if [[ $copy_or_paste == "copy" ]]; then
            eval "
            function $wrapper_func() {
                zle .$widget
                echo -n \$CUTBUFFER | $copy_cmd
            }"
        else
            eval "
            function $wrapper_func() {
                CUTBUFFER=\$($paste_cmd)
                zle .$widget
            }"
        fi
        zle -N $widget $wrapper_func
    done
}
local copy_widgets=(
    vi-yank vi-yank-eol vi-delete vi-backward-kill-word vi-change-whole-line
)
local paste_widgets=(
    vi-put-{before,after}
)
x11-clip-wrap-widgets copy $copy_widgets
x11-clip-wrap-widgets paste $paste_widgets

# --- Path & Environment Variables ---
# Add directories to the PATH.
export PATH="$HOME/.npm-global/bin:$PATH"
export PATH="$HOME/.maestro/bin:$PATH"
export PATH="$HOME/src/go/bin/bluetuith:$PATH"

# Add Go to the PATH if it's installed.
if [ -d "/usr/local/go/bin" ]; then
    export PATH=$PATH:/usr/local/go/bin
fi

# Unity path.
export UNITY_PATH="$HOME/src/Unity/Hub/Editor/6000.0.43f1/Editor/Unity"

# Neovim-related environment variables.
export MANPAGER='/snap/nvim/current/usr/bin/nvim +Man!'
export MANWIDTH=999

# Lazygit configuration.
export XDG_CONFIG_HOME="$HOME/.config"

# --- Third-Party Tool & Plugin Loading ---
# Source other configuration files and tools.

# Source the starship prompt.
eval "$(starship init zsh)"

# Source zsh-syntax-highlighting.
[ -f /usr/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh ] && source /usr/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh
[ -f /opt/homebrew/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh ] && source /opt/homebrew/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh

# Source NVM (Node Version Manager).
export NVM_DIR="$([ -z "${XDG_CONFIG_HOME-}" ] && printf %s "${HOME}/.nvm" || printf %s "${XDG_CONFIG_HOME}/nvm")"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh" # This loads nvm
[ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion" # This loads nvm bash_completion

# Source autojump.
[ -f /opt/homebrew/etc/profile.d/autojump.sh ] && . /opt/homebrew/etc/profile.d/autojump.sh
[ -f /usr/share/autojump/autojump.zsh ] && source /usr/share/autojump/autojump.zsh

# Source FZF.
[ -f ~/.fzf.zsh ] && source ~/.fzf.zsh

# Source VS Code shell integration.
[[ "$TERM_PROGRAM" == "vscode" ]] && . "$(code --locate-shell-integration-path zsh)"

# Source .bash_profile.
if [ -f "$HOME/.bash_profile" ]; then
    . "$HOME/.bash_profile"
fi

# Display a fortune cookie if cowsay is available.
if [ -x /usr/games/cowsay -a -x /usr/games/fortune ]; then
    fortune | cowsay
elif [ -x /opt/homebrew/bin/cowsay -a -x /opt/homebrew/bin/fortune ]; then
    fortune | cowsay
fi
