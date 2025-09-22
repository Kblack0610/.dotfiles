# This is my personal Bash configuration file.
# It is organized for clarity and easy management.

# --- General Settings ---
# Exit if not in an interactive shell. This is a common practice to prevent issues when a shell is launched in non-interactive mode.
case $- in
    *i*) ;;
      *) return;;
esac

# Set Vim as the default editor in the terminal.
set -o vi

# Search through history with up/down arrows.
bind '"\e[A": history-search-backward' 2>/dev/null
bind '"\e[B": history-search-forward' 2>/dev/null

# --- History Settings ---
# Don't put duplicate lines or lines starting with a space in the history.
HISTCONTROL=ignoreboth

# Append to the history file, don't overwrite it.
shopt -s histappend

# Set history size limits.
HISTSIZE=2000
HISTFILESIZE=3000

# Check the window size after each command and update the values of LINES and COLUMNS.
shopt -s checkwinsize

# If set, the pattern "**" used in a pathname expansion context will match all files and subdirectories.
shopt -s globstar

# --- Terminal Prompt ---
# Termux (without user@host)
export PS1='\[\e[1;38;5;244m\]\t \[\e[1;33m\]\w \[\e[1;36m\]\$ \[\e[0m\]'

# --- Aliases and Functions ---
# General purpose aliases
alias nvr="nvr . -s"
alias n="nvim ."
alias g="git"
alias vi='nvim --listen /tmp/nvim-server.pipe'
alias refreshfontcache='fc-cache -fv'

# Aliases for specific tools and scripts
alias f='. $HOME/.local/bin/term_scripts/fzf_dev.sh'
alias h='. $HOME/.local/bin/term_scripts/fzf_history.sh'
alias killUnity="kill -9 $(pgrep Unity)"

# Aliases for system commands
alias setbright="sudo brightnessctl set "
alias unmute='amixer -D pulse sset Master unmute'
alias setSound='amixer -D pulse sset Master 50%'

# Aliases for specific projects or tasks
alias gametodo="nvim $HOME/.config/life/todos/game_todo"
alias dailylog="cp $HOME/.config/life/templates/daily_log_template $HOME/.config/life/todos/log_$(date +%F)"
alias unitylaptop='env GDK_SCALE=2 ./Unity/Hub/Editor/2022.3.20f1/Editor/Unity -projectPath Games/DodginBalls/'

# --- Environment Variables and Path ---
# Add common user and utility directories to PATH.
export PATH="$HOME/.local/bin:$HOME/Utilities:$PATH"

# Add application-specific directories to PATH.
export PATH="$PATH:$HOME/.maestro/bin"
export PATH="$PATH:$HOME/.spicetify"

# Export Mono Framework path.
export FrameworkPathOverride=/lib/mono/4.8-api

# Limit the number of open files for the current session.
ulimit -n 4000

# --- Third-Party and Application Sourcing ---
# Source autojump for directory jumping functionality.
[ -f /usr/share/autojump/autojump.bash ] && source /usr/share/autojump/autojump.bash

# --- Conditional and Specific Scripts ---
# Warn about root shells!
if [ `id -u` -eq 0 ]; then
    start="\033[1;37;41m"
    end="\033[0m"
    printf "\n"
    printf "  $start                                                                     $end\n"
    printf "  $start  WARNING: You are in a root shell. This is probably a very bad idea.  $end\n"
    printf "  $start                                                                     $end\n"
    printf "\n"
fi

# Add a command to Vim that allows saving files with sudo permissions.
if which vim >/dev/null && ! grep '^command W ' ~/.vimrc >/dev/null 2>&1 && ! [ `id -u` -eq 0 ]; then
    echo "command W :execute ':silent w !sudo tee % > /dev/null' | :if v:shell_error | :edit! | :endif" >> ~/.vimrc
fi
