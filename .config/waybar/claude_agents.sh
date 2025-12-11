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

            # Get activity status
            last_activity=$(tmux display-message -p -t "${session}:${window_idx}" "#{window_activity}" 2>/dev/null)
            now=$(date +%s)

            if [ -n "$last_activity" ]; then
                diff=$((now - last_activity))
                if [ $diff -lt 60 ]; then
                    # Active - recently responded
                    status="✓"
                    tooltip_status="●"
                else
                    # Idle - waiting for input or thinking
                    status="✗"
                    tooltip_status="○"
                fi
            else
                status="?"
                tooltip_status="?"
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

            # Build tooltip
            dir_name=$(basename "$pane_path" 2>/dev/null || echo "~")
            tooltip+="${tooltip_status} ${session}:${window_idx}:${window_name} [${dir_name}]\\n"
        fi
    done < <(tmux list-panes -a -F "#{session_name}:#{window_index}:#{window_name}:#{pane_current_command}:#{pane_pid}:#{pane_current_path}" 2>/dev/null)

    # Build display text
    local display=""
    for session in "${!session_agents[@]}"; do
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
