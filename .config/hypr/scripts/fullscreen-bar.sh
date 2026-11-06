#!/usr/bin/env bash
# fullscreen-bar.sh - flip the focused window between true fullscreen and "fullscreen under the
# bar": Hyprland maximizes it (so it keeps waybar's reserved zone and ends below the bar, never
# under it) while the app is still told it is fullscreen (RustDesk, Moonlight and video players
# keep their fullscreen UI). Bound with bindp so it fires while RustDesk grabs the keyboard.
#
#   true fullscreen (2)      -> fullscreenstate 1 2   bar back, window laid out under it
#   under the bar (1, app 2) -> fullscreenstate 2 2   bar hidden again
#   anything else            -> fullscreenstate 1 2   straight to fullscreen under the bar
#
# It stores nothing: the state is the window's own, read from hyprctl each press.
set -euo pipefail

note() { hyprctl notify -1 2000 "rgb(88c0d0)" "$1" > /dev/null; }

read -r internal client < <(hyprctl activewindow -j | jq -r '"\(.fullscreen // 0) \(.fullscreenClient // 0)"')

if [ "$internal" = 1 ] && [ "$client" = 2 ]; then
  hyprctl dispatch fullscreenstate 2 2 > /dev/null
  note "Fullscreen: bar hidden"
else
  hyprctl dispatch fullscreenstate 1 2 > /dev/null
  note "Fullscreen under the bar"
fi
