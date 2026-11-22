#!/usr/bin/env bash
# Waybar module: the queue chip (custom/queue), whether agent work flows. The bar is "Q:27  D:126",
# items ready to start next and items shipped today (merged a PR), labels in the theme accent (pango.sh).
# Q takes the level colour: red for queue-starved, a failed runner or no pass in PASS_LATE_SECS; amber
# for a hold, a BLOCKED pass, flapping, could_start or an unhandled shepherd line.
# The hover opens with one sentence, "flowing" or the worst exception and what it blocks, with its knob
# after the point (DO below); the urgent item a hold keeps waiting and each other exception follow, one
# line each. Then Up next (the ready items by name, then the board rows dispatch takes after them), In
# flight, Today and Room. Gate internals (low water, self-heal, the shepherd, pass ages) show only as
# an exception; their homes are listed in .local/src/docs/dashboards.md. A second machine sending
# summary/dispatch is the health chip's agents queue_senders row (home-config), not a line here.
# Counts are summary/dispatch, summary/cards (Q, D and the Today figures, `hub cards --json --figures`),
# the fleet_dispatch runner, the queue-starved watch and summary/shepherd on
# Prometheus (live topics only), so the laptop thin client reads the same; item names, the board rows
# and the drain are `hub bar --json` from the summary/bar topic (summary_bar.sh). A missing topic is one
# amber line and the counts still show; Prometheus unreadable reads ? in amber, a missing number -.

set -u
here="$(dirname "$(realpath "${BASH_SOURCE[0]}")")"
# shellcheck source=../../.local/lib/prom.sh
. "${PROM_LIB:-$here/../../.local/lib/prom.sh}" 2>/dev/null || . "$HOME/.local/lib/prom.sh"
# shellcheck source=pango.sh
. "$here/pango.sh"
# shellcheck source=summary_bar.sh
. "$here/summary_bar.sh"

# fleet-dispatch runs every 15 minutes; three missed passes is a stopped timer, not a slow one.
PASS_LATE_SECS=2700
# claude-acct-usage.timer writes the accounts' textfile every 15 minutes; three missed is stale.
ROOM_LATE_SECS=2700
# Ready items named by row; the rest are one "+N more ready" line and the hub Queue tab (the click).
UP_NEXT_ROWS=5

# The knob for each exception: what shows or fixes its cause, said after the point.
declare -A DO=(
  [slots]="Run fleet-dispatch headroom"
  [load]="See the fleet-pace skill"
  [assess]="Run fleet-assess"
  [account]="Run claude-acct status"
  [other]="Run fleet-dispatch headroom"
  [blocked]="Run fleet-dispatch run --dry-run"
  [starved]="Run fleet-dispatch run --dry-run"
  [flapping]="Run agentctl logs fleet-dispatch"
  [could]="Run fleet-dispatch headroom"
  [failed]="Run agentctl logs fleet-dispatch"
  [late]="Run systemctl --user status agentctl-fleet-dispatch.timer"
  [shepherd]="Use the shepherd skill, triage"
  [nofeed]="Run systemctl --user status agent-mqtt-publish.timer"
)

now="${DISPATCH_NOW:-$(date +%s)}"
head="<b>Queue:</b>"
# The accounts' room verdicts (claude-acct textfile) ride the same query, only from a textfile
# written lately: they name which account refuses and why when the account gate holds dispatch.
q='({__name__=~"mqtt_.+", topic=~"agents_.+_(summary_dispatch|summary_cards|runner_fleet_dispatch|watch_queue_starved|summary_shepherd)"} and on (topic) cc:agents_topic_live)'
q+=" or (claude_account_room_reason and on (instance) (time() - node_textfile_mtime_seconds{file=~\".*/claude_acct.prom\"} < $ROOM_LATE_SECS))"

if ! raw="$(prom_q "$q")"; then
  emit "$(paint "$C_YEL" 'Q?')" "$head $(paint "$C_YEL" "cannot read $PROM_URL")" warn
  exit 0
fi

