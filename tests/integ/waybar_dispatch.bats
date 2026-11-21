#!/usr/bin/env bats
# dispatch.sh: the waybar queue chip, the one chip for agent work flowing. The bar is two labelled totals: the items
# ready to start next and the items done today (the agent board and backlog counts are hover only; sprints are the projects chip's), with Q coloured by what is wrong; the hover has a section per system (Queue, Dispatch, Shepherd); sessions are the agents chip's
# (waybar_ai_agents.bats). What these pin: a deep queue that is moving stays neutral; BLOCKED,
# flapping and an unhandled shepherd line are amber; queue-starved, a failed runner and a stopped
# pass are red; each number takes its own colour; the host whose pass ran last is the source and any
# other sender is named stale in amber (ar-4306); Prometheus
# down reads ? and no dispatch numbers read -, never a blank chip.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic
  MODULE="$REPO_ROOT/.config/waybar/dispatch.sh"
  # No palette unless a test writes one: a clone's own palette.css is per clone.
  export PANGO_PALETTE="$BATS_TEST_TMPDIR/palette.css"
  G="#a6e34a" Y="#ffcc2f" R="#ef5734"
  export CC_PROM_URL=http://prom.test FX="$BATS_TEST_TMPDIR" DISPATCH_NOW=100000
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
# series is topic.key (a feed number, summary_shepherd.* for the shepherd); h2: prefixes another
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
    "summary_dispatch.added_6h": 18, "summary_dispatch.done_24h": 40, "summary_dispatch.shipped_today": 12, "summary_dispatch.checks_today": 9,
    "summary_cards.figures_queue_on_deck": 39, "summary_cards.figures_projects_shipped_today": 12, "summary_cards.figures_projects_checks_closed": 9,
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
    if k.startswith("h2:"): host, inst, k = "h2", "i2", k[3:]
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

@test "a deep queue that is moving is neutral: the two totals, nothing else" {
  run "$MODULE"
  assert_success
  assert_equal "$(text)" "$(bar 39 12)"
  assert_equal "$(class)" ok
}

@test "the hover has a section per system, in standard terms" {
  run "$MODULE"
  run tip
  assert_line --index 1 "<b>Queue</b>  90 items: 60 queued, 14 running, 6 on a PR, 10 waiting on you"
  assert_line --index 2 "queued: 39 ready (32 urgent, 7 high)"
  assert_line --index 3 "oldest: ready 12h59m, urgent <span color='$Y'>12h59m</span>"
  assert_line --index 4 "last hour: 5 started, 4 done, 0 failed"
  assert_line --index 5 "last 24h: 50 started, 38 done, <span color='$Y'>2</span> failed"
  assert_line --index 6 "drain 6h: 18 added, 30 finished, net -12: <span color='$G'>shrinking, empty in about 30h at that rate</span>"
  assert_line --index 7 "today: 1522 agent rows (2200 more on the backlog)"
  assert_line --index 8 "from h1-main, the machine whose dispatch ran last"
  assert_line --index 9 "<b>Dispatch</b>  a pass every 15 minutes"
  assert_line --index 10 "capacity: sessions 21 of a 24 target; run units <span color='$G'>16/24</span>, +5 by hand; load <span color='$G'>27 of 36</span>; idle <span color='$G'>45% (floor 30%)</span>"
  assert_line --index 11 "can start now: - more; last pass 3m ago, last start 12m ago"
  assert_line --index 12 "self-heal last hour: reaped 7, flapping 0"
  refute_output --partial "<b>Sessions</b>"
  refute_output --partial "<b>Shepherd</b>"
}

@test "an urgent item ready under an hour is plain; queue-starved paints its wait red" {
  feed summary_dispatch.oldest_urgent_s=1800
  run "$MODULE"
  run tip
  assert_line --index 3 "oldest: ready 12h59m, urgent 30m"
  feed watch_queue_starved.tripped=1
  run "$MODULE"
  run tip
  assert_output --partial "urgent <span color='$R'>12h59m</span>"
}

@test "the oldest high item's wait rides after the urgent one; a feed without it reads as before" {
  feed summary_dispatch.oldest_urgent_s=1800 summary_dispatch.oldest_high_s=7200
  run "$MODULE"
  run tip
  assert_line --index 3 "oldest: ready 12h59m, urgent 30m, high 2h00m"
}

