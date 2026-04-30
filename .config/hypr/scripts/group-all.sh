#!/bin/bash
# Group all tiled windows on the active workspace into a single tab group.
# Bound to $mainMod CTRL, G in hyprland.conf.
# Floating windows are excluded (grouping floaters under dwindle is messy).

set -eu

ws=$(hyprctl activeworkspace -j | jq -r '.id')
mapfile -t addrs < <(
    hyprctl clients -j |
        jq -r --argjson ws "$ws" \
            '.[] | select(.workspace.id == $ws and .floating == false) | .address'
)
((${#addrs[@]} < 2)) && exit 0

# moveintogroup needs a direction and the correct one depends on layout state,
# so spam all four. Three no-op silently, one fires.
batch="dispatch focuswindow address:${addrs[0]}; dispatch togglegroup;"
for a in "${addrs[@]:1}"; do
    batch+=" dispatch focuswindow address:$a;"
    batch+=" dispatch moveintogroup l; dispatch moveintogroup r;"
    batch+=" dispatch moveintogroup u; dispatch moveintogroup d;"
done
hyprctl --batch "$batch"
