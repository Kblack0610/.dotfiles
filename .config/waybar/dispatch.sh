#!/usr/bin/env bash
# Waybar module: dispatch. The bar is the runnable queue items and how long since dispatch
# last started one, a dim +N when heals (reaps) ran in the last hour, and a colour:
#   red    queue-starved is tripped, the fleet-dispatch runner failed, or no pass in PASS_LATE_SECS
#   amber  the last pass left runnable work waiting (BLOCKED), an item is flapping, or more
#          could start than the limits let the last pass (could_start, `fleet-dispatch headroom`)
#   green  otherwise; a deep queue that is moving is not a fault
# The hover says runnable by priority, the last pass, starts by kind and heals.
#
# Everything is read from Prometheus (the agent feed: summary/dispatch from
# `fleet-dispatch stats`, the fleet_dispatch runner, the queue-starved watch), so the chip
# reads the same on the laptop thin client. Only live feed topics count
# (cc:agents_topic_live), so a host that stopped publishing cannot hold it red. Prometheus
# unreadable reads ? in amber and no dispatch numbers read -, never a quiet nothing.

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
title="<b>Dispatch</b>  runnable queue work, starts, heals"
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
pass_age=$((now - ${pass:-0})) start_age=-
[ -n "$start" ] && start_age="$(prom_dur $((now - start)))"

level=0 why=()
[ "$(get runner.blocked)" = 1 ] && level=1 why+=("the last pass left runnable work waiting (BLOCKED)")
((${flapping:-0} > 0)) && level=1 why+=("$flapping item(s) flapping between running and waiting")
could="$(get dispatch.could_start)"
((${could:-0} > 0)) && level=1 why+=("$could more could start now: a limit, not the machine, holds them (fleet-dispatch headroom)")
[ "$(get watch.tripped)" = 1 ] && level=2 why+=("queue-starved is tripped")
[ "$(get runner.failed)" = 1 ] && level=2 why+=("the fleet-dispatch runner failed")
((pass_age > PASS_LATE_SECS)) && level=2 why+=("no pass in $(prom_dur "$pass_age"); is fleet-dispatch.timer running?")

text="$ICON $runnable $start_age"
((level == 2)) && text="$ICON $runnable !"
((level > 0)) && text="$(paint "${LEVEL_COLOUR[$level]}" "$text")"
((${reaped:-0} > 0)) && text+=" $(paint "$C_DIM" "+$reaped")"

tip="$title"
for w in "${why[@]}"; do tip+=$'\n'"$(paint "${LEVEL_COLOUR[$level]}" "$w")"; done
tip+=$'\n'"runnable: $runnable ($urgent urgent or high), oldest $(prom_dur "$(get dispatch.oldest_runnable_s)"), oldest urgent $(prom_dur "$(get dispatch.oldest_urgent_s)")"
tip+=$'\n'"last pass: $(prom_dur "$pass_age") ago, last start: $start_age ago"
tip+=$'\n'"starts last hour: run $(get dispatch.starts_1h_run), hand $(get dispatch.starts_1h_hand), redispatch $(get dispatch.starts_1h_redispatch), resume $(get dispatch.starts_1h_resume)"
tip+=$'\n'"heals last hour: reaped ${reaped:-0}, flapping ${flapping:-0}"
tip+=$'\n'"headroom: ${could:--} more could start after the last pass"

emit "$text" "$tip" "${LEVEL_CLASS[$level]}"
