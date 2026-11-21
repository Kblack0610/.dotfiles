#!/usr/bin/env bash
# Waybar module: the Needs you chip (custom/needs), first in the status group. It lays out Home's
# Needs you card (`hub_core::cards::needs`, over `Home::waiting` and `Home::split`), the one count
# of what only the human can do, so the bar, the hub, agent-web and the phone cannot disagree.
# The card rides `hub phone --json`, which agent-mqtt-publish sends retained as
# agents/<host>/summary/overview from every host with `hub`; a host off the fleet lease counts from a
# state file that stopped, so the newest `as_of` (the fleet state's generated_epoch) wins.
# Bar: "!:N" coloured by the card's level (green 0, amber above). The hover: the count and its kind
# split, the oldest rows, and when and where it was counted. No card, or one older than STALE_SECS,
# reads "!:?" in amber, never a 0 (dashboards.md rule 6). Click opens the hub on Home.

set -u
here="$(dirname "$(realpath "${BASH_SOURCE[0]}")")"
# shellcheck source=pango.sh
. "$here/pango.sh"

# The broker agent-mqtt-publish sends to (its env file names it).
# shellcheck disable=SC1090
[ -r "${AGENT_MQTT_ENV:-$HOME/.config/agent-mqtt.env}" ] && . "${AGENT_MQTT_ENV:-$HOME/.config/agent-mqtt.env}"
MQTT_HOST="${AGENT_MQTT_HOST:-}" MQTT_PORT="${AGENT_MQTT_PORT:-1883}"
# The retained messages arrive at once; this is how long mosquitto_sub waits for a straggler.
MQTT_WAIT_SECS=1
# fleet-state.timer writes the state every minute and the publisher's full run is every 5 minutes,
# so a count 15 minutes old is a stopped publisher, not a slow one.
STALE_SECS=900
NOW="${NEEDS_NOW:-$(date +%s)}"

unread() { emit "$(paint "$C_YEL" '!:?')" "<b>Needs you</b>  not read: $1" warn; exit 0; }
[ -n "$MQTT_HOST" ] || unread "no broker: AGENT_MQTT_HOST is unset (~/.config/agent-mqtt.env)"

msgs="$(timeout $((MQTT_WAIT_SECS + 3)) mosquitto_sub -h "$MQTT_HOST" -p "$MQTT_PORT" \
  -t 'agents/+/summary/overview' --retained-only -W "$MQTT_WAIT_SECS" \
  -F '{"topic":"%t","doc":%p}' 2>/dev/null)"
best="$(jq -cs 'map(select(.doc.needs != null)) | max_by(.doc.as_of // 0) // empty' <<< "$msgs" 2>/dev/null)"

[ -n "$best" ] || unread "no host sent a Needs you card on agents/+/summary/overview (agent-mqtt-publish sends hub phone --json)"

host="$(jq -r '.topic | split("/")[1]' <<< "$best")"
as_of="$(jq -r '.doc.as_of // 0' <<< "$best")"
age=$((NOW - as_of))
((age > STALE_SECS)) && unread "the newest count is $((age / 60))m old (from $host): agent-mqtt-publish or fleet-state.timer stopped"

IFS=$'\t' read -r count level split error < <(jq -r '.doc.needs
  | [.big, .level, ([.parts[] | "\(.label) \(.value)"] | join(", ")), (.error // "")] | @tsv' <<< "$best")
case "$level" in ok) lv=0 ;; red) lv=2 ;; *) lv=1 ;; esac

tip="<b>Needs you</b>  $count waiting on you"
[ -n "$split" ] && tip+=$'\n'"$(pango_esc "$split")"
[ -n "$error" ] && tip+=$'\n'"$(paint "$C_YEL" "$(pango_esc "not all read: $error")")"
rows="$(jq -r '.doc.needs.first[] | "\(.text)\t\(.sub)"' <<< "$best")"
if [ -n "$rows" ]; then
  tip+=$'\n\n'"<b>Oldest</b>"
  while IFS=$'\t' read -r text sub; do
    tip+=$'\n'"$(pango_esc "$text")$([ -n "$sub" ] && printf '  %s' "$(paint "$C_DIM" "$(pango_esc "$sub")")")"
  done <<< "$rows"
fi
tip+=$'\n\n'"$(paint "$C_DIM" "counted $(date -d "@$as_of" +%H:%M) on $(pango_esc "$host"); click for the hub")"

emit "$(paint "${LEVEL_COLOUR[$lv]}" "!:$count")" "$tip" "${LEVEL_CLASS[$lv]}"
