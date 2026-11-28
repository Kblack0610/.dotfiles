# shellcheck shell=bash disable=SC2034  # PROM_URL, W and LONG_RUN_SECS are for the scripts that source this
# prom.sh - the one bash Prometheus reader, for the waybar load, CI, day and health chips
# (.config/waybar/load.sh, ci_runners.sh, health.sh) and the fleet scripts. The hub board
# is Rust (.local/src/hub-tui) and reads through hub-core's prom module.
#
# All of them draw the cc:* recording rules and runner-exporter series (home-config
# apps/monitoring/prometheus-rules-command-center.yaml, apps/github-runner-exporter), so
# sharing the reader keeps them from disagreeing about how a query is made or a wait is
# written. The exporter calls GitHub with its own token, so none of this spends the user's
# `gh` API budget.
#
# Endpoints stay out of this public repo. Set them in ~/.config/command-center/env (stowed
# from the private overlay):
#   CC_PROM_URL=https://prometheus.your.lan
#   CC_GRAFANA_URL=https://grafana.your.lan/d/kb-ci-runners   a dashboard link; the boards link from its base
#   CC_KUBE_CONTEXT, CC_VM_SERVICE                             VictoriaMetrics for reads over days (vm_q)

# shellcheck source=/dev/null
[ -r "$HOME/.config/command-center/env" ] && . "$HOME/.config/command-center/env"
PROM_URL="${CC_PROM_URL:-https://prometheus.example.com}"

# Scrape-target labels, stripped so two exporter pods during a rollout read as one row.
W='max without (instance, pod, job, namespace, service, endpoint, container)'

# A job running longer than this shows its time amber: playground ci.md calls a gate that
# runs past about an hour a bug to fix, not a wait.
LONG_RUN_SECS=3600

# prom_label_re <json array> -> its values as one PromQL `=~` alternation, each cut to [A-Za-z0-9_-] so
# config text cannot break out of the matcher; nothing for no value or a malformed array.
prom_label_re() {
  jq -r 'map(tostring | gsub("[^A-Za-z0-9_-]"; "") | select(. != "")) | join("|")' <<<"$1" 2>/dev/null
}

# _prom_get <api path> <curl args...> -> the raw /api/v1/<path> JSON, or rc 1 when it did not answer
# success. PROM_TIMEOUT: the board waits 10s; a bar module sets less, so a dead endpoint cannot
# stall the bar.
_prom_get() {
  local api=$1 out; shift   # not `path`: zsh ties $path to PATH, so a zsh caller lost curl
  out="$(curl -sf -m "${PROM_TIMEOUT:-10}" -G "$PROM_URL/api/v1/$api" "$@" 2>/dev/null)" || return 1
  [ "$(jq -r .status <<< "$out" 2>/dev/null)" = success ] || return 1
  printf '%s' "$out"
}

# prom_q <promql> [epoch] -> an instant query's JSON.
prom_q() { _prom_get query --data-urlencode "query=$1" ${2:+--data-urlencode "time=$2"}; }

# vm_q <promql> [epoch] -> an instant query's JSON from VictoriaMetrics, or rc 1 when it did not answer
# success. Prometheus keeps about 52 h (its retentionSize evicts first), so a read over days goes here:
# VM holds every remote-written series for 2y. It has no ingress, so this goes through the API server's
# service proxy as hub-core's prom::vm does: CC_KUBE_CONTEXT and CC_VM_SERVICE (namespace/name:port) in
# the env file above. With no kubeconfig (any host but the workstation) it is unreadable.
vm_q() {
  local svc="${CC_VM_SERVICE:-}" ns name port out
  [[ "$svc" =~ ^([a-z0-9-]+)/([a-z0-9-]+):([0-9]+)$ ]] && [ -n "${CC_KUBE_CONTEXT:-}" ] || return 1
  ns=${BASH_REMATCH[1]} name=${BASH_REMATCH[2]} port=${BASH_REMATCH[3]}
  out="$(kubectl --context "$CC_KUBE_CONTEXT" --request-timeout="${PROM_TIMEOUT:-10}s" get --raw \
    "/api/v1/namespaces/$ns/services/$name:$port/proxy/api/v1/query?query=$(jq -rn --arg q "$1" '$q | @uri')${2:+&time=$2}" 2>/dev/null)" || return 1
  [ "$(jq -r .status <<< "$out" 2>/dev/null)" = success ] || return 1
  printf '%s' "$out"
}

# prom_range <promql> <start> <end> <step> -> a range query's JSON (epochs, step in seconds).
prom_range() {
  _prom_get query_range --data-urlencode "query=$1" --data-urlencode "start=$2" --data-urlencode "end=$3" --data-urlencode "step=$4"
}

# prom_dur <seconds> -> 45s, 36m, 2h28m, 3d4h; - for anything that is not a number.
prom_dur() {
  local s="${1%%.*}"
  [[ "$s" =~ ^[0-9]+$ ]] || { printf -- '-'; return; }
  if (( s < 60 )); then printf '%ds' "$s"
  elif (( s < 3600 )); then printf '%dm' $((s / 60))
  elif (( s < 86400 )); then printf '%dh%02dm' $((s / 3600)) $((s % 3600 / 60))
  else printf '%dd%dh' $((s / 86400)) $((s % 86400 / 3600)); fi
}
