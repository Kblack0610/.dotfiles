#!/usr/bin/env bash
# command-center.sh - the hub's infra board (window hub:infra): every machine that runs CI
# with its load and the job each runner is on (repo, PR, branch), what is queued, what is
# down, and one strip of domain statuses. Terminal twin of Grafana kb-ci-runners and
# kb-command-center.
#
# It judges nothing: statuses are cc:* rules, rows are runner-exporter series (home-config
# apps/monitoring/prometheus-rules-command-center.yaml, apps/github-runner-exporter), so it
# cannot disagree with Grafana. A failed query blanks the board rather than leaving the
# last good (maybe green) values up.
#
# Usage: command-center.sh          live board (q quits, any other key refreshes)
#        command-center.sh --once   one frame, exit 1 if Prometheus could not be read
# Actions (start/stop a runner, answer an ask) stay in fleet.sh, Prefix+C-g.

set -uo pipefail

# shellcheck source=/dev/null
. "${TABLE_FIT_LIB:-/nonexistent}" 2>/dev/null \
  || . "$HOME/.local/lib/table-fit.sh" 2>/dev/null \
  || . "$(dirname "$(realpath "${BASH_SOURCE[0]}")")/../../lib/table-fit.sh" 2>/dev/null \
  || { echo "command-center: table-fit.sh not found" >&2; exit 1; }

# Endpoints stay out of this public repo. Set them in ~/.config/command-center/env (stowed
# from the private overlay):
#   CC_PROM_URL=https://prometheus.your.lan
#   CC_GRAFANA_URL=https://grafana.your.lan/d/kb-ci-runners
#   CC_HOSTS="workstation mac-studio"   machines shown even with no runner, first
# shellcheck source=/dev/null
[ -r "$HOME/.config/command-center/env" ] && . "$HOME/.config/command-center/env"
PROM_URL="${CC_PROM_URL:-https://prometheus.example.com}"
GRAFANA_URL="${CC_GRAFANA_URL:-https://grafana.example.com/d/kb-ci-runners}"
EXTRA_HOSTS="${CC_HOSTS:-workstation mac-studio}"
# Prometheus offers no push to a terminal, so the board re-reads on a fixed cadence. The
# exporter is scraped and the rules evaluate every 1m; faster only redraws the same numbers.
REFRESH_SECS=60
# Scrape-target labels, stripped so two exporter pods during a rollout read as one row.
W='max without (instance, pod, job, namespace, service, endpoint, container)'

if [ -n "${NO_COLOR:-}" ]; then
  C_OK='' C_WARN='' C_RED='' C_NONE='' C_HEAD='' C_DIM='' C_OFF=''
else
  C_OK=$'\033[1;30;42m' C_WARN=$'\033[1;30;43m' C_RED=$'\033[1;37;41m' C_NONE=$'\033[1;37;45m'
  C_HEAD=$'\033[1;37m' C_DIM=$'\033[90m' C_OFF=$'\033[0m'
fi

declare -A V # "cc:name", "cc:domain_status/<domain>" or "cc:host_x/<host>" -> value
RED_ITEMS=() RUNNERS=() WAITING=() RECENT=() LOCAL=()
API_OK='' FETCH_ERR=''

# _q <promql> -> the raw /api/v1/query JSON, or rc 1 when it did not answer success.
_q() {
  local out
  out="$(curl -sf -m 10 -G "$PROM_URL/api/v1/query" --data-urlencode "query=$1" 2>/dev/null)" || return 1
  [ "$(jq -r .status <<< "$out" 2>/dev/null)" = success ] || return 1
  printf '%s' "$out"
}

