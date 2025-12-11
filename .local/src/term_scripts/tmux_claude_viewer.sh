#!/bin/bash

# View and switch to running Claude agent sessions/windows
# Shows session:window with status indicators

export PATH=$PATH:/usr/local/bin:$HOME/.local/bin:$HOME/bin

# Colors for status (ANSI escape codes work in fzf preview)
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Build list of Claude windows with status info
get_claude_windows() {
    declare -A seen_windows

    while IFS=: read -r session window_idx window_name pane_cmd pane_pid pane_path; do
        # Skip if we already processed this window
        window_key="${session}:${window_idx}"
        [[ -n "${seen_windows[$window_key]}" ]] && continue

        # Only count panes where claude is the direct command
        if [[ "$pane_cmd" == "claude" ]]; then
            seen_windows[$window_key]=1

            # Get window activity info
            last_activity=$(tmux display-message -p -t "${session}:${window_idx}" "#{window_activity}" 2>/dev/null)
            now=$(date +%s)

            # Calculate time since last activity
            if [ -n "$last_activity" ]; then
                diff=$((now - last_activity))
                if [ $diff -lt 60 ]; then
                    activity="Active now"
                    status_icon="●"
                elif [ $diff -lt 300 ]; then
                    activity="$(( diff / 60 ))m ago"
                    status_icon="◐"
                elif [ $diff -lt 3600 ]; then
                    activity="$(( diff / 60 ))m ago"
                    status_icon="○"
                else
                    activity="$(( diff / 3600 ))h ago"
                    status_icon="○"
                fi
            else
                activity="Unknown"
                status_icon="?"
            fi

            # Get directory basename
            dir_name=$(basename "$pane_path" 2>/dev/null || echo "~")

            # Format: status_icon session:window_idx:window_name [dir] (activity)
            # Include window index to uniquely identify windows with same name
            printf "%s %-25s %-25s %s\n" "$status_icon" "${session}:${window_idx}:${window_name}" "[$dir_name]" "($activity)"
        fi
    done < <(tmux list-panes -a -F "#{session_name}:#{window_index}:#{window_name}:#{pane_current_command}:#{pane_pid}:#{pane_current_path}" 2>/dev/null)
}

# Preview function - shows last lines of pane content
preview_pane() {
    local selection="$1"
    # Extract session:window_idx:window_name from selection (format: "● session:idx:name [dir] (activity)")
    local target=$(echo "$selection" | awk '{print $2}')
    local session=$(echo "$target" | cut -d: -f1)
    local window_idx=$(echo "$target" | cut -d: -f2)
    local window_name=$(echo "$target" | cut -d: -f3-)

    if [ -n "$window_idx" ]; then
        echo -e "${CYAN}═══ ${session}:${window_name} (window ${window_idx}) ═══${NC}"
        echo ""
        tmux capture-pane -t "${session}:${window_idx}" -p -S -30 2>/dev/null | tail -25
    fi
}

# Export for fzf preview
export -f preview_pane
export GREEN YELLOW BLUE CYAN NC

# Main
CLAUDE_WINDOWS=$(get_claude_windows)

if [ -z "$CLAUDE_WINDOWS" ]; then
    echo "No Claude agents found running in tmux."
    exit 0
fi

# Show fzf with preview
SELECTION=$(echo "$CLAUDE_WINDOWS" | fzf \
    --ansi \
    --reverse \
    --border \
    --header="Claude Agents (● active, ◐ recent, ○ idle)" \
    --prompt="Select agent > " \
    --preview='bash -c "preview_pane {}"' \
    --preview-window=right:50%:wrap)

# Exit if cancelled
[[ -z "$SELECTION" ]] && exit 0

# Extract session and window index (format: "● session:idx:name [dir] (activity)")
TARGET=$(echo "$SELECTION" | awk '{print $2}')
TARGET_SESSION=$(echo "$TARGET" | cut -d: -f1)
WINDOW_IDX=$(echo "$TARGET" | cut -d: -f2)

if [ -n "$WINDOW_IDX" ]; then
    if [ -n "$TMUX" ]; then
        tmux switch-client -t "${TARGET_SESSION}:${WINDOW_IDX}"
    else
        tmux attach-session -t "${TARGET_SESSION}:${WINDOW_IDX}"
    fi
fi
