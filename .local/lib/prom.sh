# shellcheck shell=bash disable=SC2034  # PROM_URL, W and LONG_RUN_SECS are for the scripts that source this
# prom.sh - the one Prometheus reader for the hub:infra board (.local/src/tmux/command-center.sh)
# and the waybar load and CI chips (.config/waybar/load.sh, ci_runners.sh).
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
#   CC_GRAFANA_URL=https://grafana.your.lan/d/kb-ci-runners
#   CC_HOSTS="workstation mac-studio"   board: machines shown even with no runner, first

# shellcheck source=/dev/null
[ -r "$HOME/.config/command-center/env" ] && . "$HOME/.config/command-center/env"
PROM_URL="${CC_PROM_URL:-https://prometheus.example.com}"

# Scrape-target labels, stripped so two exporter pods during a rollout read as one row.
W='max without (instance, pod, job, namespace, service, endpoint, container)'

# A job running longer than this shows its time amber: playground ci.md calls a gate that
# runs past about an hour a bug to fix, not a wait.
LONG_RUN_SECS=3600

# prom_q <promql> -> the raw /api/v1/query JSON, or rc 1 when it did not answer success.
# PROM_TIMEOUT: the board waits 10s; a bar module sets less, so a dead endpoint cannot
# stall the bar.
prom_q() {
  local out
  out="$(curl -sf -m "${PROM_TIMEOUT:-10}" -G "$PROM_URL/api/v1/query" --data-urlencode "query=$1" 2>/dev/null)" || return 1
  [ "$(jq -r .status <<< "$out" 2>/dev/null)" = success ] || return 1
  printf '%s' "$out"
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
