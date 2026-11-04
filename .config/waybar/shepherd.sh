#!/usr/bin/env bash
# Waybar module: shepherd. The bar is the live agent sessions per fleet-sessions stage
# (.local/src/docs/fleet-states.md), a zero hidden:
#   W working (plain)  N needs the human (amber)  S stalled (red)  U unclear (amber)
#   L landed, D done (green)  P parked (dim)
# and a colour:
#   red    a session is STALLED, or a host's fleet_sessions.prom is older than STATE_LATE_SECS
#   amber  a session is UNCLEAR
#   green  otherwise; NEEDS is the human's queue, not a fault
# The hover lists every stalled, unclear and needs session with its idle time, worst first.
#
# Read from Prometheus (the fleet_sessions.prom textfile `fleet-sessions tick` writes each
# minute), so the chip reads the same on the laptop thin client. Sessions are per host, so
# hosts add up. Prometheus unreadable reads ? in amber and no stage numbers read -, never a
# quiet nothing.

set -u
here="$(dirname "$(realpath "${BASH_SOURCE[0]}")")"
# shellcheck source=../../.local/lib/prom.sh
. "${PROM_LIB:-$here/../../.local/lib/prom.sh}" 2>/dev/null || . "$HOME/.local/lib/prom.sh"
# shellcheck source=pango.sh
. "$here/pango.sh"

# nf-fa-tasks, written as an escape so an editor cannot strip the glyph from this file.
ICON=$'\uf0ae'
# fleet-state.timer ticks every minute; five missed ticks is a stopped timer, not a slow one.
STATE_LATE_SECS=300
C_DIM="#7f7f7f"
C_GRN="${LEVEL_COLOUR[0]}"

now="${SHEPHERD_NOW:-$(date +%s)}"
title="<b>Sessions</b>  fleet-sessions stages, every minute"
q='agent_sessions or agent_session_idle_minutes{bucket=~"STALLED|UNCLEAR|NEEDS"} or node_textfile_mtime_seconds{file=~".*/fleet_sessions.prom"}'

if ! raw="$(prom_q "$q")"; then
  emit "$ICON $(paint "$C_YEL" '?')" "$title"$'\n'"cannot read $PROM_URL" warn
  exit 0
fi

# counts: bucket -> sessions, max per host (two scrapes of one host read once), summed over hosts.
counts="$(jq -c '[.data.result[] | select(.metric.__name__ == "agent_sessions")
    | {h: (.metric.host // ""), b: .metric.bucket, v: (.value[1] | tonumber | floor)}]
  | group_by([.h, .b]) | map({b: .[0].b, v: (map(.v) | max)})
  | group_by(.b) | map({key: .[0].b, value: (map(.v) | add)}) | from_entries' <<< "$raw")"
if [ "$counts" = "{}" ]; then
  emit "$ICON $(paint "$C_YEL" -)" "$title"$'\n'"no agent_sessions on Prometheus: fleet-sessions tick writes fleet_sessions.prom" warn
  exit 0
fi
n() { jq -r --arg b "$1" '.[$b] // 0' <<< "$counts"; }

level=0 why=()
n_unclear="$(n UNCLEAR)" n_stalled="$(n STALLED)"
((n_unclear > 0)) && level=1 why+=("$n_unclear session(s) UNCLEAR: no repo, or its PR closed unmerged")
((n_stalled > 0)) && level=2 why+=("$n_stalled session(s) STALLED: unlanded work and idle, or a ready PR that conflicts")
while IFS=$'\t' read -r host age; do
  [ -n "$host" ] && level=2 why+=("fleet_sessions.prom on $host is $(prom_dur "$age") old; is fleet-state.timer running?")
done < <(jq -r --argjson now "$now" --argjson late "$STATE_LATE_SECS" '[.data.result[]
    | select(.metric.__name__ == "node_textfile_mtime_seconds")
    | {h: (.metric.host // "?"), a: ($now - (.value[1] | tonumber | floor))}]
  | group_by(.h) | map({h: .[0].h, a: (map(.a) | min)})[] | select(.a > $late) | [.h, .a] | @tsv' <<< "$raw")

# part <bucket> <letter> [colour]: "L3", painted, or nothing for an empty bucket.
part() {
  local c
  c="$(n "$1")"
  ((c > 0)) || return 0
  if [ -n "${3:-}" ]; then printf ' %s' "$(paint "$3" "$2$c")"; else printf ' %s' "$2$c"; fi
}
text="$ICON$(part WORKING W)$(part NEEDS N "$C_YEL")$(part STALLED S "$C_RED")$(part UNCLEAR U "$C_YEL")"
text+="$(part LANDED L "$C_GRN")$(part DONE D "$C_GRN")$(part PARKED P "$C_DIM")"
[ "$text" = "$ICON" ] && text="$ICON 0"

tip="$title"
for w in "${why[@]}"; do tip+=$'\n'"$(paint "${LEVEL_COLOUR[$level]}" "$w")"; done
tip+=$'\n'"$(jq -r '["WORKING", "NEEDS", "STALLED", "UNCLEAR", "LANDED", "DONE", "PARKED"] as $o
  | [$o[] as $b | "\($b | ascii_downcase) \(.[$b] // 0)"] | join(", ")' <<< "$counts")"
# One line per session that wants a look, worst first: stalled, unclear, then needs, by idle.
while IFS=$'\t' read -r bucket target project idle; do
  line="$bucket  $(pango_esc "$target")  $(pango_esc "$project")  idle $(prom_dur $((idle * 60)))"
  case "$bucket" in
    STALLED) line="$(paint "$C_RED" "$line")" ;;
    UNCLEAR) line="$(paint "$C_YEL" "$line")" ;;
  esac
  tip+=$'\n'"$line"
done < <(jq -r '[.data.result[] | select(.metric.__name__ == "agent_session_idle_minutes")
    | {b: .metric.bucket, t: (.metric.target // "?"), p: (.metric.project // "-"), i: (.value[1] | tonumber | floor)}]
  | unique_by(.t) | sort_by(({STALLED: 0, UNCLEAR: 1, NEEDS: 2}[.b] // 3), -.i)[] | [.b, .t, .p, .i] | @tsv' <<< "$raw")

emit "$text" "$tip" "${LEVEL_CLASS[$level]}"
