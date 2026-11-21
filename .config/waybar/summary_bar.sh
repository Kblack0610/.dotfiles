# shellcheck shell=bash disable=SC2034  # BAR, BAR_WHY, the caps and BAR_JQ are for the scripts that source this
# summary_bar.sh - what the queue and agents chip hovers (queue.sh, ai_agents.sh) share for their text
# rows: one read of `hub bar --json`, which the fleet lease holder's agent-mqtt-publish sends retained
# as agents/<host>/summary/bar (hub-core bar.rs), the caps of the bar channel in channels.toml, and the
# jq that lays the rows out. Counts stay on Prometheus; this is only names and reasons. Source it after
# pango.sh and prom.sh.

# The publisher resends the document on each run (agent-mqtt-publish.timer, every minute), and a new
# one carries a new as_of, so five missed runs is a stopped publisher, not a slow one.
BAR_LATE_SECS=300
# How long one read of the retained topic may take: 1.0s from the workstation and razer-laptop
# (2026-11-21), in a chip that runs every 15s.
BAR_WAIT_SECS=3

# bar_caps: BAR_LINES and BAR_WIDTH, the bar channel's max_lines and max_line, the same numbers
# comms-lint checks the hover against (comms-standard rule 12). The defaults are the shipped ones, for
# a clone whose channels.toml cannot be read.
bar_caps() {
  local f="${COMMS_CHANNELS:-$(dirname "${BASH_SOURCE[0]}")/../comms-lint/channels.toml}" k v
  BAR_LINES=45 BAR_WIDTH=120
  while IFS='=' read -r k v; do
    case "${k// /}" in
      max_lines) BAR_LINES="${v//[!0-9]/}" ;;
      max_line) BAR_WIDTH="${v//[!0-9]/}" ;;
    esac
  done < <(sed -n '/^\[channel\.bar\]/,/^\[/{/^max_line/p}' "$f" 2>/dev/null)
}

# bar_read <now>: BAR, the document, when one under BAR_LATE_SECS old arrived; otherwise BAR is empty
# and BAR_WHY says what is missing, for the hover's one amber line (dashboards.md rule 6). The broker is
# agent-mqtt-publish's (AGENT_MQTT_HOST, else ~/.config/agent-mqtt.env). Only the lease holder sends
# the topic; a former holder's retained copy would carry an old as_of and read as old here.
bar_read() {
  local now="$1" conf="${AGENT_MQTT_CONF:-${XDG_CONFIG_HOME:-$HOME/.config}/agent-mqtt.env}" host port msg at
  BAR='' BAR_WHY=''
  host="${AGENT_MQTT_HOST:-$(sed -n 's/^AGENT_MQTT_HOST=//p' "$conf" 2>/dev/null)}"
  port="${AGENT_MQTT_PORT:-$(sed -n 's/^AGENT_MQTT_PORT=//p' "$conf" 2>/dev/null)}"
  if [ -z "$host" ]; then BAR_WHY="no broker: set AGENT_MQTT_HOST in $conf"; return; fi
  if ! command -v mosquitto_sub >/dev/null 2>&1; then BAR_WHY="mosquitto_sub is not installed"; return; fi
  msg="$(timeout $((BAR_WAIT_SECS + 1)) mosquitto_sub -h "$host" -p "${port:-1883}" \
    -t 'agents/+/summary/bar' -C 1 -W "$BAR_WAIT_SECS" 2>/dev/null)"
  if ! at="$(jq -er '.as_of | numbers | floor' <<< "$msg" 2>/dev/null)"; then
    BAR_WHY="no summary/bar on $host"; return
  fi
  if ((now - at > BAR_LATE_SECS)); then
    BAR_WHY="summary/bar is $(prom_dur $((now - at))) old: is agent-mqtt-publish running on the lease holder?"; return
  fi
  BAR="$msg"
}

# The jq both hovers' row layouts start with:
#   clean    one line of plain ASCII (a title may hold a newline, a tab or a non-ASCII character)
#   fit(n)   cut to n characters, the last three "..."
#   lfit(n)  cut to n from the left, the first three "...", for a name whose end tells it apart
#   pad(n)   padded with spaces to n
#   esc      Pango-escaped, after any fit or pad, so a column's width is the text's
#   mins     minutes as 4m, 2h, 1h23m, 1d4h
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
'
