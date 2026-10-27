#!/usr/bin/env bash
# command-center.sh - the hub's glance board (window hub:infra), the terminal twin of the
# Grafana dashboard kb-command-center.
#
# It judges nothing: every colour is a cc:* recording rule from home-config
# apps/monitoring/prometheus-rules-command-center.yaml, so it cannot disagree with Grafana.
# A failed query blanks the board rather than leaving the last good (maybe green) values up.
#
# Usage: command-center.sh          live board (q quits, any other key refreshes)
#        command-center.sh --once   one frame, exit 1 if Prometheus could not be read
# Actions (start/stop a runner, answer an ask) stay in fleet.sh, Prefix+C-g.

set -uo pipefail

# Endpoints stay out of this public repo. Set both in ~/.config/command-center/env (stowed
# from the private overlay):
#   CC_PROM_URL=https://prometheus.your.lan
#   CC_GRAFANA_URL=https://grafana.your.lan/d/kb-command-center
# shellcheck source=/dev/null
[ -r "$HOME/.config/command-center/env" ] && . "$HOME/.config/command-center/env"
PROM_URL="${CC_PROM_URL:-https://prometheus.example.com}"
GRAFANA_URL="${CC_GRAFANA_URL:-https://grafana.example.com/d/kb-command-center}"
# Prometheus offers no push to a terminal, so the board re-reads on a fixed cadence. The
# recording rules evaluate every 1m; reading faster would only redraw the same numbers.
REFRESH_SECS=60

if [ -n "${NO_COLOR:-}" ]; then
  C_OK='' C_WARN='' C_RED='' C_NONE='' C_HEAD='' C_DIM='' C_OFF=''
else
  C_OK=$'\033[1;30;42m' C_WARN=$'\033[1;30;43m' C_RED=$'\033[1;37;41m' C_NONE=$'\033[1;37;45m'
  C_HEAD=$'\033[1;37m' C_DIM=$'\033[90m' C_OFF=$'\033[0m'
fi

declare -A V # "cc:name" or "cc:domain_status/<domain>" -> value
RED_ITEMS=()
FETCH_ERR=''

# _q <promql> -> the raw /api/v1/query JSON, or rc 1.
_q() {
  curl -sf -m 10 -G "$PROM_URL/api/v1/query" --data-urlencode "query=$1" 2>/dev/null
}

fetch() {
  V=() RED_ITEMS=() FETCH_ERR=''
  local cc red
  cc="$(_q '{__name__=~"cc:.+"}')" && [ "$(jq -r .status <<< "$cc" 2>/dev/null)" = success ] || {
    FETCH_ERR="cannot read $PROM_URL"; return 1
  }
  local key val
  while IFS=$'\t' read -r key val; do
    [ -n "$key" ] && V["$key"]="$val"
  done < <(jq -r '.data.result[]
      | [(.metric.__name__ + (if .metric.domain and .metric.__name__ == "cc:domain_status"
                              then "/" + .metric.domain else "" end)), .value[1]] | @tsv' <<< "$cc")
  [ -n "${V[cc:overall_status]:-}" ] || { FETCH_ERR="no cc:* series (recording rules not loaded?)"; return 1; }
  # The same three sources as the dashboard's "What is red" table.
  red="$(_q 'label_replace(mqtt_tripped{topic=~"agents_.+_watch_.+"} == 1, "item", "watch $1", "topic", "agents_.+_watch_(.+)")
    or label_replace(mqtt_failed{topic=~"agents_.+_runner_.+"} == 1, "item", "runner $1", "topic", "agents_.+_runner_(.+)")
    or label_replace(kube_node_status_condition{condition="Ready",status="true"} == 0, "item", "node $1 NotReady", "node", "(.+)")')" || true
  [ -n "$red" ] && mapfile -t RED_ITEMS < <(jq -r '.data.result[].metric.item' <<< "$red" 2>/dev/null | sort)
  return 0
}

# _num <key> -> the value rounded to an integer, or "?" when the series is absent.
_num() {
  local v="${V[$1]:-}"
  [ -n "$v" ] || { printf '?'; return; }
  printf '%.0f' "$v" 2>/dev/null || printf '?'
}
_usd() {
  local v="${V[$1]:-}"
  [ -n "$v" ] || { printf '?'; return; }
  printf '$%.2f' "$v" 2>/dev/null || printf '?'
}

# _badge <status> -> coloured fixed-width status word
_badge() {
  case "${1:-}" in
    0) printf '%s   OK   %s' "$C_OK" "$C_OFF" ;;
    1) printf '%s  WARN  %s' "$C_WARN" "$C_OFF" ;;
    2) printf '%s  RED   %s' "$C_RED" "$C_OFF" ;;
    *) printf '%sNO DATA %s' "$C_NONE" "$C_OFF" ;;
  esac
}
_dom() { _num "cc:domain_status/$1"; }
_worst() { # worst of several domains, for tiles that cover more than one
  local m='' d s
  for d in "$@"; do
    s="${V[cc:domain_status/$d]:-}"; [ -n "$s" ] || continue
    s="${s%%.*}"; { [ -z "$m" ] || [ "$s" -gt "$m" ]; } && m="$s"
  done
  printf '%s' "${m:-?}"
}

