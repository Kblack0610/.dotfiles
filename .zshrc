# if set to "random", it will load a random themeto know which specific one was loaded, run: echo $RANDOM_THEME
# See https://github.com/ohmyzsh/ohmyzsh/wiki/Themes
ZSH_THEME="robbyrussell"
# ZSH_THEME_RANDOM_CANDIDATES=( "robbyrussell", "agnoster" )

# Stop insecure messages
ZSH_DISABLE_COMPFIX="true"

plugins=(
    git
    zsh-autosuggestions
)

# NOTE: need to put bindkey -vi and plugins after importing oh-my-zsh
export ZSH="${HOME}/.oh-my-zsh"
source $ZSH/oh-my-zsh.sh

# History
HISTSIZE=5000
HISTFILE=~/.zsh_history
SAVEHIST=$HISTSIZE
HISTDUP=erase
setopt appendhistory
setopt sharehistory
setopt hist_ignore_space
setopt hist_ignore_all_dups
setopt hist_save_no_dups
setopt hist_ignore_dups
setopt hist_find_no_dups

# Disable use of ! and !! for commands
# This can interfere when ! is used in other commands, just disabling as I dont use ! or !!
setopt NO_HIST_EXPAND

#Tmux
# if command -v tmux &> /dev/null && [ -n "$PS1" ] && [[ ! "$TERM" =~ screen ]] && [[ ! "$TERM" =~ tmux ]] && [ -z "$TMUX" ]; then
#   exec tmux
# fi



[ -f /usr/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh ] && source /usr/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh
[ -f /opt/homebrew/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh ] && source /opt/homebrew/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh

# load .bash_profile
if [ -f $HOME/.bash_profile ]; then 
    . $HOME/.bash_profile;
fi

[ -f ~/.fzf.zsh ] && source ~/.fzf.zsh

# vi mode
bindkey -v

# fix small delay when entering vi mode
# https://www.reddit.com/r/vim/comments/60jl7h/zsh_vimode_no_delay_entering_normal_mode/
KEYTIMEOUT=1

# ctrl-p & ctrl-n to behave like arrow keys
bindkey '^P' up-line-or-beginning-search
bindkey '^N' down-line-or-beginning-search
bindkey '^R' history-incremental-search-backward


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
            }
            "
        else
            eval "
            function $wrapper_func() {
                CUTBUFFER=\$($paste_cmd)
                zle .$widget
            }
            "
        fi

        zle -N $widget $wrapper_func
    done
}

## ALIASES ##
alias nvr="nvr . -s"
alias n="nvim ."
alias g="git"
# . important else it will execute in subshell
alias f='. $HOME/.local/bin/term_scripts/fzf_dev.sh'
# Alias fzf search zsh_history
alias h='. $HOME/.local/bin/term_scripts/fzf_history.sh'
alias e='exit'

alias vi='nvim --listen /tmp/nvim-server.pipe'

alias python=/usr/bin/python3

alias ct='kitty @ set-tab-title'

alias lg='lazygit'
## END ALIASES ##

## AUTOJUMP ##
[ -f /opt/homebrew/etc/profile.d/autojump.sh ] && . /opt/homebrew/etc/profile.d/autojump.sh
[ -f /usr/share/autojump/autojump.zsh ] && source /usr/share/autojump/autojump.zsh

local copy_widgets=(
    vi-yank vi-yank-eol vi-delete vi-backward-kill-word vi-change-whole-line
)
local paste_widgets=(
    vi-put-{before,after}
)

x11-clip-wrap-widgets copy $copy_widgets
x11-clip-wrap-widgets paste  $paste_widgets

if [ -x /usr/games/cowsay -a -x /usr/games/fortune ]; then
    fortune | cowsay
elif [ -x /opt/homebrew/bin/cowsay -a -x /opt/homebrew/bin/fortune ]; then
    fortune | cowsay
fi

# LANGUAGES

# node version manager
export NVM_DIR="$([ -z "${XDG_CONFIG_HOME-}" ] && printf %s "${HOME}/.nvm" || printf %s "${XDG_CONFIG_HOME}/nvm")"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh" # This loads nvm

# Add golang to path if it is installed
# if [ -d "/usr/local/go/bin" ]; then
#     export PATH=$PATH:/usr/local/go/bin
# fi