@test "each capacity number takes its own colour: green with room, amber near its limit, red past it" {
  feed summary_dispatch.room_live_runs=24 summary_dispatch.room_load=40 summary_dispatch.room_idle=20
  run "$MODULE"
  assert_equal "$(text)" "$(bar 39 12)"
  run tip
  assert_output --partial "capacity: sessions 21 of a 24 target; run units <span color='$Y'>24/24</span>"
  assert_output --partial "load <span color='$R'>40 of 36</span>"
  assert_output --partial "idle <span color='$R'>20% (floor 30%)</span>"
  feed summary_dispatch.room_load=29 summary_dispatch.room_idle=35
  run "$MODULE"
  run tip
  assert_output --partial "load <span color='$Y'>29 of 36</span>"
  assert_output --partial "idle <span color='$Y'>35% (floor 30%)</span>"
}

@test "drain: more in than out is growing in amber, never an empty time; even is steady, plain; a slow drain reads days" {
  feed summary_dispatch.added_6h=42
  run "$MODULE"
  run tip
  assert_line --index 6 "drain 6h: 42 added, 30 finished, net +12: <span color='$Y'>growing about 2/h</span>"
  feed summary_dispatch.added_6h=30
  run "$MODULE"
  run tip
  assert_line --index 6 "drain 6h: 30 added, 30 finished, net 0: steady"
  feed summary_dispatch.added_6h=28
  run "$MODULE"
  run tip
  assert_line --index 6 "drain 6h: 28 added, 30 finished, net -2: <span color='$G'>shrinking, empty in about 8d at that rate</span>"
}

@test "the gate that paused the last pass is named in amber; none paused, no line" {
  feed summary_dispatch.room_held_slots=1
  run "$MODULE"
  run tip
  assert_output --partial "paused by: <span color='$Y'>the fleet is at its Claude pace target (what the accounts carry, at most DISPATCH_TARGET_PRESENT here, DISPATCH_TARGET_AWAY away)</span>"
  feed summary_dispatch.room_held_account=1
  run "$MODULE"
  run tip
  assert_output --partial "paused by: <span color='$Y'>no account has room</span>"
  # The accounts' published verdicts name each one's reason; the gate reads them, never its own guess.
  feed summary_dispatch.room_held_account=1 acct:main.pace=1 acct:main.five_hour=1 acct:alt.reserve=1
  run "$MODULE"
  run tip
  assert_output --partial "paused by: <span color='$Y'>no account has room: alt reserve, main five_hour+pace</span>"
  refute_output --partial "under its weekly pace"
  feed summary_dispatch.room_held_assess=1
  run "$MODULE"
  run tip
  assert_output --partial "fleet-assess says the machine is too busy (fleet-assess)"
  feed
  run "$MODULE"
  run tip
  refute_output --partial "paused by:"
}

@test "a #prio/focus project reads in amber with how many there are; no focus, or an old feed, no line" {
  feed summary_dispatch.focus_projects=2
  run "$MODULE"
  run tip
  assert_output --partial "focus: <span color='$Y'>2 project(s)</span> first, ahead of the other projects (reds and urgent items still go first)"
  refute_output --partial "off focus"
  feed summary_dispatch.focus_projects=0
  run "$MODULE"
  run tip
  refute_output --partial "focus:"
  feed
  run "$MODULE"
  run tip
  refute_output --partial "focus:"
}

@test "a feed without the queue or room numbers reads - and says no headroom, never 0" {
  feed summary_dispatch.queued=- summary_dispatch.done_6h=- summary_dispatch.room_max_live=-
  run "$MODULE"
  assert_equal "$(text)" "$(bar 39 12)"
  run tip
  assert_line --index 1 "<b>Queue</b>  - items: - queued, 14 running, 6 on a PR, 10 waiting on you"
  assert_line --index 6 "drain 6h: -"
  assert_output --partial "capacity: no headroom from a pass in the last 45 minutes"
}

@test "a pass that left ready work waiting (BLOCKED) is amber and leads the hover" {
  feed runner_fleet_dispatch.blocked=1
  run "$MODULE"
  assert_equal "$(text)" "$(bar "<span color='$Y'>39</span>" 12)"
  assert_equal "$(class)" warn
  run tip
  assert_line --index 2 "<span color='$Y'>the last pass left ready work waiting (BLOCKED)</span>"
}

