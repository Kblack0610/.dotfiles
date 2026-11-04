#!/usr/bin/env bash
# Waybar module: the queue chip (custom/dispatch). The bar is the runnable queue items, how long
# the oldest has waited, a dim +N when heals (reaps) ran in the last hour, and a colour:
#   red    queue-starved is tripped, the fleet-dispatch runner failed, or no pass in PASS_LATE_SECS
#   amber  the last pass left runnable work waiting (BLOCKED), an item is flapping, or more
#          could start than the limits let the last pass (could_start, `fleet-dispatch headroom`)
#   neutral otherwise: a deep queue that is moving, or full slots on a full machine, is no fault
# The hover is the whole queue: every state, holds by kind, the oldest waits, flow by the hour
# and a drain trend, the room the last pass had and what held it, the last pass and start, heals.
#
# Everything is read from Prometheus (the agent feed: summary/dispatch from
# `fleet-dispatch stats`, which folds in `agent-queue stats` and the last pass's headroom; the
# fleet_dispatch runner; the queue-starved watch), so the chip reads the same on the laptop thin
# client. Only live feed topics count (cc:agents_topic_live), so a host that stopped publishing
# cannot hold it red. Prometheus unreadable reads ? in amber and no dispatch numbers read -,
# never a quiet nothing.

set -u
here="$(dirname "$(realpath "${BASH_SOURCE[0]}")")"
# shellcheck source=../../.local/lib/prom.sh
. "${PROM_LIB:-$here/../../.local/lib/prom.sh}" 2>/dev/null || . "$HOME/.local/lib/prom.sh"
# shellcheck source=pango.sh
. "$here/pango.sh"

# nf-fa-inbox, written as an escape so an editor cannot strip the glyph from this file.
ICON=$'\uf01c'
# fleet-dispatch runs every 15 minutes; three missed passes is a stopped timer, not a slow one.
PASS_LATE_SECS=2700
C_DIM="#7f7f7f"

now="${DISPATCH_NOW:-$(date +%s)}"
title="<b>Queue</b>"
q='{__name__=~"mqtt_.+", topic=~"agents_.+_(summary_dispatch|runner_fleet_dispatch|watch_queue_starved)"} and on (topic) cc:agents_topic_live'

if ! raw="$(prom_q "$q")"; then
  emit "$ICON $(paint "$C_YEL" '?')" "$title"$'\n'"cannot read $PROM_URL" warn
  exit 0
fi

# One object: kind.key -> value, kind being dispatch, runner or watch; max over hosts. Every
# value is a count, a 0/1 or an epoch, so it is floored: Prometheus may write 1 as 1.0.
v="$(jq -c '[.data.result[] | {k: ((.metric.topic | capture("_(?<k>summary_dispatch|runner|watch)(_|$)") | .k
      | sub("summary_"; "")) + "." + (.metric.__name__ | ltrimstr("mqtt_"))), v: (.value[1] | tonumber | floor)}]
    | group_by(.k) | map({key: .[0].k, value: (map(.v) | max)}) | from_entries' <<< "$raw")"
get() { jq -r --arg k "$1" '.[$k] // empty' <<< "$v"; }

if [ -z "$(get dispatch.runnable)" ]; then
  emit "$ICON $(paint "$C_YEL" -)" "$title"$'\n'"no dispatch numbers on the feed: agent-mqtt-publish publishes fleet-dispatch stats as summary/dispatch" warn
  exit 0
fi

runnable="$(get dispatch.runnable)" urgent="$(get dispatch.runnable_urgent)"
pass="$(get dispatch.last_pass_epoch)" start="$(get dispatch.last_run_start_epoch)"
reaped="$(get dispatch.reaped_1h)" flapping="$(get dispatch.flapping_items)"
oldest="$(get dispatch.oldest_runnable_s)"
pass_age=$((now - ${pass:-0})) start_age=-
[ -n "$start" ] && start_age="$(prom_dur $((now - start)))"
d() { local x; x="$(get "dispatch.$1")"; printf '%s' "${x:--}"; }

# short <seconds> -> 45m, 14h, 2d: the bar's width, where prom_dur's 14h35m is too long.
short() {
  [[ "${1:-}" =~ ^[0-9]+$ ]] || { printf -- '-'; return; }
  if (($1 < 3600)); then printf '%dm' $(($1 / 60)); elif (($1 < 86400)); then printf '%dh' $(($1 / 3600))
  else printf '%dd' $(($1 / 86400)); fi
}