# _rows <json> <label...> -> one TSV line per series: the labels in order, then the value.
# Empty labels read "-", because bash `read` folds adjacent TABs and would shift columns.
_rows() {
  local json="$1"; shift
  jq -r --args '[$ARGS.positional[]] as $k | .data.result[]
    | . as $r | [($k[] | ($r.metric[.] // "") | gsub("\t"; " ") | if . == "" then "-" else . end), $r.value[1]]
    | @tsv' "$@" <<< "$json"
}

fetch() {
  V=() RED_ITEMS=() RUNNERS=() WAITING=() RECENT=() LOCAL=() API_OK='' FETCH_ERR=''
  local cc red runners waiting recent api gates key val
  cc="$(_q '{__name__=~"cc:.+",__name__!~"cc:host_instance|cc:host_local_gate"}')" \
    && runners="$(_q "$W (github_runner_state)")" \
    && waiting="$(_q "$W (github_actions_job_waiting)")" \
    && recent="$(_q "topk(5, $W (github_actions_run_recent))")" \
    && api="$(_q 'min(github_runner_exporter_api_ok)')" \
    && gates="$(_q 'cc:host_local_gate')" \
    || { FETCH_ERR="cannot read $PROM_URL"; return 1; }
  while IFS=$'\t' read -r key val; do
    [ -n "$key" ] && V["$key"]="$val"
  done < <(jq -r '.data.result[]
      | [(.metric.__name__ + (if .metric.domain and .metric.__name__ == "cc:domain_status" then "/" + .metric.domain
                              elif .metric.host then "/" + .metric.host else "" end)), .value[1]] | @tsv' <<< "$cc")
  [ -n "${V[cc:overall_status]:-}" ] || { FETCH_ERR="no cc:* series (recording rules not loaded?)"; return 1; }
  mapfile -t RUNNERS < <(_rows "$runners" host state pool name repo pr branch job_name workflow title | sort)
  mapfile -t WAITING < <(_rows "$waiting" labels repo pr branch)
  mapfile -t RECENT < <(_rows "$recent" conclusion repo workflow branch | sort -t$'\t' -k5,5nr)
  mapfile -t LOCAL < <(_rows "$gates" host worktree branch platform | sort)
  API_OK="$(jq -r '.data.result[0].value[1] // ""' <<< "$api")"
  # The same three sources as the dashboard's "What is red" table.
  red="$(_q 'label_replace(mqtt_tripped{topic=~"agents_.+_watch_.+"} == 1, "item", "watch $1", "topic", "agents_.+_watch_(.+)")
    or label_replace(mqtt_failed{topic=~"agents_.+_runner_.+"} == 1, "item", "runner $1", "topic", "agents_.+_runner_(.+)")
    or label_replace(kube_node_status_condition{condition="Ready",status="true"} == 0, "item", "node $1 NotReady", "node", "(.+)")')" || true
  [ -n "$red" ] && mapfile -t RED_ITEMS < <(jq -r '.data.result[].metric.item' <<< "$red" 2>/dev/null | sort)
  return 0
}

# --- formatting -------------------------------------------------------------------------
_num() { local v="${V[$1]:-}"; [ -n "$v" ] && printf '%.0f' "$v" 2>/dev/null || printf '?'; }
_usd() { local v="${V[$1]:-}"; [ -n "$v" ] && printf '$%.0f' "$v" 2>/dev/null || printf '?'; }
_pct() { local v="${V[$1]:-}"; [ -n "$v" ] && awk -v v="$v" 'BEGIN { printf "%.0f%%", v * 100 }' || printf -- '-'; }
# _dur <seconds> -> 45s, 36m, 2h28m, 3d4h
_dur() {
  local s="${1%%.*}"
  [[ "$s" =~ ^[0-9]+$ ]] || { printf -- '-'; return; }
  if (( s < 60 )); then printf '%ds' "$s"
  elif (( s < 3600 )); then printf '%dm' $((s / 60))
  elif (( s < 86400 )); then printf '%dh%02dm' $((s / 3600)) $((s % 3600 / 60))
  else printf '%dd%dh' $((s / 86400)) $((s % 86400 / 3600)); fi
}
# _tag <status> <label> -> the label on its status colour; NO DATA is never shown as OK.
_tag() {
  local c
  case "${1%%.*}" in 0) c="$C_OK" ;; 1) c="$C_WARN" ;; 2) c="$C_RED" ;; *) c="$C_NONE" ;; esac
  if [ -n "$c" ]; then printf '%s %s %s' "$c" "$2" "$C_OFF"
  else case "${1%%.*}" in 0) printf '%s OK' "$2" ;; 1) printf '%s WARN' "$2" ;; 2) printf '%s RED' "$2" ;; *) printf '%s NODATA' "$2" ;; esac; fi
}
# _clip_ansi <width>: clip coloured lines to <width> VISIBLE columns with ~, keeping escape
# codes whole and closing the colour, so a status strip never wraps or bleeds.
_clip_ansi() {
  awk -v W="${1:-0}" -v OFF="$C_OFF" '{
    v = $0; gsub(/\033\[[0-9;]*m/, "", v)
    if (W <= 0 || length(v) <= W) { print; next }
    out = ""; n = 0; s = $0
    while (s != "" && n < W - 1) {
      if (match(s, /^\033\[[0-9;]*m/)) { out = out substr(s, 1, RLENGTH); s = substr(s, RLENGTH + 1); continue }
      out = out substr(s, 1, 1); s = substr(s, 2); n++
    }
    print out "~" OFF
  }'
}
# _pool_of <runs-on labels> -> the pool a queued job is waiting for, as the exporter names pools.
_pool_of() {
  case ",$1," in
    *,unity,*) echo unity ;; *,pmp-heavy,*) echo pmp-heavy ;; *,pmp-light,*) echo pmp-light ;;
    *,macOS,*) echo macos ;; *,[Ww]indows,*) echo windows ;; ,-,) echo '-' ;; *) echo "$1" ;;
  esac
}

