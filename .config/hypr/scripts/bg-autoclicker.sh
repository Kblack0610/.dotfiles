#!/usr/bin/env bash
# bg-autoclicker.sh - toggle a HELD mouse button via ydotool, for AFK-farming a
# RawInput game (e.g. Palworld) that ignores synthetic X clicks (XTEST). ydotool
# creates a real /dev/uinput device, which RawInput accepts.
#
# Press once  -> button is pressed and HELD DOWN (continuous swing/mine/attack).
# Press again -> button RELEASED.
#
# The event goes to the FOCUSED window, so keep the game focused on its monitor.
# Because a Hyprland keybind does not change focus, toggling via the keybind
# leaves the game focused and the hold lands on it. You can do PASSIVE things on
# another monitor (watch/read); actively clicking another window moves focus and
# the hold stops landing there - a one-input-seat Wayland limit, not fixable.
#
# Usage: bg-autoclicker.sh [left|right|middle]   (default left)
# Needs ydotoold running (auto-started here if the socket is missing; for a
# persistent daemon enable the ydotoold.service user unit).

set -uo pipefail
export YDOTOOL_SOCKET="${YDOTOOL_SOCKET:-/run/user/$(id -u)/.ydotool_socket}"

BTN="${1:-left}"
case "$BTN" in
    left)   DOWN=0x40; UP=0x80 ;;
    right)  DOWN=0x41; UP=0x81 ;;
    middle) DOWN=0x42; UP=0x82 ;;
    *) echo "unknown button: $BTN (use left|right|middle)" >&2; exit 2 ;;
esac
STATE="/tmp/bg-hold-${BTN}.state"

notify() { command -v notify-send >/dev/null 2>&1 && notify-send -t 1500 "farm-hold" "$1"; }

# ensure the daemon/socket exists
if [[ ! -S "$YDOTOOL_SOCKET" ]]; then
    setsid ydotoold >/tmp/ydotoold-user.log 2>&1 &
    for _ in 1 2 3 4 5 6 7 8 9 10; do [[ -S "$YDOTOOL_SOCKET" ]] && break; sleep 0.2; done
fi
if [[ ! -S "$YDOTOOL_SOCKET" ]]; then
    notify "ydotoold not running (no socket)"; exit 1
fi

# toggle
if [[ -f "$STATE" ]]; then
    ydotool click "$UP" >/dev/null 2>&1
    rm -f "$STATE"
    notify "$BTN RELEASED"
else
    ydotool click "$DOWN" >/dev/null 2>&1
    : > "$STATE"
    notify "$BTN HELD - keep the game focused"
fi
