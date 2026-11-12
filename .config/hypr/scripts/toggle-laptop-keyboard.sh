#!/bin/bash
# Toggle the internal laptop keyboard on/off
# Useful when using an external keyboard like ZMK Corne

INTERNAL_KB="razer-razer-blade-keyboard"
STATE_FILE="/tmp/laptop-keyboard-disabled"

kb_enabled() { hyprctl eval "hl.device({ name = \"$INTERNAL_KB\", enabled = $1 })"; }

toggle() {
    if [[ -f "$STATE_FILE" ]]; then
        # Currently disabled, enable it
        kb_enabled true
        rm -f "$STATE_FILE"
        notify-send -t 2000 "Keyboard" "Internal keyboard enabled"
    else
        # Currently enabled, disable it
        kb_enabled false
        touch "$STATE_FILE"
        notify-send -t 2000 "Keyboard" "Internal keyboard disabled"
    fi
}

enable() {
    kb_enabled true
    rm -f "$STATE_FILE"
    notify-send -t 2000 "Keyboard" "Internal keyboard enabled"
}

disable() {
    kb_enabled false
    touch "$STATE_FILE"
    notify-send -t 2000 "Keyboard" "Internal keyboard disabled"
}

status() {
    if [[ -f "$STATE_FILE" ]]; then
        echo "disabled"
    else
        echo "enabled"
    fi
}

case "${1:-toggle}" in
    toggle) toggle ;;
    enable) enable ;;
    disable) disable ;;
    status) status ;;
    *) echo "Usage: $0 {toggle|enable|disable|status}" ;;
esac
