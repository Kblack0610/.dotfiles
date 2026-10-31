#!/usr/bin/env bats
# ci_runners.sh: the waybar CI chip. It lays out the cc:pool_* rules and the runner
# exporter's series, the same ones command-center.sh reads. What these pin: the bar's
# busy/slots and queue are the board header's totals (pools plus local gates); its colour
# is the ci domain status rule, never its own judgement; the hover names which runner on
# which machine runs which PR; and an unreadable Prometheus shows `CI: prom down`, never the last
# numbers.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic
  MODULE="$REPO_ROOT/.config/waybar/ci_runners.sh"
  export CC_PROM_URL=http://prom.test FX="$BATS_TEST_TMPDIR"
  cat > "$SANDBOX/bin/curl" <<'STUB'
#!/usr/bin/env bash
[ -n "${CURL_FAIL:-}" ] && exit 7
case "$*" in
  *cc:pool_*) cat "$FX/cc.json" ;;
  *github_runner_state*) cat "$FX/runners.json" ;;
  *) exit 22 ;;
esac
STUB
  chmod +x "$SANDBOX/bin/curl"
  fixtures idle
}

# fixtures [idle|offline]: unity 3/4 with 5 queued, pmp-light 0/2, workstation gates 2/4+6 q1.
# Finished in 24h: unity 40 at 95%, pmp-light 10 at 60%, github-hosted (no slots) 50 at
# 100%, the workstation gates 20 at 50%: 120 jobs, 104 passed, 87%. NO_DONE=1 drops them.
# CI_STATUS is the ci domain status (pools warn by default; "none" drops the series), API_OK
# the exporter's last GitHub call.
fixtures() {
  python3 - "$FX" "$1" <<'PY'
import json, os, sys
d, mode = sys.argv[1], sys.argv[2]
status, api = os.environ.get("CI_STATUS", "1"), os.environ.get("API_OK", "1")
no_done = os.environ.get("NO_DONE") == "1"
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
       ({"__name__": "cc:host_local_open_slots", "host": "workstation"}, "4"),
       ({"__name__": "cc:host_local_busy", "host": "workstation"}, "2"),
       ({"__name__": "cc:host_local_queued", "host": "workstation"}, "1"),
       ({"__name__": "api_ok"}, api)]
if not no_done:
    for pre, key, k, done, ratio in [("cc:pool", "pool", "unity", "40", "0.95"), ("cc:pool", "pool", "pmp-light", "10", "0.6"),
                                     ("cc:pool", "pool", "github-hosted", "50", "1"),
                                     ("cc:host_local", "host", "workstation", "20", "0.5")]:
        cc += [({"__name__": f"{pre}_done_24h", key: k}, done), ({"__name__": f"{pre}_pass_ratio_24h", key: k}, ratio)]
if status != "none":
    cc += [({"__name__": "cc:domain_status", "domain": "ci"}, status),
           ({"__name__": "cc:component_status", "domain": "ci", "component": "pools"}, status),
           ({"__name__": "cc:component_status", "domain": "ci", "component": "watches"}, "0")]
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

@test "the bar sums pools and local gates like the board header, queue in gold" {
  run "$MODULE"
  assert_success
  assert_equal "$(jq -r .text <<< "$output")" "<span color='#ffcc2f'>CI</span> 5/10 <span color='#ffcc2f'>q6</span>"
}

@test "pools and local gates list busy/slots, queue and oldest wait, longest queue first" {
  run "$MODULE"
  run tip
  assert_line --index 4 --regexp "^unity +3/4 .*5</span> +5h15m +40  95%$"
  assert_line --index 5 --regexp "^local:workstation +2/4\+6 .*1</span> +- +20  <span color='#ef5734'>50%</span>$"
}

@test "a pool with finished jobs but no slots still gets a row, with no busy count" {
  run "$MODULE"
  run tip
  assert_line --index 6 --regexp "^github-hosted +- +0 +- +50  100%$"
  assert_line --index 7 --regexp "^pmp-light +0/2 +0 +- +10  <span color='#ef5734'>60%</span>$"
}