@test "a standing hold leads the hover as how long dispatch has stopped and which gate holds it" {
  feed runner_fleet_dispatch.blocked=1 summary_dispatch.held_s=7380 summary_dispatch.room_held_account=1
  run "$MODULE"
  assert_equal "$(class)" warn
  run tip
  assert_line --index 2 "<span color='$Y'>dispatch stopped 2h03m: no account has room</span>"
  refute_output --partial "(BLOCKED)"
  feed runner_fleet_dispatch.blocked=1 summary_dispatch.held_s=600
  run "$MODULE"
  run tip
  assert_line --index 2 "<span color='$Y'>dispatch stopped 10m: the last pass left ready work waiting</span>"
}

@test "a flapping item is amber, in the why and the self-heal line" {
  feed summary_dispatch.flapping_items=1
  run "$MODULE"
  assert_equal "$(class)" warn
  run tip
  assert_output --partial "1 item(s) flapping"
  assert_output --partial "flapping <span color='$Y'>1</span>"
}

@test "more could start than the limits let the last pass: amber, with the count" {
  feed summary_dispatch.could_start=2
  run "$MODULE"
  assert_equal "$(class)" warn
  run tip
  assert_output --partial "2 more could start now: a limit, not the machine, holds them"
  assert_output --partial "can start now: <span color='$Y'>2</span> more"
  feed summary_dispatch.could_start=0
  run "$MODULE"
  assert_equal "$(class)" ok
}

@test "queue-starved tripped is red, whatever else is fine" {
  feed watch_queue_starved.tripped=1
  run "$MODULE"
  assert_equal "$(text)" "$(bar "<span color='$R'>39</span>" 12)"
  assert_equal "$(class)" critical
  run tip
  assert_output --partial "queue-starved is tripped"
}

@test "a failed fleet-dispatch runner is red" {
  feed runner_fleet_dispatch.failed=1
  run "$MODULE"
  assert_equal "$(class)" critical
  run tip
  assert_output --partial "the fleet-dispatch runner failed"
}

@test "no pass in 45 minutes is red: the timer stopped, even with every other number fine" {
  feed summary_dispatch.last_pass_epoch=$((100000 - 2760))
  run "$MODULE"
  assert_equal "$(class)" critical
  run tip
  assert_output --partial "no pass in 46m; is fleet-dispatch.timer running?"
}

@test "a second scrape of the source host counts once, and the hover names the source" {
  feed dup:summary_dispatch.runnable=39
  run "$MODULE"
  assert_equal "$(text)" "$(bar 39 12)"
  assert_equal "$(class)" ok
  tip | grep -qxF "from h1-main, the machine whose dispatch ran last"
}

# ar-4306: cachyos-rog woke with a store frozen since 2026-11-15 and sent 328 ready; the max over
# hosts showed it. The host whose pass ran last is the source, and the other one is named stale.
@test "a stale host's bigger queue is ignored and named in amber; its failed runner is not ours" {
  feed h2:summary_dispatch.runnable=328 h2:summary_dispatch.last_pass_epoch=$((100000 - 600000)) h2:summary_cards.figures_queue_on_deck=328 \
    h2:runner_fleet_dispatch.failed=1 h2:watch_queue_starved.tripped=1
  run "$MODULE"
  assert_equal "$(text)" "$(bar "<span color='$Y'>39</span>" 12)"
  assert_equal "$(class)" warn
  run tip
  assert_output --partial "stale: h2-main (328 ready) still sends a queue, ignored"
  refute_output --partial "queue-starved is tripped"
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
  refute_output --partial "queue-starved is tripped"
}

@test "negative control: the host whose pass ran last is the source, even with the smaller queue" {
  feed h2:summary_dispatch.runnable=3 h2:summary_dispatch.last_pass_epoch=$((100000 - 60)) h2:summary_cards.figures_queue_on_deck=3
  run "$MODULE"
  assert_equal "$(text)" "$(bar "<span color='$Y'>3</span>" -)"
  tip | grep -qF "stale: h1-main (39 ready)"
}

@test "a host with no pass on record is still counted, by the max, when no host has one" {
  feed summary_dispatch.last_pass_epoch=- h2:summary_dispatch.runnable=5
  run "$MODULE"
  assert_equal "$(jq -r .text <<< "$output" | grep -c 39)" 1
  run tip
  refute_output --partial "stale:"
}

