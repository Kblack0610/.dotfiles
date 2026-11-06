#!/usr/bin/env bash
# Waybar module: the queue chip (custom/dispatch), the one chip for agent work. The bar is three
# totals, "Q 87  B 1522  D 280": every queue item, the open agent board rows, and the items done in
# the last 24h. Letters are dim so the numbers lead; all the detail is in the hover. The Q number's colour:
#   red    queue-starved is tripped, the fleet-dispatch runner failed, or no pass in
#          PASS_LATE_SECS
#   amber  dispatch is stopped (held_s) or the last pass left ready work waiting (BLOCKED), an item is flapping, more could
#          start than the limits let the last pass (could_start), or a shepherd due line went
#          unhandled
#   neutral otherwise: a deep queue that is moving, or full units on a full machine, is no fault
# The hover has one section per system: Queue (items, oldest, 1h and 24h flow, drain), Dispatch
# (capacity, what paused the last pass, self-heal) and Shepherd (its last pass and the last 24h).
# Exceptions lead it. Sessions and their stages are the agents chip (ai_agents.sh).
#
# Everything is read from Prometheus (summary/dispatch from `fleet-dispatch stats`, the
# fleet_dispatch runner, the queue-starved watch and summary/shepherd from `fleet-shepherd
# stats`), so the chip reads the same on the laptop thin client. Only live feed topics count (cc:agents_topic_live), so a host
# that stopped publishing cannot hold it red. Prometheus unreadable reads ? in amber and no
# dispatch numbers read -, never a quiet nothing.

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
C_DIM="#7f7f7f"

now="${DISPATCH_NOW:-$(date +%s)}"
title="<b>Queue</b>"
q='({__name__=~"mqtt_.+", topic=~"agents_.+_(summary_dispatch|runner_fleet_dispatch|watch_queue_starved|summary_shepherd)"} and on (topic) cc:agents_topic_live)'

if ! raw="$(prom_q "$q")"; then
  emit "$(paint "$C_YEL" 'Q ?')" "$title"$'\n'"cannot read $PROM_URL" warn
  exit 0
fi

# One object: kind.key -> value, kind being dispatch, runner, watch or shepherd; max over hosts.
# Every value is a count, a 0/1 or an epoch, so it is floored: Prometheus may write 1 as 1.0.
v="$(jq -c '[.data.result[] | select(.metric.topic) | {k: ((.metric.topic
      | capture("_(?<k>summary_dispatch|summary_shepherd|runner|watch)(_|$)") | .k | sub("summary_"; ""))
      + "." + (.metric.__name__ | ltrimstr("mqtt_"))), v: (.value[1] | tonumber | floor)}]
    | group_by(.k) | map({key: .[0].k, value: (map(.v) | max)}) | from_entries' <<< "$raw")"
get() { jq -r --arg k "$1" '.[$k] // empty' <<< "$v"; }
d() { local x; x="$(get "dispatch.$1")"; printf '%s' "${x:--}"; }
n0() { local x; x="$(get "dispatch.$1")"; printf '%s' "${x:-0}"; }
# done_in <h>: items finished and not failed in the last h hours; - when the feed lacks the count.
done_in() {
  local dn fl
  dn="$(get "dispatch.done_${1}h")" fl="$(get "dispatch.failed_${1}h")"
  [ -n "$dn" ] && [ -n "$fl" ] && dn=$((dn - fl))
  printf '%s' "${dn:--}"
}

# flag <level> <text>: an exception, which raises the chip to its level and leads the hover.
level=0 why=()
flag() { ((level < $1)) && level=$1; why+=("$(paint "${LEVEL_COLOUR[$1]}" "$2")"); }

# --- Queue and Dispatch: summary/dispatch ---
ready="$(get dispatch.runnable)"
qhead="$title" queue='' disp='' total=-
if [ -z "$ready" ]; then
  flag 1 "no dispatch numbers on the feed: agent-mqtt-publish publishes fleet-dispatch stats as summary/dispatch"
