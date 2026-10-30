#!/usr/bin/env bash
# Waybar module: CPU and load, the first half of the CPU pill. The bar is this machine's CPU
# use from /proc/stat and 1-minute load from /proc/loadavg, so both still show when Prometheus
# is down; the class (ok, warn, critical by load per core) lets the theme turn this half red.
# A gold ! follows it when any OTHER machine is hot. The hover is every machine's load, CPU, memory and
# temperature from the cc:host_* rules, worst load per core first.
#
# Missing values read -, never 0: the temperature rule only reads coretemp/k10temp, so
# the Macs and Pis have no temp at all.

set -u
here="$(dirname "$(realpath "${BASH_SOURCE[0]}")")"
# shellcheck source=../../.local/lib/prom.sh
. "${PROM_LIB:-$here/../../.local/lib/prom.sh}" 2>/dev/null || . "$HOME/.local/lib/prom.sh"
# shellcheck source=pango.sh
. "$here/pango.sh"

# Hot is either line. The rules carry no heat judgement yet, so this one is the bar's own:
# 90 C sits under the 95 C where the workstation's Zen 4 stops boosting, so a laptop
# cooking shows before it throttles (fleet-assess pages on 95 C AND 1.5 load per core).
HOT_TEMP=90
HOT_RATIO=1.5
# Under this load per core, and not hot, a machine folds into the one "idle:" line.
IDLE_RATIO=0.1

read -r load1 _ < "${LOAD_LOADAVG:-/proc/loadavg}"
cores="${LOAD_CORES:-$(nproc)}"

# level <ratio> -> 0 under one per core, 1 under HOT_RATIO, 2 past it.
level=$(awk -v r="$load1" -v c="$cores" -v h="$HOT_RATIO" 'BEGIN { r = c > 0 ? r / c : 0; print (r < 1 ? 0 : (r < h ? 1 : 2)) }')
class="${LEVEL_CLASS[$level]}"

# CPU busy since the last run. /proc/stat counts since boot, so a percentage needs the previous
# sample; the first run has none and reads -, never a since-boot average. Iowait counts as idle.
cpu_state="${LOAD_CPU_STATE:-${XDG_RUNTIME_DIR:-/tmp}/waybar-load-cpu}"
read -r _ user nice sys idle iowait irq softirq steal _ < "${LOAD_STAT:-/proc/stat}"
total=$((user + nice + sys + idle + iowait + irq + softirq + steal)) rest=$((idle + iowait))
cpu=-
if [ -r "$cpu_state" ] && read -r prev_total prev_rest < "$cpu_state" && ((total > prev_total)); then
  cpu="$((100 * (total - prev_total - rest + prev_rest) / (total - prev_total)))%"
fi
printf '%s %s\n' "$total" "$rest" > "$cpu_state"

printf -v text 'CPU %s LOAD %.1f' "$cpu" "$load1"

fallback() { emit "$text" "Load $load1 on $cores cores"$'\n'"$1" "$class"; exit 0; }

# This machine's row: CC_SELF, else the one whose node-exporter nodename is our hostname.
# It is skipped for the ! (the temperature chips already cover this box), not hidden.
host="$(hostname 2>/dev/null)"
self_q="label_replace(max by (host) (cc:host_instance * on (instance) group_left () node_uname_info{nodename=\"${host//[^A-Za-z0-9._-]/}\"}), \"__name__\", \"cc:host_self\", \"\", \"\")"
json="$(prom_q "{__name__=~\"cc:host_(load1|cores|cpu_busy_ratio|mem_used_ratio|temp_c)\"} or $self_q")" \
  || fallback "fleet telemetry unavailable ($PROM_URL)"

# One row per machine, worst load per core first; a machine with no ratio sorts last.
# host|load/cores|cpu|mem|temp|load level|temp hot|self|hot|idle, cells ready to print.
# Not tab-separated: tab is IFS whitespace, so `read` would collapse an empty field.
mapfile -t rows < <(jq -r --arg self "${CC_SELF:-}" --argjson ht "$HOT_TEMP" --argjson hr "$HOT_RATIO" --argjson ir "$IDLE_RATIO" '
  def f1: (. * 10 | round) as $n | "\($n / 10 | floor).\($n % 10)";
  def pct: if . == null then "-" else "\(. * 100 | round)%" end;
  [.data.result[] | select(.metric.host)
   | {h: .metric.host, k: (.metric.__name__ | sub("^cc:host_"; "")), v: (.value[1] | tonumber)}]
  | group_by(.h)
  | map((map({(.k): .v}) | add) as $m
        | {h: .[0].h, m: $m,
           r: (if $m.load1 != null and ($m.cores // 0) > 0 then $m.load1 / $m.cores else null end),
           th: (($m.temp_c // 0) >= $ht)})
  | (if $self != "" then $self else (map(select(.m.self != null) | .h) | first // "") end) as $me
  | map(. + {hot: (.th or ((.r // 0) >= $hr))})
  | map(. + {idle: (.r != null and .r < $ir and (.hot | not))})
  | sort_by(-(.r // -1), .h)[]
  | select(.m.load1 != null or .m.cores != null or .m.cpu_busy_ratio != null or .m.mem_used_ratio != null or .m.temp_c != null)
  | [.h,
     (if .m.load1 == null then "-" else "\(.m.load1 | f1)/\(.m.cores // "-")" end),
     (.m.cpu_busy_ratio | pct), (.m.mem_used_ratio | pct),
     (if .m.temp_c == null then "-" else "\(.m.temp_c | round)C" end),
     (if .r == null then "" elif .r < 1 then 0 elif .r < $hr then 1 else 2 end),
     (if .th then 1 else 0 end), (if .h == $me then 1 else 0 end),
     (if .hot then 1 else 0 end), (if .idle then 1 else 0 end)]
  | map(tostring) | join("|")' <<< "$json" 2>/dev/null)

((${#rows[@]})) || fallback "no cc:host_* series (recording rules not loaded?)"

width=4 idle_hosts=() shown=()
for row in "${rows[@]}"; do
  IFS='|' read -r h _ _ _ _ _ _ _ _ idle <<< "$row"
  if [ "$idle" = 1 ]; then idle_hosts+=("$h"); continue; fi
  shown+=("$row")
  ((${#h} > width)) && width=${#h}
done

printf -v body "%-${width}s  %-8s %4s %4s %5s" HOST LOAD CPU MEM TEMP
hot_other=false
for row in "${shown[@]}"; do
  IFS='|' read -r h lc cpu mem temp lvl thot me hot _ <<< "$row"
  [ "$hot" = 1 ] && [ "$me" = 0 ] && hot_other=true
  printf -v lc '%-8s' "$lc"
  [ -n "$lvl" ] && lc="$(paint "${LEVEL_COLOUR[$lvl]}" "$lc")"
  printf -v temp '%5s' "$temp"
  [ "$thot" = 1 ] && temp="$(paint "$C_RED" "$temp")"
  printf -v line "%-${width}s  %s %4s %4s %s" "$h" "$lc" "$cpu" "$mem" "$temp"
  body+=$'\n'"$line"
done
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
emit "$text" "<b>Machines</b>  1-min load/cores, CPU busy, memory, temperature"$'\n'"<tt>$body</tt>" "$class"
