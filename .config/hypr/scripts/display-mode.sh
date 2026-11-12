#!/usr/bin/env bash
set -euo pipefail

err() {
    notify-send -u critical "Display mode" "$1" || true
    echo "display-mode: $1" >&2
}

mapfile -t MONITORS < <(hyprctl monitors all -j | jq -r '
    sort_by((.focused | not), .id) | .[].name
')

if (( ${#MONITORS[@]} == 0 )); then
    err "No monitors reported by hyprctl"
    exit 2
fi

PRIMARY="${MONITORS[0]}"
SECONDARY="${MONITORS[1]:-}"

# mon <output> [field=value ...]: one hl.monitor() call. A live override, like the old
# `hyprctl keyword monitor`: the next config reload restores conf/monitors.lua.
mon() {
    local out="$1" kv fields=""
    shift
    for kv in "$@"; do fields+=", $kv"; done
    printf 'hl.monitor({ output = "%s"%s })\n' "$out" "$fields"
}
ON=('mode = "preferred"' 'scale = 1')

apply() {
    local mode="$1"
    case "$mode" in
        mirror)
            [[ -z "$SECONDARY" ]] && { err "Mirror needs 2 displays"; exit 2; }
            hyprctl eval "$(mon "$PRIMARY" "${ON[@]}" 'position = "auto"')
$(mon "$SECONDARY" "${ON[@]}" 'position = "auto"' "mirror = \"$PRIMARY\"")"
            ;;
        extend)
            [[ -z "$SECONDARY" ]] && { err "Extend needs 2 displays"; exit 2; }
            hyprctl eval "$(mon "$PRIMARY" "${ON[@]}" 'position = "0x0"')
$(mon "$SECONDARY" "${ON[@]}" 'position = "auto-right"')"
            ;;
        primary-only)
            if [[ -n "$SECONDARY" ]]; then
                hyprctl eval "$(mon "$PRIMARY" "${ON[@]}" 'position = "auto"')
$(mon "$SECONDARY" 'disabled = true')"
            else
                hyprctl eval "$(mon "$PRIMARY" "${ON[@]}" 'position = "auto"')"
            fi
            ;;
        secondary-only)
            [[ -z "$SECONDARY" ]] && { err "Secondary-only needs 2 displays"; exit 2; }
            hyprctl eval "$(mon "$SECONDARY" "${ON[@]}" 'position = "auto"')
$(mon "$PRIMARY" 'disabled = true')"
            ;;
        *)
            err "Unknown mode: $mode"
            exit 2
            ;;
    esac
    notify-send "Display mode" "Applied: $mode"
}

if (( $# > 0 )); then
    apply "$1"
    exit 0
fi

# No arg → wofi picker. Build the menu based on connected count.
build_menu() {
    if [[ -n "$SECONDARY" ]]; then
        printf '%s\n' \
            "Mirror ($PRIMARY ↔ $SECONDARY)|mirror" \
            "Extend ($PRIMARY + $SECONDARY)|extend" \
            "$PRIMARY only|primary-only" \
            "$SECONDARY only|secondary-only"
    else
        printf '%s\n' "$PRIMARY only|primary-only"
    fi
}

choice="$(build_menu | wofi --dmenu --prompt 'Display mode' --width 420 --height 220 \
    | awk -F'|' 'NF==2 {print $2}')"

if [[ -z "$choice" ]]; then
    exit 1
fi

apply "$choice"
