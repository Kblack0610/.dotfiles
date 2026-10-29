#!/usr/bin/env bash
# command-center.sh - the hub's infra board (window hub:infra): each CI pool's busy slots
# against its queue and its last day's pass rate, every machine's load with its slots (the
# workstation's local Unity slots too), the job each busy runner or local gate is on (repo,
# PR, branch), what is queued, what is down, how each workflow finished over the last day,
# and one strip of domain statuses.
# Terminal twin of Grafana kb-ci-runners and kb-command-center.
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
# A job running longer than this shows its time amber: playground ci.md calls a gate that
# runs past about an hour a bug to fix, not a wait.
LONG_RUN_SECS=3600
# Scrape-target labels, stripped so two exporter pods during a rollout read as one row.
W='max without (instance, pod, job, namespace, service, endpoint, container)'

if [ -n "${NO_COLOR:-}" ]; then
  C_OK='' C_WARN='' C_RED='' C_NONE='' C_HEAD='' C_DIM='' C_OFF=''
else
  C_OK=$'\033[1;30;42m' C_WARN=$'\033[1;30;43m' C_RED=$'\033[1;37;41m' C_NONE=$'\033[1;37;45m'
  C_HEAD=$'\033[1;37m' C_DIM=$'\033[90m' C_OFF=$'\033[0m'
fi

