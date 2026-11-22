#!/usr/bin/env bash
# Waybar module: the projects chip (custom/projects), every lab project's progress at a glance.
# The bar is the icon, how many projects have work in flight (a session running or an ask
# waiting) and S: with the running sprint, its version and delivered/committed (absent with none,
# +N past one); the hover leads with one line per running sprint, then one row per project with
# open work, its state in its hue after the name,
# in flight first, then by stage, and one line for the projects with nothing open.
#
# It computes nothing: `hub projects --json` is hub-core's join (projects::gather), the same cards
# the hub Projects tab, agent-web and the phone read, with the open window already scored, and
# its `figures` are the Projects card's (in flight, the project count, sprints), which hub drops
# on a partial read, so those then read ? and -. hub unreadable reads ? in amber.

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

# The hover body: one row per card with open rows, in flight first (hub's order), then by stage;
# the rest fold into one count. Names and stages are escaped here, colours come from pango.sh.
body="$(jq -r --arg g "$C_GRN" --arg y "$C_YEL" --arg r "$C_RED" --arg d "$C_DIM" '
  def esc: gsub("&"; "&amp;") | gsub("<"; "&lt;") | gsub(">"; "&gt;");
  def paint($c): "<span color=\"\($c)\">\(.)</span>";
  def pad($n): . + (" " * ([$n - length, 0] | max));
  def rank: {"prod": 0, "beta": 1, "alpha": 2, "dev": 3, "draft": 4}[.stage] // 5;
  # The window bar is delivered of committed rows; a project with no open window draws none.
  def bar: if .window_share != null
    then (.window_share / 10 | floor) as $f
      | "[" + ("#" * $f) + ("." * (10 - $f)) + "]"
    else "" end;
  # hub_core::projects::state, painted by its state_level; grey (parked) has none.
  def hue: {"ok": $g, "warn": $y, "bad": $r}[.state_level // ""] // $d;
  # An unread queue states no card (hub_core::projects::build): a dash, not a blank.
  def st: if (.state // "") == "" then "-" else .state end;
  def flight: [ (if (.running | length) > 0 then "\(.running | length) running" | paint($g) else empty end),
                (if .waiting > 0 then "\(.waiting) waiting" | paint($y) else empty end) ] | join(", ");
  .cards as $all
  | ([$all | to_entries[] | .value + {i: .key}
      | select(.in_flight or .progress.open > 0)]
     | sort_by(if .in_flight then [0, .i] else [1, rank, .name] end)) as $shown
  | ([$shown[].name | length] | max // 0) as $w
  | ([$shown[].window_says | length] | max // 0) as $ws
  | ([$shown[] | st | length] | max // 0) as $st
  | ($shown[] | [(.name | esc | pad($w)), (hue as $h | st | pad($st) | paint($h)), (.stage | pad(5)),
      (bar | pad(12)), (.window_says | pad($ws)), flight]
      | join("  ") | sub(" +$"; "")),
    (($all | length) - ($shown | length)) as $rest
    | if $rest > 0 then "+\($rest) more with nothing open" else empty end,
    (.errors[]? | "error: \(esc)" | paint($y))
' <<< "$raw")"

# Running sprints (a sprint lock holds the open window, hub's `sprint_says`): one line each, above
# the project rows. The bar shows one itself after S:, `S:v0.5.4 10/15` from its card's window
# (sprint_says implies the window), an at-risk or late one first and then amber, and +N past one
# (only #prio/focus projects run sprints, so one is the normal case).
sprints="$(jq -r '.cards[] | select(.sprint_says != null) | "\(.name) \(.sprint_says)"' <<< "$raw")"
read -r flying total running errors < <(jq -r '[(.figures.projects_in_flight // "-"), (.figures.projects_headline // "-"),
  (.figures.projects_sprints // "-"), (.errors | length)] | @tsv' <<< "$raw")
head="$title  $flying in flight, $total total"
text="$ICON"
if [ "$flying" = - ]; then
  text+=" $(paint "$C_YEL" ?)"
elif ((flying > 0)); then
  text+=" $flying"
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
  head+=$'\n'"running sprints:"
  while IFS= read -r line; do head+=$'\n'"  $(pango_esc "$line")"; done <<< "$sprints"
fi
class=ok
((errors == 0)) || class=warn
emit "$text" "$head"$'\n'"<tt>$body</tt>" "$class"
