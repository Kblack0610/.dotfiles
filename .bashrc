case $- in
    *i*) ;;
      *) return;;
esac

set -o vi
###########
## Color ##
###########

# Normal Bash
# export PS1='\[\e[1;38;5;244m\]\t \[\e[1;36m\]\u@\H \[\e[1;33m\]\w \[\e[1;36m\]\$ \[\e[0m\]' 

# Alpine Linux / ash
# export PS1='\[\e[1;38;5;244m\]$(date +%H:%M:%S) \[\e[1;36m\]\u@\H \[\e[1;33m\]\w \[\e[1;36m\]\$ \[\e[0m\]'

# Termux (without user@host)
export PS1='\[\e[1;38;5;244m\]\t \[\e[1;33m\]\w \[\e[1;36m\]\$ \[\e[0m\]'

# Minimal without path to working directory (~ $)
# export PS1='\[\e[1;33m\]\W \[\e[1;36m\]\$ \[\e[0m\]'

##CHANGE GNOME THEME
#use-theme-colors false

#change gnome colors
#https://askubuntu.com/questions/1175987/how-to-change-the-background-to-use-built-in-theme-from-gnome-terminal-profile-p

#Solarized Dark
alias themeSolar="gsettings set org.gnome.Terminal.Legacy.Profile:/org/gnome/terminal/legacy/profiles:/:b1dcc9dd-5262-4d8d-a863-c897e6d979b9/ foreground-color 'rgb(131,148,150)' && gsettings set org.gnome.Terminal.Legacy.Profile:/org/gnome/terminal/legacy/profiles:/:b1dcc9dd-5262-4d8d-a863-c897e6d979b9/ background-color 'rgb(0,43,54)'"

#Tango Dark
alias themeTango="gsettings set org.gnome.Terminal.Legacy.Profile:/org/gnome/terminal/legacy/profiles:/:b1dcc9dd-5262-4d8d-a863-c897e6d979b9/ foreground-color 'rgb(211,215,207)' && gsettings set org.gnome.Terminal.Legacy.Profile:/org/gnome/terminal/legacy/profiles:/:b1dcc9dd-5262-4d8d-a863-c897e6d979b9/ background-color 'rgb(46,52,54)'"


##################################
## ls, exa & more colored stuff ##
##################################
# some more ls aliases
alias ll='ls --color -alF'
alias la='ls --color -A'
alias l='ls --color -CF'
alias ls='ls --color -CF'

LS_COLORS='di=36:ln=35:so=32:pi=33:ex=31:bd=34;46:cd=34;43:su=30;41:sg=30;46:tw=30;42:ow=30;43';
export LS_COLORS
# if which exa >/dev/null; then
# 	# exa is a modern ls replacement with Git integration: https://the.exa.website
# 	alias ls="exa --git-ignore"
# 	alias ll="exa --git-ignore --git -l --group"
# 	alias la="exa --git -la"
# else
# 	alias ls="ls --color=always"
# 	alias ll="ls -l"
# 	alias la="ls -lA"
# fi
# for alias in lsl sls lsls sl l s; do alias $alias=ls; done
#
# colored GCC warnings and errors
# export GCC_COLORS='error=01;31:warning=01;35:note=01;36:caret=01;32:locus=01:quote=01'


########################################
## Cool bash features nobody knows of ##
########################################

if [ -x /usr/games/cowsay -a -x /usr/games/fortune ]; then
    fortune | cowsay
fi
##OTHER
#Test to pass params
#https://unix.stackexchange.com/questions/3773/how-to-pass-parameters-to-an-alias
#alias wrap_args='f(){ echo before "$@" after;  unset -f f; }; f'

#Wrapping in function:
#https://stackoverflow.com/questions/19359049/user-input-to-bash-alias

#Submit after password:
#https://daniel-ellis.medium.com/shell-script-submitting-a-password-after-a-prompt-690bcf144c0e


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
#
# # check the window size after each command and, if necessary,
# # update the values of LINES and COLUMNS.
# shopt -s checkwinsize
#
# # If set, the pattern "**" used in a pathname expansion context will
# # match all files and zero or more directories and subdirectories.
# #shopt -s globstar
#
# # make less more friendly for non-text input files, see lesspipe(1)
# [ -x /usr/bin/lesspipe ] && eval "$(SHELL=/bin/sh lesspipe)"
#
# # set variable identifying the chroot you work in (used in the prompt below)
# if [ -z "${debian_chroot:-}" ] && [ -r /etc/debian_chroot ]; then
#     debian_chroot=$(cat /etc/debian_chroot)
# fi
#
# # set a fancy prompt (non-color, unless we know we "want" color)
# case "$TERM" in
#     xterm-color|*-256color) color_prompt=yes;;
# esac
#
# # uncomment for a colored prompt, if the terminal has the capability; turned
# # off by default to not distract the user: the focus in a terminal window
# # should be on the output of commands, not on the prompt
# force_color_prompt=yes
#
# if [ -n "$force_color_prompt" ]; then
#     if [ -x /usr/bin/tput ] && tput setaf 1 >&/dev/null; then
# 	# We have color support; assume it's compliant with Ecma-48
# 	# (ISO/IEC-6429). (Lack of such support is extremely rare, and such
# 	# a case would tend to support setf rather than setaf.)
# 	color_prompt=yes
#     else
# 	color_prompt=
#     fi
# fi
# #
# # if [ "$color_prompt" = yes ]; then
# #     PS1='${debian_chroot:+($debian_chroot)}\[\033[01;32m\]\u@\h\[\033[00m\]:\[\033[01;34m\]\w\[\033[00m\]\$ '
# # else
# #     PS1='${debian_chroot:+($debian_chroot)}\u@\h:\w\$ '
# # fi
# unset color_prompt force_color_prompt
#
# # If this is an xterm set the title to user@host:dir
# case "$TERM" in
# xterm*|rxvt*)
#     PS1="\[\e]0;${debian_chroot:+($debian_chroot)}\u@\h: \w\a\]$PS1"
#     ;;
# *)
#     ;;
# esac
#
# # enable color support of ls and also add handy aliases
# if [ -x /usr/bin/dircolors ]; then
#     test -r ~/.dircolors && eval "$(dircolors -b ~/.dircolors)" || eval "$(dircolors -b)"
#     alias ls='ls --color=auto'
#     #alias dir='dir --color=auto'
#     #alias vdir='vdir --color=auto'
#
#     alias grep='grep --color=auto'
#     alias fgrep='fgrep --color=auto'
#     alias egrep='egrep --color=auto'
# fi
#
# # colored GCC warnings and errors
# #export GCC_COLORS='error=01;31:warning=01;35:note=01;36:caret=01;32:locus=01:quote=01'

