#!/bin/bash
# Next-meeting item — reads the system Calendar (same one MeetingBar uses) via icalBuddy.
# Leftmost of the right-side cluster. Click opens the Calendar app.
sketchybar --add item calendar right \
           --set calendar \
                 update_freq=60 \
                 icon="$ICON_CALENDAR" \
                 icon.color="$CALENDAR_COLOR" \
                 label.color="$CALENDAR_COLOR" \
                 label.max_chars=28 \
                 scroll_texts=on \
                 click_script="open -a Calendar" \
                 script="$CONFIG_DIR/plugins/calendar.sh" \
           --subscribe calendar system_woke