@test "the shepherd section shows its last pass and 24h; an unhandled due line is amber; off the feed it is left out" {
  feed summary_shepherd.due=6 summary_shepherd.unhandled=0 summary_shepherd.skipped=12 summary_shepherd.nudges_24h=40 \
    summary_shepherd.escalations_24h=45 summary_shepherd.passes_24h=3 summary_shepherd.last_pass_epoch=99100
  run "$MODULE"
  assert_equal "$(class)" ok
  run tip
  assert_line --index 13 "<b>Shepherd</b>  moves sessions through their plans"
  assert_line --index 14 "last pass: 6 due, 0 unhandled, 12 skipped; 15m ago"
  assert_line --index 15 "last 24h: 40 nudges, 45 escalations, 3 passes"
  feed summary_shepherd.due=6 summary_shepherd.unhandled=2
  run "$MODULE"
  assert_equal "$(class)" warn
  run tip
  assert_line --index 2 --partial "2 shepherd due line(s) unhandled"
  assert_output --partial "<span color='$Y'>2</span> unhandled"
  assert_output --partial "none on record"
}

@test "no start on record reads - for its age, and no ready age reads - in the hover" {
  feed summary_dispatch.last_run_start_epoch=-
  run "$MODULE"
  run tip
  assert_output --partial "last start - ago"
  feed summary_dispatch.oldest_runnable_s=-
  run "$MODULE"
  run tip
  assert_output --partial "oldest: ready -"
}

# Negative control: no dispatch numbers is -, never a 0 nobody counted.
@test "a board the feed lacks reads -, never 0, in the hover" {
  feed summary_dispatch.board_agent=- summary_dispatch.board_backlog=-
  run "$MODULE"
  assert_equal "$(text)" "$(bar 39 12)"
  run tip
  assert_line --index 7 "today: - agent rows (- more on the backlog)"
}

@test "Q and D are hub cards figures; a feed without them reads -, never 0" {
  feed summary_cards.figures_queue_on_deck=- summary_cards.figures_projects_shipped_today=- summary_cards.figures_projects_checks_closed=-
  run "$MODULE"
  assert_equal "$(text)" "$(bar - -)"
  run tip
  assert_line --index 0 "Q ready to start next, D shipped today (merged a PR); - checks closed with no merge"
}

@test "the hover opens by saying what each letter counts, checks beside D" {
  run "$MODULE"
  run tip
  assert_line --index 0 "Q ready to start next, D shipped today (merged a PR); 9 checks closed with no merge"
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

@test "no summary/dispatch on the feed reads - in amber, never 0" {
  feed summary_dispatch.runnable=-
  run "$MODULE"
  # The bar reads the cards figures, so only the flag and the amber say dispatch is missing.
  assert_equal "$(text)" "$(bar "<span color='$Y'>39</span>" 12)"
  assert_equal "$(class)" warn
  run tip
  assert_output --partial "no dispatch numbers on the feed"
}

@test "Prometheus unreadable reads ? in amber, never blank" {
  CURL_FAIL=1 run "$MODULE"
  assert_success
  assert_equal "$(text)" "<span color='$Y'>Q?</span>"
  assert_equal "$(class)" warn
  run tip
  assert_output --partial "cannot read http://prom.test"
}

@test "the low water reads in the hover; an old feed without it reads as before" {
  feed summary_dispatch.low_water=3
  run "$MODULE"
  assert_success
  assert_equal "$(text)" "$(bar 39 12)"
  assert_output --partial "39 ready (32 urgent, 7 high) of low water 3"
  feed
  run "$MODULE"
  assert_equal "$(text)" "$(bar 39 12)"
  refute_output --partial "low water"
}

@test "the hover ends with the vitals line, and has none when hub cannot read them" {
  printf '#!/usr/bin/env bash\necho "2 of 4 off target: You, Outcome"\necho "You  !  a row"\n' > "$SANDBOX/bin/fake-hub"
  chmod +x "$SANDBOX/bin/fake-hub"
  HUB="$SANDBOX/bin/fake-hub" run "$MODULE"
  run tip
  assert_output --partial $'\n\nvitals: 2 of 4 off target: You, Outcome'
  refute_output --partial 'a row'
  printf '#!/usr/bin/env bash\nexit 1\n' > "$SANDBOX/bin/fake-hub"
  HUB="$SANDBOX/bin/fake-hub" run "$MODULE"
  run tip
  refute_output --partial 'vitals:'
}
