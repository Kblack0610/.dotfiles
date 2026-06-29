#!/usr/bin/env bash
# Toggle a SECONDARY display in/out of the Hyprland layout (enable/disable).
# Unlike DPMS, this changes the monitor COUNT — windows reflow onto the
# remaining display(s) and `hyprctl monitors` reflects the new reality.
#
# SAFETY (two guards, both hard):
#   1. The PRIMARY monitor is never disabled.
#   2. The last remaining active monitor is never disabled.
# So you can never black out your primary or every screen.
#
#   no arg          → one secondary: toggle it; multiple: wofi picker
#   <monitor name>  → toggle that monitor
#
# Primary defaults to HDMI-A-2; override with MONITOR_TOGGLE_PRIMARY=<name>.
set -euo pipefail

PRIMARY="${MONITOR_TOGGLE_PRIMARY:-HDMI-A-2}"

err() {
    notify-send -u critical "Monitor toggle" "$1" || true
    echo "monitor-toggle: $1" >&2
}

connected() { hyprctl monitors all -j; }
active_count() { connected | jq '[.[] | select(.disabled==false)] | length'; }

toggle() {
    local name="$1"
    local state
    state="$(connected | jq -r --arg n "$name" '.[] | select(.name==$n) | .disabled')"

    case "$state" in
        true)   # currently disabled → re-enable
            # `keyword monitor NAME,...` re-adds it; `reload` re-applies the
            # monitor=,preferred,auto,1 catch-all and actually wakes it.
            hyprctl keyword monitor "$name,preferred,auto,1" >/dev/null
            hyprctl reload >/dev/null
            # Also force DPMS on — re-enabling the layout does NOT power the
            # panel back up, so without this the screen stays black.
            hyprctl dispatch dpms on "$name" >/dev/null 2>&1 || true
            notify-send "Monitor toggle" "Enabled: $name"
            ;;
        false)  # currently enabled → disable, subject to guards
            if [[ "$name" == "$PRIMARY" ]]; then
                err "Refusing to disable $name — it's your primary display"
                exit 3
            fi
            if (( $(active_count) <= 1 )); then
                err "Refusing to disable $name — it's the only active display"
                exit 3
            fi
            hyprctl keyword monitor "$name,disable" >/dev/null
            notify-send "Monitor toggle" "Disabled: $name — windows reflowed"
            ;;
        "")
            err "Unknown / disconnected monitor: $name"
            exit 2
            ;;
        *)
            err "Unexpected state for $name: $state"
            exit 2
            ;;
    esac
}

# Explicit target.
if (( $# > 0 )); then
    toggle "$1"
    exit 0
fi

# No arg → always show the wofi list of every monitor with its ON/OFF state.
# The primary is shown but tagged (primary) so it's clear it stays on; the
# toggle() guard refuses to disable it if picked.
choice="$(connected | jq -r --arg p "$PRIMARY" '
        .[]
        | "\(.name) [\(if .disabled then "OFF" else "ON" end)]\(if .name == $p then " (primary)" else "" end)|\(.name)"' \
    | wofi --dmenu --prompt 'Toggle display' --width 420 --height 260 \
    | awk -F'|' 'NF==2 {print $2}')"

[[ -z "$choice" ]] && exit 1
toggle "$choice"
