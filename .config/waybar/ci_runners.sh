#!/usr/bin/env bash
# Waybar module: CI runners. The bar is busy of slots and the queue, summed the way the
# hub board's header sums them (the GitHub self-hosted pools plus the workstation's
# local Unity gates). The hover says how many run locally and in the cloud (cc:site_*, each
# cloud host by name, plus jobs on GitHub's own runners), the jobs finished in the last day
# painted by their pass rate on the board's lines (red under 70%, amber under 90%), each
# pool's queue, oldest wait, finished jobs and pass rate, then one row per machine: where it
# is, busy/slots, and busy/slots per pool, busiest first. Below that, any runner that is down
# and the jobs running past LONG_RUN_SECS. A runner the governor withholds is counted apart
# (`unity withheld 1/2`), so a machine reads what it is meant to run. A local row is busy of
# its open slots; its burst slots, which open only while the machine has room, are named in
# a legend line instead of the cell. The per-job list is the board's CI tab, not this hover.
#
# The chip's colour is cc:domain_status{domain="ci"}, the one CI judgement the board and
# Grafana also draw, so the bar cannot call CI green while the board calls it red. A failed
# read shows `CI: prom down`, never the last numbers.
#
# Forgejo Actions runners export no metrics yet, so they are not here.

set -u
here="$(dirname "$(realpath "${BASH_SOURCE[0]}")")"
# shellcheck source=../../.local/lib/prom.sh
. "${PROM_LIB:-$here/../../.local/lib/prom.sh}" 2>/dev/null || . "$HOME/.local/lib/prom.sh"
# shellcheck source=pango.sh
. "$here/pango.sh"

PASS_RED=70
PASS_WARN=90

fail() { emit "$(paint "$C_RED" 'CI: prom down')" "CI runners: $1" critical; exit 0; }

# api_ok reads the runner sources only: a failed call to one repo's run list leaves every
# runner row intact, so it is no reason to doubt them. exporter_up tells a missed scrape
# (every exporter series gone stale) apart from GitHub not answering, and rate_left (the
# token's emptiest bucket; the budget is per user, shared with every gh session) names the
# usual reason it stops answering. `or` matches label sets with the name ignored, so each
# carries a src label or all but the first would be dropped.
cc="$(prom_q '{__name__=~"cc:pool_(slots|busy|waiting|oldest_wait_seconds|done_24h|pass_ratio_24h)|cc:host_local_(slots|open_slots|busy|queued|done_24h|pass_ratio_24h)|cc:site_(slots|busy)|cc:github_hosted_running"}
  or cc:component_status{domain="ci"} or cc:domain_status{domain="ci"}
  or label_replace(label_replace(min(github_runner_exporter_api_ok{kind="runners"}), "__name__", "api_ok", "", ""), "src", "api", "", "")
  or label_replace(label_replace(max(up{job="github-runner-exporter"}), "__name__", "exporter_up", "", ""), "src", "up", "", "")
  or label_replace(label_replace(min(github_runner_exporter_rate_remaining), "__name__", "rate_left", "", ""), "src", "rate", "", "")')" \
  || fail "cannot read $PROM_URL"
runners="$(prom_q "$W (github_runner_state)")" || fail "cannot read $PROM_URL"
withheld="$(prom_q "$W (github_runner_withheld) == 1")" || fail "cannot read $PROM_URL"
declare -A WITHHELD=()
while read -r name; do [ -n "$name" ] && WITHHELD[$name]=1; done < <(jq -r '.data.result[].metric.name' <<< "$withheld")

# name/key -> value, key = pool, host, component or site. Counts are cut to whole numbers for bash
# arithmetic; a pass ratio keeps its fraction. Pipe-separated: tab is IFS whitespace and
# would collapse an empty field.
declare -A V=()
while IFS='|' read -r key val; do
  [ -n "$key" ] || continue
  case "$key" in *pass_ratio*) V["$key"]="$val" ;; *) V["$key"]="${val%.*}" ;; esac
