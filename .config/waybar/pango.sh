# shellcheck shell=bash disable=SC2034  # the colours are for the scripts that source this
# pango.sh - markup helpers for the waybar load, CI and day chips (load.sh, ci_runners.sh, day.sh). The
# Prometheus reader they share with the hub:infra board is .local/lib/prom.sh.

# Bar theme (Jackie Brown) colours, the set fleet_pulse.sh uses: the pale Catppuccin
# amber is invisible on the dark bar. Indexed by status level: 0 ok, 1 warn, 2 red,
# the scale the cc:*_status rules use.
LEVEL_COLOUR=("#a6e34a" "#ffcc2f" "#ef5734")
LEVEL_CLASS=(ok warn critical)
C_YEL="${LEVEL_COLOUR[1]}"
C_RED="${LEVEL_COLOUR[2]}"

# A bar module must not stall the bar on a dead endpoint; the board waits 10s.
PROM_TIMEOUT=5

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

# emit <text> <tooltip> <class>: waybar JSON, escaped by jq.
emit() { jq -cn --arg t "$1" --arg tt "$2" --arg c "$3" '{text: $t, tooltip: $tt, class: $c}'; }
