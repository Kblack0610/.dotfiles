#!/usr/bin/env bash

ROOTS=(
    "$HOME/dev"
    "$HOME/bin"
    "$HOME/src"
    "$HOME/.agent"
    "$HOME/.dotfiles"
    "$HOME/.lab"
)

PRUNE=(
    .git .github .serena
    node_modules .venv venv __pycache__
    build dist target out .next
    .cache .npm .cargo .pytest_cache
    .idea .vscode .vs
    .DS_Store .tmp .temp
)

if [[ $# -eq 1 ]]; then
    selected=$1
else
    roots=()
    for r in "${ROOTS[@]}"; do [[ -d "$r" ]] && roots+=("$r"); done

    prune_expr=()
    for p in "${PRUNE[@]}"; do prune_expr+=(-name "$p" -o); done
    unset 'prune_expr[-1]'

    selected=$(find "${roots[@]}" -maxdepth 4 \
        \( "${prune_expr[@]}" \) -prune -o \
        -type d -print 2>/dev/null | fzf)
fi

[[ -z $selected ]] && exit 0

selected_name=$(basename "$selected" | tr . _)
tmux_running=$(pgrep tmux)

if [[ -z $TMUX ]] && [[ -z $tmux_running ]]; then
    tmux new-session -s "$selected_name" -c "$selected"
    exit 0
fi

if ! tmux has-session -t="$selected_name" 2>/dev/null; then
    tmux new-session -ds "$selected_name" -c "$selected"
fi

tmux switch-client -t "$selected_name"