TILE_W=26
# tile <title> <status> <line1> [line2] -> four lines appended to TILES as one record
TILES=()
tile() {
  TILES+=("$(printf '%s\x1f%s\x1f%s\x1f%s' "$1" "$2" "$3" "${4:-}")")
}

build_tiles() {
  TILES=()
  local reds=0 warns=0 k s
  for k in "${!V[@]}"; do
    [[ "$k" == cc:domain_status/* ]] || continue
    s="${V[$k]%%.*}"
    [ "$s" = 2 ] && reds=$((reds + 1))
    [ "$s" = 1 ] && warns=$((warns + 1))
  done
  tile "OVERALL" "$(_num cc:overall_status)" "$reds red, $warns warn"
  tile "NEEDS YOU" "$( [ "$(_num cc:asks_open)" = 0 ] && [ "$(_num cc:sessions_attention)" = 0 ] && echo 0 || echo 1)" \
    "$(_num cc:asks_open) agent asks open" "$(_num cc:sessions_attention) sessions waiting"
  tile "CLUSTER home-k3s" "$(_dom k3s)" "nodes $(_num cc:k3s_nodes_ready)/$(_num cc:k3s_nodes_total) ready"
  tile "MACHINES" "$(_dom machines)" "$(_num cc:machines_up)/$(_num cc:machines_total) heartbeating"
  tile "PROD pmp" "$(_dom prod)" "pmp + mercury watches" "DO cluster not scraped"
  tile "LLM" "$(_dom llm)" "gateway + mac studio"
  tile "CI RUNNERS" "$(_dom ci)" "$(_num cc:ci_online)/$(_num cc:ci_expected) online"
  tile "AGENTS" "$(_dom agents)" "$(_num cc:runners_failed) failed, $(_num cc:runners_running) running" \
    "of $(_num cc:runners_total) runners"
  tile "SPEND" "$(_dom spend)" "lazer $(_usd cc:lazer_spend_usd) of $(_usd cc:lazer_budget_usd)" \
    "claude 24h $(_usd cc:claude_code_cost_24h_usd)"
  tile "AGENT PLATFORM" "$(_worst platform other)" "watches $(_num cc:watches_tripped)/$(_num cc:watches_total) tripped" \
    "$(_num cc:watches_stale) stale"
}

# _pad <text> <width> -> text clipped/padded to exactly width visible columns (plain text)
_pad() {
  local s="$1" w="$2"
  (( ${#s} > w )) && s="${s:0:w}"
  printf '%-*s' "$w" "$s"
}

render() {
  local cols="${COLUMNS:-$(tput cols 2>/dev/null || echo 80)}"
  local lines="${LINES:-$(tput lines 2>/dev/null || echo 24)}"
  local per=$(( cols / (TILE_W + 1) )); (( per < 1 )) && per=1
  local inner=$(( TILE_W - 4 ))
  printf '%sCOMMAND CENTER%s  %s%s%s\n\n' "$C_HEAD" "$C_OFF" "$C_DIM" "$(date '+%H:%M:%S')" "$C_OFF"
  if [ -n "$FETCH_ERR" ]; then
    printf '%s QUERY FAILED %s %s\n\n' "$C_WARN" "$C_OFF" "$FETCH_ERR"
    printf '%sNothing is shown rather than old numbers. Retrying every %ss; r retries now.%s\n' \
      "$C_DIM" "$REFRESH_SECS" "$C_OFF"
    return 0
  fi
  local i j n=${#TILES[@]} t title st l1 l2 line
  # Tiles are 6 lines tall; header and footer take 5 more. When the grid would not fit,
  # draw one line per domain instead of letting the top rows scroll off screen.
  if (( ( (n + per - 1) / per ) * 6 + 5 > lines )); then
    for (( j = 0; j < n; j++ )); do
      IFS=$'\x1f' read -r title st l1 l2 <<< "${TILES[$j]}"
      printf '%s %s%s%s %s %s%s%s\n' "$(_badge "$st")" "$C_HEAD" "$(_pad "$title" 17)" "$C_OFF" \
        "$l1" "$C_DIM" "${l2:+ - $l2}" "$C_OFF"
    done
    n=0
  fi
  for (( i = 0; i < n; i += per )); do
    for line in top title badge l1 l2 bottom; do
      for (( j = i; j < i + per && j < n; j++ )); do
        IFS=$'\x1f' read -r title st l1 l2 <<< "${TILES[$j]}"
        case "$line" in
          top)    printf '+%s+ ' "$(printf '%*s' $((TILE_W - 2)) '' | tr ' ' '-')" ;;
          bottom) printf '+%s+ ' "$(printf '%*s' $((TILE_W - 2)) '' | tr ' ' '-')" ;;
          title)  printf '| %s%s%s | ' "$C_HEAD" "$(_pad "$title" "$inner")" "$C_OFF" ;;
          badge)  printf '| %s%s | ' "$(_badge "$st")" "$(_pad '' $((inner - 8)))" ;;
          l1)     printf '| %s | ' "$(_pad "$l1" "$inner")" ;;
          l2)     printf '| %s%s%s | ' "$C_DIM" "$(_pad "$l2" "$inner")" "$C_OFF" ;;
        esac
      done
      printf '\n'
    done
  done
  printf '\n'
  if [ ${#RED_ITEMS[@]} -gt 0 ]; then
    printf '%sred now:%s %s\n' "$C_HEAD" "$C_OFF" "$(printf '%s, ' "${RED_ITEMS[@]}" | sed 's/, $//')"
  else
    printf '%sred now:%s nothing\n' "$C_HEAD" "$C_OFF"
  fi
  printf '%s%s   fleet actions: Prefix+C-g   r refresh   q quit%s\n' "$C_DIM" "$GRAFANA_URL" "$C_OFF"
}

frame() { fetch; build_tiles; render; }

if [ "${1:-}" = --once ]; then
  frame
  [ -z "$FETCH_ERR" ]
  exit
fi

[[ "${BASH_SOURCE[0]}" != "$0" ]] && return 0 # sourced by the test suite

trap 'tput cnorm 2>/dev/null; exit 0' INT TERM
# A resize must redraw at the new width. bash only interrupts `read` for a signal that
# has a trap, so the empty trap is what makes WINCH end the wait below.
trap ':' WINCH
tput civis 2>/dev/null
while :; do
  # Measured HERE, where stdout is the terminal. Inside $(frame) tput sees a pipe and
  # answers 80, which drew two tiles a row in a 144-column window.
  COLUMNS="$(tput cols 2>/dev/null || echo 80)"
  LINES="$(tput lines 2>/dev/null || echo 24)"
  export COLUMNS LINES
  out="$(frame)"
  printf '\033[H\033[2J%s' "$out"
  # One wait per frame: a keypress or a resize ends it early (q quits).
  if read -rsn1 -t "$REFRESH_SECS" key; then
    [ "$key" = q ] && { tput cnorm 2>/dev/null; exit 0; }
  fi
done
