#!/usr/bin/env bash
# Waybar module: the queue chip (custom/queue), whether agent work flows. The bar is "Q:27  D:280",
# items ready to start next and items done today, labels in the theme accent (pango.sh). Q takes
# the level colour: red for queue-starved, a failed runner or no pass in PASS_LATE_SECS; amber for
# a stopped or BLOCKED dispatch, flapping, could_start, an unhandled shepherd line or a stale host.
# A deep queue that is moving is no fault. The hover (waybar's tooltip, Noctalia's dropdown) leads
# with the verdict, the worst exception or "flowing"; each other exception follows on one line
# with its fix (DO below), and a gate said there is not said again. Then aligned number tables
# (Queue, Dispatch, Shepherd) and an "as of" stamp naming the pass and host they come from.
# Everything is read from Prometheus (summary/dispatch from `fleet-dispatch stats`, the
# fleet_dispatch runner, the queue-starved watch, summary/shepherd), live topics only
# (cc:agents_topic_live), so the laptop thin client reads the same. Prometheus unreadable reads ?
# in amber, and no dispatch numbers read -, never a quiet nothing.

set -u
here="$(dirname "$(realpath "${BASH_SOURCE[0]}")")"
# shellcheck source=../../.local/lib/prom.sh
. "${PROM_LIB:-$here/../../.local/lib/prom.sh}" 2>/dev/null || . "$HOME/.local/lib/prom.sh"
# shellcheck source=pango.sh
. "$here/pango.sh"

# fleet-dispatch runs every 15 minutes; three missed passes is a stopped timer, not a slow one.
PASS_LATE_SECS=2700
# An urgent item ready this long is past DISPATCH_STARVED_MIN's default (60): its wait is amber.
URGENT_LATE_SECS=3600
# claude-acct-usage.timer writes the accounts' textfile every 15 minutes; three missed is stale.
ROOM_LATE_SECS=2700
# The number columns: a label this wide, then the value right-aligned in this many characters.
LABEL_W=14 VALUE_W=6

# What to do about each exception: the command or skill that shows or fixes its cause.
declare -A DO=(
  [slots]="fleet-dispatch headroom"
  [load]="fleet-pace skill"
  [idle]="fleet-pace skill"
  [assess]="fleet-assess"
  [account]="claude-acct status"
  [other]="fleet-dispatch headroom"
  [blocked]="fleet-dispatch run --dry-run"
  [starved]="fleet-dispatch run --dry-run"
  [flapping]="agentctl logs fleet-dispatch"
  [could]="fleet-dispatch headroom"
  [stale]="stop agent-mqtt-publish there"
  [failed]="agentctl logs fleet-dispatch"
  [late]="systemctl --user status agentctl-fleet-dispatch.timer"
  [shepherd]="shepherd skill, triage"
  [nofeed]="systemctl --user status agent-mqtt-publish.timer"
)

now="${DISPATCH_NOW:-$(date +%s)}"
head="<b>Queue:</b>"
# The accounts' room verdicts (claude-acct textfile) ride the same query, only from a textfile
# written lately: they name which account refuses and why when the account gate holds dispatch.
q='({__name__=~"mqtt_.+", topic=~"agents_.+_(summary_dispatch|runner_fleet_dispatch|watch_queue_starved|summary_shepherd)"} and on (topic) cc:agents_topic_live)'
q+=" or (claude_account_room_reason and on (instance) (time() - node_textfile_mtime_seconds{file=~\".*/claude_acct.prom\"} < $ROOM_LATE_SECS))"

if ! raw="$(prom_q "$q")"; then
  emit "$(paint "$C_YEL" 'Q?')" "$head $(paint "$C_YEL" "cannot read $PROM_URL")" warn
  exit 0
fi

