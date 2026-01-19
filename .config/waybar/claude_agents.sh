#!/bin/bash

# Waybar module for Claude agents
# Shows status with icons:  ghe ✓~! | shk ✓ | dot ~
# Groups agents by PROJECT (working directory) not session
# ✓ = ready/good, ! = needs attention, ~ = in progress

# Extract project short name from working directory path
get_project_from_path() {
    local path="$1"
    local dir_name=$(basename "$path")

    # Strip agent suffixes (gheeggle-agent-2 -> gheeggle)
    dir_name=$(echo "$dir_name" | sed -E 's/-agent-?[0-9]*$//')

    # Apply project mapping
    case "$dir_name" in
        gheeggle*) echo "ghe" ;;
        shack) echo "shk" ;;
        dotfiles|.dotfiles) echo "dot" ;;
        binks*) echo "bnk" ;;
        placemyparents) echo "pmp" ;;
        ai-lab) echo "lab" ;;
        *) echo "${dir_name:0:3}" ;;
    esac
}

get_claude_status() {
    declare -A seen_windows
    declare -A project_agents    # project -> list of statuses
    declare -A project_sessions  # project -> list of session:window for tooltip
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

            # Extract project from working directory
            project=$(get_project_from_path "$pane_path")

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
                tooltip_status="!"
                has_urgent=true
            # Priority 2: Actively working (recent output within 3 seconds)
            elif [ $activity_diff -lt 3 ]; then
                status="~"  # Working (in progress)
                tooltip_status="~"
                has_working=true
            # Priority 3: At prompt or showing status bar (DONE)
            elif echo "$last_lines" | grep -qE '^> |^❯ |⏵⏵|bypass permissions|Context left until'; then
                status="✓"  # Done, ready (checkmark)
                tooltip_status="✓"
            # Fallback: No recent activity = done
            elif [ $activity_diff -gt 10 ]; then
                status="✓"
                tooltip_status="✓"
            else
                status="~"  # Probably working
                tooltip_status="~"
                has_working=true
            fi

            # Build project agents list
            project_agents[$project]+="$status"

            # Track session:window for tooltip
            project_sessions[$project]+="${tooltip_status} ${session}:${window_idx}\\n"
        fi
    done < <(tmux list-panes -a -F "#{session_name}:#{window_index}:#{window_name}:#{pane_current_command}:#{pane_pid}:#{pane_current_path}" 2>/dev/null)

    # Build display text (sorted alphabetically by project)
    local display=""
    local sorted_projects=($(echo "${!project_agents[@]}" | tr ' ' '\n' | sort))

    for project in "${sorted_projects[@]}"; do
        agents="${project_agents[$project]}"
        if [ -n "$display" ]; then
            display+=" │ "
        fi
        display+="${project} ${agents}"
    done

    # Build tooltip with project grouping
    for project in "${sorted_projects[@]}"; do
        tooltip+="${project}:\\n${project_sessions[$project]}"
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
