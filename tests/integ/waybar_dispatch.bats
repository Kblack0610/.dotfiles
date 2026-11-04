#!/usr/bin/env bats
# dispatch.sh: the waybar dispatch chip. The bar is the runnable queue items and the time since
# the last start, coloured by what is wrong. What these pin: a deep queue that is moving stays
# green; BLOCKED and flapping are amber; queue-starved, a failed runner and a stopped pass are
# red; heals show as a dim +N; a second host's series count once; Prometheus down reads ? and
# no dispatch numbers read -, never a blank chip.

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
# 32 urgent, last pass 3m ago, last start 12m ago, 7 reaps), with the overrides applied. A
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

@test "a deep queue that is moving is green: runnable, last start, a dim +N for heals" {
  run "$MODULE"
  assert_success
  assert_equal "$(text)" "$ICON 39 12m <span color='#7f7f7f'>+7</span>"
  assert_equal "$(class)" ok
}

@test "the hover says runnable by priority, the last pass, starts by kind and heals" {
  run "$MODULE"
  run tip
  assert_line --index 1 "runnable: 39 (32 urgent or high), oldest 12h59m, oldest urgent 12h59m"
  assert_line --index 2 "last pass: 3m ago, last start: 12m ago"
  assert_line --index 3 "starts last hour: run 4, hand 1, redispatch 0, resume 0"
  assert_line --index 4 "heals last hour: reaped 7, flapping 0"
}

@test "no reaps in the hour leaves no +N" {
  feed summary_dispatch.reaped_1h=0
  run "$MODULE"
  assert_equal "$(text)" "$ICON 39 12m"
}

@test "a pass that left runnable work waiting (BLOCKED) is amber and says so" {
  feed runner_fleet_dispatch.blocked=1 summary_dispatch.reaped_1h=0
  run "$MODULE"
  assert_equal "$(text)" "<span color='#ffcc2f'>$ICON 39 12m</span>"
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
  assert_equal "$(text)" "$ICON 39 12m <span color='#7f7f7f'>+7</span>"
}

@test "no start on record reads - for the age" {
  feed summary_dispatch.last_run_start_epoch=-
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