# --- sections ---------------------------------------------------------------------------
header() {
  local d s strip=''
  printf '%sCOMMAND CENTER%s  %s%s%s  %s  needs you: %s asks, %s sessions waiting\n' "$C_HEAD" "$C_OFF" \
    "$C_DIM" "$(date '+%H:%M:%S')" "$C_OFF" "$(_tag "${V[cc:overall_status]:-}" OVERALL)" \
    "$(_num cc:asks_open)" "$(_num cc:sessions_attention)"
  for d in k3s machines ci prod llm agents spend platform other; do
    s="${V[cc:domain_status/$d]:-}"
    [ -n "$s" ] || [ "$d" = k3s ] || [ "$d" = ci ] || continue
    strip+="$(_tag "$s" "$d") "
  done
  printf '%s\n' "$strip"
  local here=''
  [ -n "${V[cc:agent_sessions_running]:-}" ] && here="  agent sessions $(_num cc:agent_sessions_running)"
  printf '%snodes %s/%s  heartbeats %s/%s  ci slots %s/%s  agent runners %s failed  watches %s/%s tripped  lazer %s/%s  claude 24h %s%s%s\n' \
    "$C_DIM" "$(_num cc:k3s_nodes_ready)" "$(_num cc:k3s_nodes_total)" "$(_num cc:machines_up)" "$(_num cc:machines_total)" \
    "$(_num cc:ci_online)" "$(_num cc:ci_expected)" "$(_num cc:runners_failed)" "$(_num cc:watches_tripped)" \
    "$(_num cc:watches_total)" "$(_usd cc:lazer_spend_usd)" "$(_usd cc:lazer_budget_usd)" "$(_usd cc:claude_code_cost_24h_usd)" "$here" "$C_OFF"
}

# machines <width>: one block per machine. Its first row carries the load; each busy runner
# is a row of its own (repo, PR, job, how long, branch and the run's title when it says more
# than the workflow name, which is all a dispatch or push run's title is).
machines() {
  local w="$1" h line hosts=() host state pool name repo pr branch job wf title val for
  declare -A seen busy slots jobs
  for h in $EXTRA_HOSTS; do [ -n "${seen[$h]:-}" ] || { seen[$h]=1; hosts+=("$h"); }; done
  for line in "${RUNNERS[@]}"; do
    IFS=$'\t' read -r host state pool name repo pr branch job wf title val <<< "$line"
    [ -n "${seen[$host]:-}" ] || { seen[$host]=1; hosts+=("$host"); }
    slots[$host]=$(( ${slots[$host]:-0} + 1 ))
    [ "$state" = running ] || continue
    busy[$host]=$(( ${busy[$host]:-0} + 1 ))
    [ "$pr" = - ] || pr="#$pr"
    [ "$title" = - ] || [ "$title" = "$wf" ] || branch="$branch - $title"
    for='-'; [ "${val%%.*}" -gt 0 ] 2>/dev/null && for="$(_dur "$val")"
    jobs[$host]+="$pool"$'\t'"$repo"$'\t'"$pr"$'\t'"$job"$'\t'"$for"$'\t'"$branch"$'\t'"${val%%.*}"$'\n'
  done
  # A machine that is not a runner (the workstation) runs its gates locally: same rows,
  # pool "local", the worktree where the repo goes.
  local wt plat
  declare -A gates
  for line in "${LOCAL[@]}"; do
    IFS=$'\t' read -r host wt branch plat val <<< "$line"
    [ -n "${seen[$host]:-}" ] || { seen[$host]=1; hosts+=("$host"); }
    gates[$host]=$(( ${gates[$host]:-0} + 1 ))
    jobs[$host]+="local"$'\t'"$wt"$'\t'"-"$'\t'"$plat"$'\t'"$(_dur "$val")"$'\t'"$branch"$'\t'"${val%%.*}"$'\n'
  done
  {
    printf '\tMACHINE\tCPU\tLOAD\tMEM\tTEMP\tRUNNERS\tPOOL\tREPO\tPR\tJOB\tFOR\tBRANCH - PR TITLE\n'
    for h in "${hosts[@]}"; do
      local cpu load mem temp run first=1 j
      cpu="$(_pct "cc:host_cpu_busy_ratio/$h")"
      load='-'; [ -n "${V[cc:host_load1/$h]:-}" ] && load="$(printf '%.1f/%s' "${V[cc:host_load1/$h]}" "$(_num "cc:host_cores/$h")")"
      mem="$(_pct "cc:host_mem_used_ratio/$h")"
      temp='-'; [ -n "${V[cc:host_temp_c/$h]:-}" ] && temp="$(printf '%.0fC' "${V[cc:host_temp_c/$h]}")"
      run='-'; [ -n "${slots[$h]:-}" ] && run="${busy[$h]:-0}/${slots[$h]} busy"
      [ -n "${gates[$h]:-}" ] && { [ "$run" = - ] && run="${gates[$h]} gates" || run="$run +${gates[$h]}"; }
      if [ -z "${jobs[$h]:-}" ]; then
        printf '\t%s\t%s\t%s\t%s\t%s\t%s\t-\t-\t-\t-\t-\t-\n' "$h" "$cpu" "$load" "$mem" "$temp" "$run"
        continue
      fi
      while IFS= read -r j; do
        [ -n "$j" ] || continue
        if (( first )); then printf '\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$h" "$cpu" "$load" "$mem" "$temp" "$run" "${j%$'\t'*}"; first=0
        else printf '\t\t\t\t\t\t\t%s\n' "${j%$'\t'*}"; fi
      done < <(printf '%s' "${jobs[$h]}" | sort -t$'\t' -k7,7nr)
    done
  } | table_fit "$w" keep="1 8 9 10 11 2 3 6 4 5 7" flex=12 flexmin=14 right="2 3 4 5 11"
}

