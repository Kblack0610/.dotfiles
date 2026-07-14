#!/usr/bin/env bash
# which-key style popup for the pin leader submaps (see hypr/conf.d/leader.conf).
# Replace-in-place via a fixed notification id so nested levels swap the popup
# rather than stacking. Auto-expires as a safety net if a submap is left open.
#
# Usage: pin-hint.sh {main|utils|settings|sync|git|timebox|close}
set -u

ID=990011
TIMEOUT=8000

show() {
    if command -v dunstify >/dev/null 2>&1; then
        dunstify -r "$ID" -t "$TIMEOUT" -u low "$1" "$2"
    else
        notify-send -t "$TIMEOUT" "$1" "$2"
    fi
}
close() { command -v dunstify >/dev/null 2>&1 && dunstify -C "$ID" 2>/dev/null || true; }

case "${1:-main}" in
    main)  show " pin leader" "t toggle\nu utils >     s settings >\nesc/q exit" ;;
    utils) show " pin / utils" "a agents      h ssh\nr reload      t timebox >\ny sync >      g git >\nesc back      q exit" ;;
    settings) show " pin / settings" "s size\nesc back      q exit" ;;
    sync)  show " pin / sync" "d restow dotfiles\nn pull notes\nesc back     q exit" ;;
    git)   show " pin / git" "p pull dot+notes\ns git status\nesc back     q exit" ;;
    timebox) show " pin / timebox" "s start      w switch\np pause      r resume\nx stop       o status\nesc back      q exit" ;;
    close) close ;;
    *)     echo "usage: pin-hint.sh {main|utils|settings|sync|git|timebox|close}" >&2; exit 2 ;;
esac
