#!/usr/bin/env bash
# Waybar module: the agents chip (custom/ai-agents), the one overview of live agent sessions.
# The bar is the robot, the fleet total and three counts, "<robot> 34  ~:22  <check>:1  !:9": ~ working
# (amber), the check mark ready (LANDED or DONE, green), ! needs you (red above 0), each shown at 0 so
# the bar keeps its shape. The robot is the fleet's health: red when every fleet_sessions.prom is older
# than STATE_LATE_SECS, amber with a STALLED session, no session numbers or a stale file beside a fresh
# one (a former lease holder's leftover), green otherwise.
# The hover opens with one sentence (need you, stuck, working), then any warning, then a section per
# stage, worst first, filled to the bar channel's line cap (summary_bar.sh); a last line counts what
# was cut and points at the click (agent-panel, every session).
# Counts are fleet-sessions on Prometheus, so the laptop thin client reads the same; rows are
# `hub bar --json` from the summary/bar topic, which carries the task and reason no label can. A missing
# topic is one amber line and the counts still show. Prometheus unreadable reads ? in amber.
# Session series join only to a fleet_sessions.prom fresher than STATE_LATE_SECS; one selector reads
# age and idle, because `a or b` drops b's series whose labels match a's (same labels on both).
# Sources and states: .local/src/docs/fleet-states.md, the custom/ai-agents row.

set -u
here="$(dirname "$(realpath "${BASH_SOURCE[0]}")")"
# shellcheck source=../../.local/lib/prom.sh
. "${PROM_LIB:-$here/../../.local/lib/prom.sh}" 2>/dev/null || . "$HOME/.local/lib/prom.sh"
# shellcheck source=pango.sh
. "$here/pango.sh"
# shellcheck source=summary_bar.sh
. "$here/summary_bar.sh"

# nf-md-robot and a check mark, written as escapes so an editor cannot strip them.
ICON=$'\U000f06a9' READY=$'\u2713'
# fleet-state.timer ticks every minute; five missed ticks is a stopped timer, not a slow one.
STATE_LATE_SECS=300

now="${AGENTS_NOW:-$(date +%s)}"
title="<b>Sessions:</b>"
MTIME='node_textfile_mtime_seconds{file=~".*/fleet_sessions.prom"}'
q='{__name__=~"agent_session_(age|idle)_minutes"} and on (instance) (time() - '"$MTIME < $STATE_LATE_SECS)"
q+=" or agent_session_bucket or $MTIME"

if ! raw="$(prom_q "$q")"; then
  emit "$ICON $(paint "$C_YEL" '?')" "$title cannot read $PROM_URL" warn
  exit 0
fi

level=0 why=()
flag() { ((level < $1)) && level=$1; why+=("$(paint "${LEVEL_COLOUR[$1]}" "$2")"); }

# A host with no host label (a textfile dir the k3s node-exporter scrapes) is named by its instance.
fresh=0 stale=()
while IFS=$'\t' read -r host age; do
  [ -n "$host" ] || continue
  if ((age > STATE_LATE_SECS)); then stale+=("$host"$'\t'"$age"); else fresh=1; fi
done < <(jq -r --argjson now "$now" '[.data.result[]
    | select(.metric.__name__ == "node_textfile_mtime_seconds")
    | {h: (.metric.host // .metric.instance // "?"), a: ($now - (.value[1] | tonumber | floor))}]
  | group_by(.h)[] | [.[0].h, (map(.a) | min)] | @tsv' <<< "$raw")
# A stale file beside a fresh one is a leftover (amber); with no fresh one the tick stopped (red).
for s in "${stale[@]}"; do
  IFS=$'\t' read -r host age <<< "$s"
  flag $((fresh ? 1 : 2)) "fleet_sessions.prom on $host is $(prom_dur "$age") old; is fleet-state.timer running there, or is it a leftover to delete?"
done

# The bucket vocabulary fleet-sessions publishes: which buckets are in progress and which finished.
declare -A IN_PROGRESS=() FINISHED=()
n_order=0
while IFS=$'\t' read -r b ip fin; do
  n_order=$((n_order + 1))
  [ "$ip" = 1 ] && IN_PROGRESS[$b]=1
  [ "$fin" = 1 ] && FINISHED[$b]=1
done < <(jq -r '[.data.result[] | select(.metric.__name__ == "agent_session_bucket")
    | {b: .metric.bucket, i: .metric.in_progress, f: .metric.finished}] | unique_by(.b)[] | [.b, .i, .f] | @tsv' <<< "$raw")

# Each session's bucket, once however many scrapes or series carry it.
total=0 in_progress=0 n_work=0 n_ready=0 n_need=0 n_stalled=0
while read -r b; do
  [ -n "$b" ] || continue
  total=$((total + 1))
  [ -n "${IN_PROGRESS[$b]:-}" ] && in_progress=$((in_progress + 1))
  [ -n "${FINISHED[$b]:-}" ] && n_ready=$((n_ready + 1))
  case $b in WORKING) n_work=$((n_work + 1)) ;; NEEDS) n_need=$((n_need + 1)) ;; STALLED) n_stalled=$((n_stalled + 1)) ;; esac
