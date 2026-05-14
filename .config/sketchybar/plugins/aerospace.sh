#!/bin/bash
# Triggered on aerospace_workspace_change. $1 is the workspace id this item represents.
# $FOCUSED_WORKSPACE comes from the event payload (set by aerospace.toml).
# sketchybar invokes plugins with a minimal launchd env, so palette vars must be re-sourced.
source "$HOME/.config/sketchybar/colors.sh"

if [ "$1" = "$FOCUSED_WORKSPACE" ]; then
  sketchybar --set "$NAME" \
                   background.color="$ACTIVE_BG_COLOR" \
                   icon.color="$GOLD"
else
  sketchybar --set "$NAME" \
                   background.color=0x00000000 \
                   icon.color="$WHITE"
fi