# queued <width> <max rows>: waiting jobs grouped by pool, repo, PR and branch, oldest first.
queued() {
  local w="$1" max="$2" line labels repo pr branch val k n=0 oldest=0
  declare -A count old
  for line in "${WAITING[@]}"; do
    IFS=$'\t' read -r labels repo pr branch val <<< "$line"
    val="${val%%.*}"; n=$((n + 1)); (( val > oldest )) && oldest=$val
    [ "$pr" = - ] || pr="#$pr"
    k="$(_pool_of "$labels")"$'\t'"$repo"$'\t'"$pr"$'\t'"$branch"
    count[$k]=$(( ${count[$k]:-0} + 1 ))
    (( val > ${old[$k]:-0} )) && old[$k]=$val
  done
  if (( n == 0 )); then printf '%sQUEUED%s  nothing waiting\n' "$C_HEAD" "$C_OFF"; return; fi
  printf '%sQUEUED%s  %d jobs in %d groups, oldest waiting %s\n' "$C_HEAD" "$C_OFF" "$n" "${#count[@]}" "$(_dur "$oldest")"
  local rows
  rows="$(for k in "${!count[@]}"; do printf '%s\t%s\t%s\n' "${old[$k]}" "$k" "${count[$k]}"; done | sort -t$'\t' -k1,1nr)"
  {
    printf '\tPOOL\tREPO\tPR\tJOBS\tWAITING\tBRANCH\n'
    head -n "$max" <<< "$rows" | while IFS=$'\t' read -r val pool repo pr branch c; do
      printf '\t%s\t%s\t%s\t%s\t%s\t%s\n' "$pool" "$repo" "$pr" "$c" "$(_dur "$val")" "$branch"
    done
  } | table_fit "$w" keep="1 2 3 4 5" flex=6 flexmin=12 right="4 5"
  (( ${#count[@]} > max )) && printf '%s  +%d more groups (Grafana: Waiting for a runner)%s\n' "$C_DIM" $(( ${#count[@]} - max )) "$C_OFF"
  return 0
}

down() {
  local line host state pool name rest items=()
  for line in "${RUNNERS[@]}"; do
    IFS=$'\t' read -r host state pool name rest <<< "$line"
    case "$state" in offline|missing) items+=("$name $state") ;; esac
  done
  [ "$API_OK" = 1 ] || items=("GitHub API not answering: runner rows may be missing" "${items[@]}")
  [ ${#RUNNERS[@]} -gt 0 ] || items+=("no runner series (exporter down?)")
  if [ ${#items[@]} -gt 0 ]; then
    printf '%sDOWN%s    %s%s%s\n' "$C_HEAD" "$C_OFF" "$C_RED" "$(printf '%s, ' "${items[@]}" | sed 's/, $//')" "$C_OFF"
  else
    printf '%sDOWN%s    nothing: every rostered runner is registered and online\n' "$C_HEAD" "$C_OFF"
  fi
}

recent() {
  local w="$1" line c repo wf branch val now
  now="$(date +%s)"
  printf '%sRECENT%s\n' "$C_HEAD" "$C_OFF"
  {
    printf '\tAGO\tRESULT\tREPO\tWORKFLOW\tBRANCH\n'
    for line in "${RECENT[@]}"; do
      IFS=$'\t' read -r c repo wf branch val <<< "$line"
      printf '\t%s\t%s\t%s\t%s\t%s\n' "$(_dur $((now - ${val%%.*})))" "$c" "$repo" "$wf" "$branch"
    done
  } | table_fit "$w" keep="1 2 3 4" flex=5 flexmin=12 right="1" | _paint_results
}

# _paint_results: GitHub's own verdict words, coloured. Applied after fitting so escape
# codes never count toward a column's width.
_paint_results() {
  if [ -n "$C_OFF" ]; then
    sed -E -e "s/\\b(failure|timed_out)\\b/${C_RED}&${C_OFF}/" -e "s/\\b(success)\\b/${C_OK}&${C_OFF}/"
  else cat; fi
}

render() {
  local cols="${COLUMNS:-$(tput cols 2>/dev/null || echo 80)}"
  local lines="${LINES:-$(tput lines 2>/dev/null || echo 24)}"
  if [ -n "$FETCH_ERR" ]; then
    printf '%sCOMMAND CENTER%s  %s%s%s\n\n' "$C_HEAD" "$C_OFF" "$C_DIM" "$(date '+%H:%M:%S')" "$C_OFF"
    printf '%s QUERY FAILED %s %s\n\n' "$C_WARN" "$C_OFF" "$FETCH_ERR"
    printf '%sNothing is shown rather than old numbers. Retrying every %ss; r retries now.%s\n' \
      "$C_DIM" "$REFRESH_SECS" "$C_OFF"
    return 0
  fi
  local top mach dn rec red foot q_rows used
  top="$(header | _clip_ansi "$cols")"
  mach="$(machines "$cols")"
  dn="$(down | _clip_ansi "$cols")"
  rec="$(recent "$cols")"
  if [ ${#RED_ITEMS[@]} -gt 0 ]; then red="red now: $(printf '%s, ' "${RED_ITEMS[@]}" | sed 's/, $//')"; else red='red now: nothing'; fi
  foot="$(printf '%s\n%s%s   fleet actions: Prefix+C-g   r refresh   q quit%s' "$red" "$C_DIM" "$GRAFANA_URL" "$C_OFF" | _clip_ansi "$cols")"
  # Machines and DOWN always show. The queue gets what is left (at least 3 groups), and
  # RECENT goes first when the window is short.
  used=$(( $(wc -l <<< "$top") + $(wc -l <<< "$mach") + $(wc -l <<< "$dn") + $(wc -l <<< "$foot") + 4 ))
  q_rows=$(( lines - used - $(wc -l <<< "$rec") - 4 ))
  if (( q_rows < 3 )); then rec=''; q_rows=$(( lines - used - 4 )); fi
  (( q_rows < 3 )) && q_rows=3
  printf '%s\n\n%s\n\n%s\n%s\n' "$top" "$mach" "$(queued "$cols" "$q_rows")" "$dn"
  [ -n "$rec" ] && printf '\n%s\n' "$rec"
  printf '\n%s\n' "$foot"
}

frame() { fetch; render; }

if [ "${1:-}" = --once ]; then
  frame
  [ -z "$FETCH_ERR" ]
  exit
fi

[[ "${BASH_SOURCE[0]}" != "$0" ]] && return 0 # sourced by the test suite

trap 'tput cnorm 2>/dev/null; exit 0' INT TERM
tput civis 2>/dev/null
while :; do
  # Measured HERE, where stdout is the terminal. Inside $(frame) tput sees a pipe and
  # answers 80.
  COLUMNS="$(tput cols 2>/dev/null || echo 80)"
  LINES="$(tput lines 2>/dev/null || echo 24)"
  export COLUMNS LINES
  out="$(frame)"
  printf '\033[H\033[2J%s' "$out"
  # One wait per frame: a keypress or a resize ends it early (q quits). The read is in a
  # subshell whose WINCH trap exits it, because bash 5.3 keeps reading after a trap runs.
  key="$(trap 'exit 0' WINCH; read -rsn1 -t "$REFRESH_SECS" k && printf '%s' "$k")"
  [ "$key" = q ] && { tput cnorm 2>/dev/null; exit 0; }
done
