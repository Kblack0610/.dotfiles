#!/bin/bash
sketchybar --add item front_app left \
           --set front_app \
                 background.drawing=off \
                 icon.drawing=off \
                 label.font="SF Pro:Semibold:13.0" \
                 label.color="$GOLD" \
                 label.padding_left=12 \
                 script="$CONFIG_DIR/plugins/front_app.sh" \
           --subscribe front_app front_app_switched