declare -A V # "cc:name", "cc:domain_status/<domain>", "cc:host_x/<host>" or "cc:pool_x/<pool>" -> value
RED_ITEMS=() RUNNERS=() WAITING=() FINISHED=() LOCAL=()
declare -A PR_BY_BRANCH # "<repo>/<branch>" -> the PR a runner or queued job carries for it
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
  V=() RED_ITEMS=() RUNNERS=() WAITING=() FINISHED=() LOCAL=() PR_BY_BRANCH=() API_OK='' FETCH_ERR=''
  local cc red runners waiting finished api gates key val line repo pr branch
  cc="$(_q '{__name__=~"cc:.+",__name__!~"cc:host_instance|cc:host_local_gate"}')" \
    && runners="$(_q "$W (github_runner_state)")" \
    && waiting="$(_q "$W (github_actions_job_waiting)")" \
    && finished="$(_q "sum by (repo, workflow, conclusion) ($W (github_runs_finished))")" \
    && api="$(_q 'min(github_runner_exporter_api_ok)')" \
    && gates="$(_q 'cc:host_local_gate')" \
    || { FETCH_ERR="cannot read $PROM_URL"; return 1; }
  while IFS=$'\t' read -r key val; do
    [ -n "$key" ] && V["$key"]="$val"
  done < <(jq -r '.data.result[]
      | [(.metric.__name__ + (if .metric.domain and .metric.__name__ == "cc:domain_status" then "/" + .metric.domain
                              elif .metric.host then "/" + .metric.host
                              elif .metric.pool then "/" + .metric.pool else "" end)), .value[1]] | @tsv' <<< "$cc")
  [ -n "${V[cc:overall_status]:-}" ] || { FETCH_ERR="no cc:* series (recording rules not loaded?)"; return 1; }
  mapfile -t RUNNERS < <(_rows "$runners" host state pool name repo pr branch job_name workflow title | sort)
  mapfile -t WAITING < <(_rows "$waiting" pool repo pr branch stuck)
  mapfile -t FINISHED < <(_rows "$finished" repo workflow conclusion)
  mapfile -t LOCAL < <(_rows "$gates" host worktree branch platform repo | sort)
  # A local gate carries no PR; the runner and queue rows for the same branch do.
  for line in "${RUNNERS[@]}"; do
    IFS=$'\t' read -r _ _ _ _ repo pr branch _ <<< "$line"
    [ "$pr" = - ] || PR_BY_BRANCH[$repo/$branch]="$pr"
  done
  for line in "${WAITING[@]}"; do
    IFS=$'\t' read -r _ repo pr branch _ <<< "$line"
    [ "$pr" = - ] || PR_BY_BRANCH[$repo/$branch]="$pr"
  done
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
# _int <key> -> the value as a whole number, or - when the series is absent (never a 0 it did not say).
_int() { local v="${V[$1]:-}"; [ -n "$v" ] && printf '%.0f' "$v" 2>/dev/null || printf -- '-'; }
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
# _sum <cc rule...> -> the sum of their per-pool or per-host values, or ? when none has any.
_sum() {
  local k r t=''
  for r in "$@"; do
    for k in "${!V[@]}"; do [[ "$k" == "$r/"* ]] && t="$(awk -v a="${t:-0}" -v b="${V[$k]}" 'BEGIN { print a + b }')"; done
  done
  [ -n "$t" ] && printf '%.0f' "$t" || printf '?'
}
# _local_hosts -> every host whose local Unity slots are published (cc:host_local_slots).
_local_hosts() {
  local k
  for k in "${!V[@]}"; do [[ "$k" == cc:host_local_slots/* ]] && echo "${k#*/}"; done | sort
}
# _pools -> every pool a cc:pool_* series names, one per line, the longest queue first.
_pools() {
  local k p
  for k in "${!V[@]}"; do
    case "$k" in cc:pool_slots/*|cc:pool_waiting/*) echo "${k#*/}" ;; esac
  done | sort -u | while IFS= read -r p; do
    printf '%s\t%s\n' "$(_num "cc:pool_waiting/$p" | tr -d '?')" "$p"
  done | sort -t$'\t' -k1,1nr -k2,2 | cut -f2
}
# _paint_long: FOR values marked ! (over LONG_RUN_SECS) turn amber, after fitting.
_paint_long() {
  if [ -n "$C_OFF" ]; then sed -E "s/(^| )([0-9][0-9dhms]*!)/\1${C_WARN}\2${C_OFF}/"; else cat; fi
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
  printf '%snodes %s/%s  heartbeats %s/%s  ci busy %s/%s waiting %s  agent runners %s failed  watches %s/%s tripped  lazer %s/%s  claude 24h %s%s%s\n' \
    "$C_DIM" "$(_num cc:k3s_nodes_ready)" "$(_num cc:k3s_nodes_total)" "$(_num cc:machines_up)" "$(_num cc:machines_total)" \
    "$(_sum cc:pool_busy cc:host_local_busy)" "$(_sum cc:pool_slots cc:host_local_slots)" "$(_sum cc:pool_waiting cc:host_local_queued)" \
    "$(_num cc:runners_failed)" "$(_num cc:watches_tripped)" \
    "$(_num cc:watches_total)" "$(_usd cc:lazer_spend_usd)" "$(_usd cc:lazer_budget_usd)" "$(_usd cc:claude_code_cost_24h_usd)" "$here" "$C_OFF"
}

# pools <width>: the balance view, one row per pool: busy of its slots, jobs waiting for it,
# the oldest wait, jobs done and their pass rate over the last day (cc:pool_*_24h), and which
# machines serve it (host:n when a host has more than one slot). A machine's local Unity
# slots are one more pool, unity-local, its waiting being the runs queued for a slot there.
pools() {
  local w="$1" line host state pool rest p h
  declare -A on
  for line in "${RUNNERS[@]}"; do
    IFS=$'\t' read -r host state pool rest <<< "$line"
    case "$state" in running|idle) on[$pool/$host]=$(( ${on[$pool/$host]:-0} + 1 )) ;; esac
  done
  {
    printf '\tPOOL\tBUSY\tWAITING\tOLDEST\tDONE\tPASS\tON\n'
    while IFS= read -r p; do
      [ -n "$p" ] || continue
      local k hosts='' slots='-' old='-'
      for k in $(printf '%s\n' "${!on[@]}" | sort); do
        [ "${k%%/*}" = "$p" ] || continue
        hosts+="${k#*/}"; (( ${on[$k]} > 1 )) && hosts+=":${on[$k]}"; hosts+=' '
      done
      [ -n "${V[cc:pool_slots/$p]:-}" ] && slots="$(_num "cc:pool_busy/$p")/$(_num "cc:pool_slots/$p")"
      [ -n "${V[cc:pool_oldest_wait_seconds/$p]:-}" ] && old="$(_dur "${V[cc:pool_oldest_wait_seconds/$p]}")"
      printf '\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$p" "$slots" "$(_num "cc:pool_waiting/$p")" "$old" \
        "$(_int "cc:pool_done_24h/$p")" "$(_pct "cc:pool_pass_ratio_24h/$p")" "$( [ -n "$hosts" ] && printf '%s' "${hosts% }" || printf -- - )"
    done < <(_pools)
    for h in $(_local_hosts); do
      printf '\tunity-local\t%s/%s\t%s\t-\t%s\t%s\t%s\n' "$(_num "cc:host_local_busy/$h")" "$(_num "cc:host_local_slots/$h")" \
        "$(_num "cc:host_local_queued/$h")" "$(_int "cc:host_local_done_24h/$h")" "$(_pct "cc:host_local_pass_ratio_24h/$h")" "$h"
    done
  } | table_fit "$w" keep="1 2 3 6 5 4" flex=7 flexmin=8 right="2 3 4 5 6" | _paint_pass
}