done < <(jq -r '[.data.result[] | select(.metric.target) | {t: .metric.target, b: (.metric.bucket // "?")}]
  | unique_by(.t)[] | .b' <<< "$raw")

# No textfile on Prometheus at all is a missing feed, not an empty fleet.
if ! jq -e 'any(.data.result[]; .metric.__name__ == "node_textfile_mtime_seconds")' <<< "$raw" >/dev/null; then
  flag 1 "no fleet_sessions.prom on Prometheus: fleet-sessions tick writes it"
fi
((n_order > 0)) || flag 1 "no agent_session_bucket on Prometheus: fleet-sessions tick writes the bucket order"
# A stalled session is the robot's amber; the Stuck section says which and why.
((n_stalled > 0)) && ((level < 1)) && level=1

bar_caps
bar_read "$now"
need="$n_need need you" stuck="$n_stalled stuck"
((n_need > 0)) && need="$(paint "$C_RED" "$need")"
((n_stalled > 0)) && stuck="$(paint "$C_YEL" "$stuck")"
tip="$title $need, $stuck, $n_work working."
if [ -n "$BAR" ]; then
  hosts="$(jq '[.sessions[].target | if test("@") then split("@")[0] else "" end] | unique | length' <<< "$BAR")"
  tip+=" As of $(date -d "@$(jq '.as_of | floor' <<< "$BAR")" +%H:%M), $total sessions on $hosts host$( ((hosts == 1)) || printf s)."
else
  tip+=" $total sessions in all."
  why+=("$(paint "$C_YEL" "No session detail: $(pango_esc "$BAR_WHY")")")
fi
[ -z "$BAR" ] || while IFS= read -r e; do
  [ -n "$e" ] && why+=("$(paint "$C_YEL" "Session detail incomplete: $e")")
done < <(jq -r --argjson w "$BAR_WIDTH" "$BAR_JQ"'.errors[] | clean | fit($w - 28) | esc' <<< "$BAR")
for w in "${why[@]}"; do tip+=$'\n'"$w"; done

# The stage sections from summary/bar, in the lines the cap leaves: Need you, Stuck, Working, each
# worst first as hub-core sorts them, then a line for what was cut and one for the rest.
if [ -n "$BAR" ]; then
  tip+="$(jq -r --argjson lines $((BAR_LINES - 1 - ${#why[@]})) --argjson width "$BAR_WIDTH" \
    --arg red "$C_RED" --arg yel "$C_YEL" --arg sq "'" "$BAR_JQ"'
  [.sessions[] | . + {project: (.project | clean), task: (.task | clean),
      why: ((if .bucket == "WORKING" then .activity else .reason end) // "" | clean),
      tgt: (.target | clean | sub("^(?<h>[^@-]+)[^@]*@[^/]*/"; "\(.h)/") | sub(":1$"; ""))}] as $s
  | [{name: "Need you", key: "need you", b: "NEEDS", c: $red}, {name: "Stuck", key: "stuck", b: "STALLED", c: $yel},
     {name: "Working", key: "working", b: "WORKING", c: ""}]
  | map(. as $sec | . + {rows: [$s[] | select(.bucket == $sec.b)]}) | map(select(.rows | length > 0)) as $secs
  | ([$s[] | select(.done)] | group_by(.bucket) | map("\(length) \(.[0].bucket | ascii_downcase)")) as $done
  | ([$s[] | select((.done | not) and (.bucket | IN("NEEDS", "STALLED", "WORKING") | not))]
      | group_by(.bucket) | map("\(length) \(.[0].bucket | ascii_downcase)")) as $rest
  | ((if ($done | length) > 0 then ["Ready to close \($done | map(split(" ")[0] | tonumber) | add) (\($done | join(", ")))"] else [] end)
     + (if ($rest | length) > 0 then ["also \($rest | join(", "))"] else [] end) | join("; ")) as $tail
  | ($lines - 2 * ($secs | length) - (if $tail == "" then 0 else 2 end) - 1) as $room
  | (reduce $secs[] as $sec ({left: ([$room, 0] | max), out: []};
      ([($sec.rows | length), .left] | min) as $n
      | .out += [$sec + {shown: $sec.rows[:$n], cut: (($sec.rows | length) - $n)}] | .left -= $n)
    | .out) as $alloc
  | [$alloc[].shown[]] as $all
  | ([$all[].project | length] + [0] | max | [., 13] | min) as $pw
  | ([$all[].why | length] + [0] | max | [., 24] | min) as $rw
  | ([$all[] | select(.bucket != "WORKING") | .tgt | length] + [0] | max | [., 26] | min) as $gw
  | ([$width - 2 - $pw - 2 - 2 - $rw - 2 - 6 - (if $gw > 0 then 2 + $gw else 0 end), 12] | max) as $tw
  | def row: ("  " + (.project | fit($pw) | pad($pw)) + "  " + (.task | fit($tw) | pad($tw)) + "  "
      + (.why | fit($rw) | pad($rw)) + "  " + (.idle_min | mins | pad(6))
      + (if .bucket == "WORKING" then "" else "  " + (.tgt | lfit($gw)) end)) | sub(" +$"; "") | esc;
    [$alloc[] | "", "<b>" + (if .c == "" then .name else "<span color=\($sq)\(.c)\($sq)>\(.name)</span>" end) + "</b>  \(.rows | length)",
      (if (.shown | length) > 0 then "<tt>" + (.shown | map(row) | join("\n")) + "</tt>" else empty end)]
    + ([$alloc[] | select(.cut > 0) | "\(.cut) more \(.key)"] | if length > 0 then ["+" + join(", ") + ": click for every session (agent-panel)"] else [] end)
    + (if $tail == "" then [] else ["", $tail] end)
  | map("\n" + .) | join("")' <<< "$BAR")"
fi

need="!:$n_need"
((n_need == 0)) || need="$(paint "$C_RED" "$need")"
text="$(paint "${LEVEL_COLOUR[$level]}" "$ICON") $total  $(paint "$C_YEL" "~:$n_work")  $(paint "$C_GRN" "$READY:$n_ready")  $need"
class="${LEVEL_CLASS[$level]}"
((level == 0 && in_progress == 0)) && class=inactive
emit "$text" "$tip" "$class"
