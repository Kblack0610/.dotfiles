#!/usr/bin/env bash
# Waybar module: the projects chip (custom/projects), every lab project's progress at a glance.
# The bar is the icon and how many projects have work in flight (a session running or an ask
# waiting); the hover is one row per project with open work, its state in its hue after the name,
# in flight first, then by stage, and one line for the projects with nothing open.
#
# It computes nothing: `hub projects --json` is hub-core's join (projects::gather), the same cards
# the hub Projects tab, agent-web and the phone read, with the open window already scored. hub
# unreadable reads ? in amber.

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
  def flight: [ (if (.running | length) > 0 then "\(.running | length) running" | paint($g) else empty end),
                (if .waiting > 0 then "\(.waiting) waiting" | paint($y) else empty end) ] | join(", ");
  .cards as $all
  | ([$all | to_entries[] | .value + {i: .key}
      | select(.in_flight or .progress.open > 0)]
     | sort_by(if .in_flight then [0, .i] else [1, rank, .name] end)) as $shown
  | ([$shown[].name | length] | max // 0) as $w
  | ([$shown[].window_says | length] | max // 0) as $ws
  | ([$shown[] | .state // "-" | length] | max // 0) as $st
  | ($shown[] | [(.name | esc | pad($w)), (hue as $h | .state // "-" | pad($st) | paint($h)), (.stage | pad(5)),
      (bar | pad(12)), (.window_says | pad($ws)), flight]
      | join("  ") | sub(" +$"; "")),
    (($all | length) - ($shown | length)) as $rest
    | if $rest > 0 then "+\($rest) more with nothing open" else empty end,
    (.errors[]? | "error: \(esc)" | paint($y))
' <<< "$raw")"

read -r flying total errors < <(jq -r '[([.cards[] | select(.in_flight)] | length), (.cards | length), (.errors | length)] | @tsv' <<< "$raw")
head="$title  $flying in flight, $total total"
text="$ICON"
((flying == 0)) || text+=" $flying"
class=ok
((errors == 0)) || class=warn
emit "$text" "$head"$'\n'"<tt>$body</tt>" "$class"