@test "finished jobs stay off the bar; the hover paints them by the pass rate over all of them" {
  run "$MODULE"
  refute_output --partial "120</span>"
  run tip
  assert_line --index 2 "finished 24h: 120, <span color='#ffcc2f'>87%</span> passed"
}

@test "under 70% passed the hover's finished line is red" {
  python3 - "$FX/cc.json" <<'PY2'
import json, sys
d = json.load(open(sys.argv[1]))
for r in d["data"]["result"]:
    if r["metric"]["__name__"].endswith("pass_ratio_24h"):
        r["value"][1] = "0.5"
json.dump(d, open(sys.argv[1], "w"))
PY2
  run "$MODULE"
  run tip
  assert_line --index 2 "finished 24h: 120, <span color='#ef5734'>50%</span> passed"
}

# Negative control: with no finished series the count is -, never a 0 nobody measured.
@test "no finished series reads none reported, never 0" {
  NO_DONE=1 fixtures idle
  run "$MODULE"
  assert_equal "$(jq -r .text <<< "$output")" "<span color='#ffcc2f'>CI</span> 5/10 <span color='#ffcc2f'>q6</span>"
  run tip
  assert_line --index 2 "finished 24h: none reported"
}

@test "the colour and class are the ci domain status, and the hover names each component" {
  run "$MODULE"
  assert_equal "$(jq -r .class <<< "$output")" warn
  run tip
  assert_line --index 1 "ci: pools <span color='#ffcc2f'>warn</span>, watches <span color='#a6e34a'>ok</span>"
}

@test "a red ci domain paints CI red and the class critical" {
  CI_STATUS=2 fixtures idle
  run "$MODULE"
  assert_equal "$(jq -r .class <<< "$output")" critical
  assert_output --partial "<span color='#ef5734'>CI</span>"
}

@test "a green ci domain leaves CI plain" {
  CI_STATUS=0 fixtures idle
  run "$MODULE"
  assert_equal "$(jq -r .class <<< "$output")" ok
  assert_equal "$(jq -r .text <<< "$output")" "CI 5/10 <span color='#ffcc2f'>q6</span>"
}

# No status series is not a green light: the board prints NO DATA for it.
@test "no ci status series says no data and is never ok" {
  CI_STATUS=none fixtures idle
  run "$MODULE"
  assert_equal "$(jq -r .class <<< "$output")" warn
  run tip
  assert_line --index 1 "ci: no data"
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

@test "an offline runner is counted under DOWN by machine and state" {
  fixtures offline
  run "$MODULE"
  run tip
  assert_output --partial "DOWN:</span>"
  assert_output --partial "  hp-victus  1 offline"
}

# Negative control for the above: with every runner up, DOWN must not appear, or it would
# be noise that is always there.
@test "...and with every runner up there is no DOWN section" {
  run "$MODULE"
  refute_output --partial "DOWN"
}

@test "an exporter that cannot reach GitHub says the numbers may be old" {
  API_OK=0 fixtures idle
  run "$MODULE"
  run tip
  assert_output --partial "exporter cannot reach GitHub, numbers may be old"
}

@test "Prometheus unreadable: CI: prom down in red and no numbers at all" {
  CURL_FAIL=1 run "$MODULE"
  assert_success
  assert_equal "$(jq -r .text <<< "$output")" "<span color='#ef5734'>CI: prom down</span>"
  assert_equal "$(jq -r .class <<< "$output")" critical
  refute_output --partial "5/16"
}

@test "an empty queue reads q0, plain" {
  python3 - "$FX/cc.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
for r in d["data"]["result"]:
    if r["metric"]["__name__"] in ("cc:pool_waiting", "cc:host_local_queued"):
        r["value"][1] = "0"
json.dump(d, open(sys.argv[1], "w"))
PY
  run "$MODULE"
  assert_equal "$(jq -r .text <<< "$output")" "<span color='#ffcc2f'>CI</span> 5/10 q0"
}
