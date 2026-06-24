#!/bin/bash
# Dedicated, always-visible calendar button — click opens Calendar.app. Sits just left of
# the meeting item (which is text-only: left-click joins the meeting, right-click also
# opens Calendar.app as a fallback).
# Use an emoji glyph (📅), not an SF Symbol — SF Symbol icons don't render in this bar's
# font on every machine, and an icon-only item then shows as a blank gap. Emoji always render.
sketchybar --add item calendar_app right \
           --set calendar_app \
                 icon="📅" \
                 icon.font="SF Pro:Bold:16.0" \
                 icon.padding_left=8 \
                 icon.padding_right=4 \
                 label.drawing=off \
                 click_script="open -a Calendar"
