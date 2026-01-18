#!/bin/bash

# Tmux Claude status - two modes:
# 1. No args: returns status for current session (for status-left)
# 2. --all: returns all sessions with status (for choose-tree)

get_session_status() {
    local target_session="$1"
    local attention=0
    local working=0
    local done=0
    local total=0

    declare -A seen_windows

    while IFS=: read -r session window_idx window_name pane_cmd pane_pid pane_path; do
        # Filter to target session if specified
        [[ -n "$target_session" && "$session" != "$target_session" ]] && continue

        window_key="${session}:${window_idx}"
        [[ -n "${seen_windows[$window_key]}" ]] && continue

        if [[ "$pane_cmd" == "claude" ]]; then
            seen_windows[$window_key]=1
            ((total++))

            # Capture last lines to detect state
            local last_lines=$(tmux capture-pane -t "${session}:${window_idx}" -p -S -15 2>/dev/null | tail -15)

            # Check recent activity first - determines if Claude is actively outputting
            local last_activity=$(tmux display-message -p -t "${session}:${window_idx}" "#{window_activity}" 2>/dev/null)
            local now=$(date +%s)
            local activity_diff=9999
            if [ -n "$last_activity" ]; then
                activity_diff=$((now - last_activity))
            fi

            # Priority 1: Interactive questions needing input (Allow/Deny, Y/n)
            if echo "$last_lines" | grep -qE '\[Y/n\]|\[y/N\]|yes.*no.*:|proceed\?'; then
                ((attention++))
            # Priority 2: Permission prompts with Allow/Deny options
            elif echo "$last_lines" | grep -qE 'Allow.*once|Allow.*always|Deny|Do you want to'; then
                ((attention++))
            # Priority 3: Check if actively working (recent output within 3 seconds)
            elif [ $activity_diff -lt 3 ]; then
                ((working++))
            # Priority 4: At prompt waiting for input (DONE state)
            # Claude shows "> " prompt line and "bypass permissions" or "Context left" in status
            elif echo "$last_lines" | grep -qE '^> |^❯ '; then
                # Has prompt - check if it's waiting (not mid-typing with recent activity)
                if echo "$last_lines" | grep -qE 'bypass permissions|Context left'; then
                    ((done++))
                else
                    ((done++))
                fi
            # Priority 5: Shows status bar indicators (Claude is idle/waiting)
            elif echo "$last_lines" | grep -qE '⏵⏵|bypass permissions|Context left until'; then
                ((done++))
            # Fallback: If no recent activity, assume done
            elif [ $activity_diff -gt 10 ]; then
                ((done++))
            else
                ((working++))
            fi
        fi
    done < <(tmux list-panes -a -F "#{session_name}:#{window_index}:#{window_name}:#{pane_current_command}:#{pane_pid}:#{pane_current_path}" 2>/dev/null)

    # Return compact status
    if [ $total -eq 0 ]; then
        echo ""
    elif [ $attention -gt 0 ]; then
        # Needs attention - show count with !
        echo "!${attention}"
    elif [ $working -gt 0 ]; then
        # Working - show spinner-like indicator
        echo "~${working}"
    elif [ $done -gt 0 ]; then
        # Done/idle - show checkmark count
        echo "✓${done}"
    else
        # Unknown state - just show count
        echo "·${total}"
    fi
}

get_short_name() {
    local session="$1"
    case "$session" in
        placemyparents) echo "pmp" ;;
        ai-lab|ailab) echo "lab" ;;
        dotfiles) echo "dot" ;;
        home) echo "hom" ;;
        platform) echo "plt" ;;
        network) echo "net" ;;
        kenneth-black-portfolio) echo "kbp" ;;
        hub) echo "hub" ;;
        *) echo "${session:0:3}" ;;
    esac
}

# Main
case "$1" in
    --session)
        # Get status for specific session
        get_session_status "$2"
        ;;
    --current)
        # Get status for current session (default for status-left)
        current=$(tmux display-message -p '#{session_name}')
        st=$(get_session_status "$current")
        short=$(get_short_name "$current")
        if [ -n "$st" ]; then
            echo "${short}${st}"
        else
            echo "${short}"
        fi
        ;;
    --format)
        # Format for choose-tree: session_name -> short_name + status
        sess="$2"
        short=$(get_short_name "$sess")
        st=$(get_session_status "$sess")
        if [ -n "$st" ]; then
            echo "${short}${st}"
        else
            echo "${short}"
        fi
        ;;
    *)
        # Default: current session
        current=$(tmux display-message -p '#{session_name}')
        st=$(get_session_status "$current")
        short=$(get_short_name "$current")
        if [ -n "$st" ]; then
            echo "${short}${st}"
        else
            echo "${short}"
        fi
        ;;
esac
