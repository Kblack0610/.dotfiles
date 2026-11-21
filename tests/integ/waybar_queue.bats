#!/usr/bin/env bats
# queue.sh: the waybar queue chip, the one chip for agent work flowing. The bar is two labelled
# totals, Q ready to start and D done today, with Q coloured by what is wrong. The hover opens with
# one line, "Queue: flowing" or the worst exception, each exception on its own line with the command
# that fixes it, then the Queue, Dispatch and Shepherd numbers in <tt> columns and an as-of stamp.
# What these pin: a deep queue that is moving is green "flowing"; BLOCKED, a hold, flapping, a limit
# and an unhandled shepherd line are amber; queue-starved, a failed runner and a stopped pass are
# red; a hold that trips queue-starved is one red line; a gate is said once; the host whose pass ran
# last is the source and any other sender is named stale (ar-4306); Prometheus down reads ?, and a
# number the feed lacks reads -, never 0; no line is over 90 characters.
setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic
  MODULE="$REPO_ROOT/.config/waybar/queue.sh"
  # No palette unless a test writes one: a clone's own palette.css is per clone.
  export PANGO_PALETTE="$BATS_TEST_TMPDIR/palette.css"
  G="#a6e34a" Y="#ffcc2f" R="#ef5734"
  export CC_PROM_URL=http://prom.test FX="$BATS_TEST_TMPDIR" DISPATCH_NOW=100000 TZ=UTC
  cat > "$SANDBOX/bin/curl" <<'STUB'
#!/usr/bin/env bash
[ -n "${CURL_FAIL:-}" ] && exit 7
cat "$FX/prom.json"
STUB
  chmod +x "$SANDBOX/bin/curl"
  feed
}

# feed [series=value ...] -> Prometheus's answer: a healthy queue on host h1 (39 ready, 32
# urgent, the oldest 12h59m, last pass 3m ago, last start 12m ago, 7 reaps; 60 queued, 14
# running, 6 on a PR, 10 waiting; 5 started and 4 done in 1h, 50 started and 40 done (2 failed) in 24h;
# 30 done and 18 added in 6h; 1522 agent board rows and 2200 on the backlog; 16 of 24 run units, 5 by hand), with the overrides applied. A
# series is topic.key (a feed number, summary_shepherd.* for the shepherd); <host>: (h2:, say) prefixes another
# host, dup: a second scrape of h1; a value of - drops the series. acct:<name>.<reason> is that
# account's claude_account_room_reason series (claude-acct textfile, no topic).
feed() {
  python3 - "$FX/prom.json" "$@" <<'PY'
import json, sys
s = {
    "summary_dispatch.runnable": 39, "summary_dispatch.runnable_urgent": 32, "summary_dispatch.runnable_high": 7,
    "summary_dispatch.oldest_runnable_s": 46758, "summary_dispatch.oldest_urgent_s": 46758,
    "summary_dispatch.last_pass_epoch": 100000 - 180, "summary_dispatch.last_run_start_epoch": 100000 - 720,
    "summary_dispatch.started_1h": 5, "summary_dispatch.failed_1h": 0,
    "summary_dispatch.started_24h": 50, "summary_dispatch.failed_24h": 2,
    "summary_dispatch.reaped_1h": 7, "summary_dispatch.flapping_items": 0,
    "summary_dispatch.queued": 60, "summary_dispatch.running": 14, "summary_dispatch.review": 6, "summary_dispatch.waiting": 10,
    "summary_dispatch.done_1h": 4, "summary_dispatch.done_6h": 30,
    "summary_dispatch.added_6h": 18, "summary_dispatch.done_24h": 40, "summary_dispatch.done_today": 12,
    "summary_dispatch.board_agent": 1522, "summary_dispatch.board_backlog": 2200,
    "summary_dispatch.room_live_runs": 16, "summary_dispatch.room_max_live": 24,
    "summary_dispatch.room_live_hand": 5, "summary_dispatch.room_total_live": 21, "summary_dispatch.room_load": 27.4,
    "summary_dispatch.room_load_cap": 36, "summary_dispatch.room_idle": 45.2,
    "summary_dispatch.room_min_idle": 30, "summary_dispatch.room_held_slots": 0,
    "summary_dispatch.room_held_account": 0,
    "runner_fleet_dispatch.failed": 0, "runner_fleet_dispatch.blocked": 0,
    "watch_queue_starved.tripped": 0,
}
for a in sys.argv[2:]:
    k, v = a.split("=")
    if v == "-": s.pop(k, None)
    else: s[k] = float(v)
res = []
for k, v in s.items():
    host, inst = "h1", "i1"
    pre = k.split(":")[0] if ":" in k else ""
    if pre not in ("", "dup", "acct"): host, inst, k = pre, "i-" + pre, k[len(pre) + 1:]
    if k.startswith("dup:"): inst, k = "i9", k[4:]
    if k.startswith("acct:"):
        name, reason = k[5:].split(".")
        res.append({"metric": {"__name__": "claude_account_room_reason", "account": name, "reason": reason,
                               "instance": inst}, "value": [0, str(v)]})
        continue
    topic, name = k.split(".")
    m = {"__name__": "mqtt_" + name, "topic": f"agents_{host}_main_{topic}"}
    m.update(host=host, instance=inst)
    res.append({"metric": m, "value": [0, str(v)]})
json.dump({"status": "success", "data": {"result": res}}, open(sys.argv[1], "w"))
PY
}

