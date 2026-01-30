#!/usr/bin/env bash

get_whitelist() {
    echo "$HOME/dev"
    echo "$HOME/bin"
    echo "$HOME/src"
    echo "$HOME/dev/*"
    echo "$HOME/.agent"
    echo "$HOME/.dotfiles"
    # Add more directories as needed
}

get_blacklist() {
    cat <<EOF
.git
node_modules
.venv
venv
__pycache__
build
dist
target
out
.next
.cache
.npm
.cargo
.pytest_cache
.idea
.vscode
.vs
.DS_Store
.tmp
.temp
EOF
}

if [[ $# -eq 1 ]]; then
    selected=$1
else
    mapfile -t dirs < <(get_whitelist)

    # Build exclude arguments from blacklist
    exclude_args=()
    while IFS= read -r pattern; do
        [[ -z "$pattern" ]] && continue
        exclude_args+=(-not -path "*/$pattern/*")
    done < <(get_blacklist)

    selected=$(find "${dirs[@]}" -maxdepth 4 -type d "${exclude_args[@]}" -print 2> /dev/null | fzf)
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
