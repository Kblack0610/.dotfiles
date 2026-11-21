#!/usr/bin/env bash
# Waybar module: the agents chip (custom/ai-agents), the one overview of live agent sessions.
# The bar is the robot, the fleet total and three counts within it, "<robot> 34  ~:22  <check>:1  !:9", each count after its symbol and a colon (the robot is wide enough to cover one).
# Two spaces part the counts, as on the queue chip; a | would read as the line between chips.
# The total is every session on every host, though the hover lists only those that want you, so it reads as the whole fleet; then
# ~ working (WORKING, amber), the check mark ready for its next step (LANDED or DONE, green), ! needs
# you (NEEDS, red above 0), each shown at 0 so the bar keeps its shape. The rest (STALLED, CHAT, the
# human's own conversation, PARKED) is in the total only; the robot's colour carries STALLED.
# The robot is the fleet's health:
#   red    every fleet_sessions.prom is older than STATE_LATE_SECS, so the numbers are a lie
#   amber  a session is STALLED, Prometheus has no session numbers, or one host's
#          fleet_sessions.prom is stale beside a fresh one (a host that once held the lease and
#          left its file behind): a session or a file wants a look, which is not a broken fleet
#   green  otherwise
# The hover is the stage counts, then one section per tmux world (hub, lab: the part of the target
# before the slash) with its own counts and a row per session, worst first, with how long it has
# been idle; a session that needs the human or is stalled (ATTENTION) adds why, cut to REASON_MAX
# characters. Every session, not only ATTENTION, at the human's ask (2026-11-20). A GTK tooltip
# cannot scroll, so at most HOVER_MAX_ROWS rows show, the ATTENTION ones taken first (so one is cut
# only past HOVER_MAX_ROWS of them), and a last line counts the rest and points at the click,
# agent-panel, which lists every session.
#
# Session series join only to a fleet_sessions.prom fresher than STATE_LATE_SECS (`and on (instance)`),
# so a stale file's sessions never show; the file itself and the bucket order (the same vocabulary from every host, and what keeps the hover's head right when every file is stale) are read unjoined.
# One selector reads age and idle: `a or b` drops b's series whose labels match a's, and
# fleet-sessions writes both with the same labels.
#
# Read from Prometheus (agent_session_why, the reason fleet-sessions gives a NEEDS or STALLED
# session, agent_session_age_minutes, one series per session that `fleet-sessions
# tick` writes to fleet_sessions.prom every minute, and agent_session_bucket, the bucket order and
# which are in progress or finished, so no list of buckets lives here), the same stages the hub Sessions tab shows,
# so the chip reads the same on the laptop thin client and there is one count of sessions, not
# a pane count beside a stage count. Prometheus unreadable reads ? in amber, never a quiet nothing.

set -u
here="$(dirname "$(realpath "${BASH_SOURCE[0]}")")"
# shellcheck source=../../.local/lib/prom.sh
. "${PROM_LIB:-$here/../../.local/lib/prom.sh}" 2>/dev/null || . "$HOME/.local/lib/prom.sh"
# shellcheck source=pango.sh
. "$here/pango.sh"

# nf-md-robot and a check mark, written as escapes so an editor cannot strip them.
ICON=$'\U000f06a9' READY=$'\u2713'
# fleet-state.timer ticks every minute; five missed ticks is a stopped timer, not a slow one.
STATE_LATE_SECS=300
# The buckets that want the human: their rows are kept first and say why. fleet-sessions publishes
# a reason (agent_session_why) for exactly these.
ATTENTION=" NEEDS STALLED "
# Session rows the hover holds: about 20 px a line on the workstation's 1080 px screen is about 50
# lines, less the head, warnings, world heads and the more line. A tooltip taller than the screen
# is cut at its edge with nothing to say so.
HOVER_MAX_ROWS=30
# A reason longer than this ends in "...", so a row stays one line and the cap holds the height.
REASON_MAX=70