# # Add an "alert" alias for long running commands.  Use like so:
#   # sleep 10; alert
# # alias alert='notify-send --urgency=low -i "$([ $? = 0 ] && echo terminal || echo error)" "$(history|tail -n1|sed -e '\''s/^\s*[0-9]\+\s*//;s/[;&|]\s*alert$//'\'')"'
#
# # Alias definitions.
# # You may want to put all your additions into a separate file like
# # ~/.bash_aliases, instead of adding them here directly.
# # See /usr/share/doc/bash-doc/examples in the bash-doc package.
#
# if [ -f ~/.bash_aliases ]; then
#     . ~/.bash_aliases
# fi
#
# # enable programmable completion features (you don't need to enable
# # this, if it's already enabled in /etc/bash.bashrc and /etc/profile
# # sources /etc/bash.bashrc).
# if ! shopt -oq posix; then
#   if [ -f /usr/share/bash-completion/bash_completion ]; then
#     . /usr/share/bash-completion/bash_completion
#   elif [ -f /etc/bash_completion ]; then
#     . /etc/bash_completion
#   fi
# fi
#
#

####################################################################
## Type :W in vim (or :WQ respectively) to save a file using sudo ##
####################################################################

if which vim >/dev/null && ! grep '^command W ' ~/.vimrc >/dev/null 2>&1 && ! [ `id -u` -eq 0 ]; then
	echo "command W :execute ':silent w !sudo tee % > /dev/null' | :if v:shell_error | :edit! | :endif" >> ~/.vimrc
fi

#############################
## Warn about root shells! ##
#############################

if [ `id -u` -eq 0 ]; then 
    start="\033[1;37;41m"
    end="\033[0m"
    printf "\n"
    printf "  $start                                                                       $end\n"
    printf "  $start  WARNING: You are in a root shell. This is probably a very bad idea.  $end\n"
    printf "  $start                                                                       $end\n"
    printf "\n"
fi


#########################
## Path & Applications ##
#########################

PATH="$HOME/.local/bin:$PATH"
PATH="$HOME/Utilities:$PATH"
#export PATH=$PATH:$HOME/.dotnet:$HOME/.dotnet/tools

export FrameworkPathOverride=/lib/mono/4.5
export FrameworkPathOverride=/lib/mono/4.8-api
# autojump
source /usr/share/autojump/autojump.bash
alias .bashrc="nvim $HOME/.bashrc && source $HOME/.bashrc"
alias i3conf="nvim $HOME/.config/i3/config" 
alias vconf="nvim $HOME/.config/nvim/lua/user/init.lua" 
alias v="nvr . -s"
alias nv="nvim ."
alias g="git"

alias killUnity="kill -9 $(pgrep Unity)"

## CONFIGS
alias setbright="sudo brightnessctl set "

## TO-DO
# alias todaytodo="nvim $HOME/.config/life/todos/daily_todo"
alias gametodo="nvim $HOME/.config/life/todos/game_todo"

alias dailylog="cp $HOME/.config/life/templates/daily_log_template $HOME/.config/life/todos/log_$(date +%F)"
###########################
## Ubuntu-specific stuff ##
###########################

# make less more friendly for non-text input files, see lesspipe(1)
[ -x /usr/bin/lesspipe ] && eval "$(SHELL=/bin/sh lesspipe)"

# enable programmable completion features (you don't need to enable
# this, if it's already enabled in /etc/bash.bashrc and /etc/profile
# sources /etc/bash.bashrc).
if ! shopt -oq posix; then
  if [ -f /usr/share/bash-completion/bash_completion ]; then
    . /usr/share/bash-completion/bash_completion
  elif [ -f /etc/bash_completion ]; then
    . /etc/bash_completion
  fi
fi

# Ubuntu already had an "fd" package, so the one I'd like to use is called "fdfind".
! which fdfind >/dev/null || alias fd=fdfind

