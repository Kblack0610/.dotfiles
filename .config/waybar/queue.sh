#!/usr/bin/env bash
# Waybar module: the queue chip (custom/queue), whether agent work flows. The bar is "Q:27  D:126",
# items ready to start next and items shipped today (merged a PR), labels in the theme accent (pango.sh).
# It lays out hub-core's Queue and Done cards (`hub cards --json --figures`, sent retained as
# summary/cards by the fleet lease holder) and judges nothing itself: Q takes the Queue card's level
# colour, and the hover opens with the card's Flow rows, each a sentence in its level colour with its Do
# after the point (hub-core queue_verdict.rs, the lines the hub Queue tab draws). Then Up next (the ready
# items by name, then the board rows dispatch takes after them), In flight, Today and Room, and the time
# the card was built. Item names, the board rows and the drain are `hub bar --json` from summary/bar
# (summary_bar.sh). No summary/cards reads Q? in amber with why; a missing part reads -, never 0.

set -u
here="$(dirname "$(realpath "${BASH_SOURCE[0]}")")"
# shellcheck source=../../.local/lib/prom.sh
. "${PROM_LIB:-$here/../../.local/lib/prom.sh}" 2>/dev/null || . "$HOME/.local/lib/prom.sh"
# shellcheck source=pango.sh
. "$here/pango.sh"
# shellcheck source=summary_bar.sh
. "$here/summary_bar.sh"

# Ready items named by row; the rest are one "+N more ready" line and the hub Queue tab (the click).
UP_NEXT_ROWS=5

now="${DISPATCH_NOW:-$(date +%s)}"
head="<b>Queue:</b>"
bar_caps
summary_read "$now" cards bar
# no_card <why>: the bar's Q? in amber, the hover why.
no_card() { emit "$(paint "$C_YEL" 'Q?')" "$head $(paint "$C_YEL" "$(pango_esc "$1")")" warn; exit 0; }
[ -n "$CARDS" ] || no_card "$CARDS_WHY"

# The two cards as lines: "level <lvl>" (the Queue card's), "pill <card>.<label> <lvl> <value>", "flow
# <lvl> <text> <do>" for each row under the Queue card's Flow head, each cut so its line fits, and "err
# <text>" for a row above it, a source the card could not read.
declare -A PV PL
flows=() errs=() qlevel=''
while IFS=$'\t' read -r kind a b c; do
  case "$kind" in
    level) qlevel="$a" ;;
    pill) PL[$a]="$b" PV[$a]="$c" ;;
    flow) flows+=("$a"$'\t'"$b"$'\t'"$c") ;;
    err) errs+=("$a") ;;
  esac
