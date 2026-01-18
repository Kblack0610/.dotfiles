#!/bin/bash

# Custom session chooser with Claude agent status
# Shows: short_name status | full_name (windows)

export PATH=$PATH:/usr/local/bin:$HOME/.local/bin:$HOME/bin

STATUS_SCRIPT="$HOME/.local/src/term_scripts/tmux_claude_status.sh"

get_sessions() {
    while read -r session; do
        # Get short name and status from our script
        local formatted=$("$STATUS_SCRIPT" --format "$session")

        # Get window count
        local win_count=$(tmux list-windows -t "$session" 2>/dev/null | wc -l)

        # Color based on status
        local color=""
        if [[ "$formatted" == *"!"* ]]; then
            color="\033[38;5;208m"  # Orange for attention
        elif [[ "$formatted" == *"~"* ]]; then
            color="\033[38;5;82m"   # Green for working
        elif [[ "$formatted" == *"·"* ]]; then
            color="\033[38;5;244m"  # Gray for idle
        else
            color="\033[38;5;39m"   # Blue for no claude
        fi

        # Format: formatted_status | session_name (N windows)
        printf "${color}%-10s\033[0m %s (%d win)\n" "$formatted" "$session" "$win_count"
    done < <(tmux list-sessions -F '#{session_name}' 2>/dev/null | sort)
}

# Get sessions list
SESSIONS=$(get_sessions)

if [ -z "$SESSIONS" ]; then
    echo "No tmux sessions found"
    exit 0
fi

# Show with fzf
SELECTION=$(echo -e "$SESSIONS" | fzf \
    --ansi \
    --reverse \
    --border \
    --header="Sessions (! attention, ~ working, · idle)" \
    --prompt="Switch to > " \
    --preview='session=$(echo {} | awk "{print \$2}"); tmux list-windows -t "$session" -F "  #{window_index}: #{window_name} [#{pane_current_path}]" 2>/dev/null' \
    --preview-window=right:40%:wrap)

[[ -z "$SELECTION" ]] && exit 0

# Extract session name (second field)
TARGET=$(echo "$SELECTION" | awk '{print $2}')

if [ -n "$TARGET" ]; then
    if [ -n "$TMUX" ]; then
        tmux switch-client -t "$TARGET"
    else
        tmux attach-session -t "$TARGET"
    fi
fi
