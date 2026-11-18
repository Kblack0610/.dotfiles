#!/usr/bin/env bash
# Waybar module: CI runners. It renders `hub ci --json` .glance, the slot model hub-core
# computes for every CI surface (the hub Infra tab and the agent-web infra page draw the same
# struct), so the bar cannot count slots one way while the board counts them another.
#
# Bar: busy/slots, each slot counted once, and the queue. The CI label takes the colour of
# cc:domain_status{domain="ci"}; the class is that level too.
# Hover: the same head line as the board (busy/slots, queued, done in 24h, pass rate painted
# red under 70% and amber under 90%), the ci domain's parts and why runner rows may be short,
# then jobs by kind (waiting, oldest, done, pass), one row per machine (busy/slots, what the
# slots are doing in plain words, space last), the cloud hosts that are off on one line,
# the runners that are down, and the jobs running long.
# A failed read shows `CI: prom down`, never the last numbers.

set -u
here="$(dirname "$(realpath "${BASH_SOURCE[0]}")")"
# shellcheck source=pango.sh
. "$here/pango.sh"
HUB="${HUB:-$HOME/.local/bin/hub}"

fail() { emit "$(paint "$C_RED" 'CI: prom down')" "CI runners: $(pango_esc "$1")" critical; exit 0; }

raw="$("$HUB" ci --json 2>&1)" || fail "${raw:-hub ci failed}"
jq -e '.glance' <<< "$raw" >/dev/null 2>&1 || fail "hub ci: no glance in its output"

jq -c --arg grn "$C_GRN" --arg yel "$C_YEL" --arg red "$C_RED" '
  def esc: tostring | gsub("&"; "&amp;") | gsub("<"; "&lt;") | gsub(">"; "&gt;");
  def paint($c): "<span color='"'"'\($c)'"'"'>\(.)</span>";
  def pad($n): tostring | . + (" " * ([$n - length, 0] | max));
  def lpad($n): tostring | (" " * ([$n - length, 0] | max)) + .;
  # 45s, 36m, 2h28m, 3d4h, the same cut as prom_dur and the board.
  def dur: if . == null then "-" else floor as $s
    | if $s < 60 then "\($s)s" elif $s < 3600 then "\($s / 60 | floor)m"
      elif $s < 86400 then "\($s / 3600 | floor)h\($s % 3600 / 60 | floor | tostring | if length < 2 then "0" + . else . end)m"
      else "\($s / 86400 | floor)d\($s % 86400 / 3600 | floor)h" end end;
  def pct: if . == null then "-" else (. * 100 | round | tostring) + "%" end;
  def pass_paint($cell): if . == null then $cell
    elif . * 100 < 70 then $cell | paint($red) elif . * 100 < 90 then $cell | paint($yel) else $cell end;
  def num: if . == null then "-" else floor end;
  def lvl: {ok: 0, warn: 1, red: 2}[.] // 1;
  def word: {ok: "ok", warn: "warn", red: "red"}[.] // "no data";
  [$grn, $yel, $red] as $colour
  | .glance as $g
  | ($g.level | lvl) as $lv
  | ("\($g.busy)/\($g.slots) busy, \($g.queued) queued"
     + (if $g.queued > 0 and $g.oldest != null then " (oldest \($g.oldest | dur))" else "" end)
     + (if $g.done > 0 then ", \($g.done) done 24h"
          + (if $g.pass == null then "" else ", " + ($g.pass | pass_paint(($g.pass | pct) + " passed")) end)
        else "" end)) as $head
  | ((if ($g.parts | length) == 0 then ["no data"]
      else $g.parts | map(.level as $l | "\(.name | esc) " + ($l | word | paint($colour[$l | lvl]))) end)
     + (if $g.feed then [$g.feed | esc | paint($red)] else [] end)) as $parts
  | ([$g.kinds[].kind | length] + [4] | max) as $kw
  | ([$g.kinds[] | ((.kind | pad($kw)) + " " + (.waiting as $w | $w | num | lpad(7)
        | if ($w // 0) > 0 then paint($yel) else . end)
      + " " + (.oldest | dur | lpad(6)) + " " + (.done | num | lpad(5)) + "  " + (.pass as $p | $p | pass_paint($p | pct)))]) as $kinds
  | ([$g.machines[].host | length] + [7] | max) as $mw
  | ([$g.machines[].doing | length] + [5] | max) as $dw
  | ([$g.machines[] | (.host | esc | pad($mw)) + " " + ("\(.busy)/\(.slots)" | lpad(5)) + "  "
      + (.doing | esc | pad($dw)) + "  " + (.space | esc)]) as $machines
  | (("KIND" | pad($kw)) + " WAITING OLDEST  DONE  PASS") as $khead
  | (("MACHINE" | pad($mw)) + "  BUSY  " + ("DOING" | pad($dw)) + "  SPACE") as $mhead
  | ([$khead] + (if ($kinds | length) > 0 then $kinds else ["no job kind reports"] end)
     + [""] + [$mhead] + (if ($machines | length) > 0 then $machines else ["no machine reports"] end)
     + (if ($g.off | length) > 0 then ["cloud: \($g.off | length) host\(if ($g.off | length) == 1 then "" else "s" end) off"] else [] end)
     + (if ($g.down | length) > 0 then ["", "DOWN:"] + [$g.down[] | "  \(.host | esc)  \(.n) \(.state | esc)"] else [] end)
     + (if ($g.long | length) > 0 then ["", ("long runs: " + ([$g.long[] | "\(.what | esc) \(.ran | dur)"] | join(", ")) | paint($yel))] else [] end)
    ) as $body
  | {
      text: ((if $lv > 0 then "CI" | paint($colour[$lv]) else "CI" end) + " \($g.busy)/\($g.slots) "
        + ("q\($g.queued)" | if $g.queued > 0 then paint($yel) else . end)),
      tooltip: ("<b>CI runners</b>  \($head)\nci: \($parts | join(", "))\n<tt>\($body | join("\n"))</tt>"),
      class: (["ok", "warn", "critical"][$lv])
    }
' <<< "$raw" || fail "hub ci: unreadable glance"