done < <(jq -r --argjson w "$BAR_WIDTH" "$BAR_JQ"'
  .sections[] | select(.id == "queue" or .id == "done") | .id as $id
  | (if $id == "queue" then "level\t\(.level)" else empty end),
    (.items[] | select(.kind == "pill") | "pill\t\($id).\(.label)\t\(.level)\t\(.value | clean)"),
    (if $id == "queue" then
      (.items | (map(.kind == "text" and .text == "Flow") | index(true)) as $f
        | to_entries[] | select(.value.kind == "row") | .key as $k | .value
        | (.sub // "" | clean) as $do
        | if $f != null and $k > $f then
            "flow\t\(.level)\t\(.text | clean | fit($w - 8 - (if $do == "" then 0 else ($do | length) + 2 end)) | esc)\t\($do | esc)"
          else "err\t\(.text | clean | fit($w - 24) | esc)" end)
    else empty end)' <<< "$CARDS")
[ -n "$qlevel" ] || no_card "summary/cards has no Queue card"
# p <card>.<label>: a part's value, - when the card has none. LVL: a level's LEVEL_COLOUR index.
p() { printf '%s' "${PV[$1]:--}"; }
declare -A LVL=([ok]=0 [warn]=1 [bad]=2)
# hue <level> <text>: the text in its level colour; a neutral level is plain.
hue() { local i="${LVL[$1]:--1}"; if ((i < 0)); then printf '%s' "$2"; else paint "${LEVEL_COLOUR[$i]}" "$2"; fi; }

# The Flow rows: the first after "Queue:", the rest a line each, then what the hover could not read.
tip="$head"
if ((${#flows[@]} == 0)); then
  tip+=" $(paint "$C_YEL" "No flow verdict on summary/cards.")"
fi
for i in "${!flows[@]}"; do
  IFS=$'\t' read -r lvl what act <<< "${flows[i]}"
  line="$(hue "$lvl" "$what.")${act:+ $act.}"
  if ((i == 0)); then tip+=" $line"; else tip+=$'\n'"$line"; fi
done
for e in "${errs[@]}"; do tip+=$'\n'"$(paint "$C_YEL" "Queue card incomplete: $e")"; done
while IFS= read -r l; do tip+=$'\n'"$l"; done < <(bar_detail item)

# Up next: the ready count and its priorities, the first items by name in start order, then the cleared
# board rows dispatch would promote after them.
rest="$(p queue.Urgent) urgent, $(p queue.High) high"
[ -z "${PV[queue.Focus first]:-}" ] || rest+="; $(paint "$C_YEL" "$(p 'queue.Focus first') focus project(s) first")"
tip+=$'\n\n'"<b>Up next</b>  $(p 'queue.On deck') ready ($rest)"
if [ -n "$BAR" ]; then
  # The rows get the cap less what is above them and the lines below: +N more, the board, In flight,
  # Today and its blank, Room, the as-of line and one spare.
  used="$(wc -l <<< "$tip")"
  tip+="$(jq -r --argjson rows "$UP_NEXT_ROWS" --argjson lines $((BAR_LINES - used - 8)) \
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
tip+=$'\n'"<b>In flight</b>  $(p queue.Running) running, $(p 'queue.On a PR') on a PR"

# Today: shipped and closed (the Done card), failed in 24h in its level colour, and whether the queue
# shrinks or grows, hub-core's verdict (flow::drain) from summary/bar: shrinking green, growing amber.
today="$(p done.Shipped) shipped (merged a PR), $(p done.Checks) checks closed with no merge"
today+=", $(hue "${PL[queue.Failed 24h]:-neutral}" "$(p 'queue.Failed 24h')") failed in 24h"
drain="$([ -z "$BAR" ] || jq -r '.drain // empty' <<< "$BAR")"
case "$drain" in
  *shrinking) drain="$(paint "$C_GRN" "$drain")" ;;
  *growing) drain="$(paint "$C_YEL" "$drain")" ;;
esac
[ -n "$drain" ] && today+="; queue $drain"
tip+=$'\n\n'"<b>Today</b>  $today"

# Room: the sessions and load parts, each number in its part's colour; no parts, no pass read.
room() { local v="${PV[queue.$1]}"; printf '%s %s' "$(hue "${PL[queue.$1]}" "${v%% *}")" "${v#* }"; }
if [ -n "${PV[queue.Sessions]:-}" ]; then
  tip+=$'\n'"<b>Room</b>  $(room Sessions) sessions, load $(room Load)"
else
  tip+=$'\n'"<b>Room</b>  - (the Queue card has no room from a dispatch pass)"
fi
tip+=$'\n'"As of $(date -d "@$CARDS_AT" +%H:%M), as the hub Queue tab read it then."

# The bar: two totals behind their labels, and only Q takes the Queue card's level colour.
level="${LVL[$qlevel]:-0}"
qn="$(p 'queue.On deck')"
((level > 0)) && qn="$(paint "${LEVEL_COLOUR[$level]}" "$qn")"
lc="$(label_colour)"
text="$(paint "$lc" Q:)$qn  $(paint "$lc" D:)$(p done.Shipped)"

emit "$text" "$tip" "${LEVEL_CLASS[$level]}"
