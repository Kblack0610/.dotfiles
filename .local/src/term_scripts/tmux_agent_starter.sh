#!/bin/bash

# Ensure we can find user installed binaries (cargo, brew, etc)
export PATH=$PATH:/usr/local/bin:$HOME/.local/bin:$HOME/bin

# 1. Select project
# PROJECT=$(find -L ~/.config/tmuxinator -name "*.yml" | xargs -n 1 basename -s .yml | fzf --reverse --border --prompt='Select Agent dir> ')
TARGET=$(find ~/dev -mindepth 1 -maxdepth 2 -type d 2>/dev/null | fzf --reverse --border --prompt='Spawn Agent In > ')


# 2. Exit if cancelled
[[ -z "$TARGET" ]] && exit 0

# TMUX_WINDOW_COUNT=$(tmux list-windows -t platform | wc -l)
TMUX_WINDOW_COUNT=$(tmux display-message -p '#{session_windows}')
TMUX_WINDOW_COUNT=$((TMUX_WINDOW_COUNT + 1))

# 3. Setup Paths & Names
# Ensure absolute path for tmuxinator and sanitize directory name for session title
ROOT=$(cd "$TARGET" && pwd)
NAME="$(basename "$ROOT" | tr ' .:' '_')_agent_$TMUX_WINDOW_COUNT"

# 4. Switch or Start
# If we are in tmux, tell tmuxinator to switch the client, not attach inside the popup
if [ -n "$TMUX" ]; then
  notify-send "Spawning Agent in $ROOT"
    # 3. Create the window
  # -c: Sets the directory
  # -n: Names the window "agent"
  # \; split-window -h: Immediately splits it (giving you that agent/editor view)
    tmux switch-client -t agent
    tmux new-window -c "$TARGET" -n "$NAME" \
    # # Pass the 'root' and 'name' variables to the agent.yml template
    # tmuxinator start agent root="$ROOT" name="$NAME" --no-attach
    # # Manually switch to the session tmuxinator just created
    # tmux switch-client -t "$NAME"
else
    tmuxinator start agent root="$ROOT" name="$NAME"
fi
