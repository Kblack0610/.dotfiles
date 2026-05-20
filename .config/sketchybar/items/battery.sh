#!/bin/bash
sketchybar --add item battery right \
           --set battery \
                 update_freq=30 \
                 icon.color="$BATTERY_COLOR" \
                 label.color="$BATTERY_COLOR" \
                 script="$CONFIG_DIR/plugins/battery.sh" \
           --subscribe battery system_woke power_source_change
