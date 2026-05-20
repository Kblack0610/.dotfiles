#!/bin/bash
sketchybar --add item clock right \
           --set clock \
                 update_freq=10 \
                 icon="$ICON_CLOCK" \
                 icon.color="$CLOCK_COLOR" \
                 label.color="$CLOCK_COLOR" \
                 background.color="$ACCENT_BG_COLOR" \
                 script="$CONFIG_DIR/plugins/clock.sh"
