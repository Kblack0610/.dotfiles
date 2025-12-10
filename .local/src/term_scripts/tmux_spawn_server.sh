#!/bin/bash

# Spawns dev servers (api + web) for a platform app
# Creates a new window with split panes like placemyparents.yml

export PATH=$PATH:/usr/local/bin:$HOME/.local/bin:$HOME/bin

PLATFORM_APPS_DIR="$HOME/dev/bnb/platform/apps"

# 1. Select platform app
APP=$(find "$PLATFORM_APPS_DIR" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | \
      xargs -n 1 basename | \
      fzf --reverse --border --prompt='Spawn Server > ')

# 2. Exit if cancelled
[[ -z "$APP" ]] && exit 0

# 3. Setup paths
APP_PATH="$PLATFORM_APPS_DIR/$APP"
API_PATH="$APP_PATH/api"
WEB_PATH="$APP_PATH/web"
WINDOW_NAME="${APP}_server"

# 4. Verify directories exist
if [[ ! -d "$API_PATH" ]] && [[ ! -d "$WEB_PATH" ]]; then
    notify-send "Error: Neither api/ nor web/ found in $APP" 2>/dev/null || true
    echo "Error: Neither api/ nor web/ found in $APP"
    exit 1
fi

notify-send "Spawning servers for: $APP" 2>/dev/null || true

# 5. Create window with split panes
if [ -n "$TMUX" ]; then
    # Create new window
    tmux new-window -n "$WINDOW_NAME"

    # Start API server if exists
    if [[ -d "$API_PATH" ]]; then
        tmux send-keys "cd '$API_PATH' && pnpm run dev" C-m
    else
        tmux send-keys "echo 'No api/ directory found'" C-m
    fi

    # Split and start Web server if exists
    tmux split-window -h
    if [[ -d "$WEB_PATH" ]]; then
        tmux send-keys "cd '$WEB_PATH' && pnpm run dev" C-m
    else
        tmux send-keys "echo 'No web/ directory found'" C-m
    fi

    # Balance the panes
    tmux select-layout even-horizontal
else
    echo "Not in a tmux session. Please run from within tmux."
    exit 1
fi
