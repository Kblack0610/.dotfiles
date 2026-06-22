#!/bin/bash
# Calendar item click dispatcher. SketchyBar sets $BUTTON for click_script.
#   left click  → join the current/next meeting's video-call link (meeting-join)
#   right click → open Calendar.app (the old behavior, kept as a handy option)
case "$BUTTON" in
  right) open -a Calendar ;;
  *)     exec "$HOME/.local/bin/meeting-join" ;;
esac
