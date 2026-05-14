#!/bin/bash
sketchybar --add item volume right \
           --set volume \
                 icon.color="$VOLUME_COLOR" \
                 label.color="$VOLUME_COLOR" \
                 script="$CONFIG_DIR/plugins/volume.sh" \
           --subscribe volume volume_change
