#!/bin/bash
# Triggered on aerospace_workspace_change (workspace switch) and front_app_switched
# (window create/destroy/switch — a coarse but cheap "workspace contents changed" signal).
# $1 is the workspace id this item represents.
# $FOCUSED_WORKSPACE is set by aerospace.toml's exec-on-workspace-change. On other
# events it'll be empty, so we look it up here.
source "$HOME/.config/sketchybar/colors.sh"

WS="$1"
FOCUSED="${FOCUSED_WORKSPACE:-$(aerospace list-workspaces --focused 2>/dev/null)}"
OCCUPIED=$(aerospace list-workspaces --monitor all --empty no 2>/dev/null)

# Always show the focused workspace. Otherwise show only if it has windows.
if [ "$WS" = "$FOCUSED" ] || echo "$OCCUPIED" | grep -qx "$WS"; then
  DRAWING=on
else
  DRAWING=off
fi

if [ "$WS" = "$FOCUSED" ]; then
  sketchybar --set "$NAME" \
                   drawing="$DRAWING" \
                   background.color="$ACTIVE_BG_COLOR" \
                   icon.color="$GOLD"
else
  sketchybar --set "$NAME" \
                   drawing="$DRAWING" \
                   background.color=0x00000000 \
                   icon.color="$WHITE"
fi
