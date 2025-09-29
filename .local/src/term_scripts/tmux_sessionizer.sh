#!/usr/bin/env bash

if [[ $# -eq 1 ]]; then
    selected=$1
else
    dirs=(
      "$HOME/.dotfiles"
      "$HOME/dev"
      "$HOME/Work"
      "$HOME/bin"
      "$HOME/dev/*"
      "$HOME/Work/*"
      "$HOME/Documents"
      # Add more directories as needed
    )

    selected=$(find "${dirs[@]}" -maxdepth 4 -type d -not -path "*/\.git/*" -not -path "*/\node_modules/*" -print 2> /dev/null | fzf)
fi

if [[ -z $selected ]]; then
    exit 0
fi

selected_name=$(basename "$selected" | tr . _)
tmux_running=$(pgrep tmux)

if [[ -z $TMUX ]] && [[ -z $tmux_running ]]; then
    tmux new-session -s $selected_name -c $selected
    exit 0
fi

if ! tmux has-session -t=$selected_name 2> /dev/null; then
    tmux new-session -ds $selected_name -c $selected
fi

tmux switch-client -t $selected_name
