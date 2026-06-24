#!/bin/bash
# Next-meeting item — reads the system Calendar (same one MeetingBar uses) via icalBuddy.
# Text-only (the calendar glyph lives on the calendar_app button to its left). Click
# dispatch (plugins/calendar_click.sh): left = join the meeting's link, right = Calendar.app.
sketchybar --add item calendar right \
           --set calendar \
                 update_freq=60 \
                 icon.drawing=off \
                 label.color="$CALENDAR_COLOR" \
                 label.max_chars=28 \
                 scroll_texts=on \
                 click_script="$CONFIG_DIR/plugins/calendar_click.sh" \
                 script="$CONFIG_DIR/plugins/calendar.sh" \
           --subscribe calendar system_woke
