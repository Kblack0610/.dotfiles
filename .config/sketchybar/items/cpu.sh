#!/bin/bash
sketchybar --add item cpu right \
           --set cpu \
                 update_freq=5 \
                 icon="$ICON_CPU" \
                 icon.color="$CPU_COLOR" \
                 label.color="$CPU_COLOR" \
                 script="$CONFIG_DIR/plugins/cpu.sh"
