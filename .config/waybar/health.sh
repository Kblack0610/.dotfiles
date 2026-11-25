#!/usr/bin/env bash
# Waybar module: the health chip (custom/health), every system at a glance. The bar is the heart
# alone, in the overall colour; the hover's first row is one dot per system, worst first, beside
# the counts, then one row per system with what is down or warning named on it. The hover's rows are cc:watch_state items, or the failing
# cc:component_status rows for a system no watch explains. Each tripped watch is a line of its own,
# `<watch>: <reason>`, the reason being what hub-core's alerts model holds for it
# (`hub alerts --reasons --json`, the watch's last probe line); this script never reads the watch
# state files. A watch with nothing past its status header says `no reason recorded`; where the hub
# answers with no watches (a machine with no watch state, the laptop) the line says `reason on the
# workstation`, and when the hub gives no answer at all (absent, too old, timed out) `hub gave no answer`.
#
# It computes nothing and lists no system: rows and levels come from the cc:* rules (home-config
# apps/monitoring/prometheus-rules-command-center.yaml), so a new domain shows up by itself and
# the bar agrees with the Overview. The head's down, warn and up are hub-core's Health card figures
# (`hub cards --json --figures`, summary/cards on Prometheus, live topics only), the numbers the
# phone's System line prints; with none published the head says so in amber and the rows still
# show. Prometheus unreadable, or no rows, reads ? in amber.

set -u
HUB="${HUB:-$HOME/.local/bin/hub}"
# Under the module's interval, and a file read: a hung hub is no reason, not a stuck hover.
HUB_TIMEOUT=10
here="$(dirname "$(realpath "${BASH_SOURCE[0]}")")"
# shellcheck source=../../.local/lib/prom.sh
. "${PROM_LIB:-$here/../../.local/lib/prom.sh}" 2>/dev/null || . "$HOME/.local/lib/prom.sh"
# shellcheck source=pango.sh
. "$here/pango.sh"

# nf-fa-heartbeat and a filled circle, written as escapes so an editor cannot strip them.
ICON=$'\uf21e'
DOT=$'\u25cf'
WORD=(up warn DOWN)

title="<b>System</b>"
unknown() {
  emit "$(paint "$C_YEL" "$ICON ?")" "$title"$'\n'"$1" warn
  exit 0
}

q='{__name__=~"cc:(overall_status|domain_status|watch_state|component_status)"}'
q+=' or ({__name__=~"mqtt_figures_health_domains_(down|warn|up)", topic=~"agents_.+_summary_cards"} and on (topic) cc:agents_topic_live)'
raw="$(prom_q "$q")" || unknown "cannot read $PROM_URL"

# level<TAB>domain<TAB>w or c<TAB>names: a system's tripped watches (`_` words, joined by US), else
# its failing components on one comma line. Worst first then by name.
rows="$(jq -r '
  [.data.result[] | .metric + {v: (.value[1] | tonumber | floor)}] as $s
  | [$s[] | select(.__name__ == "cc:domain_status")] | sort_by(-.v, .domain)[]
  | . as $d
  | ([$s[] | select(.__name__ == "cc:watch_state" and .domain == $d.domain)] | sort_by(-.v, .item) | map(.item)) as $items
  | (if $items == [] then ["c", ([$s[] | select(.__name__ == "cc:component_status" and .domain == $d.domain and .v > 0) | .component] | map(gsub("_"; " ")) | join(", "))]
     else ["w", ($items | join("\u001f"))] end) as $why
  | [$d.v, $d.domain, $why[0], $why[1]] | @tsv' <<< "$raw")"
[ -n "$rows" ] || unknown "no cc:domain_status rows on $PROM_URL"
overall="$(jq -r 'first(.data.result[] | select(.metric.__name__ == "cc:overall_status") | .value[1] | tonumber | floor) // 1' <<< "$raw")"

# down, warn, up as published, each - when no live topic sends it. Only the lease holder sends
# summary/cards; while a lease move leaves two topics live that disagree, a figure is !, since
# Prometheus does not say which is newer.
read -r -a figs < <(jq -r '[.data.result[]] as $r | ["down", "warn", "up"]
  | map(. as $l | [$r[] | select(.metric.__name__ == "mqtt_figures_health_domains_" + $l) | .value[1] | tonumber | floor]
        | unique | if length > 1 then "!" else .[0] // "-" end) | @tsv' <<< "$raw")

# The watches' reasons, read from the hub only when a watch is tripped. `hub_ok` is whether it
# answered at all; `reasons` is empty when it answered with no watches (the laptop).
reasons='' hub_ok=1
if cut -f3 <<< "$rows" | grep -qx w; then
  if ans="$(timeout "$HUB_TIMEOUT" "$HUB" alerts --reasons --json 2>/dev/null)" && jq -e '.reasons' >/dev/null 2>&1 <<< "$ans"; then
    reasons="$(jq -c '.reasons | select(length > 0)' <<< "$ans")"
  else
    hub_ok=0
  fi
fi
reason_of() {
  local r
  ((hub_ok)) || { printf '%s\n' "hub gave no answer"; return; }
  [ -n "$reasons" ] || { printf '%s\n' "reason on the workstation"; return; }
  r="$(jq -r --arg k "${1//-/_}" '.[$k] // ""' <<< "$reasons")"
  printf '%s\n' "${r:-no reason recorded}"
}

width="$(cut -f2 <<< "$rows" | wc -L)"
dots='' body=''
while IFS=$'\t' read -r level domain kind names; do
  dots+="$(paint "${LEVEL_COLOUR[$level]}" "$DOT")"
  line="$(printf "%-${width}s  " "$(pango_esc "$domain")")$(paint "${LEVEL_COLOUR[$level]}" "${WORD[$level]}")"
  pad="$(printf '%*s' $((6 - ${#WORD[$level]})) '')"
  indent="$(printf '%*s' $((width + 8)) '')"
  texts=()
  if [ "$kind" = w ]; then
    IFS=$'\x1f' read -r -a list <<< "$names"
    for name in "${list[@]}"; do texts+=("${name//_/ }: $(reason_of "$name")"); done
  elif [ -n "$names" ]; then
    texts=("$names")
  fi
  for i in "${!texts[@]}"; do
    if ((i == 0)); then line+="$pad$(pango_esc "${texts[i]}")"; else line+=$'\n'"$indent$(pango_esc "${texts[i]}")"; fi
  done
  body+="$line"$'\n'
done <<< "$rows"

head=''
if [[ " ${figs[*]} " == *" - "* || ${#figs[@]} -ne 3 ]]; then
  head="$(paint "$C_YEL" "no published counts (summary/cards)")"
elif [[ " ${figs[*]} " == *" ! "* ]]; then
  head="$(paint "$C_YEL" "two machines publish different counts (summary/cards)")"
else
  for i in 0 1 2; do
    ((figs[i] == 0)) || head+="${head:+, }${figs[i]} ${WORD[2 - i],,}"
  done
fi
emit "$(paint "${LEVEL_COLOUR[$overall]}" "$ICON")" "$title  $dots  $head"$'\n\n'"<tt>${body%$'\n'}</tt>" "${LEVEL_CLASS[$overall]}"
