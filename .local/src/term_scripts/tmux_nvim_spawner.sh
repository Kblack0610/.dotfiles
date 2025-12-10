#!/bin/bash

# Spawns a new nvim window in the current tmux session
# Similar to agent spawner but for nvim editing sessions

export PATH=$PATH:/usr/local/bin:$HOME/.local/bin:$HOME/bin

# 1. Select target directory
TARGET=$(find ~/dev -mindepth 1 -maxdepth 3 -type d 2>/dev/null | fzf --reverse --border --prompt='Open nvim in > ')

# 2. Exit if cancelled
[[ -z "$TARGET" ]] && exit 0

# 3. Setup names
ROOT=$(cd "$TARGET" && pwd)
NAME="nvim_$(basename "$ROOT" | tr ' .:' '_')"

# 4. Create new window with nvim
if [ -n "$TMUX" ]; then
    notify-send "Opening nvim in $ROOT" 2>/dev/null || true
    tmux new-window -c "$ROOT" -n "$NAME" "nvim ."
else
    echo "Not in a tmux session. Starting new session..."
    tmux new-session -d -s "$NAME" -c "$ROOT" "nvim ."
    tmux attach-session -t "$NAME"
fi