level=0 why=()
[ "$(get runner.blocked)" = 1 ] && level=1 why+=("the last pass left runnable work waiting (BLOCKED)")
((${flapping:-0} > 0)) && level=1 why+=("$flapping item(s) flapping between running and waiting")
could="$(get dispatch.could_start)"
((${could:-0} > 0)) && level=1 why+=("$could more could start now: a limit, not the machine, holds them (fleet-dispatch headroom)")
[ "$(get watch.tripped)" = 1 ] && level=2 why+=("queue-starved is tripped")
[ "$(get runner.failed)" = 1 ] && level=2 why+=("the fleet-dispatch runner failed")
((pass_age > PASS_LATE_SECS)) && level=2 why+=("no pass in $(prom_dur "$pass_age"); is fleet-dispatch.timer running?")

text="$ICON $runnable $(short "$oldest")"
((level == 2)) && text="$ICON $runnable !"
((level > 0)) && text="$(paint "${LEVEL_COLOUR[$level]}" "$text")"
((${reaped:-0} > 0)) && text+=" $(paint "$C_DIM" "+$reaped")"

# drain: the last 6h of flow, added against done, as a trend. Holds release more work and new
# work keeps coming, so it is never an ETA.
drain=-
done6="$(get dispatch.done_6h)" added6="$(get dispatch.added_6h)" queued="$(get dispatch.queued)"
if [ -n "$done6" ] && [ -n "$added6" ]; then
  drain="last 6h +$added6 added, -$done6 done: $(awk -v a="$added6" -v d="$done6" -v q="${queued:-0}" 'BEGIN {
    n = (d - a) / 6
    if (n > 0) printf "shrinking, clears in about %dh at that rate", int(q / n + 0.5)
    else if (n < 0) printf "growing about %.0f/h", -n
    else printf "steady" }')"
fi

# held: the one gate that held the last pass, if any, by name.
held=''
for k in slots load idle account other; do
  [ "$(get "dispatch.room_held_$k")" = 1 ] || continue
  case $k in
    slots) held="every run slot is used (DISPATCH_MAX_LIVE)" ;;
    load) held="load is over the cap (DISPATCH_MAX_LOAD)" ;;
    idle) held="real idle is under the floor (DISPATCH_MIN_IDLE)" ;;
    account) held="no account has room under its weekly pace" ;;
    other) held="a gate (fleet-dispatch headroom says which)" ;;
  esac
done

tip="$title  $(d queued) queued, $(d running) running, $(d waiting) waiting on you"
for w in "${why[@]}"; do tip+=$'\n'"$(paint "${LEVEL_COLOUR[$level]}" "$w")"; done
tip+=$'\n'"queued: $runnable runnable ($urgent urgent or high), $(d held) held ($(d held_after) after a phase, $(d held_pr) on a PR, $(d held_time) by a time tag)"
tip+=$'\n'"oldest: runnable $(prom_dur "$oldest"), urgent $(prom_dur "$(get dispatch.oldest_urgent_s)")"
n0() { local x; x="$(get "dispatch.$1")"; printf '%s' "${x:-0}"; }
tip+=$'\n'"flow: last hour $(($(n0 starts_1h_run) + $(n0 starts_1h_hand) + $(n0 starts_1h_redispatch) + $(n0 starts_1h_resume))) started (run $(d starts_1h_run), hand $(d starts_1h_hand), redispatch $(d starts_1h_redispatch), resume $(d starts_1h_resume)), $(d done_1h) done; $(d done_24h) done in 24h"
tip+=$'\n'"drain: $drain"
if [ -n "$(get dispatch.room_max_live)" ]; then
  room="room: run slots $(d room_live_runs)/$(d room_max_live)"
  [ -n "$(get dispatch.room_live_hand)" ] && room+=", +$(d room_live_hand) started by hand"
  tip+=$'\n'"$room; load $(d room_load) of $(d room_load_cap); idle $(d room_idle)% (floor $(d room_min_idle)%)"
else
  tip+=$'\n'"room: no headroom from a pass in the last 45 minutes"
fi
[ -n "$held" ] && tip+=$'\n'"held by: $held"
tip+=$'\n'"last pass $(prom_dur "$pass_age") ago, last start $start_age ago"
tip+=$'\n'"heals last hour: reaped ${reaped:-0}, flapping ${flapping:-0}; could start now: ${could:--} more"

emit "$text" "$tip" "${LEVEL_CLASS[$level]}"
