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
    local server counts questions list
    server=$(tmux display-message -p '#{socket_path}' 2>/dev/null)
    server="${server##*/}"
    questions=$("$QUESTIONS_SH" count 2>/dev/null)
    questions="${questions//[!0-9]/}"
    # AGENT_LIST: the list the status-left path already read, so one refresh calls agent-panel once.
    if [ -n "${AGENT_LIST+x}" ]; then list=$AGENT_LIST; else list=$(agent-panel list 2>/dev/null); fi

    # agent-panel targets are <server>/<session>:<window>; only this tmux server's rows count.
    counts=$(
        printf '%s' "$list" | awk -F'\t' -v srv="$server" -v want="$target_session" '
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

# project_glyphs <agent-panel list>: copy each agent's live glyph onto its window as @agent_glyph,
# for the window-status format (.tmux.conf @agent_fmt), and clear it from a window that no longer
# holds an agent. A projection, never read back. Two agents in one window show the one that matters
# most: ! over ~ over the check. One tmux call, none when no glyph changed. It rides the status-left
# refresh (status-interval) because agent-panel's status files have no change event to wait on.
project_glyphs() {
    local server op t g
    local -a cmd=()
    server=$(tmux display-message -p '#{socket_path}' 2>/dev/null)
    server="${server##*/}"
    while IFS=$'\t' read -r op t g; do
        [ -n "$t" ] || continue
        [ ${#cmd[@]} -gt 0 ] && cmd+=(\;)
        if [ "$op" = set ]; then cmd+=(set-option -wq -t "=$t" @agent_glyph "$g")
        else cmd+=(set-option -wqu -t "=$t" @agent_glyph); fi
    done < <(
        { tmux list-windows -a -F $'#{session_name}:#{window_index}\t#{@agent_glyph}' 2>/dev/null | sed $'s/^/H\t/'
          printf '%s\n' "$1" | sed $'s/^/A\t/'; } |
        awk -F'\t' -v srv="$server" '
            function rank(g) { return g == "!" ? 3 : g == "~" ? 2 : 1 }
            $1 == "H" { have[$2] = $3; next }
            $1 == "A" && $2 != "" {
                t = $2; rest = t; tsrv = ""
                if (i = index(t, "/")) { tsrv = substr(t, 1, i - 1); rest = substr(t, i + 1) }
                if (srv != "" && tsrv != "" && tsrv != srv) next
                if (!(rest in want) || rank($3) > rank(want[rest])) want[rest] = $3
            }
            END {
                # Only windows tmux listed: a row for a window that is gone would fail its
                # set-option, and tmux drops the rest of a command list at the first failure.
                for (t in want) if ((t in have) && have[t] != want[t]) print "set\t" t "\t" want[t]
                for (t in have) if (have[t] != "" && !(t in want)) print "unset\t" t
            }'
    )
    [ ${#cmd[@]} -gt 0 ] && tmux "${cmd[@]}" >/dev/null 2>&1
    return 0
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
        # Default: current session. The status-left path, so it also projects each window's glyph.
        # A failed list projects nothing, so a hiccup does not blank every window's glyph.
        AGENT_LIST=$(agent-panel list 2>/dev/null) && project_glyphs "$AGENT_LIST"
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
