#!/usr/bin/env bats
# shepherd.sh: the waybar sessions chip. The bar is the live sessions per fleet-sessions stage, a
# zero hidden. What these pin: NEEDS alone stays green; UNCLEAR is amber, STALLED red; a stale
# fleet_sessions.prom is red; two scrapes of one host count once while two hosts add up; the
# hover lists the sessions worth a look, worst first; Prometheus down reads ? and no stage
# numbers read -, never a blank chip.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic
  MODULE="$REPO_ROOT/.config/waybar/shepherd.sh"
  ICON=$'\uf0ae' # nf-fa-tasks, as an escape so no editor can strip it
  export CC_PROM_URL=http://prom.test FX="$BATS_TEST_TMPDIR" SHEPHERD_NOW=100000
  cat > "$SANDBOX/bin/curl" <<'STUB'
#!/usr/bin/env bash
[ -n "${CURL_FAIL:-}" ] && exit 7
cat "$FX/prom.json"
STUB
  chmod +x "$SANDBOX/bin/curl"
  feed
}

# feed [series=value ...] -> Prometheus's answer: host h1 with 5 working, 2 needs, 1 done, its
# textfile written 60s ago, and the two needs sessions idle 30 and 90 minutes. A series is
# BUCKET (a count), idle:BUCKET:target (minutes), mtime (age in seconds) or dup (a second scrape
# of h1), shep:<field> (a summary/shepherd number); h2: prefixes another host; a value of - drops the series.
feed() {
  python3 - "$FX/prom.json" "$@" <<'PY'
import json, sys
s = {"WORKING": 5, "NEEDS": 2, "STALLED": 0, "UNCLEAR": 0, "LANDED": 0, "DONE": 1, "PARKED": 0,
     "idle:NEEDS:hub/a:1": 30, "idle:NEEDS:lab/b:2": 90, "mtime": 60}
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
    elif k.startswith("shep:"):
        m = {"__name__": "mqtt_" + k[5:], "topic": "agents_" + host + "_summary_shepherd"}
    elif k.startswith("idle:"):
        _, b, t = k.split(":", 2)
        m = {"__name__": "agent_session_idle_minutes", "bucket": b, "target": t, "project": "proj"}
    else:
        m = {"__name__": "agent_sessions", "bucket": k}
    m.update(host=host, instance=inst)
    res.append({"metric": m, "value": [0, str(v)]})
json.dump({"status": "success", "data": {"result": res}}, open(sys.argv[1], "w"))
PY
}

text() { jq -r .text <<< "$output"; }
class() { jq -r .class <<< "$output"; }
tip() { jq -r .tooltip <<< "$output"; }

@test "working, needs and done are green: needs is the human's queue, not a fault" {
  run "$MODULE"
  assert_success
  assert_equal "$(text)" "$ICON W5 <span color='#ffcc2f'>N2</span> <span color='#a6e34a'>D1</span>"
  assert_equal "$(class)" ok
}

@test "a stalled session paints S red and turns the chip red, and leads the hover" {
  feed STALLED=1 "idle:STALLED:lab/c:3=200"
  run "$MODULE"
  assert_equal "$(class)" critical
  assert_output --partial "<span color='#ef5734'>S1</span>"
  run tip
  assert_line --index 1 --partial "1 session(s) STALLED"
  assert_line --index 2 "working 5, needs 2, stalled 1, unclear 0, landed 0, done 1, parked 0"
  assert_line --index 3 "<span color='#ef5734'>STALLED  lab/c:3  proj  idle 3h20m</span>"
  assert_line --index 4 "NEEDS  lab/b:2  proj  idle 1h30m"
  assert_line --index 5 "NEEDS  hub/a:1  proj  idle 30m"
}

@test "an unclear session is amber" {
  feed UNCLEAR=1
  run "$MODULE"
  assert_equal "$(class)" warn
  assert_output --partial "<span color='#ffcc2f'>U1</span>"
}

@test "a textfile older than five minutes is red: the tick stopped" {
  feed mtime=900
  run "$MODULE"
  assert_equal "$(class)" critical
  run tip
  assert_line --index 1 --partial "fleet_sessions.prom on h1 is 15m old"
}

@test "a second scrape of one host counts once; a second host adds up" {
  feed dup:WORKING=5 h2:WORKING=3 h2:mtime=30
  run "$MODULE"
  assert_output --partial "$ICON W8 "
}

@test "no sessions at all reads 0, not a blank chip" {
  feed WORKING=0 NEEDS=0 DONE=0 "idle:NEEDS:hub/a:1=-" "idle:NEEDS:lab/b:2=-"
  run "$MODULE"
  assert_equal "$(text)" "$ICON 0"
  assert_equal "$(class)" ok
}

@test "no agent_sessions series reads - in amber" {
  feed WORKING=- NEEDS=- STALLED=- UNCLEAR=- LANDED=- DONE=- PARKED=-
  run "$MODULE"
  assert_equal "$(text)" "$ICON <span color='#ffcc2f'>-</span>"
  assert_equal "$(class)" warn
}

@test "Prometheus unreadable reads ? in amber" {
  CURL_FAIL=1 run "$MODULE"
  assert_success
  assert_equal "$(text)" "$ICON <span color='#ffcc2f'>?</span>"
  assert_equal "$(class)" warn
}

@test "the shepherd's numbers close the hover; an unhandled due line turns the chip amber; off the feed they are left out" {
  run "$MODULE"
  refute_output --partial 'shepherd '
  feed shep:due=6 shep:unhandled=0 shep:skipped=12 shep:nudges_24h=40 shep:escalations_24h=45 shep:passes_24h=3 shep:last_pass_epoch=99100
  run "$MODULE"
  assert_equal "$(class)" ok
  run tip
  assert_line --index 3 'NEEDS  hub/a:1  proj  idle 30m'
  assert_line --index 4 'shepherd 6 due, 0 unhandled, 12 skipped; 24h 40 nudges, 45 escalations, 3 passes; last pass 15m ago'
  feed shep:due=6 shep:unhandled=2
  run "$MODULE"
  assert_equal "$(class)" warn
  run tip
  assert_line --index 1 --partial '2 shepherd due line(s) unhandled'
  assert_output --partial 'last pass none'
}
