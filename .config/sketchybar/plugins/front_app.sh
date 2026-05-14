#!/bin/bash
# $INFO is the focused app name, provided by the front_app_switched event.
if [ "$SENDER" = "front_app_switched" ]; then
  sketchybar --set "$NAME" label="$INFO"
fi
