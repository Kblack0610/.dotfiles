# Preferred editor for local and remote sessions
if [[ -n $SSH_CONNECTION ]]; then
  export EDITOR='vim'
else
  export EDITOR='nvim'
fi

# Stop insecure messages
ZSH_DISABLE_COMPFIX="true"

# Path to your oh-my-zsh installation.
export ZSH="${HOME}/.oh-my-zsh"

# vi mode
bindkey -v

# ctrl-p & ctrl-n to behave like arrow keys
bindkey '^P' up-line-or-beginning-search
bindkey '^N' down-line-or-beginning-search


# Yank to system register (https://unix.stackexchange.com/questions/25765/pasting-from-clipboard-to-vi-enabled-zsh-or-bash-shell)
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
alias f='. $HOME/.bin/term_scripts/fzf_dev.sh'
# Alias fzf search zsh_history
alias h='. $HOME/.bin/term_scripts/fzf_history.sh'
alias e='exit'

alias vi='nvim --listen /tmp/nvim-server.pipe'

alias python=/usr/bin/python3

alias ct='kitty @ set-tab-title'
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

source ~/.bin/quick-push/.quick-push


if [ -x /usr/games/cowsay -a -x /usr/games/fortune ]; then
    fortune | cowsay
elif [ -x /opt/homebrew/bin/cowsay -a -x /opt/homebrew/bin/fortune ]; then
    fortune | cowsay
fi


