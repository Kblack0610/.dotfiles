#!/bin/bash
# Shared system-Calendar parser for SketchyBar. Sourced by plugins/calendar.sh
# (the meeting_watch plugin reads the cached epochs instead, never re-running the scan).
#
# calendar_scan: prints ONE tab-separated line describing the most relevant event. Two
# backends, preferred-first:
#   1. meeting-status (Swift/EventKit, ~/.local/bin) — the real source of truth. Knows your
#      RSVP status and whether an event has a video link, and emits drift-free epochs. Only
#      events that are *actual video meetings* (link present, not cancelled, not declined)
#      come back as TIMED.
#   2. icalBuddy fallback — used only when the helper binary isn't built yet (fresh machine
#      pre-build). Degraded: no RSVP (always NONE) and no link filter, so it behaves like the
#      old bar. Build the helper: ~/.dotfiles/.local/src/meeting-status/build.sh
#
# Fields by kind:
#   ERR<TAB><message>                                              no Calendar access / no backend
#   TIMED<TAB><start_epoch><TAB><end_epoch><TAB><rsvp><TAB><title> earliest relevant timed meeting
#   ALLDAY<TAB><title>                                             no timed meeting, an all-day event exists
#   NONE                                                           nothing relevant
# <rsvp> is ACCEPTED | TENTATIVE | PENDING | NONE (icalBuddy path always emits NONE).
#
# Epochs (not a live/soon label) are emitted because that classification is time-relative
# and must be recomputed against NOW by each caller every tick.
#
# Parsing notes (debugged empirically):
#   - icalBuddy's -ps takes a "|<sep>|" form where "|" is just the delimiter, so the
#     emitted property separator is "@P@"; the bullet "@EVT@" is literal.
#   - timed events render datetime as "<date> at <start> - <end>"; the " at " is normalized.
#   - the multi-day query (eventsToday+1) includes the date so parsing is uniform.

# Pin seconds to :00 explicitly. Without %S, BSD `date -j` fills missing seconds from the
# CURRENT clock, so the same meeting yields a different epoch every run — which would make
# downstream "is this the same meeting?" checks (the joined latch) drift and never stick.
_cal_to_epoch() { date -j -f "%Y-%m-%d %H:%M:%S" "$1 $2:00" +%s 2>/dev/null; }

# Preferred backend: the EventKit helper. Its stdout already IS the contract, so we just
# pass it through. If the binary is missing we fall back to the icalBuddy scanner below.
calendar_scan() {
  local helper out
  helper="$(command -v meeting-status || echo "$HOME/.local/bin/meeting-status")"
  if [ -x "$helper" ]; then
    out="$("$helper" 2>/dev/null)"
    # Trust the helper unless it couldn't reach Calendar at all — then degrade to icalBuddy.
    case "$out" in
      "ERR"*|"") _calendar_scan_icalbuddy ;;
      *)         printf '%s\n' "$out" ;;
    esac
    return 0
  fi
  _calendar_scan_icalbuddy
}

# Fallback only. Emits a NONE rsvp field for TIMED so the cache format stays uniform; has no
# link filter, so it shows any timed event (the pre-EventKit behavior).
_calendar_scan_icalbuddy() {
  local buddy raw now line dt title start end sdate stime edate etime s e first_allday
  buddy="$(command -v icalBuddy || echo /opt/homebrew/bin/icalBuddy)"
  if [ ! -x "$buddy" ]; then
    printf 'ERR\tno icalBuddy\n'; return 0
  fi

  raw="$("$buddy" -npn -nc -nrd -b "@EVT@" -ps "|@P@|" -iep "datetime,title" \
          -po "datetime,title" -df "%Y-%m-%d" -tf "%H:%M" eventsToday+1 2>&1)"

  if printf '%s' "$raw" | grep -qi "no calendars"; then
    printf 'ERR\tno cal access\n'; return 0
  fi

  now="$(date +%s)"
  first_allday=""

  while IFS= read -r line; do
    line="${line#@EVT@}"
    line="$(printf '%s' "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    [ -z "$line" ] && continue

    dt="${line%%@P@*}"
    title="${line#*@P@}"
    dt="$(printf '%s' "$dt" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    title="$(printf '%s' "$title" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    dt="${dt// at / }"                     # icalBuddy joins date+time with " at "

    # No time component → all-day. Remember the first, keep scanning for a timed one.
    case "$dt" in
      *:*) ;;
      *)   [ -z "$first_allday" ] && first_allday="$title"; continue ;;
    esac

    # dt is "<sdate> <stime> - <etime>" or "<sdate> <stime> - <edate> <etime>".
    start="${dt%% - *}"; end="${dt#* - }"
    sdate="${start%% *}"; stime="${start##* }"
    if printf '%s' "$end" | grep -q ' '; then
      edate="${end%% *}"; etime="${end##* }"
    else
      edate="$sdate"; etime="$end"
    fi

    s="$(_cal_to_epoch "$sdate" "$stime")"; e="$(_cal_to_epoch "$edate" "$etime")"
    [ -z "$s" ] || [ -z "$e" ] && continue
    [ "$e" -le "$now" ] && continue        # already ended → skip

    printf 'TIMED\t%s\t%s\t%s\t%s\n' "$s" "$e" "NONE" "$title"
    return 0
  done <<EOF
$(printf '%s' "$raw" | sed 's/@EVT@/\
/g')
EOF

  if [ -n "$first_allday" ]; then
    printf 'ALLDAY\t%s\n' "$first_allday"
  else
    printf 'NONE\n'
  fi
}
