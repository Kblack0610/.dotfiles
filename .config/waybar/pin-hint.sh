#!/usr/bin/env bash
# which-key style popup for the pin leader submaps (see hypr/conf/leader.lua).
# One popup that nested levels replace rather than stack, under any notifier (`desk notify
# show|drop`). Auto-expires as a safety net if a submap is left open.
#
# The legend is the submap's described binds (the description on each bind in leader.lua), read live from
# `hyprctl binds -j`, so a key added there with a description shows here with no edit. Keys
# that share a description share a line entry (esc/q exit).
#
# Usage: pin-hint.sh {main|agents|keys|input|mode|desk|panels|utils|settings|sync|git|timebox|close}
set -u

DESK="$HOME/.local/bin/desk"
TIMEOUT=8000

show() { "$DESK" notify show pin-hint -t "$TIMEOUT" -u low "$1" "$2" >/dev/null; }
close() { "$DESK" notify drop pin-hint; }

# legend <submap>: its described binds, two to a line.
legend() {
    hyprctl binds -j 2>/dev/null | jq -r --arg s "$1" '
        [.[] | select(.submap == $s and .has_description)
             | {k: (if .key == "escape" then "esc" else .key end), d: .description}]
        | reduce .[] as $b ([];
            if any(.[]; .d == $b.d) then map(if .d == $b.d then .k += "/" + $b.k else . end)
            else . + [$b] end)
        | map("\(.k) \(.d)")
        | [range(0; length; 2) as $i | .[$i:$i + 2]]
        | map(if length == 2 then .[0] + (" " * ([24 - (.[0] | length), 1] | max)) + .[1] else .[0] end)
        | .[]'
}

case "${1:-main}" in
    main) title=" pin leader" submap=pinbar ;;
    agents | keys | input | mode | desk | panels | utils | settings | sync | git | timebox) title=" pin / $1" submap="pinbar-$1" ;;
    close) close; exit 0 ;;
    *) echo "usage: pin-hint.sh {main|agents|keys|input|mode|desk|panels|utils|settings|sync|git|timebox|close}" >&2; exit 2 ;;
esac
body="$(legend "$submap")"
show "$title" "${body:-no described binds in submap $submap (hyprctl binds -j)}"
