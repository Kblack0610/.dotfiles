#!/usr/bin/env bash
# Waybar module: CI runners. It renders `hub ci --json` .glance, the CI model hub-core
# computes for every CI surface (the hub Infra tab and the agent-web infra page draw the same
# struct), so the bar cannot count jobs one way while the board counts them another. Every figure
# here is hub-core's; this script formats and never counts.
#
# Bar: jobs running and jobs queued behind their labels, `CI r:4 q:3`, nothing else, plain like the
# queue chip. A runner or machine down is the health chip's (cc:domain_status{domain="ci"} goes down
# on a runners-online watch), so this bar neither counts runners nor turns red; its class is ok
# unless the read itself fails.
# Hover, top to bottom: the title; hub ci's red lines first (busy ARC runners with no pod series,
# so their machines are unplaced and every booking reads `?`, then jobs no online runner can take);
# the Unity pool, jobs running of its scale sets' maxRunners plus the fixed build slots; the head
# (jobs running, queued and the oldest wait, the CPU the job pods book of the CI nodes'); runs
# finished in the last 1h and 5h with their pass rate and failures; the ci domain's parts and why
# runner rows may be short. Then jobs by kind (running, waiting, oldest, done and pass in 24h, usual),
# a kind with none of those left out. Then one row per machine, `ms-a2  cpu 27.5/32 booked, 9.1 used
# mem 41G/92G  32 jobs`, its name red with the reason on the row (`hot: load 1.6/core` past the load
# chip's HOT_RATIO, or a node state that takes no job), and under it the oldest waiting job that
# fits it and one line per scale set, repo, PR or branch and job, a matrix as `n of N units`.
# Then GitHub's own runners by repo, the cloud hosts that are off, the job pods no node has room
# for, the runners that are down, the jobs running long, WAITING (the first waiting jobs, where each
# fits and about when it starts) and where every runner is listed.
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
  # 2,050: a count with thousands marked.
  def thou: if . >= 1000 then "\(. / 1000 | floor | thou),\(. % 1000 | tostring | ("00" + .)[-3:])" else tostring end;
  def lvl: {ok: 0, warn: 1, red: 2}[.] // 1;
  def word: {ok: "ok", warn: "warn", red: "red"}[.] // "no data";
  # When a waiting job starts: now, in about its fitting slot'"'"'s usual time left, or - (no usual).
  def starts: if . == null then "-" elif . == 0 then "now" else "in \(dur)" end;
  # 6.4 (one decimal) and 16, as the board formats cores; - with no reading.
  def u1: if . == null then "-" else (. * 10 | round) as $t | "\($t / 10 | floor).\($t % 10)" end;
  def u0: if . == null then "-" else round | tostring end;
  # hub_core::host_now::bytes: 2.5G, 92G, 340M, 0B.
  def bytes: {v: ([., 0] | max), u: 0}
    | until(.v < 1024 or .u == 4; .v /= 1024 | .u += 1)
    | (if .v < 10 and .u > 0 then .v | u1 else .v | round | tostring end) + ["B", "K", "M", "G", "T"][.u];
  # hub_core::jobpods::Pending::line, the cores as machines::weight_text: `arc-org-light x3 (1.69 cpu 1.2G each)`.
  def ptext: "\(.kind)\(if .n > 1 then " x\(.n)" else "" end) (\(.cpu * 100 | round / 100 | tostring) cpu \(.mem | bytes)\(if .n > 1 then " each" else "" end))";
  [$grn, $yel, $red] as $colour
  | (.red // []) as $nobody
  | .glance as $g
  # While a busy ARC runner has no pod series its machine is unknown, so no booking is whole.
  | (($g.unplaced // 0) > 0) as $blind
  | def bk($v): if $blind then "?" else $v end;
  # hub_core::jobpods::Booked as `cpu 27.5/32 booked (7.4 reserved), 9.1 used  mem 41G/92G`, bare
  # `cpu 1.7 booked` with no allocatable read; a machine on no CI node reads its used cores only.
  def mcell: .booked as $b
    | (if $b == null then (if .used == null then [] else ["cpu \(.used | u1) used"] end)
       else [(if ($b.cpu_alloc // 0) <= 0 then "cpu \(bk($b.cpu | u1)) booked"
              else "cpu \(bk($b.cpu | u1))/\($b.cpu_alloc | u0) booked" end)
             + (if ($b.reserved // 0) > 0 then " (\($b.reserved | u1) reserved)" else "" end)
             + (if .used == null then "" else ", \(.used | u1) used" end)
             + "  mem " + (if ($b.mem_alloc // 0) <= 0 then bk($b.mem | bytes)
                           else "\(bk($b.mem | bytes))/\($b.mem_alloc | bytes)" end)] end)
    | join("");
  # Why a machine name is red: its load per core past the load chip'"'"'s hot ratio, or a node state
  # that takes no job (Machine::state). No reason, no red.
  def why: [(if (.load // 0) >= $hot then "hot: load \(.load | u1)/core" else empty end),
            (if (.state // "up") == "up" then empty else .state end)] | join(", ");
  # One line of what runs there: `.dotfiles #3592 fast tier: 16 of 24 units, 6m (usual 6m) on arc-repo-dotfiles`.
  def wline: (if .pr != "" then "\(.repo) #\(.pr)" elif .branch != "" then "\(.repo) \(.branch | if length > 24 then .[:23] + "~" else . end)" else .repo end)
    + " " + .job
    + (if .of != null then ": \(.n) of \(.of)" + (if .unit == "" then "" else " \(.unit)s" end)
       elif .n > 1 then ": x\(.n)" else "" end)
    + ", \(.ran | dur)" + (if .usual == null then "" else " (usual \(.usual | dur))" end)
    + (if .set == "" then "" else " on \(.set)" end);
  ("\($g.busy) running, \($g.queued) queued"
     + (if $g.queued > 0 and $g.oldest != null then " (oldest \($g.oldest | dur))" else "" end)
     + (if $g.booked == null then "" else ", booked \(bk($g.booked.cpu | u1))/\($g.booked.cpu_alloc | u0) cpu" end)) as $head
  | (($g.windows // []) | map("\(.span): \(.runs | thou) runs, " + (.pass as $p | $p | pass_paint(($p | pct) + " pass")) + ", \(.failed | thou) failed")
     | join("  ")) as $windows
  | (if $g.unity == null then null
     else "Unity  \($g.unity.running) running of \($g.unity.max) max"
       + (if ($g.unity.sets | length) == 0 then "" else " (" + ($g.unity.sets | map("\(.name) \(.running)/\(.max)") | join(", ")) + ")" end)
     end) as $unity
  | ((if ($g.parts | length) == 0 then ["no data"]
      else $g.parts | map(.level as $l | "\(.name | esc) " + ($l | word | paint($colour[$l | lvl]))) end)
     + (if $g.feed then [$g.feed | esc | paint($red)] else [] end)) as $parts
  # A kind with nothing running, waiting or done in 24h is no row.
  | ($g.kinds | map(select((.running // 0) + (.waiting // 0) + (.done // 0) > 0))) as $ks
  | ([$ks[].kind | length] + [4] | max) as $kw
  # RUNNING is the jobs of the kind running, USUAL how long one of them usually runs (hub_core::machines::Pool).
  | ([$ks[] | ((.kind | pad($kw) | esc) + " " + (.running | num | lpad(7))
      + " " + (.waiting as $w | $w | num | lpad(7)
        | if ($w // 0) > 0 then paint($yel) else . end)
      + " " + (.oldest | dur | lpad(6)) + " " + (.done | num | lpad(5)) + " " + (.usual | dur | lpad(5))
      + "  " + (.pass as $p | $p | pass_paint($p | pct)))]) as $kinds
  | ([$g.machines[].host | length] + [7] | max) as $mw
  | ([$g.machines[] | why as $why
      | ([(.host | pad($mw) | esc | if $why == "" then . else paint($red) end)]
         + [mcell | select(. != "") | esc]
         + ["\(.busy) job\(if .busy == 1 then "" else "s" end)"]
         + (if $why == "" then [] else [$why | esc | paint($red)] end)
         | join("  "))
      , (if .next == null then empty else "  next: " + ((.next.job + (if .next.repo == "" then "" else " (\(.next.repo))" end) + " waited \(.next.wait | dur)") | esc) end)
      , (.work // [] | .[] | "  " + (wline | esc))]) as $machines
  # WAITING: job (repo), how many, how long the oldest waited, where it fits (with the slot state
  # when that is no idle or busy slot: a seat waits for a lent slot), and when it starts.
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
  | ((if ($kinds | length) > 0 then [$khead] + $kinds + ["(done and pass: 24h)", ""] else [] end)
     + (if ($machines | length) > 0 then $machines else ["no machine reports"] end)
     + (if (($g.hosted // []) | length) > 0 then ["github-hosted: " + ($g.hosted | map("\(.repo) \(.n)") | join(", ") | esc)] else [] end)
     + (if ($g.off | length) > 0 then ["cloud: \($g.off | length) host\(if ($g.off | length) == 1 then "" else "s" end) off"] else [] end)
     + (if ($g.pending | length) > 0 then ["waiting for room: " + ([$g.pending[] | ptext] | join(", ")) | esc | paint($yel)] else [] end)
     + (if ($g.down | length) > 0 then ["", "DOWN:"] + [$g.down[] | "  \(.host | esc)  \(.n) \(.state | esc)"] else [] end)
     + (if ($g.long | length) > 0 then ["", ("long runs: " + ([$g.long[] | "\(.what | esc) \(.ran | dur)"] | join(", ")) | paint($yel))] else [] end)
     + (if ($next | length) > 0 then ["", $nhead] + $next else [] end)
     + ["", "every runner: hub --tab '"'"'infra ci'"'"', agent-web #infra/machines/&lt;host&gt;"]
    ) as $body
  | {
      text: (("CI r:" | paint($lc)) + "\($g.busy) " + ("q:" | paint($lc)) + "\($g.queued)"),
      tooltip: ("<b>CI runners</b>\n"
        + ([$nobody[] | esc | paint($red) | . + "\n"] | join(""))
        + (if $unity == null then "" else ($unity | esc) + "\n" end)
        + "\($head)\n"
        + (if $windows == "" then "" else "\($windows)\n" end)
        + "ci: \($parts | join(", "))\n"
        + "<tt>\($body | join("\n"))</tt>"),
      class: "ok"
    }
' <<< "$raw" || fail "hub ci: unreadable glance"
