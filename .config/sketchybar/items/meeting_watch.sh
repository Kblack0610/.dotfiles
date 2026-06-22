#!/bin/bash
# Invisible driver item: never draws, exists only to run meeting_watch.sh every 2s, which
# colors the whole bar by meeting state. updates=on is REQUIRED — the global default is
# updates=when_shown (see sketchybarrc), and a drawing=off item would otherwise never tick.
sketchybar --add item meeting_watch right \
           --set meeting_watch \
                 drawing=off \
                 updates=on \
                 update_freq=2 \
                 script="$CONFIG_DIR/plugins/meeting_watch.sh" \
           --subscribe meeting_watch system_woke