# One object: kind.key -> value, kind being dispatch, runner, watch or shepherd. The source is the
# host whose dispatch pass ran last: only the lease holder runs a pass and sends summary/dispatch, so
# its series alone count; with no pass on record anywhere, every host's count by their max. A peer with
# a frozen store clone once sent 622 queued (ar-4306); its series are ignored here.
# Every value is a count, a 0/1 or an epoch, so it is floored: Prometheus may write 1 as 1.0.
v="$(jq -c '{summary_dispatch: "dispatch", summary_cards: "cards", summary_shepherd: "shepherd", runner_fleet_dispatch: "runner",
      watch_queue_starved: "watch"} as $kind
    | [.data.result[] | select(.metric.topic) | (.metric.topic | capture("^agents_(?<h>.+)_(?<t>"
        + ($kind | keys | join("|")) + ")$")) as $c
      | {h: $c.h, k: ($kind[$c.t] + "." + (.metric.__name__ | ltrimstr("mqtt_"))), v: (.value[1] | tonumber | floor)}] as $all
    | ([$all[] | select(.k == "dispatch.last_pass_epoch")] | max_by(.v) | .h) as $src
    | ($all | map(select($src == null or .h == $src)) | group_by(.k)
        | map({key: .[0].k, value: (map(.v) | max)}) | from_entries)' <<< "$raw")"
get() { jq -r --arg k "$1" '.[$k] // empty' <<< "$v"; }
d() { local x; x="$(get "dispatch.$1")"; printf '%s' "${x:--}"; }
n0() { local x; x="$(get "dispatch.$1")"; printf '%s' "${x:-0}"; }
# cf <figure>: a hub-core card figure (`hub cards --json --figures`, sent as summary/cards), - when absent.
cf() { local x; x="$(get "cards.figures_$1")"; printf '%s' "${x:--}"; }

# flag <level> <what> <do key>: an exception. It raises the chip to its level; the worst one is the
# head sentence, the rest follow it, each with its knob.
level=0 ex_lvl=() ex_what=() ex_do=()
flag() { ((level < $1)) && level=$1; ex_lvl+=("$1"); ex_what+=("$2"); ex_do+=("${DO[$3]}"); }

bar_caps
bar_read "$now"
ready="$(get dispatch.runnable)" starved="$(get watch.tripped)" held="$(get dispatch.held_s)"
blocked="$(get runner.blocked)" gate='' paused='' reasons=''
if [ -z "$ready" ]; then
  flag 1 "no dispatch numbers on the feed" nofeed
else
  # The one gate that stopped the last pass, if any, in words with its numbers.
  for k in slots load account assess other; do
    [ "$(get "dispatch.room_held_$k")" = 1 ] || continue
    gate=$k
    case $k in
      slots) paused="the fleet is at its session target of $(d room_max_live)" ;;
      load) paused="load $(d room_load) is over its cap of $(d room_load_cap)" ;;
      assess) paused="the fleet-assess check says the machine is too busy" ;;
      account)
        reasons="$(jq -r '[.data.result[] | select(.metric.__name__ == "claude_account_room_reason" and (.metric.kind // "claude") == "claude") | .metric]
            | group_by(.account) | .[] | "\(.[0].account) \(map(.reason) | unique | join("+"))"' <<< "$raw")"
        paused="no account has room" ;;
      other) paused="a gate holds it" ;;
    esac
  done

  # A hold is the head: how long and what it blocks. queue-starved trips on a hold (its watch reads the
  # runner's held_since), so while one stands the starve is the same cause: one red sentence.
  if ((${held:-0} > 0)); then
    p="${paused:-the last pass left ready work waiting}"
    flag $(( starved == 1 ? 2 : 1 )) "dispatch paused $(prom_dur "$held"): $p" "${gate:-blocked}"
  elif [ "$starved" = 1 ]; then
    flag 2 "an urgent or high item sat ready too long, and nothing started it" starved
  elif [ "$blocked" = 1 ]; then
    flag 1 "the last pass started nothing${paused:+: $paused}" "${gate:-blocked}"
  fi
  [ "$(get runner.failed)" = 1 ] && flag 2 "the fleet-dispatch runner failed" failed
  pass="$(get dispatch.last_pass_epoch)"
  if [ -z "$pass" ]; then flag 2 "no dispatch pass on record" late
  elif ((now - pass > PASS_LATE_SECS)); then flag 2 "no dispatch pass in $(prom_dur $((now - pass)))" late; fi
  flapping="$(n0 flapping_items)" could="$(n0 could_start)"
  ((flapping > 0)) && flag 1 "$flapping item(s) flapping: a writer undoes reap's moves" flapping
  ((could > 0)) && flag 1 "$could more could start: a limit holds them, not the machine" could
