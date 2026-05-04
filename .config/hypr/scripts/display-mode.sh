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

apply() {
    local mode="$1"
    case "$mode" in
        mirror)
            [[ -z "$SECONDARY" ]] && { err "Mirror needs 2 displays"; exit 2; }
            hyprctl --batch "\
                keyword monitor $PRIMARY,preferred,auto,1 ; \
                keyword monitor $SECONDARY,preferred,auto,1,mirror,$PRIMARY"
            ;;
        extend)
            [[ -z "$SECONDARY" ]] && { err "Extend needs 2 displays"; exit 2; }
            hyprctl --batch "\
                keyword monitor $PRIMARY,preferred,0x0,1 ; \
                keyword monitor $SECONDARY,preferred,auto-right,1"
            ;;
        primary-only)
            if [[ -n "$SECONDARY" ]]; then
                hyprctl --batch "\
                    keyword monitor $PRIMARY,preferred,auto,1 ; \
                    keyword monitor $SECONDARY,disable"
            else
                hyprctl keyword monitor "$PRIMARY,preferred,auto,1"
            fi
            ;;
        secondary-only)
            [[ -z "$SECONDARY" ]] && { err "Secondary-only needs 2 displays"; exit 2; }
            hyprctl --batch "\
                keyword monitor $SECONDARY,preferred,auto,1 ; \
                keyword monitor $PRIMARY,disable"
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
