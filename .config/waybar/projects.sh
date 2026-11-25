#!/usr/bin/env bash
# Waybar module: the projects chip (custom/projects), every lab project's progress at a glance.
# The bar is the icon, how many projects have work in flight (a session running or an ask
# waiting), B: with the agent board's open rows (amber when the board grew over 7 days) and S: with
# the running sprint, its version and delivered/committed (absent with none, +N past one); the
# hover leads with one line per running sprint, then the projects in flight, each with its running
# work by category, then one line naming the projects not running, then the Board: its total and
# 7-day flow, and each project's rows on it with its 7-day net.
#
# It computes nothing: `hub projects --json` is hub-core's join (projects::gather), the same cards
# the hub Projects tab, agent-web and the phone read, with the open window already scored, and
# its `figures` are the Projects card's (in flight, the project count, sprints), which hub drops
# on a partial read, so those then read ? and -. The board total is hub's `board_open` (the feed's
# `totals.agent`, the Projects tab's Board count) and a project's rows its `agent_tiers.board`; an
# unread feed reads B:? in amber. hub unreadable reads ? in amber.

set -u
here="$(dirname "$(realpath "${BASH_SOURCE[0]}")")"
# shellcheck source=pango.sh
. "$here/pango.sh"

HUB="${HUB:-$HOME/.local/bin/hub}"
# nf-fa-tasks, written as an escape so an editor cannot strip it.
ICON=$'\uf0ae'
title="<b>Projects</b>"

unknown() {
  emit "$(paint "$C_YEL" "$ICON ?")" "$title"$'\n'"$(pango_esc "$1")" warn
  exit 0
}

raw="$("$HUB" projects --json 2>&1)" || unknown "hub projects failed: ${raw:0:200}"
jq -e '.cards | type == "array"' <<< "$raw" > /dev/null 2>&1 || unknown "hub projects: not JSON"