fi
s_unh="$(get shepherd.unhandled)"
((${s_unh:-0} > 0)) && flag 1 "$s_unh shepherd due line(s) unhandled" shepherd

# The head sentence and the lines under it: the urgent item a hold or a starve keeps waiting, then the
# other exceptions, then what the hover could not read.
if ((${#ex_lvl[@]} == 0)); then
  tip="$head $(paint "$C_GRN" flowing)."
  w=-1
else
  w=0
  for i in "${!ex_lvl[@]}"; do ((ex_lvl[i] > ex_lvl[w])) && w=$i; done
  tip="$head $(paint "${LEVEL_COLOUR[${ex_lvl[w]}]}" "${ex_what[w]}.") ${ex_do[w]}."
fi
if [ -n "$ready" ] && { ((${held:-0} > 0)) || [ "$starved" = 1 ] || [ "$blocked" = 1 ]; }; then
  wait_c="$C_YEL"; [ "$starved" = 1 ] && wait_c="$C_RED"
  line=''
  [ -z "$BAR" ] || line="$(jq -r --argjson w "$BAR_WIDTH" --arg starved "$starved" "$BAR_JQ"'
    [.ready.items[] | select(.priority == "urgent")] + (if $starved == "1" then [.ready.items[] | select(.priority == "high")] else [] end)
    | first // empty
    | "\(.priority | ascii_upcase[:1] + .[1:]) item waiting \(.ready_min | mins): "
      + (what | clean)
    | fit($w) | esc' <<< "$BAR")"
  us="$(get dispatch.oldest_urgent_s)"
  [ -n "$line" ] || [ -z "$us" ] || line="Urgent item waiting $(prom_dur "$us")"
  [ -z "$line" ] || tip+=$'\n'"$(paint "$wait_c" "$line")"
fi
for i in "${!ex_lvl[@]}"; do
  ((i == w)) && continue
  what="${ex_what[i]}"
  tip+=$'\n'"$(paint "${LEVEL_COLOUR[${ex_lvl[i]}]}" "${what^}.") ${ex_do[i]}."
done
while IFS= read -r l; do tip+=$'\n'"$l"; done < <(bar_detail item)

if [ -n "$ready" ]; then
  # Up next: the ready count and its priorities (Q), the first items by name in start order, then the
  # cleared board rows dispatch would promote after them.
  rest="$(d runnable_urgent) urgent, $(d runnable_high) high"
  fn="$(get dispatch.focus_projects)"
  ((${fn:-0} > 0)) && rest+="; $(paint "$C_YEL" "$fn focus project(s) first")"
  tip+=$'\n\n'"<b>Up next</b>  $(cf queue_on_deck) ready ($rest)"
  if [ -n "$BAR" ]; then
    # The rows get the cap less what is above them and the lines below: +N more, the board, In flight,
    # Today and its blank, Room, Paused, one spare, and a line per account with no room.
    used="$(wc -l <<< "$tip")"
    tip+="$(jq -r --argjson rows "$UP_NEXT_ROWS" --argjson lines $((BAR_LINES - used - 8 - $(grep -c . <<< "$reasons"))) \
      --argjson width "$BAR_WIDTH" "$BAR_JQ"'
      ([$rows, $lines] | min | [., 0] | max) as $n
      | .ready.items[:$n] as $shown | (.candidates | length) as $c
      | ([$shown[].project | clean | length] + [0] | max | [., 13] | min) as $pw
      | ($width - 2 - 6 - 2 - $pw - 2 - 2 - 6) as $tw
      | def row: "  " + (.priority | pad(6)) + "  " + (.project | clean | fit($pw) | pad($pw)) + "  "
          + (what | clean | fit($tw) | pad($tw)) + "  " + (.ready_min | mins) | sub(" +$"; "") | esc;
        (if ($shown | length) > 0 then ["<tt>" + ($shown | map(row) | join("\n")) + "</tt>"] else [] end)
        + (if .ready.total > ($shown | length) then ["+\(.ready.total - ($shown | length)) more ready: click for the Queue tab"] else [] end)
        + (if $c > 0 then ["Then from the board: " + (.candidates | map("\(.key) \(.title | clean)"
            | fit((($width - 21) / $c | floor) - 2)) | join(", ") | esc)] else [] end)
      | map("\n" + .) | join("")' <<< "$BAR")"
  fi
  tip+=$'\n'"<b>In flight</b>  $(d running) running, $(d review) on a PR, $(d waiting) waiting on you (sessions chip)"

  # Today: shipped and closed, failed in 24h (amber above 0), and whether the queue shrinks or grows,
  # hub-core's verdict (flow::drain) from summary/bar: shrinking green, growing amber.
  fl="$(d failed_24h)"
  [[ "$fl" =~ ^[0-9]+$ ]] && ((fl > 0)) && fl="$(paint "$C_YEL" "$fl")"
  today="$(cf done_shipped) shipped (merged a PR), $(cf done_checks) checks closed with no merge, $fl failed in 24h"
  drain="$([ -z "$BAR" ] || jq -r '.drain // empty' <<< "$BAR")"
  case "$drain" in
    *shrinking) drain="$(paint "$C_GRN" "$drain")" ;;
    *growing) drain="$(paint "$C_YEL" "$drain")" ;;
  esac
  [ -n "$drain" ] && today+="; queue $drain"
  tip+=$'\n\n'"<b>Today</b>  $today"

  # Room: each number in its own colour, green with room, amber near its limit, red past it. Full run
  # units are amber at most: the gates, not the count, decide when the machine is full.
  if [ -n "$(get dispatch.room_max_live)" ]; then
    units=$(n0 room_live_runs) cap=$(n0 room_max_live) load=$(n0 room_load) lcap=$(n0 room_load_cap)
    ul=0; ((units >= cap)) && ul=1
    ll=0; ((load * 100 >= lcap * 80)) && ll=1; ((load > lcap)) && ll=2
    tip+=$'\n'"<b>Room</b>  $(paint "${LEVEL_COLOUR[$ul]}" "$(d room_total_live)") of $cap sessions, load $(paint "${LEVEL_COLOUR[$ll]}" "$load") of $lcap"
  else
    tip+=$'\n'"<b>Room</b>  - (no headroom from a pass in the last 45m)"
  fi
  # A gate that paused the pass while no hold or BLOCKED sentence says so.
  if [ -n "$paused" ] && ((${held:-0} == 0)) && [ "$blocked" != 1 ]; then
    tip+=$'\n'"<b>Paused</b>  $(paint "$C_YEL" "$paused")"
  fi
  [ -z "$reasons" ] || while read -r acct why; do
    tip+=$'\n'"  $(pango_esc "$acct"): no room, $(pango_esc "$why")"
  done <<< "$reasons"
fi

# The bar: two totals behind their labels, and only Q takes the chip's level colour; a number the
# feed lacks reads -. Both are hub-core's own figures (`hub cards --json --figures`, sent as
# summary/cards): Q the queue card's On deck part, D the done card's Shipped part.
qn="$(cf queue_on_deck)"
((level > 0)) && qn="$(paint "${LEVEL_COLOUR[$level]}" "$qn")"
lc="$(label_colour)"
text="$(paint "$lc" Q:)$qn  $(paint "$lc" D:)$(cf done_shipped)"

emit "$text" "$tip" "${LEVEL_CLASS[$level]}"
