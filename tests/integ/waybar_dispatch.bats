#!/usr/bin/env bats
# dispatch.sh: the waybar queue chip, the one chip for agent work. The bar is the ready queue
# items, the oldest one's wait and the run units against the cap, coloured by what is wrong; the
# hover has a section per system (Queue, Dispatch, Sessions, Shepherd). What these pin: a deep
# queue that is moving stays neutral; BLOCKED, flapping, an unclear session and an unhandled
# shepherd line are amber; queue-starved, a failed runner, a stopped pass, a stalled session and
# a stale fleet_sessions.prom are red; each number takes its own colour; a second host's series
# count once while sessions add up over hosts; Prometheus down reads ? and no dispatch numbers
# read -, never a blank chip.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic
  MODULE="$REPO_ROOT/.config/waybar/dispatch.sh"
  ICON=$'\uf01c' # nf-fa-inbox, as an escape so no editor can strip it
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
# running, 10 waiting; 5 started and 4 done in 1h, 50 started and 40 done (2 failed) in 24h;
# 30 done and 18 added in 6h; 16 of 24 run units, 5 by hand), and its
# sessions (5 working, 2 needs idle 30 and 90 minutes, 1 done, the textfile written 60s ago),
# with the overrides applied. A series is topic.key (a feed number, summary_shepherd.* for the
# shepherd), sess:BUCKET (a count), idle:BUCKET:target (minutes), mtime (age in seconds); h2:
# prefixes another host, dup: a second scrape of h1; a value of - drops the series.
feed() {
  python3 - "$FX/prom.json" "$@" <<'PY'
import json, sys
s = {
    "summary_dispatch.runnable": 39, "summary_dispatch.runnable_urgent": 32,
    "summary_dispatch.oldest_runnable_s": 46758, "summary_dispatch.oldest_urgent_s": 46758,
    "summary_dispatch.last_pass_epoch": 100000 - 180, "summary_dispatch.last_run_start_epoch": 100000 - 720,
    "summary_dispatch.started_1h": 5, "summary_dispatch.failed_1h": 0,
    "summary_dispatch.started_24h": 50, "summary_dispatch.failed_24h": 2,
    "summary_dispatch.reaped_1h": 7, "summary_dispatch.flapping_items": 0,
    "summary_dispatch.queued": 60, "summary_dispatch.running": 14, "summary_dispatch.waiting": 10,
    "summary_dispatch.held": 21, "summary_dispatch.held_after": 19, "summary_dispatch.held_pr": 2,
    "summary_dispatch.held_time": 0, "summary_dispatch.done_1h": 4, "summary_dispatch.done_6h": 30,
    "summary_dispatch.added_6h": 18, "summary_dispatch.done_24h": 40,
    "summary_dispatch.room_live_runs": 16, "summary_dispatch.room_max_live": 24,
    "summary_dispatch.room_live_hand": 5, "summary_dispatch.room_load": 27.4,
    "summary_dispatch.room_load_cap": 36, "summary_dispatch.room_idle": 45.2,
    "summary_dispatch.room_min_idle": 30, "summary_dispatch.room_held_slots": 0,
    "summary_dispatch.room_held_account": 0,
    "runner_fleet_dispatch.failed": 0, "runner_fleet_dispatch.blocked": 0,
    "watch_queue_starved.tripped": 0,
    "sess:WORKING": 5, "sess:NEEDS": 2, "sess:STALLED": 0, "sess:UNCLEAR": 0, "sess:LANDED": 0,
    "sess:DONE": 1, "sess:PARKED": 0, "idle:NEEDS:hub/a:1": 30, "idle:NEEDS:lab/b:2": 90, "mtime": 60,
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
    if k == "mtime":
        m = {"__name__": "node_textfile_mtime_seconds", "file": "/var/lib/node_exporter/textfile/fleet_sessions.prom"}
        v = 100000 - v
    elif k.startswith("idle:"):
        _, b, t = k.split(":", 2)
        m = {"__name__": "agent_session_idle_minutes", "bucket": b, "target": t, "project": "proj"}
    elif k.startswith("sess:"):
        m = {"__name__": "agent_sessions", "bucket": k[5:]}
    else:
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

@test "a deep queue that is moving is neutral: ready, the oldest wait, units against the cap" {
  run "$MODULE"
  assert_success
  assert_equal "$(text)" "$ICON 39 12h <span color='$G'>16/24</span>"
  assert_equal "$(class)" ok
}

@test "the hover has a section per system, in standard terms" {
  run "$MODULE"
  run tip
  assert_line --index 0 "<b>Queue</b>  84 items: 60 queued, 14 running, 10 waiting on you"
  assert_line --index 1 "queued: 39 ready (32 urgent or high), 21 blocked (19 on a phase, 2 on a PR, 0 on a time tag)"
  assert_line --index 2 "oldest: ready 12h59m, urgent <span color='$Y'>12h59m</span>"
  assert_line --index 3 "last hour: 5 started, 4 done, 0 failed"
  assert_line --index 4 "last 24h: 50 started, 38 done, <span color='$Y'>2</span> failed"
  assert_line --index 5 "drain 6h: 18 added, 30 finished, net -12: <span color='$G'>shrinking, empty in about 30h at that rate</span>"
  assert_line --index 6 "<b>Dispatch</b>  a pass every 15 minutes"
  assert_line --index 7 "capacity: run units <span color='$G'>16/24</span>, +5 by hand; load <span color='$G'>27 of 36</span>; idle <span color='$G'>45% (floor 30%)</span>"
  assert_line --index 8 "can start now: - more; last pass 3m ago, last start 12m ago"
  assert_line --index 9 "self-heal last hour: reaped 7, flapping 0"
  assert_line --index 10 "<b>Sessions</b>  fleet-sessions stages, every minute"
  assert_line --index 11 "5 working, <span color='$Y'>2</span> need you, 0 stalled, 0 unclear, 0 landed, 1 done, 0 parked"
  assert_line --index 12 "NEEDS  lab/b:2  proj  idle 1h30m"
  assert_line --index 13 "NEEDS  hub/a:1  proj  idle 30m"
  refute_output --partial "<b>Shepherd</b>"
}

@test "an urgent item ready under an hour is plain; queue-starved paints its wait red" {
  feed summary_dispatch.oldest_urgent_s=1800
  run "$MODULE"
  run tip
  assert_line --index 2 "oldest: ready 12h59m, urgent 30m"
  feed watch_queue_starved.tripped=1
  run "$MODULE"
  run tip
  assert_output --partial "urgent <span color='$R'>12h59m</span>"
}

@test "each capacity number takes its own colour: green with room, amber near its limit, red past it" {
  feed summary_dispatch.room_live_runs=24 summary_dispatch.room_load=40 summary_dispatch.room_idle=20
  run "$MODULE"
  assert_equal "$(text)" "$ICON 39 12h <span color='$Y'>24/24</span>"
  run tip
  assert_output --partial "capacity: run units <span color='$Y'>24/24</span>"
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
  assert_line --index 5 "drain 6h: 42 added, 30 finished, net +12: <span color='$Y'>growing about 2/h</span>"
  feed summary_dispatch.added_6h=30
  run "$MODULE"
  run tip
  assert_line --index 5 "drain 6h: 30 added, 30 finished, net 0: steady"
  feed summary_dispatch.added_6h=28
  run "$MODULE"
  run tip
  assert_line --index 5 "drain 6h: 28 added, 30 finished, net -2: <span color='$G'>shrinking, empty in about 8d at that rate</span>"
}

@test "the gate that paused the last pass is named in amber; none paused, no line" {
  feed summary_dispatch.room_held_slots=1
  run "$MODULE"
  run tip
  assert_output --partial "paused by: <span color='$Y'>every run unit is used (DISPATCH_MAX_LIVE)</span>"
  feed summary_dispatch.room_held_account=1
  run "$MODULE"
  run tip
  assert_output --partial "no account has room under its weekly pace"
  feed summary_dispatch.room_held_assess=1
  run "$MODULE"
  run tip
  assert_output --partial "fleet-assess says the machine is too busy (fleet-assess)"
  feed
  run "$MODULE"
  run tip
  refute_output --partial "paused by:"
}

@test "a feed without the queue or room numbers reads - and says no headroom, never 0" {
  feed summary_dispatch.queued=- summary_dispatch.done_6h=- summary_dispatch.room_max_live=-
  run "$MODULE"
  assert_equal "$(text)" "$ICON 39 12h"
  run tip
  assert_line --index 0 "<b>Queue</b>  - items: - queued, 14 running, 10 waiting on you"
  assert_line --index 5 "drain 6h: -"
  assert_output --partial "capacity: no headroom from a pass in the last 45 minutes"
}

@test "a pass that left ready work waiting (BLOCKED) is amber and leads the hover" {
  feed runner_fleet_dispatch.blocked=1
  run "$MODULE"
  assert_equal "$(text)" "<span color='$Y'>$ICON 39 12h</span> <span color='$G'>16/24</span>"
  assert_equal "$(class)" warn
  run tip
  assert_line --index 1 "<span color='$Y'>the last pass left ready work waiting (BLOCKED)</span>"
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
  assert_equal "$(text)" "<span color='$R'>$ICON 39 12h</span> <span color='$G'>16/24</span>"
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

@test "a stalled session is red, leads the hover and heads the Sessions list" {
  feed sess:STALLED=1 "idle:STALLED:lab/c:3=200"
  run "$MODULE"
  assert_equal "$(class)" critical
  run tip
  assert_line --index 1 "<span color='$R'>1 session(s) STALLED: unlanded work and idle, or a ready PR that conflicts</span>"
  assert_output --partial "<span color='$R'>1</span> stalled"
  assert_output --partial $'every minute\n5 working, <span color=\''"$Y"$'\'>2</span> need you, <span color=\''"$R"$'\'>1</span> stalled, 0 unclear, 0 landed, 1 done, 0 parked\n<span color=\''"$R"$'\'>STALLED  lab/c:3  proj  idle 3h20m</span>\nNEEDS  lab/b:2  proj  idle 1h30m'
}

@test "an unclear session is amber" {
  feed sess:UNCLEAR=1
  run "$MODULE"
  assert_equal "$(class)" warn
  run tip
  assert_output --partial "<span color='$Y'>1</span> unclear"
}

@test "a sessions textfile older than five minutes is red: the tick stopped" {
  feed mtime=900
  run "$MODULE"
  assert_equal "$(class)" critical
  run tip
  assert_output --partial "fleet_sessions.prom on h1 is 15m old"
}

@test "a second host's queue series count once, by their max; its sessions add up" {
  feed h2:summary_dispatch.runnable=3 h2:watch_queue_starved.tripped=0 dup:sess:WORKING=5 h2:sess:WORKING=3 h2:mtime=30
  run "$MODULE"
  assert_equal "$(text)" "$ICON 39 12h <span color='$G'>16/24</span>"
  run tip
  assert_output --partial $'every minute\n8 working,'
}

@test "no sessions on the feed says so in the Sessions section and leaves the queue alone" {
  feed sess:WORKING=- sess:NEEDS=- sess:STALLED=- sess:UNCLEAR=- sess:LANDED=- sess:DONE=- sess:PARKED=-
  run "$MODULE"
  assert_equal "$(class)" ok
  run tip
  assert_output --partial "no agent_sessions on Prometheus: fleet-sessions tick writes fleet_sessions.prom"
}

@test "the shepherd section shows its last pass and 24h; an unhandled due line is amber; off the feed it is left out" {
  feed summary_shepherd.due=6 summary_shepherd.unhandled=0 summary_shepherd.skipped=12 summary_shepherd.nudges_24h=40 \
    summary_shepherd.escalations_24h=45 summary_shepherd.passes_24h=3 summary_shepherd.last_pass_epoch=99100
  run "$MODULE"
  assert_equal "$(class)" ok
  run tip
  assert_line --index 14 "<b>Shepherd</b>  moves sessions through their plans"
  assert_line --index 15 "last pass: 6 due, 0 unhandled, 12 skipped; 15m ago"
  assert_line --index 16 "last 24h: 40 nudges, 45 escalations, 3 passes"
  feed summary_shepherd.due=6 summary_shepherd.unhandled=2
  run "$MODULE"
  assert_equal "$(class)" warn
  run tip
  assert_line --index 1 --partial "2 shepherd due line(s) unhandled"
  assert_output --partial "<span color='$Y'>2</span> unhandled"
  assert_output --partial "none on record"
}

@test "no start on record reads - for its age, and no ready age reads - on the bar" {
  feed summary_dispatch.last_run_start_epoch=-
  run "$MODULE"
  run tip
  assert_output --partial "last start - ago"
  feed summary_dispatch.oldest_runnable_s=-
  run "$MODULE"
  assert_equal "$(text)" "$ICON 39 - <span color='$G'>16/24</span>"
}

# Negative control: no dispatch numbers is -, never a 0 nobody counted.
@test "no summary/dispatch on the feed reads - in amber, never 0, and the sessions still show" {
  feed summary_dispatch.runnable=-
  run "$MODULE"
  assert_equal "$(text)" "$ICON <span color='$Y'>-</span>"
  assert_equal "$(class)" warn
  run tip
  assert_output --partial "no dispatch numbers on the feed"
  assert_output --partial "<b>Sessions</b>"
}

@test "Prometheus unreadable reads ? in amber, never blank" {
  CURL_FAIL=1 run "$MODULE"
  assert_success
  assert_equal "$(text)" "$ICON <span color='$Y'>?</span>"
  assert_equal "$(class)" warn
  run tip
  assert_output --partial "cannot read http://prom.test"
}
