#!/bin/bash
# Group all tiled windows on the active workspace into a single tab group.
# Bound to Super+G in conf/keybindings.lua.
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
focus() { printf 'hl.dispatch(hl.dsp.focus({ window = "address:%s" }))\n' "$1"; }
lua="$(focus "${addrs[0]}")
hl.dispatch(hl.dsp.group.toggle())"
for a in "${addrs[@]:1}"; do
    lua+="
$(focus "$a")"
    for d in left right up down; do
        lua+="
hl.dispatch(hl.dsp.window.move({ into_group = \"$d\" }))"
    done
done
hyprctl eval "$lua"
