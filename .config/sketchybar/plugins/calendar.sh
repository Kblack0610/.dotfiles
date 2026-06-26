#!/bin/bash
# Renders the current/next meeting from the system Calendar (same one MeetingBar reads).
# Parsing lives in lib/calendar.sh (shared); this script classifies + renders + caches.
# States:
#   live now     → red + highlighted bg + "● now  Title"   (start ≤ now < end)
#   soon (≤5m)   → gold + "in Nm  Title"
#   upcoming     → cyan + "HH:MM  Title"
#   all-day      → cyan + "Title"      (fallback when no timed event)
#   nothing      → cyan + "Free"
#   no access    → dim + "no cal access" (grant Calendar perm to SketchyBar — see mac README)
#
# Also writes the chosen timed event's "START_EPOCH END_EPOCH TITLE" to the cache file so
# plugins/meeting_watch.sh can recompute live/soon every 2s without re-running icalBuddy.
# Non-timed states write an empty cache (no meeting to alert on).
source "$HOME/.config/sketchybar/icons.sh"
source "$HOME/.config/sketchybar/colors.sh"
source "$HOME/.config/sketchybar/lib/calendar.sh"

CACHE_DIR="$HOME/.local/cache/sketchybar"
CACHE_FILE="$CACHE_DIR/calendar.state"
mkdir -p "$CACHE_DIR" 2>/dev/null

NOW="$(date +%s)"
IFS=$'\t' read -r KIND F1 F2 F3 F4 <<<"$(calendar_scan)"

case "$KIND" in
  ERR)
    : > "$CACHE_FILE"
    sketchybar --set "$NAME" icon="$ICON_CALENDAR" label="$F1" \
                             label.color="$DIM" background.drawing=off
    ;;
  TIMED)
    S="$F1"; E="$F2"; RSVP="$F3"; TITLE="$F4"
    # Cache: "START END RSVP TITLE" — meeting_watch.sh reads RSVP to pick the amber
    # (tentative) bar state. RSVP is a single token, so it parses cleanly before TITLE.
    printf '%s %s %s %s\n' "$S" "$E" "$RSVP" "$TITLE" > "$CACHE_FILE"
    if [ "$S" -le "$NOW" ]; then
      sketchybar --set "$NAME" icon="$ICON_CALENDAR" icon.color="$RED" \
                               label="● now  $TITLE" label.color="$RED" \
                               background.color="$ACTIVE_BG_COLOR" background.drawing=on
    elif [ $((S - NOW)) -le 300 ]; then
      sketchybar --set "$NAME" icon="$ICON_CALENDAR" icon.color="$GOLD" \
                               label="in $(( (S - NOW + 59) / 60 ))m  $TITLE" \
                               label.color="$GOLD" background.drawing=off
    else
      STIME="$(date -r "$S" +%H:%M)"
      sketchybar --set "$NAME" icon="$ICON_CALENDAR" icon.color="$CALENDAR_COLOR" \
                               label="$STIME  $TITLE" label.color="$CALENDAR_COLOR" \
                               background.drawing=off
    fi
    ;;
  ALLDAY)
    : > "$CACHE_FILE"
    sketchybar --set "$NAME" icon="$ICON_CALENDAR" icon.color="$CALENDAR_COLOR" \
                             label="$F1" label.color="$CALENDAR_COLOR" background.drawing=off
    ;;
  *)  # NONE
    : > "$CACHE_FILE"
    sketchybar --set "$NAME" icon="$ICON_CALENDAR" icon.color="$CALENDAR_COLOR" \
                             label="Free" label.color="$CALENDAR_COLOR" background.drawing=off
    ;;
esac
