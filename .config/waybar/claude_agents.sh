#!/bin/bash

# Waybar module for Claude agents
# Shows shorthand session status: ai-lab: ✓✓✗ | pmp: ✓✓

get_claude_status() {
    declare -A seen_windows
    declare -A session_agents  # session -> list of statuses
    declare -A session_short   # session -> short name
    local tooltip=""

    while IFS=: read -r session window_idx window_name pane_cmd pane_pid pane_path; do
        window_key="${session}:${window_idx}"
        [[ -n "${seen_windows[$window_key]}" ]] && continue

        # Only count panes where claude is the direct command
        if [[ "$pane_cmd" == "claude" ]]; then
            seen_windows[$window_key]=1

            # Capture last lines to detect state
            last_lines=$(tmux capture-pane -t "${session}:${window_idx}" -p -S -15 2>/dev/null | tail -15)

            # Get activity status
            last_activity=$(tmux display-message -p -t "${session}:${window_idx}" "#{window_activity}" 2>/dev/null)
            now=$(date +%s)
            activity_diff=9999
            if [ -n "$last_activity" ]; then
                activity_diff=$((now - last_activity))
            fi

            # Determine state based on content and activity
            # Priority 1: Interactive questions needing input
            if echo "$last_lines" | grep -qE '\[Y/n\]|\[y/N\]|Allow.*once|Allow.*always|Deny|Do you want to'; then
                status="!"  # Needs attention
                tooltip_status="⚠"
            # Priority 2: Actively working (recent output within 3 seconds)
            elif [ $activity_diff -lt 3 ]; then
                status="~"  # Working
                tooltip_status="◐"
            # Priority 3: At prompt or showing status bar (DONE)
            elif echo "$last_lines" | grep -qE '^> |^❯ |⏵⏵|bypass permissions|Context left until'; then
                status="✓"  # Done, waiting for input
                tooltip_status="●"
            # Fallback: No recent activity = done
            elif [ $activity_diff -gt 10 ]; then
                status="✓"
                tooltip_status="●"
            else
                status="~"  # Probably working
                tooltip_status="◐"
            fi

            # Build session agents list
            session_agents[$session]+="$status"

            # Create short session name (first 3 chars or abbreviation)
            if [ -z "${session_short[$session]}" ]; then
                case "$session" in
                    placemyparents) session_short[$session]="pmp" ;;
                    ai-lab) session_short[$session]="lab" ;;
                    *) session_short[$session]="${session:0:3}" ;;
                esac
            fi

            # Build tooltip with state description
            dir_name=$(basename "$pane_path" 2>/dev/null || echo "~")
            tooltip+="${tooltip_status} ${session}:${window_idx}:${window_name} [${dir_name}]\\n"
        fi
    done < <(tmux list-panes -a -F "#{session_name}:#{window_index}:#{window_name}:#{pane_current_command}:#{pane_pid}:#{pane_current_path}" 2>/dev/null)

    # Build display text (in tmux session order)
    local display=""
    local session_order=()

    # Get sessions in tmux order
    while IFS= read -r session; do
        [[ -n "${session_agents[$session]}" ]] && session_order+=("$session")
    done < <(tmux list-sessions -F "#{session_name}" 2>/dev/null)

    for session in "${session_order[@]}"; do
        short="${session_short[$session]}"
        agents="${session_agents[$session]}"
        if [ -n "$display" ]; then
            display+=" | "
        fi
        display+="${short}: ${agents}"
    done

    # Remove trailing newline from tooltip
    tooltip="${tooltip%\\n}"

    if [ -n "$display" ]; then
        echo "{\"text\": \"${display}\", \"tooltip\": \"Claude Agents:\\n${tooltip}\", \"class\": \"active\"}"
    else
        echo "{\"text\": \"\", \"tooltip\": \"No Claude agents running\", \"class\": \"inactive\"}"
    fi
}

get_claude_status
