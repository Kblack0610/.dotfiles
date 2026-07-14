#!/bin/bash
# fleet-pulse item - one dot colored by whole-fleet liveness (see plugins/fleet.sh).
sketchybar --add item fleet right \
           --set fleet \
                 update_freq=15 \
                 icon="$ICON_FLEET" \
                 icon.color="$DIM" \
                 label.color="$WHITE" \
                 label="" \
                 script="$CONFIG_DIR/plugins/fleet.sh" \
           --subscribe fleet mouse.clicked