# machines <width>: one row per machine with its load and its slots per pool. Narrowing drops
# TEMP, then MEM, then 6H; CPU, LOAD and SLOTS stay, so the load view never goes.
machines() {
  local w="$1" h line hosts=() host state pool rest wt branch plat val order=()
  declare -A seen slots busy gates
  for h in $EXTRA_HOSTS; do [ -n "${seen[$h]:-}" ] || { seen[$h]=1; hosts+=("$h"); }; done
  for line in "${RUNNERS[@]}"; do
    IFS=$'\t' read -r host state pool rest <<< "$line"
    [ -n "${seen[$host]:-}" ] || { seen[$host]=1; hosts+=("$host"); }
    # A slot counts when it is registered, as in cc:pool_slots; a missing one is DOWN's.
    case "$state" in running|idle) ;; *) continue ;; esac
    slots[$host/$pool]=$(( ${slots[$host/$pool]:-0} + 1 ))
    busy[$host/$pool]=$(( ${busy[$host/$pool]:-0} + 0 ))
    [ "$state" = running ] && busy[$host/$pool]=$(( ${busy[$host/$pool]} + 1 ))
    [[ " ${order[*]} " == *" $pool "* ]] || order+=("$pool")
  done
  # Pools in POOLS' order (longest queue first), then any the cc:pool_* rules do not name.
  local p known=()
  mapfile -t known < <(_pools)
  for p in "${order[@]}"; do [[ " ${known[*]} " == *" $p "* ]] || known+=("$p"); done
  order=("${known[@]}")
  for line in "${LOCAL[@]}"; do
    IFS=$'\t' read -r host wt branch plat _ val <<< "$line"
    [ -n "${seen[$host]:-}" ] || { seen[$host]=1; hosts+=("$host"); }
    gates[$host]=$(( ${gates[$host]:-0} + 1 ))
  done
  # SLOTS asks for its widest row, but no more than room for two pools' counts, so the
  # narrowing drops TEMP, MEM and 6H to keep it whole and never reaches CPU or LOAD.
  local rows k widest=5 slots_min=24
  rows="$(for h in "${hosts[@]}"; do
    local cpu avg load mem temp sl=''
    cpu="$(_pct "cc:host_cpu_busy_ratio/$h")"
    avg="$(_pct "cc:host_cpu_busy_ratio:avg6h/$h")"
    load='-'; [ -n "${V[cc:host_load1/$h]:-}" ] && load="$(printf '%.1f/%s' "${V[cc:host_load1/$h]}" "$(_num "cc:host_cores/$h")")"
    mem="$(_pct "cc:host_mem_used_ratio/$h")"
    temp='-'; [ -n "${V[cc:host_temp_c/$h]:-}" ] && temp="$(printf '%.0fC' "${V[cc:host_temp_c/$h]}")"
    for k in "${order[@]}"; do
      [ -n "${slots[$h/$k]:-}" ] && sl+="$k ${busy[$h/$k]}/${slots[$h/$k]}  "
    done
    # Local slots once slots.sh publishes them; until then only the gates' count is known.
    if [ -n "${V[cc:host_local_slots/$h]:-}" ]; then
      sl+="unity-local $(_num "cc:host_local_busy/$h")/$(_num "cc:host_local_slots/$h")  "
    elif [ -n "${gates[$h]:-}" ]; then
      sl+="${gates[$h]} gates  "
    fi
    sl="${sl%  }"
    printf '\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$h" "$cpu" "$avg" "$load" "$mem" "$temp" "${sl:--}"
  done)"
  while IFS=$'\t' read -r _ _ _ _ _ _ k; do (( ${#k} > widest )) && widest=${#k}; done <<< "$rows"
  { printf '\tMACHINE\tCPU\t6H\tLOAD\tMEM\tTEMP\tSLOTS\n'; printf '%s\n' "$rows"; } \
    | table_fit "$w" keep="1 2 4 3 5 6" flex=7 flexmin="$(( widest < slots_min ? widest : slots_min ))" flexkeep=1 right="2 3 4 5 6"
}

# running <width>: one row per busy runner and per local gate, longest first: the repo, PR,
# job, time in job (amber past LONG_RUN_SECS), and the branch plus the run's title when it
# says more than the workflow name, which is all a dispatch or push run's title is.
running() {
  local w="$1" line host state pool name repo pr branch job wf title val for wt plat rows=''
  for line in "${RUNNERS[@]}"; do
    IFS=$'\t' read -r host state pool name repo pr branch job wf title val <<< "$line"
    [ "$state" = running ] || continue
    [ "$pr" = - ] || pr="#$pr"
    [ "$title" = - ] || [ "$title" = "$wf" ] || branch="$branch - $title"
    rows+="${val%%.*}"$'\t'"$host"$'\t'"$pool"$'\t'"$repo"$'\t'"$pr"$'\t'"$job"$'\t'"$branch"$'\n'
  done
  # A machine that is not a runner (the workstation) runs its gates locally: pool
  # unity-local, the PR from a runner or queue row on the same branch, and the worktree only
  # when the gate's repo is unknown.
  for line in "${LOCAL[@]}"; do
    IFS=$'\t' read -r host wt branch plat repo val <<< "$line"
    [ "$repo" = - ] && repo="$wt"
    pr="${PR_BY_BRANCH[$repo/$branch]:--}"; [ "$pr" = - ] || pr="#$pr"
    rows+="${val%%.*}"$'\t'"$host"$'\t'"unity-local"$'\t'"$repo"$'\t'"$pr"$'\t'"$plat"$'\t'"$branch"$'\n'
  done
  if [ -z "$rows" ]; then printf '%sRUNNING%s  nothing\n' "$C_HEAD" "$C_OFF"; return; fi
  printf '%sRUNNING%s\n' "$C_HEAD" "$C_OFF"
  {
    printf '\tHOST\tPOOL\tREPO\tPR\tJOB\tFOR\tBRANCH - PR TITLE\n'
    sort -t$'\t' -k1,1nr <<< "${rows%$'\n'}" | while IFS=$'\t' read -r val host pool repo pr job branch; do
      for='-'
      if [ "${val:-0}" -gt 0 ] 2>/dev/null; then
        for="$(_dur "$val")"; (( val > LONG_RUN_SECS )) && for+='!'
      fi
      printf '\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$host" "$pool" "$repo" "$pr" "$job" "$for" "$branch"
    done
  } | table_fit "$w" keep="1 3 4 6 5 2" flex=7 flexmin=16 flexkeep=1 right="6" cap="3:21 5:18" | _paint_long
}

# queued <width> <max rows>: waiting jobs grouped by pool, repo, PR and branch, oldest first.
# A stuck run (queued with no jobs, flagged by the exporter) is DOWN's, so it cannot pass
# for the queue's age.
queued() {
  local w="$1" max="$2" line pool repo pr branch stuck val k n=0 oldest=0
  declare -A count old
  for line in "${WAITING[@]}"; do
    IFS=$'\t' read -r pool repo pr branch stuck val <<< "$line"
    [ "$stuck" = true ] && continue
    val="${val%%.*}"; n=$((n + 1)); (( val > oldest )) && oldest=$val
    [ "$pr" = - ] || pr="#$pr"
    k="$pool"$'\t'"$repo"$'\t'"$pr"$'\t'"$branch"
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
  local line host state pool name rest repo pr branch stuck val items=()
  for line in "${RUNNERS[@]}"; do
    IFS=$'\t' read -r host state pool name rest <<< "$line"
    case "$state" in offline|missing) items+=("$name $state") ;; esac
  done
  for line in "${WAITING[@]}"; do
    IFS=$'\t' read -r pool repo pr branch stuck val <<< "$line"
    [ "$stuck" = true ] && items+=("stuck run: $repo $branch, $(_dur "$val"), no jobs")
  done
  [ "$API_OK" = 1 ] || items=("GitHub API not answering: runner rows may be missing" "${items[@]}")
  [ ${#RUNNERS[@]} -gt 0 ] || items+=("no runner series (exporter down?)")
  if [ ${#items[@]} -gt 0 ]; then
    printf '%sDOWN%s    %s%s%s\n' "$C_HEAD" "$C_OFF" "$C_RED" "$(printf '%s, ' "${items[@]}" | sed 's/, $//')" "$C_OFF"
  else
    printf '%sDOWN%s    nothing: every rostered runner is registered and online\n' "$C_HEAD" "$C_OFF"
  fi
}

# finished <width> <max rows>: the last day of runs per repo and workflow, the worst pass
# rate first. Pass is success of success + failure + timed out, as cc:pool_pass_ratio_24h
# counts jobs; cancelled is its own column, since gates for closed PRs are cancelled on
# purpose. Workflows with nothing failed or cancelled fold into one line.
finished() {
  local w="$1" max="$2" agg bad green
  if [ ${#FINISHED[@]} -eq 0 ]; then
    printf '%sFINISHED 24H%s  no finished-run series yet (runner exporter)\n' "$C_HEAD" "$C_OFF"; return
  fi
  # pass% (-1 when nothing passed or failed), runs, passed, failed, cancelled, repo, workflow
  agg="$(printf '%s\n' "${FINISHED[@]}" | awk -F'\t' '
    { k = $1 "\t" $2; n = $4 + 0; runs[k] += n
      if ($3 == "success") ok[k] += n
      else if ($3 == "failure" || $3 == "timed_out") bad[k] += n
      else if ($3 == "cancelled") can[k] += n }
    END { for (k in runs) { j = ok[k] + bad[k]
            printf "%d\t%d\t%d\t%d\t%d\t%s\n", j ? int(100 * ok[k] / j + 0.5) : -1, runs[k], ok[k], bad[k], can[k], k } }')"
  bad="$(awk -F'\t' '$4 + $5 > 0' <<< "$agg" | sort -t$'\t' -k1,1n -k4,4nr -k5,5nr)"
  green="$(awk -F'\t' '$4 + $5 == 0 { n++; r += $2 } END { if (n) print n, r }' <<< "$agg")"
  printf '%sFINISHED 24H%s  %s\n' "$C_HEAD" "$C_OFF" "$(awk -F'\t' '{ r += $2; o += $3; f += $4; c += $5 }
    END { printf "%d runs, %s pass, %d failed, %d cancelled", r, (o + f) ? sprintf("%.0f%%", 100 * o / (o + f)) : "-", f, c }' <<< "$agg")"
  if [ -n "$bad" ]; then
    {
      printf '\tPASS\tRUNS\tFAIL\tCANCEL\tREPO\tWORKFLOW\n'
      head -n "$max" <<< "$bad" | while IFS=$'\t' read -r pct runs _ f c repo wf; do
        printf '\t%s\t%s\t%s\t%s\t%s\t%s\n' "$( [ "$pct" -ge 0 ] && printf '%s%%' "$pct" || printf -- - )" "$runs" "$f" "$c" "$repo" "$wf"
      done
    } | table_fit "$w" keep="1 3 6 4 2 5" flex=6 flexmin=10 flexkeep=1 right="1 2 3 4" cap="5:21" | _paint_pass
    (( $(wc -l <<< "$bad") > max )) && printf '%s  +%d more workflows with failures (Grafana: Finished, last 24h)%s\n' "$C_DIM" $(( $(wc -l <<< "$bad") - max )) "$C_OFF"
  fi
  [ -n "$green" ] && printf '%s  +%s green workflows, %s runs%s\n' "$C_DIM" "${green% *}" "${green#* }" "$C_OFF"
  return 0
}

# _paint_pass: a pass rate under 70% red, under 90% amber, applied after fitting. Only tables
# with a pass column are piped through it, and that is the one % on their rows.
_paint_pass() {
  if [ -n "$C_OFF" ]; then
    awk -v R="$C_RED" -v A="$C_WARN" -v OFF="$C_OFF" '
      match($0, /[0-9]+%/) { v = substr($0, RSTART, RLENGTH - 1) + 0; c = v < 70 ? R : (v < 90 ? A : "")
        if (c != "") $0 = substr($0, 1, RSTART - 1) c substr($0, RSTART, RLENGTH) OFF substr($0, RSTART + RLENGTH) }
      { print }'
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
  local top pl mach run dn fin red foot q_rows used
  top="$(header | _clip_ansi "$cols")"
  pl="$(pools "$cols")"
  mach="$(machines "$cols")"
  run="$(running "$cols")"
  dn="$(down | _clip_ansi "$cols")"
  fin="$(finished "$cols" 6)"
  if [ ${#RED_ITEMS[@]} -gt 0 ]; then red="red now: $(printf '%s, ' "${RED_ITEMS[@]}" | sed 's/, $//')"; else red='red now: nothing'; fi
  foot="$(printf '%s\n%s%s   fleet actions: Prefix+C-g   r refresh   q quit%s' "$red" "$C_DIM" "$GRAFANA_URL" "$C_OFF" | _clip_ansi "$cols")"
  # Pools, machines, running and DOWN always show. The queue gets what is left (at least 3
  # groups), and FINISHED goes first when the window is short.
  used=$(( $(wc -l <<< "$top") + $(wc -l <<< "$pl") + $(wc -l <<< "$mach") + $(wc -l <<< "$run") + $(wc -l <<< "$dn") + $(wc -l <<< "$foot") + 6 ))
  q_rows=$(( lines - used - $(wc -l <<< "$fin") - 4 ))
  if (( q_rows < 3 )); then fin=''; q_rows=$(( lines - used - 4 )); fi
  (( q_rows < 3 )) && q_rows=3
  printf '%s\n\n%s\n\n%s\n\n%s\n\n%s\n%s\n' "$top" "$pl" "$mach" "$run" "$(queued "$cols" "$q_rows")" "$dn"
  [ -n "$fin" ] && printf '\n%s\n' "$fin"
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
