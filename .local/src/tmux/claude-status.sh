#!/usr/bin/env bash

# Tmux Claude status - two modes:
# 1. No args: returns status for current session (for status-left)
# 2. --all: returns all sessions with status (for choose-tree)

# The panel's count: sourcing this file (the test suite) can point it at a stub.
QUESTIONS_SH="${QUESTIONS_SH:-${BASH_SOURCE[0]%/*}/questions.sh}"

get_session_status() {
    local target_session="$1"

    # `!N` is the number of questions waiting on the human: the Prefix y panel's own count
    # (`questions.sh count`: every pending ask file, held or live, plus every open dialog), the
    # same fleet-wide number whatever session the bar is drawn in. `~` and the check count this
    # tmux server's agents in the session: where an agent stands is decided once, elsewhere
    # (.local/src/docs/fleet-states.md), by agent-panel's live glyph (~ busy or on a background
    # shell, check = idle). This script classifies nothing from pane text.
    #
    # awk, NOT an associative array: tmux runs status-left through its own environment, so on
    # macOS this gets /bin/bash 3.2 (no `declare -A`), and the status bar once rendered a
    # `declare: -A: invalid option` error instead of the glyphs.
    local server counts questions
    server=$(tmux display-message -p '#{socket_path}' 2>/dev/null)
    server="${server##*/}"
    questions=$("$QUESTIONS_SH" count 2>/dev/null)
    questions="${questions//[!0-9]/}"

    # agent-panel targets are <server>/<session>:<window>; only this tmux server's rows count.
    counts=$(
        agent-panel list 2>/dev/null | awk -F'\t' -v srv="$server" -v want="$target_session" '
            {
                t = $1; rest = t; tsrv = ""
                if (i = index(t, "/")) { tsrv = substr(t, 1, i - 1); rest = substr(t, i + 1) }
                if (srv != "" && tsrv != "" && tsrv != srv) next
                sess = rest; sub(/:[^:]*$/, "", sess)
                if (want != "" && sess != want) next
                total++
                if ($2 == "~") working++
                else if ($2 == "✓") idle++
            }
            END { print total + 0, working + 0, idle + 0 }'
    )
    local total working idle
    read -r total working idle <<< "$counts"
    local attention="${questions:-0}"

    # Return compact status
    if [ "$attention" -gt 0 ]; then
        # Questions waiting on you - show the count with !
        echo "!${attention}"
    elif [ $total -eq 0 ]; then
        echo ""
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
