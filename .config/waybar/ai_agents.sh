#!/usr/bin/env bash
# Waybar module: the agents chip (custom/ai-agents), the one overview of live agent sessions.
# The bar is the robot, the fleet total and two counts, "<robot> 34  ~:22  <check>:1": ~ working (amber)
# and the check mark ready (LANDED or DONE, green), each shown at 0 so the bar keeps its shape. What
# needs the human is custom/needs (needs.sh), Home's one count, so a NEEDS session here is "waiting"
# and has no number on the bar. The robot is the fleet's health: red when every fleet_sessions.prom is
# older than STATE_LATE_SECS, amber with a STALLED session, no session numbers or a stale file beside a
# fresh one (a former lease holder's leftover), green otherwise.
# The hover opens with one sentence (waiting, stuck, working), then any warning, then the Machines
# block (one line per machine: its sessions, a worker's free slots or else its tmux spaces, the count
# per model, the stuck ones), then a section per stage, worst first, each row ending in its model and
# a short host tag, filled to the bar channel's line cap (summary_bar.sh); a last line counts what was
# cut and points at the click (agent-panel, every session).
# The counts are hub-core's Sessions card figures (`hub cards --json --figures`: headline, working,
# need_you, stalled, ready_to_close; every host, less the fleet's own), which summary/cards carries to
# Prometheus, live topics only, as health.sh reads its Health figures; this script counts no session.
# Rows and the Machines lines are `hub bar --json` (`.sessions`, `.hosts`) from the summary/bar topic,
# which carries the task and reason no label can; hub-core counts the Machines figures, not this script.
# A missing topic is one amber line and the counts still show; counts nobody publishes read ? in amber.
# fleet_sessions.prom is read for its age alone: the tick that writes the state the card counts.
# Prometheus unreadable reads ? in amber.
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
q="$MTIME"' or ({__name__=~"mqtt_figures_sessions_(headline|working|need_you|stalled|ready_to_close)", topic=~"agents_.+_summary_cards"} and on (topic) cc:agents_topic_live)'

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

# The Sessions card's figures as published, each - when no live topic sends it. Only the lease holder
# sends summary/cards; while a lease move leaves two topics live that disagree, a figure is !, since
# Prometheus does not say which is newer.
fig() {
  jq -r --arg l "$1" '[.data.result[] | select(.metric.__name__ == "mqtt_figures_sessions_" + $l)
      | .value[1] | tonumber | floor] | unique | if length > 1 then "!" else .[0] // "-" end' <<< "$raw"
}
total=$(fig headline) n_work=$(fig working) n_wait=$(fig need_you) n_stalled=$(fig stalled) n_ready=$(fig ready_to_close)
figs_ok=1 in_progress=0
for v in "$total" "$n_work" "$n_wait" "$n_stalled" "$n_ready"; do
  [[ "$v" =~ ^[0-9]+$ ]] || figs_ok=0
done
if ((figs_ok)); then
  # in progress is what an agent or the human still has to move: working, waiting and stalled
  in_progress=$((n_work + n_wait + n_stalled))
else
  total='?' n_work='?' n_wait='?' n_stalled='?' n_ready='?'
fi

# No textfile on Prometheus at all is a missing feed, not an empty fleet.
if ! jq -e 'any(.data.result[]; .metric.__name__ == "node_textfile_mtime_seconds")' <<< "$raw" >/dev/null; then
  flag 1 "no fleet_sessions.prom on Prometheus: fleet-sessions tick writes it"
fi
((figs_ok)) || flag 1 "no published session counts (summary/cards), or two machines publish different ones"
# A stalled session is the robot's amber; the Stuck section says which and why.
((figs_ok)) && ((n_stalled > 0)) && ((level < 1)) && level=1

bar_caps
summary_read "$now" bar
waiting="$n_wait waiting" stuck="$n_stalled stuck"
((figs_ok)) && ((n_wait > 0)) && waiting="$(paint "$C_YEL" "$waiting")"
((figs_ok)) && ((n_stalled > 0)) && stuck="$(paint "$C_YEL" "$stuck")"
tip="$title $waiting, $stuck, $n_work working."
if [ -n "$BAR" ]; then
  tip+=" As of $(date -d "@$BAR_AT" +%H:%M), $total sessions."
else
  tip+=" $total sessions in all."
fi
while IFS= read -r l; do why+=("$l"); done < <(bar_detail session)
for w in "${why[@]}"; do tip+=$'\n'"$w"; done

