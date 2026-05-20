#!/bin/bash
# CPU% via top — single sample, no average. Idle is "X% idle"; usage = 100 - idle.
IDLE=$(top -l 1 -n 0 | awk '/CPU usage/ {print $7}' | tr -d '%')
if [ -z "$IDLE" ]; then
  sketchybar --set "$NAME" label="--"
  exit 0
fi
USAGE=$(printf "%.0f" "$(echo "100 - $IDLE" | bc -l)")
sketchybar --set "$NAME" label="${USAGE}%"
