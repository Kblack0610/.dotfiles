#!/usr/bin/env bash
# Toggle a display's content on/off via DPMS.
# Keeps windows/workspaces in place — just blanks (powers off) the screen.
#   no arg          → single monitor: toggle it; multiple: wofi picker
#   <monitor name>  → toggle that monitor
#   all             → toggle every monitor
set -euo pipefail

err() {
    notify-send -u critical "Monitor toggle" "$1" || true
    echo "monitor-toggle: $1" >&2
}

mapfile -t MONITORS < <(hyprctl monitors all -j | jq -r '.[].name')

if (( ${#MONITORS[@]} == 0 )); then
    err "No monitors reported by hyprctl"
    exit 2
fi

toggle() {
    local target="$1"
    if [[ "$target" == all ]]; then
        hyprctl dispatch dpms toggle
        notify-send "Monitor toggle" "Toggled all displays"
    else
        hyprctl dispatch dpms toggle "$target"
        notify-send "Monitor toggle" "Toggled: $target"
    fi
}

# Explicit target.
if (( $# > 0 )); then
    toggle "$1"
    exit 0
fi

# Single monitor → just toggle it, no picker.
if (( ${#MONITORS[@]} == 1 )); then
    toggle "${MONITORS[0]}"
    exit 0
fi

# Multiple → wofi picker. Show on/off state per monitor.
build_menu() {
    hyprctl monitors all -j | jq -r '
        .[] | "\(.name) [\(if .dpmsStatus then "ON" else "OFF" end)]|\(.name)"'
    echo "All displays|all"
}

choice="$(build_menu | wofi --dmenu --prompt 'Toggle display' --width 420 --height 260 \
    | awk -F'|' 'NF==2 {print $2}')"

[[ -z "$choice" ]] && exit 1
toggle "$choice"
