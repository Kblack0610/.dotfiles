#!/usr/bin/env bash
# Waybar module: CI runners. It renders `hub ci --json` .glance, the CI model hub-core
# computes for every CI surface (the hub Infra tab and the agent-web infra page draw the same
# struct), so the bar cannot count slots one way while the board counts them another.
#
# Bar: jobs running and jobs queued behind their labels, `CI r:4 q:3`, nothing else, plain like the
# queue chip. A runner or machine down is the health chip's (cc:domain_status{domain="ci"} goes down
# on a runners-online watch), so this bar neither counts runners nor turns red; its class is ok
# unless the read itself fails.
# A job no online runner can take (hub ci's red lines) is the hover's first line under the parts.
# Hover: the title with each CI node's cells (BAR of them, the fuller of its booked CPU and memory
# shares, a part cell as an eighth block on the dim colour, the rest dim), then the board's head
# line less its runner count (jobs running, queued, the CPU job pods book of the CI nodes', done
# in 1h and 5h once reported, done in 24h, pass rate painted red under 70% and amber under 90%),
# the ci domain's parts and why
# runner rows may be short, then jobs by kind (running, waiting, oldest, done, usual, pass), one row per
# machine: BOOKED (the CPU and memory its job pods book of allocatable, then its cells like the
# title's, `-` on no CI node), RUNNING (each job by kind and repo: a pod's scale set or
# ScaledJob, a Unity slot's pool) and NEXT (the oldest waiting job that fits it, how long it has
# waited). A machine's name and booking are red when its load per core is past HOT_RATIO (the
# load chip's own line). Then the job pods no node has
# room for, the runners that are down, the jobs running long, WAITING (the first waiting jobs,
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

