#!/usr/bin/env bash

# Tmux Claude status - two modes:
# 1. No args: returns status for current session (for status-left)
# 2. --all: returns all sessions with status (for choose-tree)

get_session_status() {
    local target_session="$1"

    # Where an agent stands is decided once, elsewhere (.local/src/docs/fleet-states.md):
    # agent-panel's live glyph (! prompt or dialog waiting, ~ busy or on a background shell,
    # check = idle) and the bucket in the fleet state document, joined by target. A session
    # with an open ask or a question left for the human is bucket NEEDS even while its pane
    # looks idle or busy, so NEEDS counts as "needs you" here. This script reads both and
    # classifies nothing from pane text.
    #
    # awk and a tagged stream, NOT an associative array: tmux runs status-left through its
    # own environment, so on macOS this gets /bin/bash 3.2 (no `declare -A`), and the status
    # bar once rendered a `declare: -A: invalid option` error instead of the glyphs.
    local server state counts
    server=$(tmux display-message -p '#{socket_path}' 2>/dev/null)
    server="${server##*/}"
    state="${FLEET_STATE_FILE:-${XDG_STATE_HOME:-$HOME/.local/state}/fleet/state.json}"

    # agent-panel targets are <server>/<session>:<window>; only this tmux server's rows count.
    counts=$(
        {
            jq -r '.sessions[]? | [.target, .bucket] | @tsv' "$state" 2>/dev/null | awk '{ print "B\t" $0 }'
            agent-panel list 2>/dev/null | awk '{ print "R\t" $0 }'
        } | awk -F'\t' -v srv="$server" -v want="$target_session" '
            $1 == "B" { bucket[$2] = $3; next }
            $1 == "R" {
                t = $2; rest = t; tsrv = ""
                if (i = index(t, "/")) { tsrv = substr(t, 1, i - 1); rest = substr(t, i + 1) }
                if (srv != "" && tsrv != "" && tsrv != srv) next
                sess = rest; sub(/:[^:]*$/, "", sess)
                if (want != "" && sess != want) next
                total++
                if ($3 == "!" || bucket[t] == "NEEDS") attention++
                else if ($3 == "~") working++
                else idle++
            }
            END { print total + 0, attention + 0, working + 0, idle + 0 }'
    )
    local total attention working idle
    read -r total attention working idle <<< "$counts"

    # Return compact status
    if [ $total -eq 0 ]; then
        echo ""
    elif [ $attention -gt 0 ]; then
        # Needs attention - show count with !
        echo "!${attention}"
    elif [ $working -gt 0 ]; then
        # Working - show spinner-like indicator
        echo "~${working}"
    elif [ $idle -gt 0 ]; then
        # Idle (between turns, nothing to approve) - show checkmark count
        echo "✓${idle}"
    else
        # Unknown state - just show count
        echo "·${total}"
    fi
}

get_short_name() {
    local session="$1"
    case "$session" in
        myapp) echo "pmp" ;;
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

# Sourced (by the test suite) rather than run: every function is defined, nothing executes.
[[ "${BASH_SOURCE[0]}" != "$0" ]] && return 0

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
