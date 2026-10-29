#!/usr/bin/env bash
# Waybar module: load. The bar is this machine's 1-minute load, read from /proc/loadavg so
# it still shows when Prometheus is down, coloured by load per core. A gold ! follows it
# when any OTHER machine is hot. The hover is every machine's load, CPU, memory and
# temperature from the cc:host_* rules, worst load per core first.
#
# Missing values read -, never 0: the temperature rule only reads coretemp/k10temp, so
# the Macs and Pis have no temp at all.

set -u
# shellcheck source=prom.sh
. "$(dirname "$(realpath "${BASH_SOURCE[0]}")")/prom.sh"

# This machine's name in the cc:host_* series. It is skipped for the ! (the temperature
# chips already cover this box) but still listed in the hover.
SELF="${CC_SELF:-workstation}"
# A machine is hot at either line. 90 C sits under the 95 C where the workstation's Zen 4
# stops boosting (fleet-assess FLEET_HOT_TCTL), so a laptop cooking shows before it throttles.
HOT_TEMP=90
HOT_RATIO=1.5
# Under this load per core, and not hot, a machine folds into the one "idle:" line.
IDLE_RATIO=0.1

LOADAVG="${LOAD_LOADAVG:-/proc/loadavg}"
read -r load1 _ < "$LOADAVG"
cores="${LOAD_CORES:-$(nproc)}"

# colour_for <ratio>: green under 1 core's worth per core, gold under HOT_RATIO, red past it.
colour_for() {
  awk -v r="$1" -v h="$HOT_RATIO" -v g="$C_GRN" -v y="$C_YEL" -v x="$C_RED" \
    'BEGIN { print (r < 1 ? g : (r < h ? y : x)) }'
}

local_ratio="$(awk -v l="$load1" -v c="$cores" 'BEGIN { printf "%.3f", (c > 0 ? l / c : 0) }')"
local_colour="$(colour_for "$local_ratio")"
class="$(awk -v r="$local_ratio" -v h="$HOT_RATIO" 'BEGIN { print (r < 1 ? "ok" : (r < h ? "warn" : "critical")) }')"
text="LOAD $(paint "$local_colour" "$(printf '%.1f' "$load1")")"

if ! json="$(prom_q '{__name__=~"cc:host_(load1|cores|cpu_busy_ratio|mem_used_ratio|temp_c)"}')"; then
  emit "$text" "Load $load1 on $cores cores"$'\n'"fleet telemetry unavailable ($PROM_URL)" "$class"
  exit 0
fi

# One row per machine, worst load per core first; a machine with no ratio sorts last.
# host|load1|cores|cpu|mem|temp|ratio|hot|idle, "" for a missing value. Not tab-separated:
# tab is IFS whitespace, so `read` would collapse an empty field and shift the rest.
rows="$(jq -r --argjson ht "$HOT_TEMP" --argjson hr "$HOT_RATIO" --argjson ir "$IDLE_RATIO" '
  [.data.result[] | select(.metric.host)
   | {h: .metric.host, k: (.metric.__name__ | sub("^cc:host_"; "")), v: (.value[1] | tonumber)}]
  | group_by(.h)
  | map((map({(.k): .v}) | add) as $m
        | {h: .[0].h, m: $m,
           r: (if $m.load1 != null and ($m.cores // 0) > 0 then $m.load1 / $m.cores else null end)})
  | map(. + {hot: (((.m.temp_c // 0) >= $ht) or ((.r // 0) >= $hr))})
  | map(. + {idle: (.r != null and .r < $ir and (.hot | not))})
  | sort_by(-(.r // -1), .h)[]
  | [.h, (.m.load1 // ""), (.m.cores // ""), (.m.cpu_busy_ratio // ""), (.m.mem_used_ratio // ""),
     (.m.temp_c // ""), (.r // ""), (if .hot then 1 else 0 end), (if .idle then 1 else 0 end)]
  | map(tostring) | join("|")' <<< "$json" 2>/dev/null)"

if [ -z "$rows" ]; then
  emit "$text" "Load $load1 on $cores cores"$'\n'"no cc:host_* series (recording rules not loaded?)" "$class"
  exit 0
fi

# Host column fits the longest name that gets a row.
width=4
while IFS='|' read -r h _ _ _ _ _ _ _ idle; do
  [ "$idle" = 1 ] && continue
  ((${#h} > width)) && width=${#h}
done <<< "$rows"

pct() { [ -n "$1" ] && awk -v v="$1" 'BEGIN { printf "%d%%", v * 100 + 0.5 }' || printf -- '-'; }

body="$(printf "%-${width}s  %-8s %4s %4s %5s" HOST LOAD CPU MEM TEMP)"
idle_hosts=() hot_other=false
while IFS='|' read -r h l c cpu mem temp r hot idle; do
  if [ "$idle" = 1 ]; then
    idle_hosts+=("$h")
    continue
  fi
  [ "$hot" = 1 ] && [ "$h" != "$SELF" ] && hot_other=true
  if [ -n "$l" ]; then
    lc="$(printf '%.1f/%s' "$l" "${c:--}")"
  else
    lc=-
  fi
  lc="$(printf '%-8s' "$lc")"
  [ -n "$r" ] && lc="$(paint "$(colour_for "$r")" "$lc")"
  t=-
  [ -n "$temp" ] && t="$(printf '%.0fC' "$temp")"
  t="$(printf '%5s' "$t")"
  [ -n "$temp" ] && awk -v v="$temp" -v h="$HOT_TEMP" 'BEGIN { exit !(v >= h) }' && t="$(paint "$C_RED" "$t")"
  body+=$'\n'"$(printf "%-${width}s  %s %4s %4s %s" "$h" "$lc" "$(pct "$cpu")" "$(pct "$mem")" "$t")"
done <<< "$rows"
# Four names a line, so the folded k3s pis do not stretch the tooltip across the screen.
if ((${#idle_hosts[@]})); then
  mapfile -t idle_hosts < <(printf '%s\n' "${idle_hosts[@]}" | sort)
  line="idle:"
  for i in "${!idle_hosts[@]}"; do
    ((i > 0 && i % 4 == 0)) && { body+=$'\n'"${line%,}"; line="     "; }
    line+=" ${idle_hosts[$i]},"
  done
  body+=$'\n'"${line%,}"
fi

$hot_other && text+=" $(paint "$C_YEL" '!')"
tooltip="<b>Load</b>  1-min load/cores, CPU busy, memory, temperature"$'\n'"<tt>$body</tt>"
emit "$text" "$tooltip" "$class"