jq -c --arg grn "$C_GRN" --arg yel "$C_YEL" --arg red "$C_RED" --arg dim "$C_DIM" --arg lc "$(label_colour)" --argjson hot "$HOT_RATIO" '
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
  def cells($n): if $n > 0 then "█" * $n else "" end;
  def paint_some($c): if . == "" then . else paint($c) end;
  def under($c): "<span background='"'"'\($c)'"'"'>\(.)</span>";
  # $busy of $cap cells, the title and every machine row alike: a whole cell full, a part one
  # as a left eighth block on the dim colour (2.48 of 4 is two full cells and a half one), the
  # rest dim. No $cap is no cells.
  def ubar($busy; $cap):
    if $cap == null then "" else
      ([$cap | round, 0] | max) as $n
      | ([[$busy // 0, 0] | max, $n] | min) as $b
      | ($b | floor) as $f
      | (($b - $f) * 8 | round) as $e
      | (if $e == 8 then [$f + 1, 0] else [$f, $e] end) as [$full, $part]
      | cells($full)
        + (if $part > 0 then ["", "▏", "▎", "▍", "▌", "▋", "▊", "▉"][$part] | under($dim) else "" end)
        + (cells($n - $full - (if $part > 0 then 1 else 0 end)) | paint_some($dim))
    end;
  # The cells a CI node'"'"'s booking takes in the hover.
  def BAR: 4;
  # When a waiting job starts: now, in about its fitting slot'"'"'s usual time left, or - (no usual).
  def starts: if . == null then "-" elif . == 0 then "now" else "in \(dur)" end;
  # 6.4 (one decimal) and 16, as the board formats cores; - with no reading.
  def u1: if . == null then "-" else (. * 10 | round) as $t | "\($t / 10 | floor).\($t % 10)" end;
  def u0: if . == null then "-" else round | tostring end;
  # hub_core::host_now::bytes: 2.5G, 92G, 340M, 0B.
  def bytes: {v: ([., 0] | max), u: 0}
    | until(.v < 1024 or .u == 4; .v /= 1024 | .u += 1)
    | (if .v < 10 and .u > 0 then .v | u1 else .v | round | tostring end) + ["B", "K", "M", "G", "T"][.u];
  # hub_core::jobpods::Booked: cell is `4.4/32 2.5G/92G` (bare `1.7 1.2G` with no allocatable read),
  # share the fuller of its CPU and memory.
  def bcell: if . == null then "-"
    elif (.cpu_alloc // 0) <= 0 then "\(.cpu | u1) \(.mem | bytes)"
    else "\(.cpu | u1)/\(.cpu_alloc | u0) \(.mem | bytes)/\(.mem_alloc | bytes)" end;
  def share: [(if .cpu_alloc > 0 then .cpu / .cpu_alloc else 0 end), (if .mem_alloc > 0 then .mem / .mem_alloc else 0 end)] | max;
  def bbar: if .booked == null then "" else ubar(.booked | share * BAR; BAR) end;
  # hub_core::jobpods::Pending::line, the cores as jobpods::request: `arc-org-light x3 (1.69 cpu 1.2G each)`.
  def ptext: "\(.kind)\(if .n > 1 then " x\(.n)" else "" end) (\(.cpu * 100 | round / 100 | tostring) cpu \(.mem | bytes)\(if .n > 1 then " each" else "" end))";
  [$grn, $yel, $red] as $colour
  | (.red // []) as $nobody
  | .glance as $g
  | ("\($g.busy) running, \($g.queued) queued"
     + (if $g.queued > 0 and $g.oldest != null then " (oldest \($g.oldest | dur))" else "" end)
     + (if $g.booked == null then "" else ", booked \($g.booked.cpu | u1)/\($g.booked.cpu_alloc | u0) cpu" end)
     + (if $g.done_1h == null then "" else ", \($g.done_1h) done 1h" end)
     + (if $g.done_5h == null then "" else ", \($g.done_5h) done 5h" end)
     + (if $g.done > 0 then ", \($g.done) done 24h"
          + (if $g.pass == null then "" else ", " + ($g.pass | pass_paint(($g.pass | pct) + " passed")) end)
        else "" end)) as $head
  | ((if ($g.parts | length) == 0 then ["no data"]
      else $g.parts | map(.level as $l | "\(.name | esc) " + ($l | word | paint($colour[$l | lvl]))) end)
     + (if $g.feed then [$g.feed | esc | paint($red)] else [] end)) as $parts
  | ([$g.kinds[].kind | length] + [4] | max) as $kw
  # RUNNING is the jobs of the kind running, USUAL how long one of them usually runs (hub_core::machines::Pool).
  | ([$g.kinds[] | ((.kind | pad($kw) | esc) + " " + (.running | num | lpad(7))
      + " " + (.waiting as $w | $w | num | lpad(7)
        | if ($w // 0) > 0 then paint($yel) else . end)
      + " " + (.oldest | dur | lpad(6)) + " " + (.done | num | lpad(5)) + " " + (.usual | dur | lpad(5))
      + "  " + (.pass as $p | $p | pass_paint($p | pct)))]) as $kinds
  | ([$g.machines[].host | length] + [7] | max) as $mw
  | ($g.machines | map(.bcell = (.booked | bcell))) as $ms
  | ([$ms[].bcell | length] + [6] | max) as $uw
  | ([$ms[] | .runlist = (if (.running | length) == 0 then "-" else .running | join(", ") end)
            | .nextline = (if .next == null then "-"
                else .next.job + (if .next.repo == "" then "" else " (\(.next.repo))" end) + " " + (.next.wait | dur) end)]) as $ms
  | ([$ms[].runlist | length] + [7] | max) as $rw
  | ([$ms[] | ((.load // 0) >= $hot) as $hotrow
      | ((.host | pad($mw) | esc) + " " + (.bcell | lpad($uw))
         | if $hotrow then paint($red) else . end)
      + "  " + bbar + (" " * (if .booked == null then BAR else 0 end)) + "  " + (.runlist | pad($rw) | esc) + "  " + (.nextline | esc)]) as $machines
  # WAITING: job (repo), how many, how long the oldest waited, where it fits (with the slot state
  # when that is no idle or busy slot), and when it starts.
  | ([$g.next[] | . as $q
      | ($q.can | map(select(.host == $q.at)) | first | .state // "") as $st
      | {what: ($q.job + (if $q.repo == "" then "" else " (\($q.repo))" end)), n: $q.n,
         wait: ($q.wait | dur),
         where: (if $q.at == "" then (if $q.stuck then "nobody" else "-" end)
                 elif $q.starts == null and ($st | IN("idle", "busy") | not) and $st != "" then "\($q.at) \($st)"
                 else $q.at end),
         when: ($q.starts | starts)}]) as $nx
  | ([$nx[].what | length] + [7] | max) as $jw
  | ([$nx[].where | length] + [5] | max) as $ww
  | ((("WAITING" | pad($jw)) + "  N WAITED  " + ("WHERE" | pad($ww)) + "  STARTS")) as $nhead
  | ([$nx[] | (.what | pad($jw) | esc) + " " + (.n | tostring | lpad(2)) + " " + (.wait | lpad(6)) + "  "
      + (.where | pad($ww) | esc) + "  " + .when]) as $next
  | (("KIND" | pad($kw)) + " RUNNING WAITING OLDEST  DONE USUAL  PASS") as $khead
  | (("MACHINE" | pad($mw)) + " " + ("BOOKED" | lpad($uw)) + "  " + ("" | pad(BAR)) + "  " + ("RUNNING" | pad($rw)) + "  NEXT") as $mhead
  | ([$khead] + (if ($kinds | length) > 0 then $kinds else ["no job kind reports"] end)
     + [""] + [$mhead] + (if ($machines | length) > 0 then $machines else ["no machine reports"] end)
     + (if ($g.pending | length) > 0 then ["waiting for room: " + ([$g.pending[] | ptext] | join(", ")) | esc | paint($yel)] else [] end)
     + (if ($g.down | length) > 0 then ["", "DOWN:"] + [$g.down[] | "  \(.host | esc)  \(.n) \(.state | esc)"] else [] end)
     + (if ($g.long | length) > 0 then ["", ("long runs: " + ([$g.long[] | "\(.what | esc) \(.ran | dur)"] | join(", ")) | paint($yel))] else [] end)
     + (if ($next | length) > 0 then ["", $nhead] + $next else [] end)
     + ["", "every runner: hub --tab '"'"'infra ci'"'"', agent-web #infra/machines/&lt;host&gt;"]
    ) as $body
  | ([$ms[] | bbar | select(. != "")] | join(" ")) as $cells
  | {
      text: (("CI r:" | paint($lc)) + "\($g.busy) " + ("q:" | paint($lc)) + "\($g.queued)"),
      tooltip: ("<b>CI runners</b>" + (if $cells == "" then "" else "  " + $cells end) + "\n\($head)\nci: \($parts | join(", "))\n"
        + ([$nobody[] | esc | paint($red) | . + "\n"] | join(""))
        + "<tt>\($body | join("\n"))</tt>"),
      class: "ok"
    }
' <<< "$raw" || fail "hub ci: unreadable glance"
