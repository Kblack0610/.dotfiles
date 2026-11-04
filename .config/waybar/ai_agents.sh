#!/usr/bin/env bash
# Waybar module: the agents chip (custom/ai-agents), the one overview of live agent sessions.
# The bar is three totals and a health dot, "~22 <check>1 !9 <dot>": ~ working (WORKING), the check mark
# ready for its next step (LANDED or DONE), ! needs you (NEEDS, amber), each shown at 0 so the bar
# keeps its shape. STALLED and UNCLEAR are in none of the three; the dot carries them.
# The dot is the fleet's health:
#   red    a session is STALLED, or a host's fleet_sessions.prom is older than STATE_LATE_SECS
#   amber  a session is UNCLEAR, or Prometheus has no session numbers
#   green  otherwise
# The hover has the stage counts, then one section per tmux world (hub, lab: the part of the
# target before the slash), each with its own counts and one line per session, worst first.
#
# Read from Prometheus (agent_session_age_minutes, one series per session that `fleet-sessions
# tick` writes to fleet_sessions.prom every minute), the same stages the hub Sessions tab shows,
# so the chip reads the same on the laptop thin client and there is one count of sessions, not
# a pane count beside a stage count. Prometheus unreadable reads ? in amber, never a quiet nothing.

set -u
here="$(dirname "$(realpath "${BASH_SOURCE[0]}")")"
# shellcheck source=../../.local/lib/prom.sh
. "${PROM_LIB:-$here/../../.local/lib/prom.sh}" 2>/dev/null || . "$HOME/.local/lib/prom.sh"
# shellcheck source=pango.sh
. "$here/pango.sh"

# nf-md-robot, a check mark and a filled circle, written as escapes so an editor cannot strip them.
ICON=$'\U000f06a9' READY=$'\u2713' DOT=$'\u25cf'
# fleet-state.timer ticks every minute; five missed ticks is a stopped timer, not a slow one.
STATE_LATE_SECS=300

now="${AGENTS_NOW:-$(date +%s)}"
title="<b>Sessions</b>"
q='agent_session_age_minutes or agent_session_idle_minutes or node_textfile_mtime_seconds{file=~".*/fleet_sessions.prom"}'

if ! raw="$(prom_q "$q")"; then
  emit "$ICON $(paint "$C_YEL" '?')" "$title"$'\n'"cannot read $PROM_URL" warn
  exit 0
fi

level=0 why=()
flag() { ((level < $1)) && level=$1; why+=("$(paint "${LEVEL_COLOUR[$1]}" "$2")"); }

while IFS=$'\t' read -r host age; do
  [ -n "$host" ] && flag 2 "fleet_sessions.prom on $host is $(prom_dur "$age") old; is fleet-state.timer running?"
