# Sourced by load.sh and ci_runners.sh: the one Prometheus reader the bar uses.
#
# The numbers are the cc:* recording rules and runner-exporter series that the hub:infra
# board (.local/src/tmux/command-center.sh) and Grafana read, so the bar cannot disagree
# with either. The runner exporter calls GitHub with its own token in k8s, so nothing here
# spends the user's `gh` API budget.
#
# Endpoints stay out of this public repo. ~/.config/command-center/env (stowed from the
# private overlay) sets CC_PROM_URL and CC_GRAFANA_URL, the same file command-center reads.

# shellcheck source=/dev/null
[ -r "$HOME/.config/command-center/env" ] && . "$HOME/.config/command-center/env"
PROM_URL="${CC_PROM_URL:-https://prometheus.example.com}"

# Drops the scrape labels so one runner is one series, as command-center does.
W='max without (instance, pod, job, namespace, service, endpoint, container)'

# Bar theme (Jackie Brown) colours, the set fleet_pulse.sh uses: the pale Catppuccin
# amber is invisible on the dark bar.
C_GRN="#a6e34a"
C_YEL="#ffcc2f"
C_RED="#ef5734"

# prom_q <promql>: the query's JSON on stdout; non-zero when Prometheus cannot be read or
# answers anything but success. Short timeout: a dead endpoint must not stall the bar.
prom_q() {
  local out
  out="$(curl -sf -m 5 -G "$PROM_URL/api/v1/query" --data-urlencode "query=$1" 2>/dev/null)" || return 1
  [ "$(jq -r .status <<< "$out" 2>/dev/null)" = success ] || return 1
  printf '%s' "$out"
}

# Pango markup escape for text that came from outside (run titles, job names). The
# replacements are quoted: bash 5.2's patsub_replacement makes a bare & mean "the match".
pango_esc() {
  local s="$1"
  s="${s//&/"&amp;"}"
  s="${s//</"&lt;"}"
  s="${s//>/"&gt;"}"
  printf '%s' "$s"
}

# paint <colour> <text>
paint() { printf "<span color='%s'>%s</span>" "$1" "$2"; }

# Seconds as 45s / 12m / 5h15m.
fmt_dur() {
  local s="${1%.*}"
  [ -n "$s" ] || { printf -- '-'; return; }
  if ((s < 60)); then printf '%ss' "$s"
  elif ((s < 3600)); then printf '%sm' "$((s / 60))"
  else printf '%sh%02dm' "$((s / 3600))" "$(((s % 3600) / 60))"
  fi
}

# emit <text> <tooltip> <class>: waybar JSON, escaped by jq.
emit() { jq -cn --arg t "$1" --arg tt "$2" --arg c "$3" '{text: $t, tooltip: $tt, class: $c}'; }