now="${AGENTS_NOW:-$(date +%s)}"
title="<b>Sessions</b>"
MTIME='node_textfile_mtime_seconds{file=~".*/fleet_sessions.prom"}'
q='{__name__=~"agent_session_(age|idle)_minutes|agent_session_why"} and on (instance) (time() - '"$MTIME < $STATE_LATE_SECS)"
q+=" or agent_session_bucket or $MTIME"

if ! raw="$(prom_q "$q")"; then
  emit "$ICON $(paint "$C_YEL" '?')" "$title"$'\n'"cannot read $PROM_URL" warn
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

# The bucket vocabulary fleet-sessions publishes: its order (ORDER), and the flags on each bucket.
declare -A IN_PROGRESS=() FINISHED=()
ORDER=()
while IFS=$'\t' read -r b ip fin; do
  ORDER+=("$b")
  [ "$ip" = 1 ] && IN_PROGRESS[$b]=1
  [ "$fin" = 1 ] && FINISHED[$b]=1
done < <(jq -r '[.data.result[] | select(.metric.__name__ == "agent_session_bucket")
    | {b: .metric.bucket, o: (.value[1] | tonumber), i: .metric.in_progress, f: .metric.finished}]
  | unique_by(.b) | sort_by(.o)[] | [.b, .i, .f] | @tsv' <<< "$raw")

