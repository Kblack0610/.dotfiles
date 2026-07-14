#!/bin/bash
# fleet-pulse sketchybar plugin (macOS) - color the fleet dot by whole-fleet liveness.
#
# Mirrors the waybar module (~/.config/waybar/fleet_pulse.sh) but for sketchybar:
# polls the gatus statuses API, judges each fleet host's freshness HERE (success
# && age < FLEET_STALE_AFTER), and sets the item's icon color.
#
# Counting is driven by $FLEET_ROSTER, not by the API's own rows: gatus only
# materializes an external-endpoint on a host's FIRST push, so a never-enrolled
# machine is missing from the API rather than stale. Taking the denominator from
# the API meant it came from the same set as the numerator, and the dot went green
# while most of the fleet had never reported. The roster is the independent list.
#
#   green  = every roster host fresh + success
#   amber  = >=1 host never-reported/stale/failing (but API reachable)
#   red    = statuses API unreachable
#
# NOTE macOS uses BSD `date` (no `date -d`): timestamps are parsed with `date -j`.
# NOTE /bin/bash on macOS is 3.2 - no associative arrays; roster lookup uses awk.

# Same machine-local config the pusher and waybar read, so the fleet endpoint and
# roster are defined once per machine instead of hardcoded in each module.
[ -r "$HOME/.config/fleet-pulse/env" ] && . "$HOME/.config/fleet-pulse/env"
GATUS_BASE="${GATUS_BASE:-https://status.example.com}"
STALE_AFTER="${FLEET_STALE_AFTER:-180}"
ROSTER="${FLEET_ROSTER:-}"

# Theme-INDEPENDENT semantic colors (0xAARRGGBB), same intent as meeting_watch.sh:
# fleet health is an alert, not decoration, so it must not follow the pastel theme.
GREEN=0xffa6e3a1
AMBER=0xfff9e2af
RED=0xfff38ba8

# Convert an RFC3339 timestamp (UTC, maybe fractional) to epoch seconds via BSD date.
ts_to_epoch() {
    local ts="$1"
    ts="${ts%Z}"       # drop trailing Z
    ts="${ts%%.*}"     # drop fractional seconds
    [ -z "$ts" ] && { echo ""; return; }
    date -u -j -f "%Y-%m-%dT%H:%M:%S" "$ts" +%s 2>/dev/null
}

json="$(curl -fsS -m 8 "${GATUS_BASE}/api/v1/endpoints/statuses" 2>/dev/null)"
if [ -z "$json" ]; then
    sketchybar --set "$NAME" icon.color="$RED" label="fleet?"
    exit 0
fi

rows="$(echo "$json" | jq -r '
    .[] | select(.group=="fleet") | . as $e
    | (($e.results // []) | last) as $r
    | [$e.name, (($r.success // false) | tostring), ($r.timestamp // "")] | @tsv
' 2>/dev/null)"

# No roster configured: fall back to whoever the API knows about. This is the old
# behaviour and it cannot see a never-enrolled host, so it is a fallback only.
if [ -z "$ROSTER" ]; then
    ROSTER="$(printf '%s\n' "$rows" | cut -f1 | tr '\n' ' ')"
fi

if [ -z "$(printf '%s' "$ROSTER" | tr -d ' ')" ]; then
    sketchybar --set "$NAME" icon.color="$AMBER" label=""
    exit 0
fi

now="$(date -u +%s)"
total=0
healthy=0
for name in $ROSTER; do
    [ -z "$name" ] && continue
    total=$((total + 1))

    # Roster drives the loop, so a host absent from the API is counted unhealthy.
    row="$(printf '%s\n' "$rows" | awk -F'\t' -v n="$name" '$1 == n { print; exit }')"
    [ -z "$row" ] && continue   # never reported

    success="$(printf '%s' "$row" | cut -f2)"
    ts="$(printf '%s' "$row" | cut -f3)"
    age=-1
    if [ -n "$ts" ]; then
        epoch="$(ts_to_epoch "$ts")"
        [ -n "$epoch" ] && age=$((now - epoch))
    fi
    if [ "$success" = "true" ] && [ "$age" -ge 0 ] && [ "$age" -lt "$STALE_AFTER" ]; then
        healthy=$((healthy + 1))
    fi
done

if [ "$healthy" -eq "$total" ]; then
    sketchybar --set "$NAME" icon.color="$GREEN" label=""
else
    sketchybar --set "$NAME" icon.color="$AMBER" label="$((total - healthy))"
fi