text() { jq -r .text <<< "$output"; }
class() { jq -r .class <<< "$output"; }
tip() { jq -r .tooltip <<< "$output"; }
# bar <q> <d> -> the bar text: each label and colon in the label colour (no
# palette, so C_DIM; LABEL overrides), two spaces apart, the numbers as given.
bar() {
  local l=${LABEL:-#7f7f7f}
  printf "<span color='$l'>Q:</span>%s  <span color='$l'>D:</span>%s" "$1" "$2"
}
# g|y|r <text> -> the text in that level colour, as pango.sh paints it.
g() { printf "<span color='%s'>%s</span>" "$G" "$1"; }
y() { printf "<span color='%s'>%s</span>" "$Y" "$1"; }
r() { printf "<span color='%s'>%s</span>" "$R" "$1"; }
# head_is <painted what> <do>: the hover's first two lines, the worst exception and what to do.
head_is() {
  run tip
  assert_line --index 0 "<b>Queue:</b> $1"
  assert_line --index 1 "  Do: $2"
}

@test "a deep queue that is moving is neutral: the two totals, nothing else" {
  run "$MODULE"
  assert_success
  assert_equal "$(text)" "$(bar 39 12)"
  assert_equal "$(class)" ok
}

@test "a queue that flows says so first, then aligned number columns, then the as-of stamp" {
  run "$MODULE"
  run tip
  assert_output "<b>Queue:</b> $(g flowing)
<tt>Q ready           39  32 urgent, 7 high; 60 queued in all
  oldest      12h59m  urgent $(y 12h59m)
  running         14  on a PR 6, waiting on you 10
D done today      12
  last hour        4  started 5, failed 0
  last 24h        38  started 50, failed $(y 2)
  6h net         -12  18 added, 30 finished: $(g 'shrinking, empty in about 30h')
  board         1522  agent rows, 2200 on the backlog</tt>

<b>Dispatch:</b> last pass 3m ago, last start 12m ago
<tt>  sessions        21  of 24; run units $(g 16), by hand 5
  load            $(g 27)  of 36
  idle           $(g 45%)  floor 30%
  self-heal        7  reaped last hour, 0 flapping</tt>

as of 03:43, the last dispatch pass, on h1-main"
}

# Retired lines (dashboards.md Retired names): the legend, the items total, the cadence and
# purpose blurbs, the "from <host>" line (now the as-of stamp) and the vitals line (hub Home).
@test "the hover has no legend, items total, blurbs, from-host or vitals line" {
  printf '#!/usr/bin/env bash\necho "2 of 4 off target: You, Outcome"\n' > "$SANDBOX/bin/fake-hub"
  chmod +x "$SANDBOX/bin/fake-hub"
  HUB="$SANDBOX/bin/fake-hub" run "$MODULE"
  run tip
  refute_output --partial "ready to start next"
  refute_output --partial " items"
  refute_output --partial "a pass every"
  refute_output --partial "through their plans"
  refute_output --partial "the machine whose dispatch ran last"
  refute_output --partial "vitals"
}

@test "an urgent item ready under an hour is plain; queue-starved paints its wait red" {
  feed summary_dispatch.oldest_urgent_s=1800
  run "$MODULE"
  run tip
  assert_line --index 2 "  oldest      12h59m  urgent 30m"
  feed watch_queue_starved.tripped=1
  run "$MODULE"
  run tip
  assert_line --index 3 "  oldest      12h59m  urgent $(r 12h59m)"
}

@test "the oldest high item's wait rides after the urgent one; a feed without it reads as before" {
  feed summary_dispatch.oldest_urgent_s=1800 summary_dispatch.oldest_high_s=7200
  run "$MODULE"
  run tip
  assert_line --index 2 "  oldest      12h59m  urgent 30m, high 2h00m"
}

@test "each capacity number takes its own colour: green with room, amber near its limit, red past it" {
  feed summary_dispatch.room_live_runs=24 summary_dispatch.room_load=40 summary_dispatch.room_idle=20
  run "$MODULE"
  assert_equal "$(text)" "$(bar 39 12)"
  run tip
  assert_output --partial "  sessions        21  of 24; run units $(y 24), by hand 5"
  assert_output --partial "  load            $(r 40)  of 36"
  assert_output --partial "  idle           $(r 20%)  floor 30%"
  feed summary_dispatch.room_load=29 summary_dispatch.room_idle=35
  run "$MODULE"
  run tip
  assert_output --partial "  load            $(y 29)  of 36"
  assert_output --partial "  idle           $(y 35%)  floor 30%"
}

@test "drain: growing is amber with no empty time; even is steady; a slow drain reads days; no queue count, no empty time" {
  feed summary_dispatch.added_6h=42
  run "$MODULE"
  run tip
  assert_line --index 7 "  6h net         +12  42 added, 30 finished: $(y 'growing about 2/h')"
  feed summary_dispatch.added_6h=30
  run "$MODULE"
  run tip
  assert_line --index 7 "  6h net           0  30 added, 30 finished: steady"
  feed summary_dispatch.added_6h=28
  run "$MODULE"
  run tip
  assert_line --index 7 "  6h net          -2  28 added, 30 finished: $(g 'shrinking, empty in about 8d')"
  feed summary_dispatch.queued=-
  run "$MODULE"
  run tip
  assert_line --index 7 "  6h net         -12  18 added, 30 finished: $(g shrinking)"
}

@test "a gate that paused a pass with work still flowing is an amber row; each account names its own reasons" {
  feed summary_dispatch.room_held_slots=1
  run "$MODULE"
  run tip
  assert_line --index 0 "<b>Queue:</b> $(g flowing)"
  assert_output --partial "  paused              $(y 'the fleet is at its session target of 24')"
  feed summary_dispatch.room_held_account=1 acct:main.pace=1 acct:main.five_hour=1 acct:alt.reserve=1
  run "$MODULE"
  run tip
  assert_output --partial "  paused              $(y 'no account has room')
  alt                 no room: reserve
  main                no room: five_hour+pace
  self-heal"
  feed summary_dispatch.room_held_assess=1
  run "$MODULE"
  run tip
  assert_output --partial "$(y 'fleet-assess says the machine is too busy')"
  feed
  run "$MODULE"
  run tip
  refute_output --partial "paused"
}

@test "BLOCKED heads the hover in amber with the gate that held it and its command, said once" {
  feed runner_fleet_dispatch.blocked=1
  run "$MODULE"
  assert_equal "$(text)" "$(bar "$(y 39)" 12)"
  assert_equal "$(class)" warn
  head_is "$(y 'the last pass started nothing: ready work waited')" "fleet-dispatch run --dry-run"
  feed runner_fleet_dispatch.blocked=1 summary_dispatch.room_held_load=1
  run "$MODULE"
  head_is "$(y 'the last pass started nothing: load 27 is over its cap of 36')" "fleet-pace skill"
  refute_output --partial "  paused"
}

@test "a standing hold heads the hover with how long and which gate, said once, never BLOCKED too" {
  feed runner_fleet_dispatch.blocked=1 summary_dispatch.held_s=7380 summary_dispatch.room_held_account=1
  run "$MODULE"
  assert_equal "$(class)" warn
  head_is "$(y 'stopped 2h03m: no account has room')" "claude-acct status"
  refute_output --partial "started nothing"
  refute_output --partial "  paused"
  assert_equal "$(grep -c 'no account has room' <<< "$output")" 1
  feed runner_fleet_dispatch.blocked=1 summary_dispatch.held_s=600
  run "$MODULE"
  head_is "$(y 'stopped 10m: the last pass left ready work waiting')" "fleet-dispatch run --dry-run"
}

# queue-starved trips on a hold (its watch reads the runner's held_since): one cause, one red line.
@test "a hold that trips queue-starved is one red line naming both, with the gate's command" {
  feed summary_dispatch.held_s=7380 summary_dispatch.room_held_load=1 summary_dispatch.room_load=40 watch_queue_starved.tripped=1
  run "$MODULE"
  assert_equal "$(class)" critical
  head_is "$(r 'stopped 2h03m: load 40 is over its cap of 36 (queue-starved)')" "fleet-pace skill"
  refute_output --partial "queue-starved: "
}

@test "each exception heads the hover in its level colour with the command for it" {
  feed watch_queue_starved.tripped=1
  run "$MODULE"
  assert_equal "$(text)" "$(bar "$(r 39)" 12)"
  assert_equal "$(class)" critical
  head_is "$(r 'queue-starved: an urgent or high item sat ready over 60m')" "fleet-dispatch run --dry-run"
  feed runner_fleet_dispatch.failed=1
  run "$MODULE"
  assert_equal "$(class)" critical
  head_is "$(r 'the fleet-dispatch runner failed')" "agentctl logs fleet-dispatch"
  feed summary_dispatch.last_pass_epoch=$((100000 - 2760))
  run "$MODULE"
  assert_equal "$(class)" critical
  head_is "$(r 'no pass in 46m')" "systemctl --user status agentctl-fleet-dispatch.timer"
  feed summary_dispatch.flapping_items=1
  run "$MODULE"
  assert_equal "$(class)" warn
  head_is "$(y "1 item(s) flapping: a writer undoes reap's moves")" "agentctl logs fleet-dispatch"
  assert_output --partial "  self-heal        7  reaped last hour, $(y 1) flapping"
  feed summary_dispatch.could_start=2
  run "$MODULE"
  assert_equal "$(class)" warn
  head_is "$(y '2 more could start: a limit holds them, not the machine')" "fleet-dispatch headroom"
  feed summary_dispatch.could_start=0
  run "$MODULE"
  assert_equal "$(class)" ok
}

@test "the worst exception leads and the rest follow, each with its command" {
  feed runner_fleet_dispatch.failed=1 summary_dispatch.flapping_items=1 summary_dispatch.could_start=2
  run "$MODULE"
  head_is "$(r 'the fleet-dispatch runner failed')" "agentctl logs fleet-dispatch"
  assert_line --index 2 "  $(y "1 item(s) flapping: a writer undoes reap's moves"). Do: agentctl logs fleet-dispatch"
  assert_line --index 3 "  $(y '2 more could start: a limit holds them, not the machine'). Do: fleet-dispatch headroom"
  assert_line --index 4 --partial "<tt>Q ready"
}

@test "a #prio/focus project reads in amber with how many; no focus, or an old feed, no row" {
  feed summary_dispatch.focus_projects=2
  run "$MODULE"
  run tip
  assert_output --partial "  focus            $(y 2)  project(s) first; reds and urgent items still go first"
  feed summary_dispatch.focus_projects=0
  run "$MODULE"
  run tip
  refute_output --partial "focus"
  feed
  run "$MODULE"
  run tip
  refute_output --partial "focus"
}

@test "a feed without the queue or room numbers reads - and says no headroom, never 0" {
  feed summary_dispatch.queued=- summary_dispatch.done_6h=- summary_dispatch.room_max_live=-
  run "$MODULE"
  assert_equal "$(text)" "$(bar 39 12)"
  run tip
  assert_line --index 1 "<tt>Q ready           39  32 urgent, 7 high"
  assert_line --index 7 "  6h net           -"
  assert_output --partial "  capacity         -  no headroom from a pass in the last 45m"
}

@test "a second scrape of the source host counts once, and the as-of stamp names the source" {
  feed dup:summary_dispatch.runnable=39
  run "$MODULE"
  assert_equal "$(text)" "$(bar 39 12)"
  assert_equal "$(class)" ok
  tip | grep -qxF "as of 03:43, the last dispatch pass, on h1-main"
}

# ar-4306: cachyos-rog woke with a store frozen since 2026-11-15 and sent 328 ready; the max over
# hosts showed it. The host whose pass ran last is the source, and the other one is named stale.
@test "a stale host's bigger queue is ignored and named in amber; its failed runner is not ours" {
  feed h2:summary_dispatch.runnable=328 h2:summary_dispatch.last_pass_epoch=$((100000 - 600000)) \
    h2:runner_fleet_dispatch.failed=1 h2:watch_queue_starved.tripped=1
  run "$MODULE"
  assert_equal "$(text)" "$(bar "$(y 39)" 12)"
  assert_equal "$(class)" warn
  head_is "$(y 'h2-main (328 ready) sends a stale queue')" "stop agent-mqtt-publish there"
  refute_output --partial "queue-starved"
  refute_output --partial "runner failed"
}

@test "a key the source lacks is never filled from a stale host" {
  feed runner_fleet_dispatch.failed=- watch_queue_starved.tripped=- \
    h2:summary_dispatch.runnable=328 h2:summary_dispatch.last_pass_epoch=$((100000 - 600000)) \
    h2:runner_fleet_dispatch.failed=1 h2:watch_queue_starved.tripped=1
  run "$MODULE"
  assert_equal "$(class)" warn
  run tip
  refute_output --partial "runner failed"
  refute_output --partial "queue-starved"
}

@test "negative control: the host whose pass ran last is the source, even with the smaller queue" {
  feed h2:summary_dispatch.runnable=3 h2:summary_dispatch.last_pass_epoch=$((100000 - 60))
  run "$MODULE"
  assert_equal "$(text)" "$(bar "$(y 3)" -)"
  run tip
  assert_output --partial "h1-main (39 ready) sends a stale queue"
  assert_output --partial "the last dispatch pass, on h2-main"
}

@test "with no pass on record anywhere every host counts by the max, and the head says no pass is on record" {
  feed summary_dispatch.last_pass_epoch=- h2:summary_dispatch.runnable=5
  run "$MODULE"
  assert_equal "$(jq -r .text <<< "$output" | grep -c 39)" 1
  assert_equal "$(class)" critical
  head_is "$(r 'no dispatch pass on record')" "systemctl --user status agentctl-fleet-dispatch.timer"
  refute_output --partial "stale queue"
  refute_output --partial "as of"
  assert_output --partial "<b>Dispatch:</b> last pass - ago"
}

@test "the shepherd section shows its last pass and 24h; an unhandled due line is amber; off the feed it is left out" {
  feed summary_shepherd.due=6 summary_shepherd.unhandled=0 summary_shepherd.skipped=12 summary_shepherd.nudges_24h=40 \
    summary_shepherd.escalations_24h=45 summary_shepherd.passes_24h=3 summary_shepherd.last_pass_epoch=99100
  run "$MODULE"
  assert_equal "$(class)" ok
  run tip
  assert_line --index 14 "<b>Shepherd:</b> last pass 15m ago"
  assert_line --index 15 "<tt>  last pass        6  due, 12 skipped, 0 unhandled"
  assert_line --index 16 "  last 24h        40  nudges, 45 escalations, 3 passes</tt>"
  feed summary_shepherd.due=6 summary_shepherd.unhandled=2
  run "$MODULE"
  assert_equal "$(class)" warn
  head_is "$(y '2 shepherd due line(s) unhandled')" "shepherd skill, triage"
  assert_output --partial "due, - skipped, $(y 2) unhandled"
  assert_output --partial "<b>Shepherd:</b> no pass on record"
  feed
  run "$MODULE"
  run tip
  refute_output --partial "Shepherd"
}

@test "no start on record reads - for its age, and no ready age reads - in the hover" {
  feed summary_dispatch.last_run_start_epoch=-
  run "$MODULE"
  run tip
  assert_output --partial "last start - ago"
  feed summary_dispatch.oldest_runnable_s=-
  run "$MODULE"
  run tip
  assert_line --index 2 --partial "  oldest           -  urgent"
}

# Negative control: no dispatch numbers is -, never a 0 nobody counted.
@test "a board the feed lacks reads -, never 0, in the hover" {
  feed summary_dispatch.board_agent=- summary_dispatch.board_backlog=-
  run "$MODULE"
  assert_equal "$(text)" "$(bar 39 12)"
  run tip
  assert_line --index 8 "  board            -  agent rows, - on the backlog</tt>"
}

@test "D is the items done today; a feed without it reads -, never 0" {
  feed summary_dispatch.done_today=-
  run "$MODULE"
  assert_equal "$(text)" "$(bar 39 -)"
  run tip
  assert_line --index 4 "D done today       -"
}

# The labels are the theme accent, palette.css's palette_accent. Negative controls: no palette,
# and an accent that is a level colour (Jackie Brown's warn amber), keep C_DIM.
@test "the labels take the palette accent; no palette or a level-colour accent keeps the dim grey" {
  echo '@define-color palette_accent #123456;' > "$PANGO_PALETTE"
  run "$MODULE"
  assert_equal "$(text)" "$(LABEL='#123456' bar 39 12)"
  echo '@define-color palette_accent #FFCC2F;' > "$PANGO_PALETTE"
  run "$MODULE"
  assert_equal "$(text)" "$(bar 39 12)"
  rm "$PANGO_PALETTE"
  run "$MODULE"
  assert_equal "$(text)" "$(bar 39 12)"
}

@test "no summary/dispatch on the feed reads - in amber with the publisher to check, never 0" {
  feed summary_dispatch.runnable=-
  run "$MODULE"
  assert_equal "$(text)" "$(bar "$(y -)" 12)"
  assert_equal "$(class)" warn
  head_is "$(y 'no dispatch numbers on the feed')" "systemctl --user status agent-mqtt-publish.timer"
}

@test "Prometheus unreadable reads ? in amber, never blank" {
  CURL_FAIL=1 run "$MODULE"
  assert_success
  assert_equal "$(text)" "$(y 'Q?')"
  assert_equal "$(class)" warn
  run tip
  assert_output "<b>Queue:</b> $(y 'cannot read http://prom.test')"
}

@test "the refill point reads on the ready row; an old feed without it reads as before" {
  feed summary_dispatch.low_water=3
  run "$MODULE"
  assert_equal "$(text)" "$(bar 39 12)"
  run tip
  assert_line --index 1 "<tt>Q ready           39  32 urgent, 7 high; 60 queued in all; refills under 3"
  feed
  run "$MODULE"
  run tip
  refute_output --partial "refills"
}

# The dropdown draws each line on one row (dotfiles-chips detail.luau, maxLines 1) in an 820px
# panel: about 95 monospace characters. Every exception at once is the longest hover there is.
@test "no hover line is over 90 visible characters, even with every exception at once" {
  feed runner_fleet_dispatch.failed=1 summary_dispatch.flapping_items=12 summary_dispatch.could_start=10 \
    summary_dispatch.held_s=36000 summary_dispatch.room_held_account=1 watch_queue_starved.tripped=1 \
    acct:main.pace=1 acct:main.five_hour=1 acct:alt.reserve=1 acct:bnb.weekly=1 \
    summary_dispatch.focus_projects=3 summary_dispatch.low_water=3 summary_dispatch.oldest_high_s=90000 \
    cachyos-x8664:summary_dispatch.runnable=328 cachyos-x8664:summary_dispatch.last_pass_epoch=1000 \
    summary_shepherd.due=6 summary_shepherd.unhandled=2 summary_shepherd.last_pass_epoch=99100
  run "$MODULE"
  run tip
  assert_equal "$(sed 's/<[^>]*>//g' <<< "$output" | awk 'length > 90')" ""
}
