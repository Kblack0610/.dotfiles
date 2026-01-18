#!/bin/bash

# Spawns a fresh tmux session for a platform app with nvim
# Discovers apps from ~/dev/bnb/platform/apps/

export PATH=$PATH:/usr/local/bin:$HOME/.local/bin:$HOME/bin

PLATFORM_APPS_DIR="$HOME/dev/bnb/platform/apps"

# 1. Select platform app
APP=$(find "$PLATFORM_APPS_DIR" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | \
      xargs -n 1 basename | \
      fzf --reverse --border --prompt='Spawn Project > ')

# 2. Exit if cancelled
[[ -z "$APP" ]] && exit 0

# 3. Setup paths & names
APP_PATH="$PLATFORM_APPS_DIR/$APP"
SESSION_NAME="$APP"

# 4. Check if session already exists
if tmux has-session -t "$SESSION_NAME" 2>/dev/null; then
    notify-send "Session '$SESSION_NAME' already exists. Switching..." 2>/dev/null || true
    if [ -n "$TMUX" ]; then
        tmux switch-client -t "$SESSION_NAME"
    else
        tmux attach-session -t "$SESSION_NAME"
    fi
    exit 0
fi

# 5. Create new session with nvim
notify-send "Spawning project: $APP" 2>/dev/null || true

if [ -n "$TMUX" ]; then
    # Create detached session, then switch to it
    tmux new-session -d -s "$SESSION_NAME" -c "$APP_PATH" "nvim ."
    tmux switch-client -t "$SESSION_NAME"
else
    tmux new-session -s "$SESSION_NAME" -c "$APP_PATH" "nvim ."
fi
