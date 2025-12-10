#!/bin/bash

# Spawns nvim at the repo root in a new window within the current session
# Detects git root or falls back to platform root for platform apps

export PATH=$PATH:/usr/local/bin:$HOME/.local/bin:$HOME/bin

# 1. Get current working directory
CURRENT_DIR=$(tmux display-message -p '#{pane_current_path}')

# 2. Try to find git root
ROOT=$(cd "$CURRENT_DIR" && git rev-parse --show-toplevel 2>/dev/null)

# 3. If no git root, check if we're in a platform app and use platform root
if [[ -z "$ROOT" ]]; then
    if [[ "$CURRENT_DIR" == *"/dev/bnb/platform/"* ]]; then
        ROOT="$HOME/dev/bnb/platform"
    else
        # Fall back to current directory
        ROOT="$CURRENT_DIR"
    fi
fi

# 4. Create window name from repo
NAME="nvim_$(basename "$ROOT" | tr ' .:' '_')"

# 5. Create new window with nvim at repo root
if [ -n "$TMUX" ]; then
    notify-send "Opening nvim at $ROOT" 2>/dev/null || true
    tmux new-window -c "$ROOT" -n "$NAME" "nvim ."
else
    echo "Not in a tmux session."
    exit 1
fi
