# shellcheck shell=bash
# Sourced, never executed (SC2148). Runs on macOS /bin/bash 3.2, for the sketchybar plugin.
#
# fleet-pulse-roster.sh - who the fleet bars count and draw.
#
# The roster lives in one place: the fleet_pulse group in home-config ansible/inventory.yml.
# scripts/render-fleet-pulse.py renders it to {roster, display} and fleet-exporter serves that at
# $GATUS_BASE/roster, so a machine joins every bar with one inventory edit and no machine keeps a
# copy. Fetched over HTTP, not read from a checkout, because a work laptop has no home-config.
#
# fleet_pulse_roster_load <gatus_base> fetches it at most once per FLEET_ROSTER_TTL_MIN, keeps the
# last good copy in the cache for when the fetch fails, and sets:
#   FLEET_PULSE_ROSTER    names counted for health, space-separated
#   FLEET_PULSE_DISPLAY   bar tokens (<name>=<label>, ~<name>=<label>, @<group>=<label>)
# It returns 1, with both empty, when no roster was ever fetched.

: "${FLEET_ROSTER_TTL_MIN:=10}"   # minutes a fetched roster is used before it is fetched again

fleet_pulse_roster_load() {
    local dir="${XDG_CACHE_HOME:-$HOME/.cache}/fleet-pulse" cache tmp
    cache="$dir/roster.json"
    if [ -z "$(find "$cache" -mmin "-$FLEET_ROSTER_TTL_MIN" 2>/dev/null)" ]; then
        mkdir -p "$dir"
        tmp="$cache.$$"
        if curl -fsS -m 8 "$1/roster" > "$tmp" 2>/dev/null &&
            jq -e '.roster | type == "array"' "$tmp" > /dev/null 2>&1; then
            mv -f "$tmp" "$cache"
        else
            rm -f "$tmp"
        fi
    fi
    FLEET_PULSE_ROSTER="$(jq -r '.roster | join(" ")' "$cache" 2>/dev/null)"
    FLEET_PULSE_DISPLAY="$(jq -r '.display // [] | join(" ")' "$cache" 2>/dev/null)"
    [ -n "$FLEET_PULSE_ROSTER" ]
}
