# shellcheck shell=bash disable=SC2034  # BAR, BAR_AT, BAR_WHY, the caps and BAR_JQ are for the scripts that source this
# summary_bar.sh - what the queue and agents chip hovers (queue.sh, ai_agents.sh) share for their text
# rows: one read of `hub bar --json`, which the fleet lease holder's agent-mqtt-publish sends retained
# as agents/<host>/summary/bar (hub-core bar.rs), the caps of the bar channel in channels.toml, and the
# jq that lays the rows out. Counts stay on Prometheus; this is only names and reasons. Source it after
# pango.sh and prom.sh.

# The publisher resends the document on each run (agent-mqtt-publish.timer, every minute), and a new
# one carries a new as_of, so five missed runs is a stopped publisher, not a slow one.
BAR_LATE_SECS=300
# How long mosquitto_sub listens once subscribed. Retained copies arrive with the subscribe, so 1s
# reads them all: 2.0s a read from the workstation, 1.0s of it the connect (2026-11-21), in a chip that
# runs every 15s.
BAR_WAIT_SECS=1

# bar_caps: BAR_LINES and BAR_WIDTH, the bar channel's max_lines and max_line, the same numbers
# comms-lint checks the hover against (comms-standard rule 12). The defaults are the shipped ones, for
# a clone whose channels.toml cannot be read.
bar_caps() {
  local f="${COMMS_CHANNELS:-$(dirname "${BASH_SOURCE[0]}")/../comms-lint/channels.toml}" k v
  BAR_LINES='' BAR_WIDTH=''
  while IFS='=' read -r k v; do
    case "${k// /}" in
      max_lines) v="${v%%#*}"; BAR_LINES="${v//[!0-9]/}" ;;
      max_line) v="${v%%#*}"; BAR_WIDTH="${v//[!0-9]/}" ;;
    esac
  done < <(sed -n '/^\[channel\.bar\]/,/^\[/{/^max_line/p}' "$f" 2>/dev/null)
  BAR_LINES="${BAR_LINES:-45}" BAR_WIDTH="${BAR_WIDTH:-120}"
}

# bar_read <now>: BAR, the document, and BAR_AT, its as_of, when one under BAR_LATE_SECS old arrived;
# otherwise BAR is empty and BAR_WHY says what is missing (dashboards.md rule 6). The broker is
# agent-mqtt-publish's (AGENT_MQTT_HOST, else ~/.config/agent-mqtt.env). Only the lease holder sends
# the topic, but a former holder that is switched off keeps its retained copy on the broker, so every
# retained copy is read and the newest as_of wins. mosquitto_sub exits 27 when -W ends, and 1 when it
# cannot connect.
bar_read() {
  local now="$1" conf="${AGENT_MQTT_CONF:-${XDG_CONFIG_HOME:-$HOME/.config}/agent-mqtt.env}" host port raw rc msg at
  BAR='' BAR_AT='' BAR_WHY=''
  host="${AGENT_MQTT_HOST:-$(sed -n 's/^AGENT_MQTT_HOST=//p' "$conf" 2>/dev/null)}"
  port="${AGENT_MQTT_PORT:-$(sed -n 's/^AGENT_MQTT_PORT=//p' "$conf" 2>/dev/null)}"
  port="${port:-1883}"
  if [ -z "$host" ]; then BAR_WHY="no broker: set AGENT_MQTT_HOST in $conf"; return; fi
  if ! command -v mosquitto_sub >/dev/null 2>&1; then BAR_WHY="mosquitto_sub is not installed"; return; fi
  raw="$(timeout $((BAR_WAIT_SECS + 3)) mosquitto_sub -h "$host" -p "$port" \
    -t 'agents/+/summary/bar' -W "$BAR_WAIT_SECS" 2>/dev/null)"
  rc=$?
  msg="$(jq -cnR '[inputs | fromjson? | objects | select(.as_of | type == "number")] | max_by(.as_of) // empty' <<< "$raw")"
  if ! at="$(jq -er '.as_of | floor' <<< "$msg" 2>/dev/null)"; then
    if [ -z "$raw" ] && ((rc != 0 && rc != 27)); then BAR_WHY="cannot reach the broker $host:$port"
    else BAR_WHY="no summary/bar on $host"; fi
    return
  fi
  if ((now - at > BAR_LATE_SECS)); then
    BAR_WHY="summary/bar is $(prom_dur $((now - at))) old: is agent-mqtt-publish running on the lease holder?"; return
  fi
  BAR="$msg" BAR_AT="$at"
}

# bar_detail <noun>: the hover's amber lines for what bar_read could not give, one a line: "No <noun>
# detail: <why>" with no document, else "<Noun> detail incomplete: <error>" for each source hub-core
# could not read, cut so the line fits BAR_WIDTH.
bar_detail() {
  local noun="$1" e
  if [ -z "$BAR" ]; then
    paint "$C_YEL" "No $noun detail: $(pango_esc "$BAR_WHY")"; echo; return
  fi
  while IFS= read -r e; do
    [ -n "$e" ] && { paint "$C_YEL" "${noun^} detail incomplete: $e"; echo; }
  done < <(jq -r --argjson w $((BAR_WIDTH - ${#noun} - 21)) "$BAR_JQ"'.errors[] | clean | fit($w) | esc' <<< "$BAR")
}

# The jq both hovers' row layouts start with:
#   clean    one line of plain ASCII (a title may hold a newline, a tab or a non-ASCII character)
#   fit(n)   cut to n characters, the last three "..."
#   lfit(n)  cut to n from the left, the first three "...", for a name whose end tells it apart
#   pad(n)   padded with spaces to n
#   esc      Pango-escaped, after any fit or pad, so a column's width is the text's
#   mins     minutes as 4m, 2h, 1h23m, 1d4h
#   what     a ready item as "kind(area): title", the kind and area left out when empty
BAR_JQ='
def clean: tostring | gsub("[\n\t]"; " ") | gsub("[^ -~]"; "?");
def fit($n): if length > $n then .[:([$n - 3, 0] | max)] + "..." else . end;
def lfit($n): if length > $n then "..." + .[(length - ([$n - 3, 0] | max)):] else . end;
def pad($n): . + (" " * ([$n - length, 0] | max));
def esc: gsub("&"; "&amp;") | gsub("<"; "&lt;") | gsub(">"; "&gt;");
def two: if . < 10 then "0\(.)" else "\(.)" end;
def mins: if . == null then "-"
  else floor | if . < 60 then "\(.)m"
  elif . < 1440 then "\(. / 60 | floor)h" + (if . % 60 > 0 then "\(. % 60 | two)m" else "" end)
  else "\(. / 1440 | floor)d" + (if . % 1440 >= 60 then "\(. % 1440 / 60 | floor)h" else "" end) end end;
def what: (if .kind == "" then "" elif .area == "" then "\(.kind): " else "\(.kind)(\(.area)): " end) + .title;
'
