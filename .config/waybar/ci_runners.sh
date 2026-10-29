#!/usr/bin/env bash
# Waybar module: CI runners. The bar is busy of slots and the queue, summed the way the
# hub:infra board's header sums them (the GitHub self-hosted pools plus the workstation's
# local Unity gates), then the jobs finished in the last day, painted by their pass rate on
# the board's lines (red under 70%, amber under 90%). The hover lists each pool's queue,
# oldest wait, finished jobs and pass rate, then each machine's runners with the job every
# busy one is on, then any runner that is down.
#
# The chip's colour is cc:domain_status{domain="ci"}, the one CI judgement the board and
# Grafana also draw, so the bar cannot call CI green while the board calls it red. A failed
# read shows `CI ?`, never the last numbers.
#
# Forgejo Actions runners export no metrics yet, so they are not here.

set -u
here="$(dirname "$(realpath "${BASH_SOURCE[0]}")")"
# shellcheck source=../../.local/lib/prom.sh
. "${PROM_LIB:-$here/../../.local/lib/prom.sh}" 2>/dev/null || . "$HOME/.local/lib/prom.sh"
# shellcheck source=pango.sh
. "$here/pango.sh"

# nf-fa-check, written as an escape so an editor cannot strip the glyph from this file.
DONE_ICON=$'\uf00c'
PASS_RED=70
PASS_WARN=90

fail() { emit "$(paint "$C_RED" 'CI ?')" "CI runners: $1" critical; exit 0; }

cc="$(prom_q '{__name__=~"cc:pool_(slots|busy|waiting|oldest_wait_seconds|done_24h|pass_ratio_24h)|cc:host_local_(slots|busy|queued|done_24h|pass_ratio_24h)"}
  or cc:component_status{domain="ci"} or cc:domain_status{domain="ci"}
  or label_replace(min(github_runner_exporter_api_ok), "__name__", "api_ok", "", "")')" \
  || fail "cannot read $PROM_URL"
runners="$(prom_q "$W (github_runner_state)")" || fail "cannot read $PROM_URL"

# name/key -> value, key = pool, host or component. Counts are cut to whole numbers for bash
# arithmetic; a pass ratio keeps its fraction. Pipe-separated: tab is IFS whitespace and
# would collapse an empty field.
declare -A V=()
while IFS='|' read -r key val; do
  [ -n "$key" ] || continue
  case "$key" in *pass_ratio*) V["$key"]="$val" ;; *) V["$key"]="${val%.*}" ;; esac
done < <(jq -r '.data.result[]
    | [(.metric.__name__ + "/" + (.metric.pool // .metric.host // .metric.component // "")), .value[1]]
    | join("|")' <<< "$cc")

# pass_cell <ratio> -> "87%" painted red/amber on the board's lines, "-" with no ratio.
pass_cell() {
  [ -n "$1" ] || { printf -- '-'; return; }
  local pct
  pct=$(awk -v r="$1" 'BEGIN { printf "%.0f", r * 100 }')
  if ((pct < PASS_RED)); then paint "$C_RED" "$pct%"
  elif ((pct < PASS_WARN)); then paint "$C_YEL" "$pct%"
  else printf '%s%%' "$pct"; fi
}

# Every pool with slots or finished jobs (github-hosted has only the latter) and every
# local-gate host, queue length first (longest on top), then name.
# queue|pool|busy/slots|done|pass ratio
pool_rows=() busy=0 slots=0 waiting=0 done_total=0 passes=""
for key in "${!V[@]}"; do
  case "$key" in
    cc:pool_slots/*) p="${key#*/}" pre=cc:pool b="${V[cc:pool_busy/$p]:-0}" q="${V[cc:pool_waiting/$p]:-0}" ;;
    cc:pool_done_24h/*)
      p="${key#*/}" pre=cc:pool b=- q=0
      [ -z "${V[cc:pool_slots/$p]:-}" ] || continue ;;
    cc:host_local_slots/*) p="${key#*/}" pre=cc:host_local b="${V[cc:host_local_busy/$p]:-0}" q="${V[cc:host_local_queued/$p]:-0}" ;;
    *) continue ;;
  esac
  s="${V[${pre}_slots/$p]:-}" d="${V[${pre}_done_24h/$p]:-}" r="${V[${pre}_pass_ratio_24h/$p]:-}"
  ((busy += ${b/-/0}, slots += ${s:-0}, waiting += q, done_total += ${d:-0}))
  [ -n "$d" ] && [ -n "$r" ] && passes+=" $d:$r"
  [ "$pre" = cc:pool ] || p="local:$p"
  pool_rows+=("$q|$p|${s:+$b/$s}|$d|$r")
