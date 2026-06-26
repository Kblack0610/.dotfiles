#!/bin/bash
# meeting_watch — color the WHOLE bar by meeting state. Visual only (no sound, no
# notifications — those are deliberately out for modularity; re-add as separate concerns).
# Run every 2s by the invisible meeting_watch item.
#
# States (highest precedence first):
#   INCALL  green   — your mic is active (you're in a call)
#   MAYBE   amber   — meeting live or ≤5m away, you're TENTATIVE ("maybe") on it, not joined.
#                     Steady (no pulse): a soft heads-up, not the red "you said yes, join now".
#   ALERT   red⇡    — meeting live or ≤5m away, mic off, and you haven't joined yet (pulses)
#   LEFT    yellow  — you joined this meeting and left while it's still on (no longer nagging)
#   NORMAL  base    — nothing relevant
#
# Only events the calendar layer deems real meetings reach here: plugins/calendar.sh caches
# just video-link meetings you haven't declined (via the meeting-status EventKit helper), so
# link-less personal events and declined/cancelled invites never light the bar at all.
#
# "Joined" is latched the first time your mic is active during a meeting's window, so leaving
# early turns the bar yellow (not back to red). Everything is data-driven off two inputs:
# the cached meeting (written by plugins/calendar.sh) and mic-active. Colors come from
# colors.sh; the only tunable here is SOON_SECS.
#
# Modules this composes (each does one job):
#   mic-active            → is any input device capturing? (handles Krisp virtual mic)
#   lib/calendar.sh       → parses the calendar (via plugins/calendar.sh → cache)
#   meeting-join          → the click/hotkey join action (separate; not used here)

# ── config ──────────────────────────────────────────────────────────────────────────
source "$HOME/.config/sketchybar/colors.sh"
[ -n "$BAR_COLOR" ] || exit 0   # colors.sh mid-regen (theme-switch truncate) — skip this tick

STATE_DIR="$HOME/.local/cache/sketchybar"
CAL_FILE="$STATE_DIR/calendar.state"     # "START_EPOCH END_EPOCH RSVP TITLE" (or empty)
MODE_FILE="$STATE_DIR/meeting_mode"       # last applied mode (change detection)
PHASE_FILE="$STATE_DIR/pulse_phase"       # 0/1 pulse toggle for ALERT
CUR_FILE="$STATE_DIR/cur_meeting"         # start-epoch of the meeting we're tracking
SOON_SECS=300                             # alert/pulse window: starts 5 min before
MICBIN="$(command -v mic-active || echo "$HOME/.local/bin/mic-active")"
mkdir -p "$STATE_DIR" 2>/dev/null

# ── inputs ──────────────────────────────────────────────────────────────────────────
NOW="$(date +%s)"

read_meeting() {                          # → sets S, E, RSVP, TITLE (S/E empty if none)
  S=""; E=""; RSVP=""; TITLE=""
  [ -r "$CAL_FILE" ] && read -r S E RSVP TITLE < "$CAL_FILE" 2>/dev/null
  case "$S" in ''|*[!0-9]*) S=""; E="" ;; esac
}

mic_active() { [ "$("$MICBIN" 2>/dev/null)" = "1" ]; }

# ── state ───────────────────────────────────────────────────────────────────────────
read_meeting

# New target meeting → drop the previous meeting's "joined" latch.
CUR="$(cat "$CUR_FILE" 2>/dev/null)"
if [ "$S" != "$CUR" ]; then
  rm -f "$STATE_DIR"/joined.* 2>/dev/null
  echo "$S" > "$CUR_FILE"
fi

# Is a meeting in its alert window (live now, or starting within SOON_SECS)?
alert_window=0
if [ -n "$S" ] && [ -n "$E" ]; then
  if { [ "$S" -le "$NOW" ] && [ "$NOW" -lt "$E" ]; } \
     || { [ $((S - NOW)) -gt 0 ] && [ $((S - NOW)) -le "$SOON_SECS" ]; }; then
    alert_window=1
  fi
fi

# Latch "joined" the first time the mic is active inside the window.
JOINED_FILE="$STATE_DIR/joined.$S"
if mic_active && [ "$alert_window" = 1 ]; then : > "$JOINED_FILE"; fi
joined=0; [ -n "$S" ] && [ -f "$JOINED_FILE" ] && joined=1

# ── decide mode ─────────────────────────────────────────────────────────────────────
if mic_active; then                       MODE="INCALL"
elif [ "$alert_window" = 1 ] && [ "$joined" = 0 ] && [ "$RSVP" = "TENTATIVE" ]; then MODE="MAYBE"
elif [ "$alert_window" = 1 ] && [ "$joined" = 0 ]; then MODE="ALERT"
elif [ "$alert_window" = 1 ] && [ "$joined" = 1 ]; then MODE="LEFT"
else                                      MODE="NORMAL"
fi

# ── apply to the bar ────────────────────────────────────────────────────────────────
# Steady colors (INCALL/LEFT) re-assert every tick so a sketchybar --reload can't strip
# them; NORMAL only resets on change (avoids idle churn); ALERT toggles to pulse.
LAST="$(cat "$MODE_FILE" 2>/dev/null)"
case "$MODE" in
  INCALL) sketchybar --animate sin 30 --bar color="$BAR_INCALL_COLOR" ;;
  MAYBE)  sketchybar --animate sin 30 --bar color="$BAR_MAYBE_COLOR" ;;
  LEFT)   sketchybar --animate sin 30 --bar color="$BAR_LEFT_COLOR" ;;
  ALERT)
    phase="$(cat "$PHASE_FILE" 2>/dev/null)"; [ "$phase" = 1 ] && nphase=0 || nphase=1
    echo "$nphase" > "$PHASE_FILE"
    [ "$nphase" = 1 ] && target="$BAR_ALERT_COLOR" || target="$BAR_COLOR"
    sketchybar --animate sin 120 --bar color="$target"
    ;;
  NORMAL) [ "$LAST" != "NORMAL" ] && sketchybar --animate sin 30 --bar color="$BAR_COLOR" ;;
esac
echo "$MODE" > "$MODE_FILE"
