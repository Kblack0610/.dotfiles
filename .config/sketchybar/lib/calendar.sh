#!/bin/bash
# Shared system-Calendar parser for SketchyBar. Sourced by plugins/calendar.sh
# (the meeting_watch plugin reads the cached epochs instead, never re-running icalBuddy).
#
# calendar_scan: runs icalBuddy ONCE and prints one tab-separated line describing the
# most relevant event. Fields by kind:
#   ERR<TAB><message>                                    icalBuddy missing or no Calendar access
#   TIMED<TAB><start_epoch><TAB><end_epoch><TAB><title>  earliest not-yet-ended timed event
#   ALLDAY<TAB><title>                                   no timed event, but an all-day one exists
#   NONE                                                 nothing on the calendar
#
# Epochs (not a live/soon label) are emitted because that classification is time-relative
# and must be recomputed against NOW by each caller every tick.
#
# Parsing notes (debugged empirically):
#   - icalBuddy's -ps takes a "|<sep>|" form where "|" is just the delimiter, so the
#     emitted property separator is "@P@"; the bullet "@EVT@" is literal.
#   - timed events render datetime as "<date> at <start> - <end>"; the " at " is normalized.
#   - the multi-day query (eventsToday+1) includes the date so parsing is uniform.

_cal_to_epoch() { date -j -f "%Y-%m-%d %H:%M" "$1 $2" +%s 2>/dev/null; }

calendar_scan() {
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

    printf 'TIMED\t%s\t%s\t%s\n' "$s" "$e" "$title"
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
