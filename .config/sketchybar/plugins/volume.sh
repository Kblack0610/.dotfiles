#!/bin/bash
source "$HOME/.config/sketchybar/icons.sh"

# $INFO is volume 0-100 from the volume_change event.
VOLUME="$INFO"

if [ -z "$VOLUME" ]; then
  VOLUME=$(osascript -e 'output volume of (get volume settings)')
fi

case "${VOLUME}" in
  100|9[0-9]|8[0-9]|7[0-9]) ICON="$ICON_VOLUME_100";;
  6[0-9]|5[0-9]|4[0-9])     ICON="$ICON_VOLUME_66";;
  3[0-9]|2[0-9])            ICON="$ICON_VOLUME_33";;
  1[0-9])                   ICON="$ICON_VOLUME_10";;
  *)                        ICON="$ICON_VOLUME_0";;
esac

[ "$VOLUME" = "0" ] && ICON="$ICON_VOLUME_MUTE"

sketchybar --set "$NAME" icon="$ICON" label="${VOLUME}%"