# One object: kind.key -> value, kind being dispatch, runner, watch or shepherd. The source is the
# host whose dispatch pass ran last: only the lease holder runs a pass (`fleet-lease fleet-dispatch`)
# and, since #2971, only it sends summary/dispatch. Its series alone count; with no pass on record
# anywhere, every host's count by their max. A peer with a frozen store clone sent 622 queued and
# the old max over hosts showed it (ar-4306), so src.host names the source and src.stale each
# other host still sending summary/dispatch.
# Every value is a count, a 0/1 or an epoch, so it is floored: Prometheus may write 1 as 1.0.
v="$(jq -c '{summary_dispatch: "dispatch", summary_shepherd: "shepherd", runner_fleet_dispatch: "runner",
      watch_queue_starved: "watch"} as $kind
    | [.data.result[] | select(.metric.topic) | (.metric.topic | capture("^agents_(?<h>.+)_(?<t>"
        + ($kind | keys | join("|")) + ")$")) as $c
      | {h: $c.h, k: ($kind[$c.t] + "." + (.metric.__name__ | ltrimstr("mqtt_"))), v: (.value[1] | tonumber | floor)}] as $all
    | ([$all[] | select(.k == "dispatch.last_pass_epoch")] | max_by(.v) | .h) as $src
    | ($all | map(select($src == null or .h == $src)) | group_by(.k)
        | map({key: .[0].k, value: (map(.v) | max)}) | from_entries)
    + {"src.host": ($src // "" | gsub("_"; "-")),
       "src.stale": ([$all[] | select(.k == "dispatch.runnable" and $src != null and .h != $src)]
         | unique_by(.h) | map("\(.h | gsub("_"; "-")) (\(.v) ready)") | join("\n"))}' <<< "$raw")"
get() { jq -r --arg k "$1" '.[$k] // empty' <<< "$v"; }
d() { local x; x="$(get "dispatch.$1")"; printf '%s' "${x:--}"; }
n0() { local x; x="$(get "dispatch.$1")"; printf '%s' "${x:-0}"; }

# flag <level> <what> <do key>: an exception. It raises the chip to its level; the worst one is the
# head line, the rest follow it, each with what to do.
level=0 ex_lvl=() ex_what=() ex_do=()
flag() { ((level < $1)) && level=$1; ex_lvl+=("$1"); ex_what+=("$2"); ex_do+=("${DO[$3]}"); }

# vis <markup>: how many characters it shows, tags dropped and an entity counted as one.
vis() {
  local s="$1"
  while [[ $s =~ ^(.*)\<[^\>]*\>(.*)$ ]]; do s="${BASH_REMATCH[1]}${BASH_REMATCH[2]}"; done
  while [[ $s =~ ^(.*)\&[a-z]+\;(.*)$ ]]; do s="${BASH_REMATCH[1]}_${BASH_REMATCH[2]}"; done
  printf '%s' "${#s}"
}
# row <label> <value> [rest]: one line of a number table, the value right-aligned whatever markup
# paints it. rows collects them until `table <var>` closes the block into <var>.
rows=''
row() {
  local line lpad vpad
  lpad=$((LABEL_W - $(vis "$1"))) vpad=$((VALUE_W - $(vis "$2")))
  ((lpad < 0)) && lpad=0; ((vpad < 0)) && vpad=0
  printf -v line '%s%*s%*s%s' "$1" "$lpad" '' "$vpad" '' "$2"
  [ -z "${3:-}" ] || line+="  $3"
  rows+="${rows:+$'\n'}$line"
}
table() { printf -v "$1" '<tt>%s</tt>' "$rows"; rows=''; }

qtab='' dtab='' dhead='' stab='' shead=''
ready="$(get dispatch.runnable)"
pass="$(get dispatch.last_pass_epoch)" pass_age='' pass_ago=-
[ -n "$pass" ] && pass_age=$((now - pass)) pass_ago="$(prom_dur "$pass_age")"
if [ -z "$ready" ]; then
  flag 1 "no dispatch numbers on the feed" nofeed
else
  start="$(get dispatch.last_run_start_epoch)"
  reaped="$(get dispatch.reaped_1h)" flapping="$(get dispatch.flapping_items)" could="$(get dispatch.could_start)"
  oldest="$(get dispatch.oldest_runnable_s)" urgent_s="$(get dispatch.oldest_urgent_s)" high_s="$(get dispatch.oldest_high_s)"
  start_age=-
  [ -n "$start" ] && start_age="$(prom_dur $((now - start)))"
  units=$(n0 room_live_runs) cap=$(n0 room_max_live) load=$(n0 room_load) lcap=$(n0 room_load_cap)
  idle=$(n0 room_idle) floor=$(n0 room_min_idle)

  # The one gate that stopped the last pass, if any, in words with its numbers.
  gate='' paused='' reasons=''
  for k in slots load idle account assess other; do
    [ "$(get "dispatch.room_held_$k")" = 1 ] || continue
    gate=$k
    case $k in
      slots) paused="the fleet is at its session target of $(d room_max_live)" ;;
      load) paused="load $(d room_load) is over its cap of $(d room_load_cap)" ;;
      idle) paused="idle $(d room_idle)% is under its floor of $(d room_min_idle)%" ;;
      assess) paused="fleet-assess says the machine is too busy" ;;
      account)
        # Each account's published reasons, one "<account> <reason+reason>" line per account; they are
        # Dispatch rows, so the head line stays short however many accounts there are.
        reasons="$(jq -r '[.data.result[] | select(.metric.__name__ == "claude_account_room_reason" and (.metric.kind // "claude") == "claude") | .metric]
            | group_by(.account) | .[] | "\(.[0].account) \(map(.reason) | unique | join("+"))"' <<< "$raw")"
        paused="no account has room" ;;
      other) paused="a gate holds it" ;;
    esac
  done

  # A hold leads with how long dispatch has stopped and which gate holds it. queue-starved trips on
  # a hold (its watch reads the runner's held_since), so while one stands the hold is the starve:
  # one red line, never two lines for one cause.
  held="$(get dispatch.held_s)" starved="$(get watch.tripped)" gate_said=''
  if ((${held:-0} > 0)); then
    hl=1 what="stopped $(prom_dur "$held"): ${paused:-the last pass left ready work waiting}"
    [ "$starved" = 1 ] && hl=2 what+=" (queue-starved)"
    flag "$hl" "$what" "${gate:-blocked}"; gate_said=1
  else
    [ "$starved" = 1 ] && flag 2 "queue-starved: an urgent or high item sat ready too long" starved
    [ "$(get runner.blocked)" = 1 ] && { flag 1 "the last pass started nothing: ${paused:-ready work waited}" "${gate:-blocked}"; gate_said=1; }
  fi
  [ "$(get runner.failed)" = 1 ] && flag 2 "the fleet-dispatch runner failed" failed
  if [ -z "$pass_age" ]; then flag 2 "no dispatch pass on record" late
  elif ((pass_age > PASS_LATE_SECS)); then flag 2 "no pass in $pass_ago" late; fi
  ((${flapping:-0} > 0)) && flag 1 "$flapping item(s) flapping: a writer undoes reap's moves" flapping
  ((${could:-0} > 0)) && flag 1 "$could more could start: a limit holds them, not the machine" could
  stale="$(get src.stale)"
  [ -z "$stale" ] || while IFS= read -r h; do flag 1 "$(pango_esc "$h") sends a stale queue" stale; done <<< "$stale"

  # Queue: Q ready and its waits, D done today and the flow behind it.
  uw="$(prom_dur "$urgent_s")"
  if [ "$starved" = 1 ]; then uw="$(paint "$C_RED" "$uw")"
  elif [[ "$urgent_s" =~ ^[0-9]+$ ]] && ((urgent_s > URGENT_LATE_SECS)); then uw="$(paint "$C_YEL" "$uw")"; fi
  rest="$(d runnable_urgent) urgent, $(d runnable_high) high"
  queued="$(get dispatch.queued)"
  ((${queued:-0} > ready)) && rest+="; $queued queued in all"
  low="$(get dispatch.low_water)"
  ((${low:-0} > 0)) && rest+="; refills under $low"
  row "Q ready" "$ready" "$rest"
  rest="urgent $uw"
  [ -z "$high_s" ] || rest+=", high $(prom_dur "$high_s")"
  row "  oldest" "$(prom_dur "$oldest")" "$rest"
  row "  running" "$(d running)" "on a PR $(d review), waiting on you $(d waiting)"
  row "D done today" "$(d done_today)"
  # flow <h>: done (finished and not failed) in the last h hours, then started and failed; failed is amber.
  flow() {
    local dn fl
    dn="$(get "dispatch.done_${1}h")" fl="$(get "dispatch.failed_${1}h")"
    [ -n "$dn" ] && [ -n "$fl" ] && dn=$((dn - fl))
    ((${fl:-0} > 0)) && fl="$(paint "$C_YEL" "$fl")"
    row "  last $2" "${dn:--}" "started $(d "started_${1}h"), failed ${fl:--}"
  }
  flow 1 hour
  flow 24 24h
  # drain: the last 6h, added against finished, and the net. Blocks release more work and new work
  # keeps coming, so the empty time is a rate, never an ETA. Shrinking is green, growing amber,
  # steady plain. hub-core's flow strip says the same verdict (hub-core/src/flow.rs `drain`).
  done6="$(get dispatch.done_6h)" added6="$(get dispatch.added_6h)"
  if [ -n "$done6" ] && [ -n "$added6" ]; then
    net=$((added6 - done6))
    t="$(awk -v n="$net" -v q="${queued:--}" 'BEGIN {
      r = -n / 6
      if (r > 0 && q == "-") printf "0 shrinking"
      else if (r > 0) { h = int(q / r + 0.5); printf "0 shrinking, empty in about %s", (h < 48 ? h "h" : int(h / 24 + 0.5) "d") }
      else if (r < 0) printf "1 growing about %.0f/h", -r
      else printf "- steady" }')"
    case ${t%% *} in 0) t="$(paint "$C_GRN" "${t#* }")" ;; 1) t="$(paint "$C_YEL" "${t#* }")" ;; *) t="${t#* }" ;; esac
    row "  6h net" "$( ((net > 0)) && printf '+')$net" "$added6 added, $done6 finished: $t"
  else
    row "  6h net" "-"
  fi
  row "  board" "$(d board_agent)" "agent rows, $(d board_backlog) on the backlog"
  table qtab

  # Dispatch: capacity. Each number in its own colour: green with room, amber near its limit, red
  # past it. Full units are amber at most: the gates, not the count, decide when the machine is full.
  dhead="<b>Dispatch:</b> last pass $pass_ago ago, last start $start_age ago"
  if [ -n "$(get dispatch.room_max_live)" ]; then
    ul=0; [ "$units" -ge "$cap" ] && ul=1
    ll=0; [ $((load * 100)) -ge $((lcap * 80)) ] && ll=1; [ "$load" -gt "$lcap" ] && ll=2
    il=0; [ "$idle" -lt $((floor + 10)) ] && il=1; [ "$idle" -lt "$floor" ] && il=2
    # Every live session, hand starts included, against the pace target the run units share.
    rest="of $cap; run units $(paint "${LEVEL_COLOUR[$ul]}" "$units")"
    [ -n "$(get dispatch.room_live_hand)" ] && rest+=", by hand $(d room_live_hand)"
    row "  sessions" "$(d room_total_live)" "$rest"
    row "  load" "$(paint "${LEVEL_COLOUR[$ll]}" "$load")" "of $lcap"
    row "  idle" "$(paint "${LEVEL_COLOUR[$il]}" "$idle%")" "floor $floor%"
  else
    row "  capacity" "-" "no headroom from a pass in the last 45m"
  fi
  # A gate that paused the pass with no exception saying so (no hold, not BLOCKED).
  [ -n "$paused" ] && [ -z "$gate_said" ] && row "  paused" "" "$(paint "$C_YEL" "$paused")"
  [ -z "$reasons" ] || while read -r acct why; do row "  $(pango_esc "$acct")" "" "no room: $(pango_esc "$why")"; done <<< "$reasons"
  # The human's #prio/focus projects: names are on the hub Projects tab and in `fleet-dispatch headroom`.
  fn="$(get dispatch.focus_projects)"
  ((${fn:-0} > 0)) && row "  focus" "$(paint "$C_YEL" "$fn")" "project(s) first; reds and urgent items still go first"
  fl="${flapping:-0}"; ((fl > 0)) && fl="$(paint "$C_YEL" "$fl")"
  row "  self-heal" "${reaped:-0}" "reaped last hour, $fl flapping"
  table dtab
fi

# Shepherd: summary/shepherd, left out when it is not on the feed.
if [ -n "$(get shepherd.due)" ]; then
  s() { local x; x="$(get "shepherd.$1")"; printf '%s' "${x:--}"; }
  s_unh="$(get shepherd.unhandled)" s_pass="$(get shepherd.last_pass_epoch)"
  ((${s_unh:-0} > 0)) && flag 1 "$s_unh shepherd due line(s) unhandled" shepherd
  uh="${s_unh:-0}"; ((uh > 0)) && uh="$(paint "$C_YEL" "$uh")"
  shead="<b>Shepherd:</b> $([ -n "$s_pass" ] && echo "last pass $(prom_dur $((now - s_pass))) ago" || echo "no pass on record")"
  row "  last pass" "$(s due)" "due, $(s skipped) skipped, $uh unhandled"
  row "  last 24h" "$(s nudges_24h)" "nudges, $(s escalations_24h) escalations, $(s passes_24h) passes"
  table stab
fi

# The head: the worst exception (the first at the top level) and what to do, then the others.
if ((${#ex_lvl[@]} == 0)); then
  tip="$head $(paint "$C_GRN" flowing)"
else
  w=0
  for i in "${!ex_lvl[@]}"; do ((ex_lvl[i] > ex_lvl[w])) && w=$i; done
  tip="$head $(paint "${LEVEL_COLOUR[${ex_lvl[w]}]}" "${ex_what[w]}")"$'\n'"  Do: ${ex_do[w]}"
  for i in "${!ex_lvl[@]}"; do
    ((i == w)) && continue
    tip+=$'\n'"  $(paint "${LEVEL_COLOUR[${ex_lvl[i]}]}" "${ex_what[i]}"). Do: ${ex_do[i]}"
  done
fi
[ -n "$qtab" ] && tip+=$'\n'"$qtab"
[ -n "$dtab" ] && tip+=$'\n\n'"$dhead"$'\n'"$dtab"
[ -n "$stab" ] && tip+=$'\n\n'"$shead"$'\n'"$stab"
src="$(get src.host)"
if [ -n "$pass" ]; then
  tip+=$'\n\n'"as of $(date -d "@$pass" +%H:%M) ($pass_ago ago), the last dispatch pass${src:+, on $src}"
fi

# The bar: two totals behind their labels, and only Q takes the chip's level colour; a number the
# feed lacks reads -.
qn="${ready:--}"
((level > 0)) && qn="$(paint "${LEVEL_COLOUR[$level]}" "$qn")"
lc="$(label_colour)"
text="$(paint "$lc" Q:)$qn  $(paint "$lc" D:)$(d done_today)"

emit "$text" "$tip" "${LEVEL_CLASS[$level]}"
