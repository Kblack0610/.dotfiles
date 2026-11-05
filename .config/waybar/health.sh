#!/usr/bin/env bash
# Waybar module: the health chip (custom/health), every system at a glance. The bar is a pulse in
# the overall colour and one dot per system, worst first; the hover is one row per system, what
# is down or warning named on it. The hover's reasons are cc:watch_state items, or the failing
# cc:component_status rows for a system no watch explains.
#
# It computes nothing and lists no system: rows and levels come from the cc:* rules (home-config
# apps/monitoring/prometheus-rules-command-center.yaml), so a new domain shows up by itself and
# the bar agrees with the Overview. Prometheus unreadable, or no rows, reads ? in amber.

set -u
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

raw="$(prom_q '{__name__=~"cc:(overall_status|domain_status|watch_state|component_status)"}')" ||
  unknown "cannot read $PROM_URL"

# level<TAB>domain<TAB>why, worst first then by name.
rows="$(jq -r '
  [.data.result[] | .metric + {v: (.value[1] | tonumber | floor)}] as $s
  | [$s[] | select(.__name__ == "cc:domain_status")] | sort_by(-.v, .domain)[]
  | . as $d
  | ([$s[] | select(.__name__ == "cc:watch_state" and .domain == $d.domain)] | sort_by(-.v, .item) | map(.item)) as $items
  | (if $items == [] then [$s[] | select(.__name__ == "cc:component_status" and .domain == $d.domain and .v > 0) | .component]
     else $items end) as $why
  | [$d.v, $d.domain, ($why | join(", ") | gsub("_"; " "))] | @tsv' <<< "$raw")"
[ -n "$rows" ] || unknown "no cc:domain_status rows on $PROM_URL"
overall="$(jq -r 'first(.data.result[] | select(.metric.__name__ == "cc:overall_status") | .value[1] | tonumber | floor) // 1' <<< "$raw")"

width="$(cut -f2 <<< "$rows" | wc -L)"
count=(0 0 0) dots='' body=''
while IFS=$'\t' read -r level domain why; do
  count[level]=$((count[level] + 1))
  dots+="$(paint "${LEVEL_COLOUR[$level]}" "$DOT")"
  line="$(printf "%-${width}s  " "$(pango_esc "$domain")")$(paint "${LEVEL_COLOUR[$level]}" "${WORD[$level]}")"
  [ -z "$why" ] || line+="$(printf '%*s' $((6 - ${#WORD[$level]})) '')$(pango_esc "$why")"
  body+="$line"$'\n'
done <<< "$rows"

head=''
for l in 2 1 0; do
  ((count[l] == 0)) || head+="${head:+, }${count[l]} ${WORD[$l],,}"
done
emit "$(paint "${LEVEL_COLOUR[$overall]}" "$ICON") $dots" "$title  $head"$'\n\n'"<tt>${body%$'\n'}</tt>" "${LEVEL_CLASS[$overall]}"
