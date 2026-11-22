# shellcheck shell=bash disable=SC2034  # the documents summary_read sets, the caps and BAR_JQ are for the scripts that source this
# summary_bar.sh - what the queue and agents chip hovers (queue.sh, ai_agents.sh) share: one read of the
# summary documents the fleet lease holder's agent-mqtt-publish sends retained as agents/<host>/summary/<topic>
# (`hub bar --json` as summary/bar, hub-core bar.rs; `hub cards --json --figures` as summary/cards,
# widget_doc.rs), the caps of the bar channel in channels.toml, and the jq that lays the rows out. Source it
# after pango.sh and prom.sh.

# The publisher resends each document on each run (agent-mqtt-publish.timer, every minute), and a new
# one carries a new as_of or updated_at, so five missed runs is a stopped publisher, not a slow one.
SUMMARY_LATE_SECS=300
# How long mosquitto_sub listens once subscribed. Retained copies arrive with the subscribe, so 1s
# reads them all: 2.0s a read from the workstation, 1.0s of it the connect (2026-11-21), in a chip that
# runs every 15s. Every topic a chip needs rides the one subscribe.
SUMMARY_WAIT_SECS=1

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

# summary_read <now> <topic>...: for each topic (bar, cards), <TOPIC>, the document, and <TOPIC>_AT, its
# time (as_of, else updated_at), when one under SUMMARY_LATE_SECS old arrived; otherwise <TOPIC> is empty
# and <TOPIC>_WHY says what is missing (dashboards.md rule 6). The broker is agent-mqtt-publish's
# (AGENT_MQTT_HOST, else ~/.config/agent-mqtt.env). Only the lease holder sends the topics, but a former
# holder that is switched off keeps its retained copies on the broker, so every retained copy is read and
# the newest wins. mosquitto_sub exits 27 when -W ends, and 1 when it cannot connect.
summary_read() {
  local now="$1" conf="${AGENT_MQTT_CONF:-${XDG_CONFIG_HOME:-$HOME/.config}/agent-mqtt.env}" host port raw='' rc=0 t v at doc why
  shift
  local subs=()
  local -A at_of doc_of
  for t; do
    v="${t^^}"; printf -v "$v" ''; printf -v "${v}_AT" ''; printf -v "${v}_WHY" ''
    subs+=(-t "agents/+/summary/$t")
  done
  host="${AGENT_MQTT_HOST:-$(sed -n 's/^AGENT_MQTT_HOST=//p' "$conf" 2>/dev/null)}"
  port="${AGENT_MQTT_PORT:-$(sed -n 's/^AGENT_MQTT_PORT=//p' "$conf" 2>/dev/null)}"
  port="${port:-1883}"
  why=''
  if [ -z "$host" ]; then why="no broker: set AGENT_MQTT_HOST in $conf"
  elif ! command -v mosquitto_sub >/dev/null 2>&1; then why="mosquitto_sub is not installed"
  else
    raw="$(timeout $((SUMMARY_WAIT_SECS + 3)) mosquitto_sub -h "$host" -p "$port" -v \
      "${subs[@]}" -W "$SUMMARY_WAIT_SECS" 2>/dev/null)"
    rc=$?
    [ -z "$raw" ] && ((rc != 0 && rc != 27)) && why="cannot reach the broker $host:$port"
  fi
  # One jq over every message: each topic's newest document, "<topic> TAB <time> TAB <document>".
  [ -n "$why" ] || while IFS=$'\t' read -r t at doc; do
    at_of[$t]="$at" doc_of[$t]="$doc"
  done < <(jq -rnR '[inputs | capture("^agents/[^/ ]+/summary/(?<t>[^/ ]+) (?<m>.*)$")?
      | {t, doc: (.m | fromjson? | objects)} | select(.doc)
      | .at = (.doc.as_of // (.doc.updated_at | strings | fromdateiso8601?)) | select(.at | type == "number")]
    | reduce .[] as $x ({}; if (.[$x.t].at // -1) <= $x.at then .[$x.t] = $x else . end)
    | .[] | "\(.t)\t\(.at | floor)\t\(.doc | tojson)"' <<< "$raw")
  for t; do
    v="${t^^}"
    if [ -n "$why" ]; then printf -v "${v}_WHY" '%s' "$why"; continue; fi
    at="${at_of[$t]:-}"
    if [ -z "$at" ]; then
      printf -v "${v}_WHY" '%s' "no summary/$t on $host"; continue
    fi
    if ((now - at > SUMMARY_LATE_SECS)); then
      printf -v "${v}_WHY" '%s' "summary/$t is $(prom_dur $((now - at))) old: is agent-mqtt-publish running on the lease holder?"
      continue
    fi
    printf -v "$v" '%s' "${doc_of[$t]}"; printf -v "${v}_AT" '%s' "$at"
  done
}

# bar_detail <noun>: the hover's amber lines for what summary_read could not give for summary/bar, one a line: "No <noun>
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
