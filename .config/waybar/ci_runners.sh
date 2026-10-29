#!/usr/bin/env bash
# Waybar module: CI runners. The bar is busy of slots across the GitHub self-hosted pools,
# then the queued job count. The hover lists each pool's queue and oldest wait, then each
# machine's runners with the job every busy one is on, then any runner that is down, then
# the workstation's local Unity gates.
#
# Red when the exporter cannot reach GitHub, a runner is offline or missing, or Prometheus
# cannot be read. A failed read shows `CI ?`, never the last numbers, so a dead source
# cannot leave a calm bar up.
#
# Forgejo Actions runners export no metrics yet, so they are not here.

set -u
# shellcheck source=prom.sh
. "$(dirname "$(realpath "${BASH_SOURCE[0]}")")/prom.sh"

# A job past an hour shows amber: playground ci.md calls a gate that long a bug to fix, not
# a wait. command-center.sh paints the same line.
LONG_JOB=3600

fail() { emit "$(paint "$C_RED" 'CI ?')" "CI runners: $1" critical; exit 0; }

cc="$(prom_q '{__name__=~"cc:pool_(slots|busy|waiting|oldest_wait_seconds)|cc:host_local_(slots|busy|queued)"}')" \
  && runners="$(prom_q "$W (github_runner_state)")" \
  && api="$(prom_q 'min(github_runner_exporter_api_ok)')" \
  || fail "cannot read $PROM_URL"

# name/key|value, key = pool or host. Pipe-separated: tab is IFS whitespace and would
# collapse an empty field.
declare -A V
while IFS='|' read -r key val; do
  [ -n "$key" ] && V["$key"]="${val%.*}"
done < <(jq -r '.data.result[]
    | [(.metric.__name__ + "/" + (.metric.pool // .metric.host // "")), .value[1]] | join("|")' <<< "$cc")

mapfile -t POOLS < <(jq -r '[.data.result[] | select(.metric.__name__ == "cc:pool_slots") | .metric.pool] | unique[]' <<< "$cc")
((${#POOLS[@]})) || fail "no cc:pool_* series (recording rules not loaded?)"

api_ok="$(jq -r '.data.result[0].value[1] // "0"' <<< "$api")"

busy=0 slots=0 waiting=0
for p in "${POOLS[@]}"; do
  ((busy += ${V[cc:pool_busy/$p]:-0}, slots += ${V[cc:pool_slots/$p]:-0}, waiting += ${V[cc:pool_waiting/$p]:-0}))
done

# host|pool|state|name|repo|pr|workflow|job_name|seconds, sorted by host then pool.
mapfile -t RUNNERS < <(jq -r '.data.result[]
    | [.metric.host, .metric.pool, .metric.state, .metric.name, .metric.repo, .metric.pr,
       .metric.workflow, .metric.job_name, .value[1]]
    | map(. // "" | gsub("[|\n]"; " ")) | join("|")' <<< "$runners" | sort)

# --- pools, longest queue first ----------------------------------------------------------
pool_rows="$(for p in "${POOLS[@]}"; do printf '%s %s\n' "${V[cc:pool_waiting/$p]:-0}" "$p"; done | sort -k1,1nr -k2)"
body="$(printf '%-10s %6s %6s  %s' POOL BUSY QUEUE OLDEST)"
while read -r q p; do
  qs="$(printf '%6s' "$q")"
  ((q > 0)) && qs="$(paint "$C_YEL" "$qs")"
  oldest=-
  ((q > 0)) && oldest="$(fmt_dur "${V[cc:pool_oldest_wait_seconds/$p]:-}")"
  body+=$'\n'"$(printf '%-10s %6s %s  %s' "$p" "${V[cc:pool_busy/$p]:-0}/${V[cc:pool_slots/$p]:-0}" "$qs" "$oldest")"
done <<< "$pool_rows"

# --- runners by machine ------------------------------------------------------------------
declare -A HOST_POOL_BUSY HOST_POOL_ALL
hosts=() down=() offline=0
for r in "${RUNNERS[@]}"; do
  IFS='|' read -r h p state name _ <<< "$r"
  [[ " ${hosts[*]} " == *" $h "* ]] || hosts+=("$h")
  HOST_POOL_ALL[$h/$p]=$((${HOST_POOL_ALL[$h/$p]:-0} + 1))
  [ "$state" = running ] && HOST_POOL_BUSY[$h/$p]=$((${HOST_POOL_BUSY[$h/$p]:-0} + 1))
  case "$state" in running | idle) ;; *) down+=("$name ($h, $state)"); offline=$((offline + 1)) ;; esac
done

((${#hosts[@]})) && body+=$'\n'
for h in "${hosts[@]}"; do
  line="$h "
  for key in $(printf '%s\n' "${!HOST_POOL_ALL[@]}" | grep "^$h/" | sort); do
    line+=" ${key#*/} ${HOST_POOL_BUSY[$key]:-0}/${HOST_POOL_ALL[$key]}"
  done
  body+=$'\n'"<b>$(pango_esc "$line")</b>"
  for r in "${RUNNERS[@]}"; do
    IFS='|' read -r rh _ state name repo pr workflow job secs <<< "$r"
    [ "$rh" = "$h" ] && [ "$state" = running ] || continue
    where="${repo:--}"
    [ -n "$pr" ] && where+="#$pr"
    what="${workflow:+$workflow: }$job"
    t="$(fmt_dur "$secs")"
    ((${secs%.*} > LONG_JOB)) && t="$(paint "$C_YEL" "$t")"
    body+=$'\n'"  $(pango_esc "$name  $where  $what")  $t"
  done
done

if ((${#down[@]})); then
  body+=$'\n\n'"$(paint "$C_RED" DOWN:)"
  for d in "${down[@]}"; do body+=$'\n'"  $(pango_esc "$d")"; done
fi

# --- the workstation's local Unity gates (not GitHub runners, same machine pressure) -----
for key in "${!V[@]}"; do
  [[ "$key" == cc:host_local_slots/* ]] || continue
  h="${key#*/}"
  body+=$'\n\n'"$(printf 'local gates (%s)  %s/%s  q%s' "$h" "${V[cc:host_local_busy/$h]:-0}" "${V[$key]}" "${V[cc:host_local_queued/$h]:-0}")"
done

# --- bar -----------------------------------------------------------------------------------
class=ok label="CI"
((waiting > 0)) && class=warn
if [ "$api_ok" != 1 ] || ((offline > 0)); then
  class=critical
  label="$(paint "$C_RED" CI)"
fi
[ "$api_ok" = 1 ] || body="$(paint "$C_RED" 'exporter cannot reach GitHub: these numbers may be old')"$'\n'"$body"
text="$label $busy/$slots"
if ((waiting > 0)); then
  text+=" $(paint "$C_YEL" "q$waiting")"
else
  text+=" q0"
fi

emit "$text" "<b>CI runners</b>  busy/slots, queued"$'\n'"<tt>$body</tt>" "$class"
