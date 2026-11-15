#!/bin/bash
# Ungroup every grouped window on the active workspace.
# Bound to Super+Alt+G in conf/keybindings.lua.
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

lua=""
for a in "${addrs[@]}"; do
    lua+="hl.dispatch(hl.dsp.focus({ window = \"address:$a\" }))
hl.dispatch(hl.dsp.window.move({ out_of_group = true }))
"
done
hyprctl eval "$lua"
