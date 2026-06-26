#!/bin/bash
# Repaint the bose_audio item from `bose-audio status`. Fired by the bose_audio custom event
# (on grab/release), system_woke, and the initial --update. Visual only.
source "$HOME/.config/sketchybar/colors.sh"
source "$HOME/.config/sketchybar/icons.sh"
[ -n "$BAR_INCALL_COLOR" ] || exit 0   # colors.sh mid-regen (theme switch) — skip this tick

# `status` only reads a flag file, so it needs no PATH/Homebrew deps. Absolute path: sketchybar
# runs scripts with a minimal environment.
if [ "$("$HOME/.local/bin/bose-audio" status 2>/dev/null)" = "claimed" ]; then
  sketchybar --set "$NAME" icon="$ICON_BOSE" icon.color="$BAR_INCALL_COLOR"   # green = Mac owns it
else
  sketchybar --set "$NAME" icon="$ICON_BOSE" icon.color="$DIM"                # dim = guarding
fi
