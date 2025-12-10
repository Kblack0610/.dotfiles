#!/bin/bash

# Spawns nvim at the repo root in a new window within a selected session
# Select from existing tmux sessions, then opens nvim at that session's git root

export PATH=$PATH:/usr/local/bin:$HOME/.local/bin:$HOME/bin

# 1. Select from existing tmux sessions
SESSION=$(tmux list-sessions -F "#{session_name}" 2>/dev/null | \
          fzf --reverse --border --prompt='Open nvim in session > ')

# 2. Exit if cancelled
[[ -z "$SESSION" ]] && exit 0

# 3. Get the working directory of the first window in that session
SESSION_DIR=$(tmux display-message -t "$SESSION" -p '#{pane_current_path}')

# 4. Try to find git root from that session's directory
ROOT=$(cd "$SESSION_DIR" 2>/dev/null && git rev-parse --show-toplevel 2>/dev/null)

# 5. If no git root, check if we're in a platform app and use platform root
if [[ -z "$ROOT" ]]; then
    if [[ "$SESSION_DIR" == *"/dev/bnb/platform/"* ]]; then
        ROOT="$HOME/dev/bnb/platform"
    else
        ROOT="$SESSION_DIR"
    fi
fi

# 6. Create window name
NAME="nvim_$(basename "$ROOT" | tr ' .:' '_')"

# 7. Check if a window running nvim already exists in that session
# Look for windows where the pane is running nvim
EXISTING_WINDOW=$(tmux list-windows -t "$SESSION" -F "#{window_index}:#{pane_current_command}" 2>/dev/null | \
                  grep -E ":n?vim$" | head -1 | cut -d: -f1)

if [ -n "$TMUX" ]; then
    if [[ -n "$EXISTING_WINDOW" ]]; then
        # Switch to existing nvim window
        notify-send "Switching to nvim window in $SESSION" 2>/dev/null || true
        tmux select-window -t "$SESSION:$EXISTING_WINDOW"
        tmux switch-client -t "$SESSION"
    else
        # Create new nvim window
        notify-send "Opening nvim at $ROOT in $SESSION" 2>/dev/null || true
        tmux new-window -t "$SESSION" -c "$ROOT" -n "$NAME" "nvim ."
        tmux switch-client -t "$SESSION"
    fi
else
    echo "Not in a tmux session."
    exit 1
fi
