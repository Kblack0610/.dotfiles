## ALIASES ##
##################################

# some more ls aliases
alias ll='ls --color -alF'
alias la='ls --color -A'
alias l='ls --color -CF'
alias ls='ls --color -CF'

alias refreshfontcache='fc-cache -fv'

alias v="nvr . -s"
alias nv="nvim ."
alias g="git"

alias killUnity="kill -9 $(pgrep Unity)"

alias setbright="sudo brightnessctl set "

alias gametodo="nvim $HOME/.config/life/todos/game_todo"
alias dailylog="cp $HOME/.config/life/templates/daily_log_template $HOME/.config/life/todos/log_$(date +%F)"

alias vi='nvim --listen /tmp/nvim-server.pipe'

## Color ##
##################################

# Normal Bash
# export PS1='\[\e[1;38;5;244m\]\t \[\e[1;36m\]\u@\H \[\e[1;33m\]\w \[\e[1;36m\]\$ \[\e[0m\]' 

# Alpine Linux / ash
# export PS1='\[\e[1;38;5;244m\]$(date +%H:%M:%S) \[\e[1;36m\]\u@\H \[\e[1;33m\]\w \[\e[1;36m\]\$ \[\e[0m\]'

# Termux (without user@host)
export PS1='\[\e[1;38;5;244m\]\t \[\e[1;33m\]\w \[\e[1;36m\]\$ \[\e[0m\]'

# Minimal without path to working directory (~ $)
# export PS1='\[\e[1;33m\]\W \[\e[1;36m\]\$ \[\e[0m\]'

## CONFIGURATION ##
##################################

case $- in
    *i*) ;;
      *) return;;
esac

#Add docker as a group for lazydocker
#DO NOT USE
# newgrp docker

## Set Vim in terminal 
set -o vi

## Initial Prompt
if [ -x /usr/games/cowsay -a -x /usr/games/fortune ]; then
    fortune | cowsay
fi

# search through history with up/down arrows
bind '"\e[A": history-search-backward' 2>/dev/null
bind '"\e[B": history-search-forward' 2>/dev/null

# don't put duplicate lines or lines starting with space in the history.
# See bash(1) for more options
HISTCONTROL=ignoreboth

# append to the history file, don't overwrite it
shopt -s histappend

# for setting history length see HISTSIZE and HISTFILESIZE in bash(1)
HISTSIZE=2000
HISTFILESIZE=3000

# check the window size after each command and, if necessary,
# update the values of LINES and COLUMNS.
shopt -s checkwinsize

# If set, the pattern "**" used in a pathname expansion context will
# match all files and zero or more directories and subdirectories.
shopt -s globstar

## Type :W in vim (or :WQ respectively) to save a file using sudo ##

if which vim >/dev/null && ! grep '^command W ' ~/.vimrc >/dev/null 2>&1 && ! [ `id -u` -eq 0 ]; then
	echo "command W :execute ':silent w !sudo tee % > /dev/null' | :if v:shell_error | :edit! | :endif" >> ~/.vimrc
fi

## Warn about root shells! ##

if [ `id -u` -eq 0 ]; then 
    start="\033[1;37;41m"
    end="\033[0m"
    printf "\n"
    printf "  $start                                                                       $end\n"
    printf "  $start  WARNING: You are in a root shell. This is probably a very bad idea.  $end\n"
    printf "  $start                                                                       $end\n"
    printf "\n"
fi


## Path & Applications ##
##################################

PATH="$HOME/.local/bin:$PATH"
PATH="$HOME/Utilities:$PATH"
#export PATH=$PATH:$HOME/.dotnet:$HOME/.dotnet/tools

export FrameworkPathOverride=/lib/mono/4.5
export FrameworkPathOverride=/lib/mono/4.8-api

# autojump
source /usr/share/autojump/autojump.bash

ulimit -n 4000

## Useful info?
#Test to pass params
#https://unix.stackexchange.com/questions/3773/how-to-pass-parameters-to-an-alias
#alias wrap_args='f(){ echo before "$@" after;  unset -f f; }; f'

#Wrapping in function:
#https://stackoverflow.com/questions/19359049/user-input-to-bash-alias

#Submit after password:
#https://daniel-ellis.medium.com/shell-script-submitting-a-password-after-a-prompt-690bcf144c0e



export PATH=$PATH:/home/kblack0610/.spicetify