done < <(jq -r '.data.result[]
    | [(.metric.__name__ + "/" + (.metric.pool // .metric.host // .metric.component // .metric.site // "")), .value[1]]
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
pool_rows=() busy=0 slots=0 waiting=0 done_total=0 passes="" burst_legend=""
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
  cell="${s:+$b/$s}"
  # A local row counts its open slots, and a burst slot only while one runs: burst slots
  # open only while the machine has room, so the legend names them instead of the cell.
  if [ "$pre" = cc:host_local ]; then
    open="${V[cc:host_local_open_slots/$p]:-0}" room=$((s - ${V[cc:host_local_open_slots/$p]:-0}))
    s=$((b > open ? b : open)) cell="$b/$s"
    ((room > 0)) && burst_legend+=$'\n'"local:$p has $room burst slots more, opened only while the CPU has room"
  fi
  ((busy += ${b/-/0}, slots += ${s:-0}, waiting += q, done_total += ${d:-0}))
  [ -n "$d" ] && [ -n "$r" ] && passes+=" $d:$r"
  [ "$pre" = cc:pool ] || p="local:$p"
  pool_rows+=("$q|$p|$cell|$d|$r")
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
body+="$burst_legend"

# --- machines, one pass over the runner rows ---------------------------------------------
# host|pool|state|name|site|repo|pr|seconds
# A slot is what cc:pool_slots counts: running, or idle and not withheld. A withheld runner
# is keyed <host>/<pool> withheld, so it prints after its pool's admitted ones.
declare -A ALL=() BUSY=() HB=() HS=() SITE=() DOWN=()
long=()
while IFS='|' read -r h p state name site repo pr secs; do
  [ "$site" = cloud ] && SITE[$h]=cloud
  [ -n "${SITE[$h]:-}" ] || SITE[$h]=local
  [ -n "${HS[$h]:-}" ] || HS[$h]=0 HB[$h]=0
  w="${WITHHELD[$name]:-}"
  case "$state" in
    running)
      [ -z "$w" ] || p+=" withheld"
      ALL[$h/$p]=$((${ALL[$h/$p]:-0} + 1)) BUSY[$h/$p]=$((${BUSY[$h/$p]:-0} + 1))
      ((HB[$h]++, HS[$h]++))
      ((${secs%.*} > LONG_RUN_SECS)) && long+=("${secs%.*}|$name ${repo:--}${pr:+#$pr}") ;;
    idle)
      [ -z "$w" ] || p+=" withheld"
      ALL[$h/$p]=$((${ALL[$h/$p]:-0} + 1))
      [ -n "$w" ] || ((HS[$h]++)) ;;
    offline | missing) DOWN[$h/$state]=$((${DOWN[$h/$state]:-0} + 1)) ;;
  esac
done < <(jq -r '.data.result[]
    | [.metric.host, .metric.pool, .metric.state, .metric.name, .metric.site, .metric.repo,
       .metric.pr, .value[1]]
    | map(. // "" | gsub("[|\n]"; " ")) | join("|")' <<< "$runners")

# busy|host|where|busy/slots|pools. A machine with no runner up is under DOWN instead.
# The workstation's local gates are a machine row of their own, busy of their open slots
# like the POOL table's local row.
machine_rows=()
for h in "${!HS[@]}"; do
  ((HS[$h] > 0 || HB[$h] > 0)) || continue
  pools=""
  while read -r key; do
    [[ "$key" == "$h/"* ]] && pools+=" ${key#*/} ${BUSY[$key]:-0}/${ALL[$key]}"
  done < <(printf '%s\n' "${!ALL[@]}" | sort)
  machine_rows+=("${HB[$h]}|$h|${SITE[$h]}|${HB[$h]}/${HS[$h]}|${pools# }")
done
for key in "${!V[@]}"; do
  [[ "$key" == cc:host_local_slots/* ]] || continue
  h="${key#*/}" b="${V[cc:host_local_busy/${key#*/}]:-0}" open="${V[cc:host_local_open_slots/${key#*/}]:-0}"
  s=$((b > open ? b : open))
  machine_rows+=("$b|$h|local|$b/$s|gates $b/$s")
done
if ((${#machine_rows[@]})); then
  mapfile -t machine_rows < <(printf '%s\n' "${machine_rows[@]}" | sort -t'|' -k1,1nr -k2,2)
  mw=7
  for row in "${machine_rows[@]}"; do
    IFS='|' read -r _ h _ <<< "$row"
    ((${#h} > mw)) && mw=${#h}
  done
  printf -v line "%-${mw}s %-5s %5s  %s" MACHINE WHERE BUSY POOLS
  body+=$'\n\n'"$line"
  for row in "${machine_rows[@]}"; do
    IFS='|' read -r _ h where bs pools <<< "$row"
    printf -v line "%-${mw}s %-5s %5s  %s" "$h" "$where" "$bs" "$pools"
    body+=$'\n'"$(pango_esc "$line")"
  done
fi

# --- local vs cloud: cc:site_* totals, each cloud machine by name, GitHub's runners -------
# A cloud host with no runner up (aws-burst-1 is kept stopped when idle) reads "off".
hosted="${V[cc:github_hosted_running/]:-0}"
if [ -n "${V[cc:site_slots/local]:-}${V[cc:site_slots/cloud]:-}" ]; then
  cloud_list=()
  while read -r h; do
    [ -n "$h" ] || continue
    if ((HS[$h] > 0 || HB[$h] > 0)); then cloud_list+=("$h ${HB[$h]}/${HS[$h]}"); else cloud_list+=("$h off"); fi
  done < <(for h in "${!SITE[@]}"; do [ "${SITE[$h]}" = cloud ] && echo "$h"; done | sort)
  ((hosted > 0)) && cloud_list+=("github-hosted $hosted")
  running="running: local ${V[cc:site_busy/local]:-0}/${V[cc:site_slots/local]:-0}  cloud $((${V[cc:site_busy/cloud]:-0} + hosted))"
  if ((${#cloud_list[@]})); then
    printf -v joined '%s, ' "${cloud_list[@]}"
    running+=" (${joined%, })"
  fi
else
  running="running: no cc:site_* series (recording rules not loaded?)"
fi

# Counted per machine and state: a roster slot that never registered is one line per box,
# not one per slot.
if ((${#DOWN[@]})); then
  body+=$'\n\n'"$(paint "$C_RED" DOWN:)"
  while read -r key; do
    body+=$'\n'"  $(pango_esc "${key%/*}  ${DOWN[$key]} ${key#*/}")"
  done < <(printf '%s\n' "${!DOWN[@]}" | sort)
fi

# Only the jobs past LONG_RUN_SECS, longest first, on one line: the full list is the board's.
if ((${#long[@]})); then
  line=""
  while IFS='|' read -r secs what; do
    line+=" $(pango_esc "$what") $(paint "$C_YEL" "$(prom_dur "$secs")"),"
  done < <(printf '%s\n' "${long[@]}" | sort -t'|' -k1,1nr)
  body+=$'\n\n'"long runs:${line%,}"
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
if [ "${V[exporter_up/]:-0}" != 1 ]; then
  status+=" $(paint "$C_RED" 'runner exporter missed its last scrape, runner rows may be missing'),"
elif [ "${V[rate_left/]:-}" = 0 ]; then
  status+=" $(paint "$C_RED" 'GitHub rate limit spent, runner jobs and history unread until it resets'),"
elif [ "${V[api_ok/]:-0}" != 1 ]; then
  status+=" $(paint "$C_RED" 'GitHub not answering the exporter, runner rows may be missing'),"
fi

label=CI
((level > 0)) && label="$(paint "${LEVEL_COLOUR[$level]}" CI)"
q="q$waiting"
((waiting > 0)) && q="$(paint "$C_YEL" "$q")"
# Finished in the last day, for the hover only, painted by the pass rate over all of them
# (each pool's ratio weighted by its finished count). The bar leaves it out: a rolling job
# count mixes housekeeping and light checks with the Unity gates and says nothing to act on.
finished="finished 24h: none reported"
if ((done_total > 0)); then
  ratio="$(awk -v ps="$passes" 'BEGIN { n = split(ps, a, " "); for (i = 1; i <= n; i++) { split(a[i], x, ":"); d += x[1]; p += x[1] * x[2] } if (d > 0) printf "%.4f", p / d }')"
  finished="finished 24h: $done_total"
  [ -z "$ratio" ] || finished+=", $(pass_cell "$ratio") passed"
fi

emit "$label $busy/$slots $q" \
  "<b>CI runners</b>  busy/slots, queued"$'\n'"ci:${status%,}"$'\n'"$running"$'\n'"$finished"$'\n'"<tt>$body</tt>" \
  "${LEVEL_CLASS[$level]}"