else
  pass="$(get dispatch.last_pass_epoch)" start="$(get dispatch.last_run_start_epoch)"
  reaped="$(get dispatch.reaped_1h)" flapping="$(get dispatch.flapping_items)" could="$(get dispatch.could_start)"
  oldest="$(get dispatch.oldest_runnable_s)" urgent_s="$(get dispatch.oldest_urgent_s)"
  pass_age=$((now - ${pass:-0})) start_age=-
  [ -n "$start" ] && start_age="$(prom_dur $((now - start)))"
  # paused by: the one gate that stopped the last pass, if any, by name.
  paused=''
  for k in slots load idle account assess other; do
    [ "$(get "dispatch.room_held_$k")" = 1 ] || continue
    case $k in
      slots) paused="every run unit is used (DISPATCH_MAX_LIVE)" ;;
      load) paused="load is over the cap (DISPATCH_MAX_LOAD)" ;;
      idle) paused="real idle is under the floor (DISPATCH_MIN_IDLE)" ;;
      assess) paused="fleet-assess says the machine is too busy (fleet-assess)" ;;
      account) paused="no account has room under its weekly pace" ;;
      other) paused="a gate (fleet-dispatch headroom says which)" ;;
    esac
  done

  # A hold that has stopped every pass leads with how long (held_s, the Stopped line's clock);
  # a single BLOCKED pass is said as one.
  held="$(get dispatch.held_s)"
  if ((${held:-0} > 0)); then flag 1 "dispatch stopped $(prom_dur "$held"): ${paused:-the last pass left ready work waiting}"
  elif [ "$(get runner.blocked)" = 1 ]; then flag 1 "the last pass left ready work waiting (BLOCKED)"; fi
  ((${flapping:-0} > 0)) && flag 1 "$flapping item(s) flapping between running and waiting"
  ((${could:-0} > 0)) && flag 1 "$could more could start now: a limit, not the machine, holds them (fleet-dispatch headroom)"
  [ "$(get watch.tripped)" = 1 ] && flag 2 "queue-starved is tripped"
  [ "$(get runner.failed)" = 1 ] && flag 2 "the fleet-dispatch runner failed"
  ((pass_age > PASS_LATE_SECS)) && flag 2 "no pass in $(prom_dur "$pass_age"); is fleet-dispatch.timer running?"

  # oldest: the urgent wait is amber past URGENT_LATE_SECS, red when queue-starved trips.
  uw="$(prom_dur "$urgent_s")"
  if [ "$(get watch.tripped)" = 1 ]; then uw="$(paint "$C_RED" "$uw")"
  elif [[ "$urgent_s" =~ ^[0-9]+$ ]] && ((urgent_s > URGENT_LATE_SECS)); then uw="$(paint "$C_YEL" "$uw")"; fi

  # drain: the last 6h, added against finished, and the net. Blocks release more work and new
  # work keeps coming, so the empty time is a rate, never an ETA. Shrinking is green, growing
  # amber, steady plain.
  drain=-
  done6="$(get dispatch.done_6h)" added6="$(get dispatch.added_6h)" queued="$(get dispatch.queued)"
  if [ -n "$done6" ] && [ -n "$added6" ]; then
    net=$((added6 - done6))
    t="$(awk -v n="$net" -v q="${queued:-0}" 'BEGIN {
      r = -n / 6
      if (r > 0) { h = int(q / r + 0.5); printf "0 shrinking, empty in about %s at that rate", (h < 48 ? h "h" : int(h / 24 + 0.5) "d") }
      else if (r < 0) printf "1 growing about %.0f/h", -r
      else printf "- steady" }')"
    case ${t%% *} in 0) t="$(paint "$C_GRN" "${t#* }")" ;; 1) t="$(paint "$C_YEL" "${t#* }")" ;; *) t="${t#* }" ;; esac
    drain="$added6 added, $done6 finished, net $( ((net > 0)) && printf '+')$net: $t"
  fi

  # flow <h>: started, done (finished and not failed) and failed in the last h hours; failed is amber.
  flow() {
    local st fl
    st="$(d "started_${1}h")" fl="$(get "dispatch.failed_${1}h")"
    ((${fl:-0} > 0)) && fl="$(paint "$C_YEL" "$fl")"
    printf '%s started, %s done, %s failed' "$st" "$(done_in "$1")" "${fl:--}"
  }

  [ -n "$queued" ] && total=$((queued + $(n0 running) + $(n0 waiting)))
  qhead="$title  $total items: $(d queued) queued, $(d running) running, $(d waiting) waiting on you"
  ready_line="$ready ready ($(d runnable_urgent) urgent or high)"
  low="$(get dispatch.low_water)"
  [ -z "$low" ] || ready_line+=" of low water $low"
  queue="queued: $ready_line, $(d held) blocked ($(d held_after) on a phase, $(d held_pr) on a PR, $(d held_time) on a time tag)"
  queue+=$'\n'"oldest: ready $(prom_dur "$oldest"), urgent $uw"
  [ -z "$(get dispatch.present_per_hour)" ] ||
    queue+=$'\n'"present trickle: $(d present_starts_1h) of $(d present_per_hour) board starts this hour"
  queue+=$'\n'"last hour: $(flow 1)"
  queue+=$'\n'"last 24h: $(flow 24)"
  queue+=$'\n'"drain 6h: $drain"
  queue+=$'\n'"board: $(d board_agent) agent rows, $(d board_human) yours, $(d board_playtest) playtest checks"

  disp="<b>Dispatch</b>  a pass every 15 minutes"
  if [ -n "$(get dispatch.room_max_live)" ]; then
    # Each number in its own colour, labels plain: green with room, amber near its limit, red past it.
    # Full units are amber at most: the gates, not the count, decide when the machine is full.
    units=$(n0 room_live_runs) cap=$(n0 room_max_live) load=$(n0 room_load) lcap=$(n0 room_load_cap)
    idle=$(n0 room_idle) floor=$(n0 room_min_idle)
    ul=0; [ "$units" -ge "$cap" ] && ul=1
    ll=0; [ $((load * 100)) -ge $((lcap * 80)) ] && ll=1; [ "$load" -gt "$lcap" ] && ll=2
    il=0; [ "$idle" -lt $((floor + 10)) ] && il=1; [ "$idle" -lt "$floor" ] && il=2
    cl="capacity: run units $(paint "${LEVEL_COLOUR[$ul]}" "$units/$cap")"
    [ -n "$(get dispatch.room_live_hand)" ] && cl+=", +$(d room_live_hand) by hand"
    cl+="; load $(paint "${LEVEL_COLOUR[$ll]}" "$load of $lcap"); idle $(paint "${LEVEL_COLOUR[$il]}" "$idle% (floor $floor%)")"
  else
    cl="capacity: no headroom from a pass in the last 45 minutes"
  fi
  [ -n "$paused" ] && cl+=$'\n'"paused by: $(paint "$C_YEL" "$paused")"
  disp+=$'\n'"$cl"
  cs="${could:--}"; ((${could:-0} > 0)) && cs="$(paint "$C_YEL" "$could")"
  disp+=$'\n'"can start now: $cs more; last pass $(prom_dur "$pass_age") ago, last start $start_age ago"
  fl="${flapping:-0}"; ((fl > 0)) && fl="$(paint "$C_YEL" "$fl")"
  disp+=$'\n'"self-heal last hour: reaped ${reaped:-0}, flapping $fl"
fi

# --- Shepherd: summary/shepherd, left out when it is not on the feed ---
shep=''
if [ -n "$(get shepherd.due)" ]; then
  s() { local x; x="$(get "shepherd.$1")"; printf '%s' "${x:--}"; }
  s_unh="$(get shepherd.unhandled)" s_pass="$(get shepherd.last_pass_epoch)"
  ((${s_unh:-0} > 0)) && flag 1 "$s_unh shepherd due line(s) unhandled: the last pass neither moved nor skipped them"
  uh="${s_unh:-0}"; ((uh > 0)) && uh="$(paint "$C_YEL" "$uh")"
  shep="<b>Shepherd</b>  moves sessions through their plans"
  shep+=$'\n'"last pass: $(s due) due, $uh unhandled, $(s skipped) skipped; $([ -n "$s_pass" ] && echo "$(prom_dur $((now - s_pass))) ago" || echo "none on record")"
  shep+=$'\n'"last 24h: $(s nudges_24h) nudges, $(s escalations_24h) escalations, $(s passes_24h) passes"
fi

# The bar: three totals behind dim letters, and only Q takes the chip's level colour; a number the
# feed lacks reads -.
board="$(get dispatch.board_agent)" qn="$total"
((level > 0)) && qn="$(paint "${LEVEL_COLOUR[$level]}" "$qn")"
text="$(paint "$C_DIM" Q) $qn  $(paint "$C_DIM" B) ${board:--}  $(paint "$C_DIM" D) $(done_in 24)"

tip="Q in the queue, B on the board, D done in 24h"$'\n'"$qhead"
for w in "${why[@]}"; do tip+=$'\n'"$w"; done
[ -n "$queue" ] && tip+=$'\n'"$queue"
for sec in "$disp" "$shep"; do [ -n "$sec" ] && tip+=$'\n\n'"$sec"; done

emit "$text" "$tip" "${LEVEL_CLASS[$level]}"
