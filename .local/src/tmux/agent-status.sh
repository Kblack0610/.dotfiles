#!/bin/bash

# Tmux agent status - two modes:
# 1. No args: returns status for current session (for status-left)
# 2. --all: returns all sessions with status (for choose-tree)

SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
source "$SCRIPT_DIR/agent-lib.sh"

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

        if is_agent_pane "$session" "$window_idx" "$pane_cmd"; then
            seen_windows[$window_key]=1
            ((total++))

            case "$(get_agent_state "${session}:${window_idx}")" in
                '!') ((attention++)) ;;
                '~') ((working++)) ;;
                '✓') ((done++)) ;;
            esac
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
