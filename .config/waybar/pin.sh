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
MATCH='waybar.*config.pin'   # pgrep/pkill pattern for the pin instance only

running() { pgrep -f "$MATCH" >/dev/null 2>&1; }
get_size() { [[ -r "$STATE_FILE" ]] && cat "$STATE_FILE" || echo min; }
set_size() { printf '%s' "$1" > "$STATE_FILE"; }

stop() { pkill -f "$MATCH" 2>/dev/null; }

start() {
    local size="$1"
    [[ "$size" == "full" ]] || size="min"
    set_size "$size"
    stop
    # brief settle so the old layer surface is gone before the new one maps
    for _ in 1 2 3 4 5; do running || break; sleep 0.05; done
    # setsid -f fully detaches: survives the calling shell/terminal, not just
    # the Hyprland exec double-fork - so `pin.sh` behaves the same from a keybind
    # or a terminal.
    setsid -f waybar -c "$CONF_DIR/config.pin-$size" -s "$STYLE" >/dev/null 2>&1 </dev/null
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