# The hover body: one row per project in flight (running or waiting), in hub's order, with its
# counts and, when it is due (on track, at risk, late), its state in its hue and its window; then one line of its
# running work by category, the system of each item's epic (hub's `running_areas`, `no epic`
# dim), the top AREAS and +N past them. A due project with nothing in flight keeps a row, so a
# late release never hides, window or not. The rest are one line of names, by stage. Names are escaped
# here, colours come from pango.sh.
AREAS=4
body="$(jq -r --arg g "$C_GRN" --arg y "$C_YEL" --arg r "$C_RED" --arg d "$C_DIM" --argjson top "$AREAS" '
  def esc: gsub("&"; "&amp;") | gsub("<"; "&lt;") | gsub(">"; "&gt;");
  def paint($c): "<span color=\"\($c)\">\(.)</span>";
  def pad($n): . + (" " * ([$n - length, 0] | max));
  def rank: {"prod": 0, "beta": 1, "alpha": 2, "dev": 3, "draft": 4}[.stage] // 5;
  # hub_core::projects::state, painted by its state_level; flow and parked have none.
  def hue: {"ok": $g, "warn": $y, "bad": $r}[.state_level // ""] // $d;
  # An unread queue states no card (hub_core::projects::build): a dash, not a blank.
  def st: if (.state // "") == "" then "-" else .state end;
  # A release state (hub_core::projects::state): late or at risk can come from the target day
  # with no window, so a row shows it whenever the card is due, not only with a window.
  def due: .window != null or (.state | IN("on track", "at risk", "late"));
  def run: if (.running | length) > 0 then "\(.running | length) running" else "" end;
  def wait: if .waiting > 0 then "\(.waiting) waiting" else "" end;
  # A count painted, then padded outside its span so a row ends without trailing spaces.
  def cell($c; $n): (if . == "" then "" else paint($c) end) + (" " * ([$n - length, 0] | max));
  def areas: (.running_areas // []) as $a
    | ($a | map(select(.area != "no epic"))) as $sys
    | [ ($sys[:$top][] | "\(.area | esc) \(.n)"),
        (($sys | length) - $top | select(. > 0) | "+\(.) more"),
        ($a[] | select(.area == "no epic") | "no epic \(.n)" | paint($d)) ] | join(", ");
  .cards as $all
  | [$all[] | select(.in_flight or due)] as $shown
  | ([$shown[].name | esc | length] | max // 0) as $w
  | ([$shown[] | run | length] | max // 0) as $rw
  | ([$shown[] | wait | length] | max // 0) as $ww
  | ($shown[] | ([(.name | esc | pad($w)),
        # A column no row fills (nothing waiting anywhere) is left out, not drawn as a gap.
        (if $rw > 0 then run | cell($g; $rw) else empty end),
        (if $ww > 0 then wait | cell($y; $ww) else empty end),
        (if due then (hue as $h | st | paint($h)) + " " + (.window_says | esc) else "" end)]
      | join("  ") | sub(" +$"; "")),
      (areas | select(. != "") | "  " + .)),
    ([$all[] | select((.in_flight or due) | not)] | sort_by([rank, .name]) | map(.name | esc)) as $rest
    | if ($rest | length) > 0
      then "Not running: " + ($rest[:4] | join(", ")) + (if ($rest | length) > 4 then ", +\(($rest | length) - 4)" else "" end)
      else empty end,
    (.errors[]? | "error: \(esc)" | paint($y))
' <<< "$raw")"

# Running sprints (a sprint lock holds the open window, hub's `sprint_says`): one line each, above
# the project rows. The bar shows one itself after S:, `S:v0.5.4 10/15` from its card's window
# (sprint_says implies the window), an at-risk or late one first and then amber, and +N past one
# (only #prio/focus projects run sprints, so one is the normal case).
sprints="$(jq -r --arg g "$C_GRN" --arg y "$C_YEL" --arg r "$C_RED" --arg d "$C_DIM" '
  def esc: gsub("&"; "&amp;") | gsub("<"; "&lt;") | gsub(">"; "&gt;");
  def st: if (.state // "") == "" then "-" else .state end;
  .cards[] | select(.sprint_says != null)
  | ({"ok": $g, "warn": $y, "bad": $r}[.state_level // ""] // $d) as $h
  | "\(.name | esc)  \(.sprint_says | esc)  <span color=\"\($h)\">\(st | esc)</span>"' <<< "$raw")"
read -r flying total running errors board grew < <(jq -r '[(.figures.projects_in_flight // "-"), (.figures.projects_headline // "-"),
  (.figures.projects_sprints // "-"), (.errors | length), (.board_open // "-"), ((.board_7d.net // 0) > 0)] | @tsv' <<< "$raw")

# The Board block: the total and the fleet's 7-day flow in points (hub's `board_7d`, left out when
# no day-log record carries points), then one row per project with rows on the board, the most
# first, its rows and its 7-day net in points (`net7d_cell`), amber when it grew (`growing`).
boardblock="$(jq -r --arg y "$C_YEL" '
  def esc: gsub("&"; "&amp;") | gsub("<"; "&lt;") | gsub(">"; "&gt;");
  def paint($c): "<span color=\"\($c)\">\(.)</span>";
  def pad($n): . + (" " * ([$n - length, 0] | max));
  def lpad($n): (" " * ([$n - length, 0] | max)) + .;
  "<b>Board</b>  \(.board_open // "?") rows"
    + (.board_7d | if . == null then ""
       else ", net \(.net | if . > 0 then "+\(.)" else tostring end) pts in 7d (\(.in) in, \(.done) done, \(.dropped) dropped)" end),
  ([.cards[] | select((.agent_tiers.board // 0) > 0)] | sort_by(-.agent_tiers.board, .name)) as $b
  | ([$b[].name | esc | length] + [7] | max) as $w
  | ([$b[].agent_tiers.board | tostring | length] + [4] | max) as $nw
  | ([$b[].net7d_cell // "-" | length] + [6] | max) as $cw
  | if ($b | length) > 0 then "<tt>" + ([("  " + ("PROJECT" | pad($w)) + "  " + ("ROWS" | lpad($nw)) + "  " + ("7D NET" | lpad($cw)))]
      + [$b[] | . as $c | (.net7d_cell // "-") as $n
        | "  " + (.name | esc | pad($w)) + "  " + (.agent_tiers.board | tostring | lpad($nw))
          + "  " + (" " * ($cw - ($n | length))) + ($n | if $c.growing then paint($y) else . end)] | join("\n")) + "</tt>"
    else empty end
' <<< "$raw")"
head="$title  $flying in flight, $total total"
text="$ICON"
if [ "$flying" = - ]; then
  text+=" $(paint "$C_YEL" ?)"
elif ((flying > 0)); then
  text+=" $flying"
fi
# The board's open rows, amber when the board grew; an unread feed is B:? in amber.
if [ "$board" = - ]; then
  text+="  $(paint "$(label_colour)" B:)$(paint "$C_YEL" ?)"
elif [ "$grew" = true ]; then
  text+="  $(paint "$(label_colour)" B:)$(paint "$C_YEL" "$board")"
else
  text+="  $(paint "$(label_colour)" B:)$board"
fi
# With no Sprints figure the bar's sprint is ? while the cards still name one.
if [ "$running" = - ] && [ -n "$sprints" ]; then
  text+="  $(paint "$(label_colour)" S:)$(paint "$C_YEL" ?)"
elif [ "$running" != - ] && ((running > 0)); then
  read -r risky sprint < <(jq -r '[.cards[] | select(.sprint_says != null)
    | {risky: (.state_level == "warn" or .state_level == "bad"), w: .window}]
    | (map(select(.risky)) + map(select(.risky | not)))[0]
    | "\(.risky) \(.w.version) \(.w.delivered)/\(.w.committed)"' <<< "$raw")
  sprint="$(pango_esc "$sprint")"
  ((running == 1)) || sprint+=" +$((running - 1))"
  [[ "$risky" == false ]] || sprint="$(paint "$C_YEL" "$sprint")"
  text+="  $(paint "$(label_colour)" S:)$sprint"
fi
if [ -n "$sprints" ]; then
  head+=$'\n\n'"<b>Sprint</b>"
  while IFS= read -r line; do head+=$'\n'"  $line"; done <<< "$sprints"
fi
class=ok
((errors == 0)) || class=warn
emit "$text" "$head"$'\n\n'"<tt>$body</tt>"$'\n\n'"$boardblock" "$class"
