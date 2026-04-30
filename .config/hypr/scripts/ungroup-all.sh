#!/bin/bash
# Ungroup every grouped window on the active workspace.
# Bound to $mainMod ALT, G in hyprland.conf.
# Targets any window whose .grouped array is non-empty (including stale
# 1-window groups left behind by an earlier togglegroup press).

set -eu

ws=$(hyprctl activeworkspace -j | jq -r '.id')
mapfile -t addrs < <(
    hyprctl clients -j |
        jq -r --argjson ws "$ws" \
            '.[] | select(.workspace.id == $ws and (.grouped|length) >= 1) | .address'
)
((${#addrs[@]} == 0)) && exit 0

batch=""
for a in "${addrs[@]}"; do
    batch+=" dispatch focuswindow address:$a; dispatch moveoutofgroup;"
done
hyprctl --batch "$batch"