done < <(jq -r --argjson now "$now" --argjson late "$STATE_LATE_SECS" '[.data.result[]
    | select(.metric.__name__ == "node_textfile_mtime_seconds")
    | {h: (.metric.host // "?"), a: ($now - (.value[1] | tonumber | floor))}]
  | group_by(.h) | map({h: .[0].h, a: (map(.a) | min)})[] | select(.a > $late) | [.h, .a] | @tsv' <<< "$raw")

# One row per session (a second scrape of a host reads once): world, stage, target without its
# world, age and idle minutes (- when unknown). Worst stage first, then the longest idle and age.
mapfile -t rows < <(jq -r '
  [.data.result[] | select(.metric.target)
   | {t: .metric.target, b: (.metric.bucket // "?"), n: .metric.__name__, v: (.value[1] | tonumber | floor)}]
  | group_by(.t)
  | map({t: .[0].t, b: .[0].b,
         age: (map(select(.n == "agent_session_age_minutes") | .v) | max),
         idle: (map(select(.n == "agent_session_idle_minutes") | .v) | max)})
  | map(select(.age != null or .idle != null))
  | map(. + {w: (if (.t | contains("/")) then (.t | split("/")[0]) else "other" end),
             s: ({STALLED: 0, UNCLEAR: 1, NEEDS: 2, WORKING: 3, LANDED: 4, DONE: 5, PARKED: 6}[.b] // 7)})
  | sort_by(.w, .s, -(.idle // -1), -(.age // -1), .t)[]
  | [.w, .b, (.t | sub("^[^/]*/"; "")), (.age // "-"), (.idle // "-")] | map(tostring) | join("|")' <<< "$raw")

# counts <rows...>: "N in progress: 3 working, 2 need you, ..." for those rows, zeros left out.
in_progress() { case "$1" in WORKING|NEEDS|STALLED|UNCLEAR) return 0 ;; esac; return 1; }
counts() {
  local -A c=()
  local r b n=0 k label out=''
  for r in "$@"; do IFS='|' read -r _ b _ <<< "$r"; c[$b]=$((${c[$b]:-0} + 1)); in_progress "$b" && n=$((n + 1)); done
  for k in WORKING:working NEEDS:'need you' STALLED:stalled UNCLEAR:unclear LANDED:landed DONE:done PARKED:parked; do
    label="${k#*:}" k="${k%%:*}"
    ((${c[$k]:-0} > 0)) || continue
    case $k in
      STALLED) out+=", $(paint "$C_RED" "${c[$k]}") $label" ;;
      UNCLEAR|NEEDS) out+=", $(paint "$C_YEL" "${c[$k]}") $label" ;;
      *) out+=", ${c[$k]} $label" ;;
    esac
  done
  printf '%s in progress' "$n"
  [ -n "$out" ] && printf ': %s' "${out#, }"
}

total=0 n_work=0 n_ready=0 n_need=0 n_stalled=0 n_unclear=0 width=8
for r in "${rows[@]}"; do
  IFS='|' read -r _ b t _ <<< "$r"
  in_progress "$b" && total=$((total + 1))
  case $b in WORKING) n_work=$((n_work + 1)) ;; LANDED|DONE) n_ready=$((n_ready + 1)) ;; NEEDS) n_need=$((n_need + 1)) ;; esac
  [ "$b" = STALLED ] && n_stalled=$((n_stalled + 1))
  [ "$b" = UNCLEAR ] && n_unclear=$((n_unclear + 1))
  ((${#t} > width)) && width=${#t}
done
((n_stalled > 0)) && flag 2 "$n_stalled session(s) STALLED: unlanded work and idle, or a ready PR that conflicts"
((n_unclear > 0)) && flag 1 "$n_unclear session(s) UNCLEAR: no repo, or its PR closed unmerged"

# No textfile on Prometheus at all is a missing feed, not an empty fleet.
if ! jq -e 'any(.data.result[]; .metric.__name__ == "node_textfile_mtime_seconds")' <<< "$raw" >/dev/null; then
  flag 1 "no fleet_sessions.prom on Prometheus: fleet-sessions tick writes it"
fi

tip="$title  $(counts "${rows[@]}")"
for w in "${why[@]}"; do tip+=$'\n'"$w"; done

# A section per world: its counts, then a line per session.
world='' section=() body=''
flush() {
  [ -n "$world" ] || return 0
  tip+=$'\n\n'"<b>$(pango_esc "$world")</b>  $(counts "${section[@]}")"
  [ -n "$body" ] && tip+=$'\n'"<tt>${body#$'\n'}</tt>"
}
for r in "${rows[@]}"; do
  IFS='|' read -r w b t age idle <<< "$r"
  if [ "$w" != "$world" ]; then flush; world="$w" section=() body=''; fi
  section+=("$r")
  up=-; [ "$age" != - ] && up="$(prom_dur $((age * 60)))"
  if [ "$idle" = - ]; then printf -v line "%-8s %-${width}s up %s" "$b" "$t" "$up"
  else printf -v line "%-8s %-${width}s up %-6s idle %s" "$b" "$t" "$up" "$(prom_dur $((idle * 60)))"; fi
  line="$(pango_esc "$line")"
  case "$b" in
    STALLED) line="$(paint "$C_RED" "$line")" ;;
    UNCLEAR) line="$(paint "$C_YEL" "$line")" ;;
  esac
  body+=$'\n'"$line"
done
flush

need="!$n_need"; ((n_need > 0)) && need="$(paint "$C_YEL" "$need")"
text="$ICON ~$n_work $READY$n_ready $need $(paint "${LEVEL_COLOUR[$level]}" "$DOT")"
class="${LEVEL_CLASS[$level]}"
((level == 0 && total == 0)) && class=inactive
emit "$text" "$tip" "$class"
