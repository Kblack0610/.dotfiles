#!/usr/bin/env bats
# ci_runners.sh: the waybar CI chip. It lays out the cc:pool_* rules and the runner
# exporter's series, the same ones command-center.sh reads. What these pin: the bar's
# busy/slots and queue are the pool totals; the hover names which runner on which machine
# runs which PR; a down runner or a blind exporter turns it red; and an unreadable
# Prometheus shows `CI ?`, never the last numbers.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic
  MODULE="$REPO_ROOT/.config/waybar/ci_runners.sh"
  export CC_PROM_URL=http://prom.test FX="$BATS_TEST_TMPDIR" API_OK=1
  cat > "$SANDBOX/bin/curl" <<'STUB'
#!/usr/bin/env bash
[ -n "${CURL_FAIL:-}" ] && exit 7
case "$*" in
  *cc:pool_*) cat "$FX/cc.json" ;;
  *github_runner_state*) cat "$FX/runners.json" ;;
  *github_runner_exporter_api_ok*) printf '{"status":"success","data":{"result":[{"metric":{},"value":[0,"%s"]}]}}' "$API_OK" ;;
  *) exit 22 ;;
esac
STUB
  chmod +x "$SANDBOX/bin/curl"
  fixtures idle
}

# fixtures [idle|offline]: unity 3/4 with 5 queued, pmp-light 0/2, workstation gates 2/10 q1.
fixtures() {
  python3 - "$FX" "$1" <<'PY'
import json, sys
d, mode = sys.argv[1], sys.argv[2]
def out(name, rows):
    res = [{"metric": m, "value": [0, v]} for m, v in rows]
    json.dump({"status": "success", "data": {"result": res}}, open(f"{d}/{name}.json", "w"))
cc = []
for pool, slots, busy, waiting, oldest in [("unity", "4", "3", "5", "18900"), ("pmp-light", "2", "0", "0", None)]:
    cc += [({"__name__": "cc:pool_slots", "pool": pool}, slots), ({"__name__": "cc:pool_busy", "pool": pool}, busy),
           ({"__name__": "cc:pool_waiting", "pool": pool}, waiting)]
    if oldest:
        cc.append(({"__name__": "cc:pool_oldest_wait_seconds", "pool": pool}, oldest))
cc += [({"__name__": "cc:host_local_slots", "host": "workstation"}, "10"),
       ({"__name__": "cc:host_local_busy", "host": "workstation"}, "2"),
       ({"__name__": "cc:host_local_queued", "host": "workstation"}, "1")]
out("cc", cc)
def r(host, pool, state, name, val="0", **kw):
    return ({"host": host, "pool": pool, "state": state, "name": name, **kw}, val)
runners = [
    r("razer-laptop", "unity", "running", "razer-unity-1", "545", repo="playground", pr="1210",
      workflow="Tests", job_name="PlayMode 4"),
    r("razer-laptop", "unity", "running", "razer-unity-2", "4000", repo="playground", pr="1183",
      workflow="Tests", job_name="PlayMode <2> & \"quoted\""),
    r("razer-laptop", "pmp-light", "idle", "razer-light-1"),
    r("hp-victus", "unity", "running", "hp-unity-1", "60", repo="playground", workflow="Release", job_name="Mac"),
    r("hp-victus", "unity", "idle", "hp-unity-2"),
    r("hp-victus", "pmp-light", "offline" if mode == "offline" else "idle", "hp-light-1"),
]
out("runners", runners)
PY
}

tip() { jq -r .tooltip <<< "$output"; }

@test "the bar is busy of slots across pools, then the queue in gold" {
  run "$MODULE"
  assert_success
  assert_equal "$(jq -r .text <<< "$output")" "CI 3/6 <span color='#ffcc2f'>q5</span>"
  assert_equal "$(jq -r .class <<< "$output")" warn
}

@test "pools list busy/slots, queue and oldest wait, longest queue first" {
  run "$MODULE"
  run tip
  assert_line --index 2 --regexp "^unity +3/4 .*5</span>  5h15m$"
  assert_line --index 3 --regexp '^pmp-light +0/2 +0  -$'
}

@test "each machine lists its pools, and every busy runner names repo#PR, job and time" {
  run "$MODULE"
  run tip
  assert_output --partial "<b>razer-laptop  pmp-light 0/1 unity 2/2</b>"
  assert_output --partial "<b>hp-victus  pmp-light 0/1 unity 1/2</b>"
  assert_output --partial "  razer-unity-1  playground#1210  Tests: PlayMode 4  9m"
  # No PR: the repo alone, no dangling #.
  assert_output --partial "  hp-unity-1  playground  Release: Mac  1m"
  refute_output --partial "razer-light-1"
}

@test "a job past an hour is painted amber" {
  run "$MODULE"
  run tip
  assert_output --partial "<span color='#ffcc2f'>1h06m</span>"
}

@test "markup and quotes in a job name are escaped and the output stays valid JSON" {
  run "$MODULE"
  jq -e . <<< "$output" > /dev/null
  run tip
  assert_output --partial 'PlayMode &lt;2&gt; &amp; "quoted"'
}

@test "the workstation's local gates are listed with busy/slots and queue" {
  run "$MODULE"
  run tip
  assert_output --partial "local gates (workstation)  2/10  q1"
}

@test "an offline runner is listed under DOWN and turns the chip red" {
  fixtures offline
  run "$MODULE"
  assert_equal "$(jq -r .class <<< "$output")" critical
  assert_output --partial "<span color='#ef5734'>CI</span>"
  run tip
  assert_output --partial "hp-light-1 (hp-victus, offline)"
}

# Negative control for the above: with every runner up, DOWN must not appear, or it would
# be noise that is always there.
@test "...and with every runner up there is no DOWN section" {
  run "$MODULE"
  refute_output --partial "DOWN"
}

@test "an exporter that cannot reach GitHub turns it red and says the numbers may be old" {
  API_OK=0 run "$MODULE"
  assert_equal "$(jq -r .class <<< "$output")" critical
  run tip
  assert_output --partial "exporter cannot reach GitHub"
}

@test "Prometheus unreadable: CI ? in red and no numbers at all" {
  CURL_FAIL=1 run "$MODULE"
  assert_success
  assert_equal "$(jq -r .text <<< "$output")" "<span color='#ef5734'>CI ?</span>"
  assert_equal "$(jq -r .class <<< "$output")" critical
  refute_output --partial "3/6"
}

@test "an empty queue reads q0, plain, and the class is ok" {
  python3 - "$FX/cc.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
for r in d["data"]["result"]:
    if r["metric"]["__name__"] == "cc:pool_waiting":
        r["value"][1] = "0"
json.dump(d, open(sys.argv[1], "w"))
PY
  run "$MODULE"
  assert_equal "$(jq -r .text <<< "$output")" "CI 3/6 q0"
  assert_equal "$(jq -r .class <<< "$output")" ok
}
