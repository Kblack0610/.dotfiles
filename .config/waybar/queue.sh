#!/usr/bin/env bash
# Waybar module: the queue chip (custom/queue), whether agent work flows. The bar is "Q:27  D:126",
# items ready to start next and items shipped today (merged a PR), labels in the theme accent (pango.sh).
# It lays out hub-core's Queue and Done cards (`hub cards --json --figures`, sent retained as
# summary/cards by the fleet lease holder) and judges nothing itself: Q takes the Queue card's level
# colour, and the hover opens with the card's Flow rows, each a sentence in its level colour with its Do
# after the point (hub-core queue_verdict.rs, the lines the hub Queue tab draws). Then Up next (the rows
# of the card's own Up next list, then the board rows dispatch takes after them), In flight, Today and
# Room, and the time the card was built. The board rows and the drain are `hub bar --json` from
# summary/bar (summary_bar.sh). No summary/cards reads Q? in amber with why; a missing part reads -,
# never 0.

set -u
here="$(dirname "$(realpath "${BASH_SOURCE[0]}")")"
# shellcheck source=../../.local/lib/prom.sh
. "${PROM_LIB:-$here/../../.local/lib/prom.sh}" 2>/dev/null || . "$HOME/.local/lib/prom.sh"
# shellcheck source=pango.sh
. "$here/pango.sh"
# shellcheck source=summary_bar.sh
. "$here/summary_bar.sh"

now="${DISPATCH_NOW:-$(date +%s)}"
head="<b>Queue:</b>"
bar_caps
summary_read "$now" cards bar
# no_card <why>: the bar's Q? in amber, the hover why.
no_card() { emit "$(paint "$C_YEL" 'Q?')" "$head $(paint "$C_YEL" "$(pango_esc "$1")")" warn; exit 0; }
[ -n "$CARDS" ] || no_card "$CARDS_WHY"

# The two cards as lines: "level <lvl>" (the Queue card's), "pill <card>.<label> <lvl> <value>", "flow
# <lvl> <text> <do>" for each row under the Queue card's Flow head, "up <text> <sub>" for each row under
# its Up next head and "uptotal <n>" for the ready count in that head, each cut so its line fits, and
# "err <text>" for a row above every head, a source the card could not read. The Running and On a PR
# lists are the card's and the chip reads their counts as pills.
declare -A PV PL
flows=() ups=() errs=() qlevel='' uptotal=''
while IFS=$'\t' read -r kind a b c; do
  case "$kind" in
    level) qlevel="$a" ;;
    pill) PL[$a]="$b" PV[$a]="$c" ;;
    flow) flows+=("$a"$'\t'"$b"$'\t'"$c") ;;
    up) ups+=("$a"$'\t'"$b") ;;
    uptotal) uptotal="$a" ;;
    err) errs+=("$a") ;;
  esac
done < <(jq -r --argjson w "$BAR_WIDTH" "$BAR_JQ"'
  .sections[] | select(.id == "queue" or .id == "done") | .id as $id
  | (if $id == "queue" then "level\t\(.level)" else empty end),
    (.items[] | select(.kind == "pill") | "pill\t\($id).\(.label)\t\(.level)\t\(.value | clean)"),
    (if $id == "queue" then
      (reduce .items[] as $x ({h: null, o: []};
          if $x.kind == "text" then .h = $x.text
          elif $x.kind == "row" then .o += [{h: .h, r: $x}] else . end)
        | .o[] | .h as $h | .r | (.sub // "" | clean) as $do
        | if $h == null then "err\t\(.text | clean | fit($w - 24) | esc)"
          elif $h == "Flow" then
            "flow\t\(.level)\t\(.text | clean | fit([$w - 8 - (if $do == "" then 0 else ($do | length) + 2 end), 20] | max) | esc)\t\($do | esc)"
          elif ($h | startswith("Up next")) then
            "up\t\(.text | clean | fit([$w - 6 - ($do | length), 20] | max) | esc)\t\($do | esc)"
          else empty end),
      (.items[] | select(.kind == "text") | .text | capture("^Up next: (?<n>[0-9]+) ready") | "uptotal\t\(.n)")
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

# Up next: the ready count and its priorities, the card's rows in start order, then the cleared board
# rows dispatch would promote after them.
rest="$(p queue.Urgent) urgent, $(p queue.High) high"
[ -z "${PV[queue.On focus]:-}" ] || rest+="; $(paint "$C_YEL" "$(p 'queue.On focus') project(s) on focus, running sprints")"
tip+=$'\n\n'"<b>Up next</b>  $(p 'queue.On deck') ready ($rest)"
# The card's rows, as many as the bar channel's line cap leaves after what is above them and the lines
# below: +N more, the board, In flight, Today and its blank, Room, the as-of line and one spare.
used="$(wc -l <<< "$tip")"
room_lines=$((BAR_LINES - used - 8))
((room_lines < 0)) && room_lines=0
view=("${ups[@]:0:room_lines}")
shown=${#view[@]}
block=''
for u in "${view[@]}"; do
  IFS=$'\t' read -r what sub <<< "$u"
  block+="${block:+$'\n'}  $what${sub:+  $sub}"
done
[ -z "$block" ] || tip+=$'\n'"<tt>$block</tt>"
if [ -n "$uptotal" ] && ((uptotal > shown)); then
  tip+=$'\n'"+$((uptotal - shown)) more ready: click for the Queue tab"
fi
if [ -n "$BAR" ]; then
  tip+="$(jq -r --argjson width "$BAR_WIDTH" "$BAR_JQ"'
    (.candidates | length) as $c
    | if $c > 0 then ["Then from the board: " + (.candidates | map("\(.key) \(.title | clean)"
          | fit((($width - 21) / $c | floor) - 2)) | join(", ") | esc)] else [] end
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

# Room: the sessions and load parts, each number in its part's colour, - for a part the card lacks;
# no Sessions part, no pass read.
room() {
  local v="${PV[queue.$1]:-}"
  if [ -z "$v" ]; then printf -; else printf '%s %s' "$(hue "${PL[queue.$1]}" "${v%% *}")" "${v#* }"; fi
}
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
