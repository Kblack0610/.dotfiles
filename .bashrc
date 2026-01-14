# Source the common settings file if it exists.
[ -f "$HOME/.commonrc" ] && source "$HOME/.commonrc"

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

# Export Mono Framework path.
export FrameworkPathOverride=/lib/mono/4.8-api

# Limit the number of open files for the current session.
ulimit -n 4000

# --- Third-Party and Application Sourcing ---
# Initialize zoxide (smarter cd command)
eval "$(zoxide init bash)"
. "$HOME/.cargo/env"

. "$HOME/.local/share/../bin/env"
