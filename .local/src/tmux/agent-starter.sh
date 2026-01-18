#!/bin/bash

# Spawns a claude agent in a new window within a selected session
# Allows multiple agents per session

export PATH=$PATH:/usr/local/bin:$HOME/.local/bin:$HOME/bin

# 1. Select from existing tmux sessions
SESSION=$(tmux list-sessions -F "#{session_name}" 2>/dev/null | \
          fzf --reverse --border --prompt='Spawn agent in session > ')

# 2. Exit if cancelled
[[ -z "$SESSION" ]] && exit 0

# 3. Select target directory
TARGET=$(find ~/dev -mindepth 1 -maxdepth 2 -type d 2>/dev/null | \
         fzf --reverse --border --prompt='Select directory > ')

# 4. Exit if cancelled
[[ -z "$TARGET" ]] && exit 0

# 5. Setup Paths & Names
ROOT=$(cd "$TARGET" && pwd)
WINDOW_COUNT=$(tmux list-windows -t "$SESSION" 2>/dev/null | wc -l)
WINDOW_COUNT=$((WINDOW_COUNT + 1))
NAME="$(basename "$ROOT" | tr ' .:' '_')_agent_$WINDOW_COUNT"

# 6. Create new window with claude in the selected session
if [ -n "$TMUX" ]; then
    notify-send "Spawning Agent in $ROOT ($SESSION)" 2>/dev/null || true
    tmux new-window -t "$SESSION" -c "$ROOT" -n "$NAME" "claude --dangerously-skip-permissions"
    tmux switch-client -t "$SESSION"
else
    echo "Not in a tmux session."
    exit 1
fi
