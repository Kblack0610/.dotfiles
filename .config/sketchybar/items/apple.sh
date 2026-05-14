#!/bin/bash
sketchybar --add item apple.logo left \
           --set apple.logo icon="$ICON_APPLE" \
                            icon.font="SF Pro:Black:16.0" \
                            icon.color="$GOLD" \
                            label.drawing=off \
                            background.drawing=off \
                            icon.padding_left=10 \
                            icon.padding_right=10
