#!/bin/bash

# Waybar module for Claude agents
# Shows status with icons:  lab ✓ ~ |  pmp !
# ✓ = ready/good, ! = needs attention, ~ = in progress

get_claude_status() {
    declare -A seen_windows
    declare -A session_agents  # session -> list of statuses
    declare -A session_short   # session -> short name
    declare -A session_classes # session -> class for urgent highlighting
    local tooltip=""
    local has_urgent=false
    local has_working=false
    local AGENT_PATTERN="^(claude|claude-real|aider|opencode)$"

    while IFS=: read -r session window_idx window_name pane_cmd pane_pid pane_path; do
        window_key="${session}:${window_idx}"
        [[ -n "${seen_windows[$window_key]}" ]] && continue

        # Count panes running AI agents
        if [[ "$pane_cmd" =~ $AGENT_PATTERN ]]; then
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
                tooltip_status="! NEEDS INPUT"
                has_urgent=true
            # Priority 2: Actively working (recent output within 3 seconds)
            elif [ $activity_diff -lt 3 ]; then
                status="~"  # Working (in progress)
                tooltip_status="~ Working"
                has_working=true
            # Priority 3: At prompt or showing status bar (DONE)
            elif echo "$last_lines" | grep -qE '^> |^❯ |⏵⏵|bypass permissions|Context left until'; then
                status="✓"  # Done, ready (checkmark)
                tooltip_status="✓ Ready"
            # Fallback: No recent activity = done
            elif [ $activity_diff -gt 10 ]; then
                status="✓"
                tooltip_status="✓ Idle"
            else
                status="~"  # Probably working
                tooltip_status="~ Working"
                has_working=true
            fi

            # Build session agents list
            session_agents[$session]+="$status"

            # Create short session name (first 3 chars or abbreviation)
            if [ -z "${session_short[$session]}" ]; then
                case "$session" in
                    placemyparents) session_short[$session]="pmp" ;;
                    ai-lab) session_short[$session]="lab" ;;
                    dotfiles) session_short[$session]="dot" ;;
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
            display+=" │ "
        fi
        display+="${short} ${agents}"
    done

    # Remove trailing newline from tooltip
    tooltip="${tooltip%\\n}"

    # Determine class based on state priority
    local css_class="idle"
    if $has_urgent; then
        css_class="urgent"
    elif $has_working; then
        css_class="working"
    elif [ -n "$display" ]; then
        css_class="ready"
    fi

    if [ -n "$display" ]; then
        echo "{\"text\": \" ${display}\", \"tooltip\": \"Claude Agents:\\n${tooltip}\", \"class\": \"${css_class}\"}"
    else
        echo "{\"text\": \" \", \"tooltip\": \"No Claude agents running\", \"class\": \"inactive\"}"
    fi
}

get_claude_status
