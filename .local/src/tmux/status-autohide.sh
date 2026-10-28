#!/usr/bin/env bash
# status-autohide.sh - give the status bar's row back to phone-sized clients.
#
# Driven by the client-attached / client-detached / client-resized hooks in
# .tmux.conf. Takes no arguments and re-decides EVERY session, so a detach is
# handled by the same path as an attach - tmux fires client-detached on the
# leaving client, and there is no format that names who is left behind.
#
# The test is client_height, never window_height: hiding the status bar GROWS
# the window by a row, so deciding on window height feeds back into itself and
# flaps around the threshold. A client's own height does not move when the bar
# does.
set -uo pipefail

THRESHOLD="${TMUX_STATUS_MIN_HEIGHT:-20}"

# The whole body lives in a function so the source guard below has something to
# guard. A flat script cannot honour that seam: sourcing it would run the sweep
# against the developer's live tmux server, which is exactly what the seam
# exists to prevent.
#
# `command -v tmux` moved in here with it, because an `exit 0` at top level
# would take the sourcing shell down with it.
autohide_apply() {
    command -v tmux >/dev/null 2>&1 || return 0

    local -A min=()
    local session height current

    while IFS='|' read -r session height; do
        [ -n "$session" ] && [ -n "$height" ] || continue
        current="${min[$session]:-999999}"
        [ "$height" -lt "$current" ] && min["$session"]="$height"
    done < <(tmux list-clients -F '#{client_session}|#{client_height}' 2>/dev/null)

    for session in "${!min[@]}"; do
        if [ "${min[$session]}" -lt "$THRESHOLD" ]; then
            tmux set-option -t "$session" status off 2>/dev/null || true
        else
            tmux set-option -t "$session" status on 2>/dev/null || true
        fi
    done
}

# --- The test seam ----------------------------------------------------------
[[ "${BASH_SOURCE[0]}" != "$0" ]] && return 0

autohide_apply