# The Machines block and the stage sections from summary/bar, in the lines the cap leaves: Machines
# first (a heading and one line per machine), then Waiting, Stuck, Working, each worst first as
# hub-core sorts them, then a line for what was cut and one for the rest.
if [ -n "$BAR" ]; then
  tip+="$(jq -r --argjson lines $((BAR_LINES - 1 - ${#why[@]})) --argjson width "$BAR_WIDTH" \
    --arg yel "$C_YEL" --arg sq "'" "$BAR_JQ"'
  [.sessions[] | . + {project: (.project | clean), task: (.task | clean),
      why: ((if .bucket == "WORKING" then .activity else .reason end) // "" | clean),
      on: (.runs_on // "-" | clean), at: (.host // "" | clean | split("-")[0] // "")}] as $s
  | [{name: "Waiting", b: "NEEDS", c: $yel}, {name: "Stuck", b: "STALLED", c: $yel}, {name: "Working", b: "WORKING", c: ""}] as $defs
  | ($defs | map(. as $sec | . + {rows: [$s[] | select(.bucket == $sec.b)]}) | map(select(.rows | length > 0))) as $secs
  | def counts: group_by(.bucket) | map("\(length) \(.[0].bucket | ascii_downcase)");
  ([$s[] | select(.done)] | counts) as $done
  | ([$s[] | select((.done | not) and (.bucket | IN($defs[].b) | not))] | counts) as $rest
  | ((if ($done | length) > 0 then ["Ready to close \($done | map(split(" ")[0] | tonumber) | add) (\($done | join(", ")))"] else [] end)
     + (if ($rest | length) > 0 then ["also \($rest | join(", "))"] else [] end) | join("; ")) as $tail
  | [.hosts // [] | .[] | {name: (.name | clean), live, stuck,
      where: (if .max_live != null and .free != null then "\(.free) of \(.max_live) slots free"
        else .spaces | map("\(.name | clean) \(.n)") | join(", ") end),
      on: (.models | map("\(.name | clean) \(.n)") | join("  "))}] as $hosts
  | ($hosts | if length > 0 then 2 + length else 0 end) as $mlines
  | ($lines - 2 * ($secs | length) - (if $tail == "" then 0 else 2 end) - 1 - $mlines) as $room
  | (reduce $secs[] as $sec ({left: ([$room, 0] | max), out: []};
      ([($sec.rows | length), .left] | min) as $n
      | .out += [$sec + {shown: $sec.rows[:$n], cut: (($sec.rows | length) - $n)}] | .left -= $n)
    | .out) as $alloc
  | [$alloc[].shown[]] as $all
  | ([$all[].project | length] + [0] | max | [., 13] | min) as $pw
  | ([$all[].why | length] + [0] | max | [., 24] | min) as $rw
  | ([$all[].on | length] + [0] | max | [., 14] | min) as $mw
  | ([$all[].at | length] + [0] | max | [., 10] | min) as $hw
  | ([$width - 2 - $pw - 2 - 2 - $rw - 2 - 6 - 2 - $mw - (if $hw > 0 then 2 + $hw else 0 end), 12] | max) as $tw
  | def row: ("  " + (.project | fit($pw) | pad($pw)) + "  " + (.task | fit($tw) | pad($tw)) + "  "
      + (.why | fit($rw) | pad($rw)) + "  " + (.idle_min | mins | pad(6)) + "  " + (.on | fit($mw) | pad($mw))
      + "  " + (.at | fit($hw))) | sub(" +$"; "") | esc;
    def lpad($n): (" " * ([$n - length, 0] | max)) + .;
    ([$hosts[].name | length] + [0] | max | [., 20] | min) as $nw
  | ([$hosts[].where | length] + [0] | max | [., 24] | min) as $ww
  | ([$hosts[] | select(.stuck > 0) | "\(.stuck) stuck" | length + 2] + [0] | max) as $sw
  | ([$hosts[].on | length] + [0] | max | [., ([$width - 2 - $nw - 2 - 3 - 2 - $ww - 2 - $sw, 12] | max)] | min) as $ow
  | def mrow: . as $h | ("  " + (.name | fit($nw) | pad($nw)) + "  " + ("\(.live)" | lpad(3)) + "  "
      + (.where | fit($ww) | pad($ww)) + "  " + (.on | fit($ow) | pad($ow))
      | if $h.stuck > 0 then esc + "  <span color=\($sq)\($yel)\($sq)>\($h.stuck) stuck</span>" else sub(" +$"; "") | esc end);
    (if ($hosts | length) > 0 then ["", "<b>Machines</b>", "<tt>" + ($hosts | map(mrow) | join("\n")) + "</tt>"] else [] end)
    + [$alloc[] | "", "<b>" + (if .c == "" then .name else "<span color=\($sq)\(.c)\($sq)>\(.name)</span>" end) + "</b>  \(.rows | length)",
      (if (.shown | length) > 0 then "<tt>" + (.shown | map(row) | join("\n")) + "</tt>" else empty end)]
    + ([$alloc[] | select(.cut > 0) | "\(.cut) more \(.name | ascii_downcase)"] | if length > 0 then ["+" + join(", ") + ": click for every session (agent-panel)"] else [] end)
    + (if $tail == "" then [] else ["", $tail] end)
  | map("\n" + .) | join("")' <<< "$BAR")"
fi

text="$(paint "${LEVEL_COLOUR[$level]}" "$ICON") $total  $(paint "$C_YEL" "~:$n_work")  $(paint "$C_GRN" "$READY:$n_ready")"
class="${LEVEL_CLASS[$level]}"
((level == 0 && in_progress == 0)) && class=inactive
emit "$text" "$tip" "$class"
