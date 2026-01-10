#!/bin/bash
# Toggle the internal laptop keyboard on/off
# Useful when using an external keyboard like ZMK Corne

INTERNAL_KB="razer-razer-blade-keyboard"
STATE_FILE="/tmp/laptop-keyboard-disabled"

toggle() {
    if [[ -f "$STATE_FILE" ]]; then
        # Currently disabled, enable it
        hyprctl keyword "device[$INTERNAL_KB]:enabled" true
        rm -f "$STATE_FILE"
        notify-send -t 2000 "Keyboard" "Internal keyboard enabled"
    else
        # Currently enabled, disable it
        hyprctl keyword "device[$INTERNAL_KB]:enabled" false
        touch "$STATE_FILE"
        notify-send -t 2000 "Keyboard" "Internal keyboard disabled"
    fi
}

enable() {
    hyprctl keyword "device[$INTERNAL_KB]:enabled" true
    rm -f "$STATE_FILE"
    notify-send -t 2000 "Keyboard" "Internal keyboard enabled"
}

disable() {
    hyprctl keyword "device[$INTERNAL_KB]:enabled" false
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
