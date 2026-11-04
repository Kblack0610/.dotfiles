#!/usr/bin/env bats
# dispatch.sh: the waybar queue chip. The bar is the runnable queue items and the oldest one's
# wait, coloured by what is wrong; the hover is the whole queue. What these pin: a deep queue that
# is moving stays neutral; BLOCKED and flapping are amber; queue-starved, a failed runner and a
# stopped pass are red; heals show as a dim +N; the hover counts every state, the drain trend,
# the room and what held the pass; a second host's series count once; Prometheus down reads ?
# and no dispatch numbers read -, never a blank chip.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic
  MODULE="$REPO_ROOT/.config/waybar/dispatch.sh"
  ICON=$'\uf01c' # nf-fa-inbox, as an escape so no editor can strip it
  export CC_PROM_URL=http://prom.test FX="$BATS_TEST_TMPDIR" DISPATCH_NOW=100000
  cat > "$SANDBOX/bin/curl" <<'STUB'
#!/usr/bin/env bash
[ -n "${CURL_FAIL:-}" ] && exit 7
cat "$FX/prom.json"
STUB
  chmod +x "$SANDBOX/bin/curl"
  feed
}

# feed [topic.key=value ...] -> Prometheus's answer: a healthy queue on host h1 (39 runnable,
# 32 urgent, the oldest 12h59m, last pass 3m ago, last start 12m ago, 7 reaps; 60 queued, 14
# running, 10 waiting; 30 done and 18 added in 6h; 16 of 24 run slots, 5 by hand), with the overrides applied. A
# value of - drops the series.
feed() {
  python3 - "$FX/prom.json" "$@" <<'PY'
import json, sys
s = {
    "summary_dispatch.runnable": 39, "summary_dispatch.runnable_urgent": 32,
    "summary_dispatch.oldest_runnable_s": 46758, "summary_dispatch.oldest_urgent_s": 46758,
    "summary_dispatch.last_pass_epoch": 100000 - 180, "summary_dispatch.last_run_start_epoch": 100000 - 720,
    "summary_dispatch.starts_1h_run": 4, "summary_dispatch.starts_1h_hand": 1,
    "summary_dispatch.starts_1h_redispatch": 0, "summary_dispatch.starts_1h_resume": 0,
    "summary_dispatch.reaped_1h": 7, "summary_dispatch.flapping_items": 0,
    "summary_dispatch.queued": 60, "summary_dispatch.running": 14, "summary_dispatch.waiting": 10,
    "summary_dispatch.held": 21, "summary_dispatch.held_after": 19, "summary_dispatch.held_pr": 2,
    "summary_dispatch.held_time": 0, "summary_dispatch.done_1h": 4, "summary_dispatch.done_6h": 30,
    "summary_dispatch.added_6h": 18, "summary_dispatch.done_24h": 40,
    "summary_dispatch.room_live_runs": 16, "summary_dispatch.room_max_live": 24,
    "summary_dispatch.room_live_hand": 5, "summary_dispatch.room_load": 27.4,
    "summary_dispatch.room_load_cap": 36, "summary_dispatch.room_idle": 35.2,
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
    host = "h1"
    if k.startswith("h2:"): host, k = "h2", k[3:]
    topic, name = k.split(".")
    res.append({"metric": {"__name__": "mqtt_" + name, "topic": f"agents_{host}_main_{topic}"}, "value": [0, str(v)]})
json.dump({"status": "success", "data": {"result": res}}, open(sys.argv[1], "w"))
PY
}

text() { jq -r .text <<< "$output"; }
class() { jq -r .class <<< "$output"; }
tip() { jq -r .tooltip <<< "$output"; }

@test "a deep queue that is moving is neutral: runnable, the oldest wait, a dim +N for heals" {
  run "$MODULE"
  assert_success
  assert_equal "$(text)" "$ICON 39 12h <span color='#7f7f7f'>+7</span>"
  assert_equal "$(class)" ok
}

@test "the hover is the whole queue: states, holds, oldest, flow, drain, room, pass, heals" {
  run "$MODULE"
  run tip
  assert_line --index 0 "<b>Queue</b>  60 queued, 14 running, 10 waiting on you"
  assert_line --index 1 "queued: 39 runnable (32 urgent or high), 21 held (19 after a phase, 2 on a PR, 0 by a time tag)"
  assert_line --index 2 "oldest: runnable 12h59m, urgent 12h59m"
  assert_line --index 3 "flow: last hour 5 started (run 4, hand 1, redispatch 0, resume 0), 4 done; 40 done in 24h"
  assert_line --index 4 "drain: last 6h +18 added, -30 done: shrinking, clears in about 30h at that rate"
  assert_line --index 5 "room: run units <span color='#a6e34a'>16/24</span>, +5 started by hand; load <span color='#a6e34a'>27 of 36</span>; idle <span color='#ffcc2f'>35% (floor 30%)</span>"
  assert_line --index 6 "last pass 3m ago, last start 12m ago"
  assert_line --index 7 "heals last hour: reaped 7, flapping 0; could start now: - more"
}

@test "each room number takes its own colour: green with room, amber near its limit, red past it" {
  feed summary_dispatch.room_live_runs=24 summary_dispatch.room_load=40 summary_dispatch.room_idle=20
  run "$MODULE"
  run tip
  assert_output --partial "room: run units <span color='#ffcc2f'>24/24</span>"
  assert_output --partial "load <span color='#ef5734'>40 of 36</span>"
  assert_output --partial "idle <span color='#ef5734'>20% (floor 30%)</span>"
  feed summary_dispatch.room_load=29 summary_dispatch.room_idle=40
  run "$MODULE"
  run tip
  assert_output --partial "load <span color='#ffcc2f'>29 of 36</span>"
  assert_output --partial "idle <span color='#a6e34a'>40% (floor 30%)</span>"
}

@test "more added than done in 6h reads growing, never a clear time" {
  feed summary_dispatch.added_6h=42
  run "$MODULE"
  run tip
  assert_line --index 4 "drain: last 6h +42 added, -30 done: growing about 2/h"
}

@test "the gate that held the last pass is named; none held, no line" {
  feed summary_dispatch.room_held_slots=1
  run "$MODULE"
  run tip
  assert_output --partial "held by: every run unit is used (DISPATCH_MAX_LIVE)"
  feed summary_dispatch.room_held_account=1
  run "$MODULE"
  run tip
  assert_output --partial "held by: no account has room under its weekly pace"
  feed summary_dispatch.room_held_assess=1
  run "$MODULE"
  run tip
  assert_output --partial "held by: fleet-assess says the machine is too busy (fleet-assess)"
  feed
  run "$MODULE"
  run tip
  refute_output --partial "held by:"
}

@test "a feed without the queue or room numbers reads - and says no headroom, never 0" {
  feed summary_dispatch.queued=- summary_dispatch.done_6h=- summary_dispatch.room_max_live=-
  run "$MODULE"
  run tip
  assert_line --index 0 "<b>Queue</b>  - queued, 14 running, 10 waiting on you"
  assert_line --index 4 "drain: -"
  assert_output --partial "room: no headroom from a pass in the last 45 minutes"
}

@test "no reaps in the hour leaves no +N" {
  feed summary_dispatch.reaped_1h=0
  run "$MODULE"
  assert_equal "$(text)" "$ICON 39 12h"
}

@test "a pass that left runnable work waiting (BLOCKED) is amber and says so" {
  feed runner_fleet_dispatch.blocked=1 summary_dispatch.reaped_1h=0
  run "$MODULE"
  assert_equal "$(text)" "<span color='#ffcc2f'>$ICON 39 12h</span>"
  assert_equal "$(class)" warn
  run tip
  assert_line --index 1 --partial "left runnable work waiting (BLOCKED)"
}

@test "a flapping item is amber" {
  feed summary_dispatch.flapping_items=1
  run "$MODULE"
  assert_equal "$(class)" warn
  run tip
  assert_output --partial "1 item(s) flapping"
}

@test "more could start than the limits let the last pass: amber, with the count" {
  feed summary_dispatch.could_start=2
  run "$MODULE"
  assert_equal "$(class)" warn
  run tip
  assert_output --partial "2 more could start now: a limit, not the machine, holds them"
  assert_output --partial "could start now: 2 more"
  feed summary_dispatch.could_start=0
  run "$MODULE"
  assert_equal "$(class)" ok
}

@test "queue-starved tripped is red with !, whatever else is fine" {
  feed watch_queue_starved.tripped=1 summary_dispatch.reaped_1h=0
  run "$MODULE"
  assert_equal "$(text)" "<span color='#ef5734'>$ICON 39 !</span>"
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

@test "a second host's series count once, by their max" {
  feed h2:summary_dispatch.runnable=3 h2:watch_queue_starved.tripped=0
  run "$MODULE"
  assert_equal "$(text)" "$ICON 39 12h <span color='#7f7f7f'>+7</span>"
}

@test "no start on record reads - for its age, and no runnable age reads - on the bar" {
  feed summary_dispatch.last_run_start_epoch=-
  run "$MODULE"
  run tip
  assert_output --partial "last start - ago"
  feed summary_dispatch.oldest_runnable_s=-
  run "$MODULE"
  assert_equal "$(text)" "$ICON 39 - <span color='#7f7f7f'>+7</span>"
}

# Negative control: no dispatch numbers is -, never a 0 nobody counted.
@test "no summary/dispatch on the feed reads - in amber, never 0" {
  feed summary_dispatch.runnable=-
  run "$MODULE"
  assert_equal "$(text)" "$ICON <span color='#ffcc2f'>-</span>"
  assert_equal "$(class)" warn
  run tip
  assert_output --partial "no dispatch numbers on the feed"
}

@test "Prometheus unreadable reads ? in amber, never blank" {
  CURL_FAIL=1 run "$MODULE"
  assert_success
  assert_equal "$(text)" "$ICON <span color='#ffcc2f'>?</span>"
  assert_equal "$(class)" warn
  run tip
  assert_output --partial "cannot read http://prom.test"
}
