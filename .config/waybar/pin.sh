#!/usr/bin/env bash
# Toggle + resize the "mini pin" - a second waybar on the overlay layer that
# floats over fullscreen windows (RustDesk remote, etc).
#
#   pin.sh toggle   show/hide the pin (restores last size)
#   pin.sh size     swap min <-> full while shown (relaunch)
#   pin.sh min      show, minimal view
#   pin.sh full     show, bigger view
#   pin.sh off      hide
#
# State: /tmp/waybar-pin.state holds "min" | "full" (last chosen size).

set -u

CONF_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/waybar"
STYLE="$CONF_DIR/style.css"
STATE_FILE="/tmp/waybar-pin.state"
# Line 1 is the pin's pid, written by `modules.sh pin-up`; the main bar reads the same file.
PIN_SHOWN="${XDG_RUNTIME_DIR:-/tmp}/waybar-pin.shown"

get_size() { [[ -r "$STATE_FILE" ]] && cat "$STATE_FILE" || echo min; }
set_size() { printf '%s' "$1" > "$STATE_FILE"; }

MODULES="$CONF_DIR/modules.sh"

# The pin by its recorded pid, never a pkill -f pattern: that also matches any shell whose
# command line holds it, this script's caller included. A pid that is no longer a waybar on a
# pin config (the pin died and the pid was reused, by the main bar too) is no pin.
pin_pid() {
    local pid="" comm=""
    [[ -r "$PIN_SHOWN" ]] && read -r pid < "$PIN_SHOWN"
    [[ "$pid" =~ ^[0-9]+$ ]] && read -r comm 2>/dev/null < "/proc/$pid/comm"
    [[ "$comm" == waybar ]] && grep -qaF config.pin "/proc/$pid/cmdline" 2>/dev/null && echo "$pid"
}
running() { pin_pid >/dev/null; }

stop() {
    local pid
    if pid="$(pin_pid)"; then
        kill "$pid" 2>/dev/null
        # Settle so the old layer surface is gone before a new one maps, and so pin-down never
        # drops the record of a pin still up. Polled because the pin is not this shell's child,
        # so there is nothing to `wait` on; one second, then SIGKILL.
        for _ in {1..20}; do kill -0 "$pid" 2>/dev/null || break; sleep 0.05; done
        kill -0 "$pid" 2>/dev/null && kill -9 "$pid"
    fi
    "$MODULES" pin-down
}

start() {
    local size="$1"
    [[ "$size" == "full" ]] || size="min"
    set_size "$size"
    stop
    # setsid puts the pin in its own session, so it survives the calling
    # shell/terminal, not just the Hyprland exec double-fork - `pin.sh` behaves the
    # same from a keybind or a terminal. No -f: a background job of a
    # non-interactive shell is never a group leader, so setsid execs in place and
    # $! is waybar's own pid, which the main bar uses as the pin's liveness check.
    # WAYBAR_PIN=1 tells this bar's gated execs they are the pin (modules.sh).
    WAYBAR_PIN=1 setsid waybar -c "$CONF_DIR/config.pin-$size" -s "$STYLE" >/dev/null 2>&1 </dev/null &
    local pid=$!
    disown
    "$MODULES" pin-up "$pid" "$CONF_DIR/config.pin-$size"
}

case "${1:-toggle}" in
    toggle) if running; then stop; else start "$(get_size)"; fi ;;
    size)   if [[ "$(get_size)" == "full" ]]; then start min; else start full; fi ;;
    min)    start min ;;
    full)   start full ;;
    off)    stop ;;
    reload) hyprctl reload >/dev/null 2>&1 || true
            systemctl --user restart waybar >/dev/null 2>&1 || true
            if running; then start "$(get_size)"; fi ;;
    *)      echo "usage: pin.sh {toggle|size|min|full|off|reload}" >&2; exit 2 ;;
esac
