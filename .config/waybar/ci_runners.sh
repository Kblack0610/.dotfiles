#!/usr/bin/env bash
# Waybar module: CI runners. It renders `hub ci --json` .glance, the slot model hub-core
# computes for every CI surface (the hub Infra tab and the agent-web infra page draw the same
# struct), so the bar cannot count slots one way while the board counts them another.
#
# Bar: one cell per slot on the hosts that are up (busy filled, held amber, free dim), then
# busy/total and the queue; total counts the held slots too. The CI label takes the colour of
# cc:domain_status{domain="ci"}; the class is that level too.
# Hover: the same head line as the board (busy/total, held, queued, done in 24h, pass rate
# painted red under 70% and amber under 90%), the ci domain's parts and why runner rows may be
# short, then jobs by kind (waiting, oldest, done, pass), one row per machine (busy/total and
# what the slots are doing, with why each held one is held; the row is red when the machine's
# load per core is past HOT_RATIO, the load chip's own line), the cloud hosts that are off on
# one line, the runners that are down, the jobs running long, NEXT (the first waiting jobs,
# where each fits and about when it starts) and where every runner is listed.
# A failed read shows `CI: prom down`, never the last numbers.

set -u
here="$(dirname "$(realpath "${BASH_SOURCE[0]}")")"
# shellcheck source=pango.sh
. "$here/pango.sh"
HUB="${HUB:-$HOME/.local/bin/hub}"
# Under the module's 60s interval, so a hung read is prom down before the next tick.
HUB_TIMEOUT=30

fail() { emit "$(paint "$C_RED" 'CI: prom down')" "CI runners: $(pango_esc "$1")" critical; exit 0; }

err="$(mktemp)"
trap 'rm -f "$err"' EXIT
# stderr apart, so a warning cannot break the JSON and the reason is hub's own last line.
raw="$(timeout "$HUB_TIMEOUT" "$HUB" ci --json 2>"$err")" || {
  rc=$?
  [ "$rc" = 124 ] && fail "hub ci: no answer in ${HUB_TIMEOUT}s"
  why="$(tail -n 1 "$err")"
  fail "${why:-hub ci failed}"
}
jq -e '.glance' <<< "$raw" >/dev/null 2>&1 || fail "hub ci: no glance in its output"

jq -c --arg grn "$C_GRN" --arg yel "$C_YEL" --arg red "$C_RED" --arg dim "$C_DIM" --argjson hot "$HOT_RATIO" '
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
  def cells($n): if $n > 0 then "▮" * $n else "" end;
  def paint_some($c): if . == "" then . else paint($c) end;
  # When a waiting job starts: now, in about its fitting slot'"'"'s usual time left, or - (no usual).
  def starts: if . == null then "-" elif . == 0 then "now" else "in \(dur)" end;
  [$grn, $yel, $red] as $colour
  | .glance as $g
  | ($g.level | lvl) as $lv
  | ("\($g.busy)/\($g.total) busy" + (if $g.held > 0 then ", \($g.held) held" else "" end)
     + ", \($g.queued) queued"
     + (if $g.queued > 0 and $g.oldest != null then " (oldest \($g.oldest | dur))" else "" end)
     + (if $g.done > 0 then ", \($g.done) done 24h"
          + (if $g.pass == null then "" else ", " + ($g.pass | pass_paint(($g.pass | pct) + " passed")) end)
        else "" end)) as $head
  | ((if ($g.parts | length) == 0 then ["no data"]
      else $g.parts | map(.level as $l | "\(.name | esc) " + ($l | word | paint($colour[$l | lvl]))) end)
     + (if $g.feed then [$g.feed | esc | paint($red)] else [] end)) as $parts
  | ([$g.kinds[].kind | length] + [4] | max) as $kw
  | ([$g.kinds[] | ((.kind | pad($kw) | esc) + " " + (.waiting as $w | $w | num | lpad(7)
        | if ($w // 0) > 0 then paint($yel) else . end)
      + " " + (.oldest | dur | lpad(6)) + " " + (.done | num | lpad(5)) + "  " + (.pass as $p | $p | pass_paint($p | pct)))]) as $kinds
  | ([$g.machines[].host | length] + [7] | max) as $mw
  | ([$g.machines[] | ((.load // 0) >= $hot) as $hotrow
      | (.host | pad($mw) | esc) + " " + ("\(.busy)/\(.slots + .held)" | lpad(5)) + "  " + (.doing | esc)
      | if $hotrow then paint($red) else . end]) as $machines
  # NEXT: job (repo), how many, how long the oldest waited, where it fits (with the slot state
  # when that is no idle or busy slot: a seat waits for a lent slot), and when it starts.
  | ([$g.next[] | . as $q
      | ($q.can | map(select(.host == $q.at)) | first | .state // "") as $st
      | {what: ($q.job + (if $q.repo == "" then "" else " (\($q.repo))" end)), n: $q.n,
         wait: ($q.wait | dur),
         where: (if $q.at == "" then (if $q.stuck then "nobody" else "-" end)
                 elif $q.starts == null and ($st | IN("idle", "busy") | not) and $st != "" then "\($q.at) \($st)"
                 else $q.at end),
         when: ($q.starts | starts)}]) as $nx
  | ([$nx[].what | length] + [4] | max) as $jw
  | ([$nx[].where | length] + [5] | max) as $ww
  | ((("NEXT" | pad($jw)) + "  N WAITED  " + ("WHERE" | pad($ww)) + "  STARTS")) as $nhead
  | ([$nx[] | (.what | pad($jw) | esc) + " " + (.n | tostring | lpad(2)) + " " + (.wait | lpad(6)) + "  "
      + (.where | pad($ww) | esc) + "  " + .when]) as $next
  | (("KIND" | pad($kw)) + " WAITING OLDEST  DONE  PASS") as $khead
  | (("MACHINE" | pad($mw)) + "  BUSY  DOING") as $mhead
  | ([$khead] + (if ($kinds | length) > 0 then $kinds else ["no job kind reports"] end)
     + [""] + [$mhead] + (if ($machines | length) > 0 then $machines else ["no machine reports"] end)
     + (if ($g.off | length) > 0 then ["cloud: \($g.off | length) host\(if ($g.off | length) == 1 then "" else "s" end) off"] else [] end)
     + (if ($g.down | length) > 0 then ["", "DOWN:"] + [$g.down[] | "  \(.host | esc)  \(.n) \(.state | esc)"] else [] end)
     + (if ($g.long | length) > 0 then ["", ("long runs: " + ([$g.long[] | "\(.what | esc) \(.ran | dur)"] | join(", ")) | paint($yel))] else [] end)
     + (if ($next | length) > 0 then ["", $nhead] + $next else [] end)
     + ["", "every runner: hub --tab '"'"'infra ci'"'"', agent-web #infra/machines/&lt;host&gt;"]
    ) as $body
  # One cell per slot: busy filled, held amber, free dim.
  | (cells($g.busy) + (cells($g.held) | paint_some($yel))
     + (cells($g.slots - $g.busy) | paint_some($dim))) as $cells
  | {
      text: ((if $lv > 0 then "CI" | paint($colour[$lv]) else "CI" end) + " " + $cells + " \($g.busy)/\($g.total) "
        + ("q\($g.queued)" | if $g.queued > 0 then paint($yel) else . end)),
      tooltip: ("<b>CI runners</b>  \($head)\nci: \($parts | join(", "))\n<tt>\($body | join("\n"))</tt>"),
      class: (["ok", "warn", "critical"][$lv])
    }
' <<< "$raw" || fail "hub ci: unreadable glance"