# One row per session (a second scrape of a host reads once): world, stage, target without its
# world, idle minutes (- when unknown), and why (- when none is published). Worst stage
# first, then the longest idle and age.
mapfile -t rows < <(jq -r '
  ([.data.result[] | select(.metric.__name__ == "agent_session_bucket")
    | {key: .metric.bucket, value: (.value[1] | tonumber)}] | from_entries) as $order
  | [.data.result[] | select(.metric.target)
   | {t: .metric.target, b: (.metric.bucket // "?"), n: .metric.__name__,
      v: (.value[1] | tonumber | floor), r: (.metric.reason // "")}]
  | group_by(.t)
  | map({t: .[0].t, b: .[0].b,
         age: (map(select(.n == "agent_session_age_minutes") | .v) | max),
         idle: (map(select(.n == "agent_session_idle_minutes") | .v) | max),
         why: (map(select(.n == "agent_session_why") | .r) | first // "")})
  | map(select(.age != null or .idle != null))
  | map(. + {w: (if (.t | contains("/")) then (.t | split("/")[0]) else "other" end),
             s: ($order[.b] // 99)})
  | sort_by(.w, .s, -(.idle // -1), -(.age // -1), .t)[]
  | [.w, .b, (.t | sub("^[^/]*/"; "")), (.idle // "-"), (if .why == "" then "-" else (.why | gsub("[\n\t|]"; " ")) end)] | map(tostring) | join("|")' <<< "$raw")

# stage_paint <stage> <text>: amber for what wants a look, plain for the rest.
stage_paint() {
  case "$1" in
    STALLED|NEEDS) paint "$C_YEL" "$2" ;;
    *) printf '%s' "$2" ;;
  esac
}

# counts <rows...>: "N in progress: 3 working, 2 need you, ..." for those rows in the vocabulary's
# order, zeros left out.
counts() {
  local -A c=()
  local r b n=0 k label out=''
  for r in "$@"; do IFS='|' read -r _ b _ <<< "$r"; c[$b]=$((${c[$b]:-0} + 1)); [ -n "${IN_PROGRESS[$b]:-}" ] && n=$((n + 1)); done
  for k in "${ORDER[@]}"; do
    ((${c[$k]:-0} > 0)) || continue
    label="${k,,}"; [ "$k" = NEEDS ] && label='need you'
    out+=", $(stage_paint "$k" "${c[$k]}") $label"
  done
  printf '%s in progress' "$n"
  [ -n "$out" ] && printf ': %s' "${out#, }"
}

in_progress=0 n_work=0 n_ready=0 n_need=0 n_stalled=0 width=8
for r in "${rows[@]}"; do
  IFS='|' read -r _ b t _ <<< "$r"
  [ -n "${IN_PROGRESS[$b]:-}" ] && in_progress=$((in_progress + 1))
  [ -n "${FINISHED[$b]:-}" ] && n_ready=$((n_ready + 1))
  case $b in WORKING) n_work=$((n_work + 1)) ;; NEEDS) n_need=$((n_need + 1)) ;; esac
  [ "$b" = STALLED ] && n_stalled=$((n_stalled + 1))
done

# The rows the hover holds (shown[index]): every ATTENTION row first, then the rest in order, up
# to HOVER_MAX_ROWS; hidden counts the rest.
declare -A shown=()
n_shown=0
for pass in attention rest; do
  for i in "${!rows[@]}"; do
    ((n_shown < HOVER_MAX_ROWS)) || break 2
    IFS='|' read -r _ b t _ <<< "${rows[$i]}"
    want=rest; [[ "$ATTENTION" == *" $b "* ]] && want=attention
    [ "$want" = "$pass" ] || continue
    shown[$i]=1 n_shown=$((n_shown + 1))
    ((${#t} > width)) && width=${#t}
  done
done
hidden=$((${#rows[@]} - n_shown))

# No textfile on Prometheus at all is a missing feed, not an empty fleet.
if ! jq -e 'any(.data.result[]; .metric.__name__ == "node_textfile_mtime_seconds")' <<< "$raw" >/dev/null; then
  flag 1 "no fleet_sessions.prom on Prometheus: fleet-sessions tick writes it"
fi
((${#ORDER[@]} > 0)) || flag 1 "no agent_session_bucket on Prometheus: fleet-sessions tick writes the bucket order"
((n_stalled > 0)) && flag 1 "$n_stalled session(s) STALLED: unlanded work and idle, or a ready PR that conflicts"

head="$title  ${#rows[@]} total, $(counts "${rows[@]}")"
tip="$head"
for w in "${why[@]}"; do tip+=$'\n'"$w"; done

# A section per world: its counts, then a line per session the hover holds.
world='' section=() body=''
flush() {
  [ -n "$world" ] || return 0
  tip+=$'\n\n'"<b>$(pango_esc "$world")</b>  $(counts "${section[@]}")"
  [ -n "$body" ] && tip+=$'\n'"<tt>${body#$'\n'}</tt>"
}
for i in "${!rows[@]}"; do
  r="${rows[$i]}"
  IFS='|' read -r w b t idle reason <<< "$r"
  if [ "$w" != "$world" ]; then flush; world="$w" section=() body=''; fi
  section+=("$r")
  [ -n "${shown[$i]:-}" ] || continue
  if [[ "$ATTENTION" == *" $b "* ]]; then
    [ "$reason" = - ] && reason="no reason published"
    ((${#reason} > REASON_MAX)) && reason="${reason:0:REASON_MAX-3}..."
  else
    reason=''
  fi
  idle_for=-; [ "$idle" != - ] && idle_for="$(prom_dur $((idle * 60)))"
  printf -v line "%-8s %-${width}s idle %-6s %s" "$b" "$t" "$idle_for" "$reason"
  line="${line%"${line##*[! ]}"}"
  line="$(pango_esc "$line")"
  case "$b" in
    STALLED) line="$(paint "$C_YEL" "$line")" ;;
  esac
  body+=$'\n'"$line"
done
flush
((hidden > 0)) && tip+=$'\n\n'"+$hidden more: click for every session (agent-panel)"

need="!:$n_need"
((n_need == 0)) || need="$(paint "$C_RED" "$need")"
text="$(paint "${LEVEL_COLOUR[$level]}" "$ICON") ${#rows[@]}  $(paint "$C_YEL" "~:$n_work")  $(paint "$C_GRN" "$READY:$n_ready")  $need"
class="${LEVEL_CLASS[$level]}"
((level == 0 && in_progress == 0)) && class=inactive
emit "$text" "$tip" "$class"
