#!/bin/bash
# Drives the WHOLE bar's background color to signal meeting state. Run every 2s by the
# invisible meeting_watch item. Modes (precedence top-down):
#   IN-CALL  mic active                     → solid green tint, steady (you're in a call)
#   ALERT    meeting live or ≤5m away,       → pulse red (animate toggle each tick)
#            mic inactive                       (a meeting you haven't joined)
#   NORMAL   neither                         → theme $BAR_COLOR
# Mic precedence is deliberate: being in a call (even ad-hoc) wins over the calendar nudge.
#
# Reads the timed-event epochs cached by plugins/calendar.sh — never runs icalBuddy here.
# Known limitation: the mic probe can't tell a meeting from Dictation / Voice Memos / Photo
# Booth, so those also show green. Acceptable for v1.
source "$HOME/.config/sketchybar/colors.sh"
[ -n "$BAR_COLOR" ] || exit 0   # colors.sh is mid-regen (theme-switch truncate); skip this tick

STATE_DIR="$HOME/.local/cache/sketchybar"
CAL_FILE="$STATE_DIR/calendar.state"
MODE_FILE="$STATE_DIR/meeting_mode"
PHASE_FILE="$STATE_DIR/pulse_phase"
SOON_SECS=300                   # how early before a meeting the red nudge starts
mkdir -p "$STATE_DIR" 2>/dev/null

MICBIN="$(command -v mic-active || echo "$HOME/.local/bin/mic-active")"
NOW="$(date +%s)"

# --- mic state (fail-safe: any non-"1" → not in call) ---
MIC="$("$MICBIN" 2>/dev/null)"; [ "$MIC" = "1" ] || MIC=0

# --- live/soon from cached epochs (cheap, no icalBuddy) ---
live=0
if [ -r "$CAL_FILE" ]; then
  read -r S E _ < "$CAL_FILE" 2>/dev/null
  if [ -n "$S" ] && [ -n "$E" ]; then
    if [ "$S" -le "$NOW" ] && [ "$NOW" -lt "$E" ]; then
      live=1                                            # in progress
    elif [ $((S - NOW)) -gt 0 ] && [ $((S - NOW)) -le "$SOON_SECS" ]; then
      live=1                                            # starts within SOON_SECS
    fi
  fi
fi

# --- decide mode ---
if [ "$MIC" = "1" ]; then MODE="INCALL"
elif [ "$live" = "1" ]; then MODE="ALERT"
else MODE="NORMAL"; fi

LAST="$(cat "$MODE_FILE" 2>/dev/null)"

case "$MODE" in
  INCALL)
    # Re-assert green every tick, not just on entry: a `sketchybar --reload` (e.g. from
    # theme-switch) resets the bar to BAR_COLOR while we're still INCALL, and we must
    # restore the tint. Animating green→green is a visual no-op, so this is safe each tick.
    sketchybar --animate sin 30 --bar color="$BAR_INCALL_COLOR"
    ;;
  ALERT)
    # Continuous throb: each 2s tick animates to the opposite color over ~2s (sin 120 ≈ 2s
    # at 60fps), so the fade is edge-to-edge with no flat dwell. ~4s red→base→red cycle.
    phase="$(cat "$PHASE_FILE" 2>/dev/null)"
    if [ "$phase" = "1" ]; then nphase=0; else nphase=1; fi
    echo "$nphase" > "$PHASE_FILE"
    if [ "$nphase" = "1" ]; then
      sketchybar --animate sin 120 --bar color="$BAR_ALERT_COLOR"
    else
      sketchybar --animate sin 120 --bar color="$BAR_COLOR"
    fi
    ;;
  NORMAL)
    # Reset to theme color when leaving another mode, or when last mode is unknown/missing
    # (crash-recovery — never leave the bar stuck on alert red).
    if [ "$LAST" != "NORMAL" ]; then
      sketchybar --animate sin 30 --bar color="$BAR_COLOR"
    fi
    ;;
esac

echo "$MODE" > "$MODE_FILE"
