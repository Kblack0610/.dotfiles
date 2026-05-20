#!/bin/bash
source "$HOME/.config/sketchybar/colors.sh"
source "$HOME/.config/sketchybar/icons.sh"

PERCENT=$(pmset -g batt | grep -Eo "\d+%" | cut -d% -f1)
CHARGING=$(pmset -g batt | grep 'AC Power')

# Empty/unknown — likely a desktop Mac. Hide the item entirely.
if [ -z "$PERCENT" ]; then
  sketchybar --set "$NAME" drawing=off
  exit 0
fi

if [ -n "$CHARGING" ]; then
  ICON="$ICON_BATTERY_CHARGING"
  COLOR="$GREEN"
else
  case "${PERCENT}" in
    100|9[0-9]) ICON="$ICON_BATTERY_100"; COLOR="$GREEN";;
    [6-8][0-9]) ICON="$ICON_BATTERY_75"; COLOR="$GREEN";;
    [3-5][0-9]) ICON="$ICON_BATTERY_50"; COLOR="$GOLD";;
    [1-2][0-9]) ICON="$ICON_BATTERY_25"; COLOR="$GOLD";;
    *)          ICON="$ICON_BATTERY_0";  COLOR="$RED";;
  esac
fi

sketchybar --set "$NAME" icon="$ICON" \
                         icon.color="$COLOR" \
                         label="${PERCENT}%" \
                         label.color="$COLOR"