done
((${#pool_rows[@]})) || fail "no cc:pool_* series (recording rules not loaded?)"
mapfile -t pool_rows < <(printf '%s\n' "${pool_rows[@]}" | sort -t'|' -k1,1nr -k2,2)
pw=4
for row in "${pool_rows[@]}"; do
  IFS='|' read -r _ p _ <<< "$row"
  ((${#p} > pw)) && pw=${#p}
done

printf -v body "%-${pw}s %6s %6s %7s %5s  %s" POOL BUSY QUEUE OLDEST DONE PASS
for row in "${pool_rows[@]}"; do
  IFS='|' read -r q p bs d r <<< "$row"
  printf -v qs '%6s' "$q"
  oldest=-
  if ((q > 0)); then
    qs="$(paint "$C_YEL" "$qs")"
    [[ "$p" == local:* ]] || oldest="$(prom_dur "${V[cc:pool_oldest_wait_seconds/$p]:-}")"
  fi
  printf -v line "%-${pw}s %6s %s %7s %5s  %s" "$p" "${bs:--}" "$qs" "$oldest" "${d:--}" "$(pass_cell "$r")"
  body+=$'\n'"$line"
done

# --- runners by machine, one pass over rows sorted by host then pool ---------------------
# host|pool|state|name|repo|pr|workflow|job_name|seconds
declare -A ALL=() BUSY=() JOBS=() DOWN=()
hosts=()
while IFS='|' read -r h p state name repo pr workflow job secs; do
  [ -n "${ALL[$h/$p]:-}" ] || { [[ " ${hosts[*]} " == *" $h "* ]] || hosts+=("$h"); }
  ALL[$h/$p]=$((${ALL[$h/$p]:-0} + 1))
  case "$state" in
    running)
      BUSY[$h/$p]=$((${BUSY[$h/$p]:-0} + 1))
      t="$(prom_dur "$secs")"
      ((${secs%.*} > LONG_RUN_SECS)) && t="$(paint "$C_YEL" "$t")"
      JOBS[$h]+=$'\n'"  $(pango_esc "$name  ${repo:--}${pr:+#$pr}  ${workflow:+$workflow: }$job")  $t" ;;
    offline | missing) DOWN[$h/$state]=$((${DOWN[$h/$state]:-0} + 1)) ;;
  esac
done < <(jq -r '.data.result[]
    | [.metric.host, .metric.pool, .metric.state, .metric.name, .metric.repo, .metric.pr,
       .metric.workflow, .metric.job_name, .value[1]]
    | map(. // "" | gsub("[|\n]"; " ")) | join("|")' <<< "$runners" | sort -t'|' -k1,1 -k2,2)

((${#hosts[@]})) && body+=$'\n'
for h in "${hosts[@]}"; do
  line="$h "
  while read -r key; do
    [[ "$key" == "$h/"* ]] && line+=" ${key#*/} ${BUSY[$key]:-0}/${ALL[$key]}"
  done < <(printf '%s\n' "${!ALL[@]}" | sort)
  body+=$'\n'"<b>$(pango_esc "$line")</b>${JOBS[$h]:-}"
done

# Counted per machine and state: a roster slot that never registered is one line per box,
# not one per slot.
if ((${#DOWN[@]})); then
  body+=$'\n\n'"$(paint "$C_RED" DOWN:)"
  while read -r key; do
    body+=$'\n'"  $(pango_esc "${key%/*}  ${DOWN[$key]} ${key#*/}")"
  done < <(printf '%s\n' "${!DOWN[@]}" | sort)
fi

# --- status: the ci domain's components, worst first -----------------------------------
names=(ok warn red)
status="" level="${V[cc:domain_status/]:-}"
for key in "${!V[@]}"; do
  [[ "$key" == cc:component_status/* ]] || continue
  c="${V[$key]}"
  status+=" ${key#*/} $(paint "${LEVEL_COLOUR[$c]}" "${names[$c]}"),"
done
if [ -z "$level" ]; then
  # No status series is not a green light: the board prints NO DATA here.
  level=1 status=" no data,"
fi
[ "${V[api_ok/]:-0}" = 1 ] || status+=" $(paint "$C_RED" 'exporter cannot reach GitHub, numbers may be old'),"

label=CI
((level > 0)) && label="$(paint "${LEVEL_COLOUR[$level]}" CI)"
q="q$waiting"
((waiting > 0)) && q="$(paint "$C_YEL" "$q")"
# Finished in the last day, painted by the pass rate over all of them (each pool's ratio
# weighted by its finished count). No finished series at all reads -, never 0.
done_text="${DONE_ICON}-" finished="finished 24h: none reported"
if ((done_total > 0)); then
  ratio="$(awk -v ps="$passes" 'BEGIN { n = split(ps, a, " "); for (i = 1; i <= n; i++) { split(a[i], x, ":"); d += x[1]; p += x[1] * x[2] } if (d > 0) printf "%.4f", p / d }')"
  done_text="${DONE_ICON}${done_total}"
  if [ -n "$ratio" ]; then
    pct=$(awk -v r="$ratio" 'BEGIN { printf "%.0f", r * 100 }')
    if ((pct < PASS_RED)); then done_text="$(paint "$C_RED" "$done_text")"
    elif ((pct < PASS_WARN)); then done_text="$(paint "$C_YEL" "$done_text")"; fi
    finished="finished 24h: $done_total, $pct% passed"
  fi
fi

emit "$label $busy/$slots $q $done_text" \
  "<b>CI runners</b>  busy/slots, queued, finished in 24h"$'\n'"ci:${status%,}"$'\n'"$finished"$'\n'"<tt>$body</tt>" \
  "${LEVEL_CLASS[$level]}"
