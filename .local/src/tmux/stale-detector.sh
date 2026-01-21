#!/bin/bash

# Detects stale tmux windows (agent windows where process has exited)
# Usage: stale-detector.sh [--json] [--threshold SECONDS]
#
# A window is stale when:
# 1. Window name matches agent pattern (agent, claude, aider)
# 2. Current command is shell (process exited/returned)
# 3. Idle time exceeds threshold

SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
CONFIG_FILE="$SCRIPT_DIR/tmux-manager.conf"

# Load config if exists
if [[ -f "$CONFIG_FILE" ]]; then
    source "$CONFIG_FILE"
fi

# Defaults
STALE_THRESHOLD="${STALE_THRESHOLD:-900}"  # 15 minutes
AGENT_WINDOW_PATTERNS="${AGENT_WINDOW_PATTERNS:-agent|claude|aider}"
OUTPUT_JSON=0

# Parse args
while [[ $# -gt 0 ]]; do
    case "$1" in
        --json|-j)
            OUTPUT_JSON=1
            shift
            ;;
        --threshold|-t)
            STALE_THRESHOLD="$2"
            shift 2
            ;;
        *)
            shift
            ;;
    esac
done

NOW=$(date +%s)
STALE_WINDOWS=()

# Scan all windows
while IFS=: read -r session window_idx window_name pane_cmd pane_path activity; do
    # Skip if not an agent window (by name)
    if ! echo "$window_name" | grep -qiE "$AGENT_WINDOW_PATTERNS"; then
        continue
    fi

    # Check if process has exited (returned to shell)
    if ! [[ "$pane_cmd" =~ ^(zsh|bash|sh|fish)$ ]]; then
        continue
    fi

    # Calculate idle time
    IDLE_SECONDS=0
    if [[ -n "$activity" && "$activity" =~ ^[0-9]+$ ]]; then
        IDLE_SECONDS=$((NOW - activity))
    fi

    # Check if exceeds threshold
    if [[ $IDLE_SECONDS -lt $STALE_THRESHOLD ]]; then
        continue
    fi

    # This window is stale
    STALE_WINDOWS+=("$session:$window_idx:$window_name:$pane_path:$IDLE_SECONDS")

done < <(tmux list-windows -a -F "#{session_name}:#{window_index}:#{window_name}:#{pane_current_command}:#{pane_current_path}:#{window_activity}" 2>/dev/null)

# Output
if [[ $OUTPUT_JSON -eq 1 ]]; then
    # JSON output for scripting
    echo "{"
    echo "  \"threshold_seconds\": $STALE_THRESHOLD,"
    echo "  \"stale_windows\": ["

    first=1
    for entry in "${STALE_WINDOWS[@]}"; do
        IFS=: read -r session window_idx window_name pane_path idle_seconds <<< "$entry"

        [[ $first -eq 0 ]] && echo ","
        first=0

        # Format idle time
        idle_min=$((idle_seconds / 60))
        idle_hr=$((idle_min / 60))
        if [[ $idle_hr -gt 0 ]]; then
            idle_fmt="${idle_hr}h $((idle_min % 60))m"
        else
            idle_fmt="${idle_min}m"
        fi

        cat <<EOF
    {
      "session": "$session",
      "window_index": $window_idx,
      "window_name": "$window_name",
      "path": "$pane_path",
      "idle_seconds": $idle_seconds,
      "idle_formatted": "$idle_fmt"
    }
EOF
    done

    echo ""
    echo "  ]"
    echo "}"
else
    # Human-readable output
    if [[ ${#STALE_WINDOWS[@]} -eq 0 ]]; then
        echo "No stale windows found (threshold: ${STALE_THRESHOLD}s)"
        exit 0
    fi

    echo "Stale windows (idle > $((STALE_THRESHOLD / 60))m):"
    echo ""

    for entry in "${STALE_WINDOWS[@]}"; do
        IFS=: read -r session window_idx window_name pane_path idle_seconds <<< "$entry"

        # Format idle time
        idle_min=$((idle_seconds / 60))
        idle_hr=$((idle_min / 60))
        if [[ $idle_hr -gt 0 ]]; then
            idle_fmt="${idle_hr}h $((idle_min % 60))m"
        else
            idle_fmt="${idle_min}m"
        fi

        printf "  %-12s %-4s %-20s %s idle\n" "$session" ":$window_idx" "$window_name" "$idle_fmt"
    done

    echo ""
    echo "Total: ${#STALE_WINDOWS[@]} stale window(s)"
fi
