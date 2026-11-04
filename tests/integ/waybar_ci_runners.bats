#!/usr/bin/env bats
# ci_runners.sh: the waybar CI chip. It lays out the cc:pool_* and cc:site_* rules and the
# runner exporter's series, the same ones the hub board reads. What these pin: the bar's
# busy/slots and queue are the board header's totals (pools plus local gates); its colour
# is the ci domain status rule, never its own judgement; the hover counts local vs cloud,
# names each cloud machine, and lists one row per machine instead of one per job; a missed
# scrape and GitHub not answering read differently; and an unreadable Prometheus shows
# `CI: prom down`, never the last numbers. The phone lines say the same without the hover's
# aligned table, which a proportional widget font cannot draw.

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
printf '%s\n' "$*" >> "$FX/queries"
case "$*" in
  *cc:pool_*) cat "$FX/cc.json" ;;
  *github_runner_state*) cat "$FX/runners.json" ;;
  *github_runner_withheld*) cat "$FX/withheld.json" ;;
  *) exit 22 ;;
esac
STUB
  chmod +x "$SANDBOX/bin/curl"
  fixtures idle
}

# fixtures [idle|offline|cloud-off]: unity 3/4 with 5 queued, light 0/2, workstation gates 2/4 q1
# with 6 burst slots, hp-unity-3 withheld by the governor, aws-burst-1 in the cloud running
# 2/2 (cloud-off: both offline), 3 jobs on GitHub's own runners. cc:site_* says local 5/9,
# cloud 2/2 (NO_SITE=1 drops it).
# Finished in 24h: unity 40 at 95%, light 10 at 60%, github-hosted (no slots) 50 at
# 100%, the workstation gates 20 at 50%: 120 jobs, 104 passed, 87%. NO_DONE=1 drops them.
# CI_STATUS is the ci domain status (pools warn by default; "none" drops the series), API_OK
# the exporter's last call for runners, EXPORTER_UP its scrape ("none" drops it), RATE_LEFT
# the token's emptiest bucket.
fixtures() {
  python3 - "$FX" "$1" <<'PY'
import json, os, sys
d, mode = sys.argv[1], sys.argv[2]
status, api = os.environ.get("CI_STATUS", "1"), os.environ.get("API_OK", "1")
up, rate_left = os.environ.get("EXPORTER_UP", "1"), os.environ.get("RATE_LEFT", "3000")
no_done, no_site = os.environ.get("NO_DONE") == "1", os.environ.get("NO_SITE") == "1"
def out(name, rows):
    res = [{"metric": m, "value": [0, v]} for m, v in rows]
    json.dump({"status": "success", "data": {"result": res}}, open(f"{d}/{name}.json", "w"))
cc = []
for pool, slots, busy, waiting, oldest in [("unity", "4", "3", "5", "18900"), ("light", "2", "0", "0", None)]:
    cc += [({"__name__": "cc:pool_slots", "pool": pool}, slots), ({"__name__": "cc:pool_busy", "pool": pool}, busy),
           ({"__name__": "cc:pool_waiting", "pool": pool}, waiting)]
    if oldest:
        cc.append(({"__name__": "cc:pool_oldest_wait_seconds", "pool": pool}, oldest))
cc += [({"__name__": "cc:host_local_slots", "host": "workstation"}, "10"),
       ({"__name__": "cc:host_local_open_slots", "host": "workstation"}, "4"),
       ({"__name__": "cc:host_local_busy", "host": "workstation"}, "2"),
       ({"__name__": "cc:host_local_queued", "host": "workstation"}, "1"),
       ({"__name__": "api_ok", "src": "api"}, api), ({"__name__": "rate_left", "src": "rate"}, rate_left)]
if up != "none":
    cc.append(({"__name__": "exporter_up", "src": "up"}, up))
if not no_site:
    cc += [({"__name__": "cc:site_slots", "site": "local"}, "9"), ({"__name__": "cc:site_busy", "site": "local"}, "5"),
           ({"__name__": "cc:site_slots", "site": "cloud"}, "2"), ({"__name__": "cc:site_busy", "site": "cloud"}, "2"),
           ({"__name__": "cc:github_hosted_running"}, "3")]
if not no_done:
    for pre, key, k, done, ratio in [("cc:pool", "pool", "unity", "40", "0.95"), ("cc:pool", "pool", "light", "10", "0.6"),
                                     ("cc:pool", "pool", "github-hosted", "50", "1"),
                                     ("cc:host_local", "host", "workstation", "20", "0.5")]:
        cc += [({"__name__": f"{pre}_done_24h", key: k}, done), ({"__name__": f"{pre}_pass_ratio_24h", key: k}, ratio)]
if status != "none":
    cc += [({"__name__": "cc:domain_status", "domain": "ci"}, status),
           ({"__name__": "cc:component_status", "domain": "ci", "component": "pools"}, status),
           ({"__name__": "cc:component_status", "domain": "ci", "component": "watches"}, "0")]
out("cc", cc)
def r(host, pool, state, name, val="0", site="local", **kw):
    return ({"host": host, "pool": pool, "state": state, "name": name, "site": site, **kw}, val)
aws = "offline" if mode == "cloud-off" else "running"
runners = [
    r("razer-laptop", "unity", "running", "razer-unity-1", "545", repo="playground", pr="1210",
      workflow="Tests", job_name="PlayMode 4"),
    r("razer-laptop", "unity", "running", "razer-unity-2", "4000", repo="playground", pr="1183",
      workflow="Tests", job_name="PlayMode <2> & \"quoted\""),
    r("razer-laptop", "light", "idle", "razer-light-1"),
    r("hp-victus", "unity", "running", "hp-unity-1", "60", repo="playground", workflow="Release", job_name="Mac"),
    r("hp-victus", "unity", "idle", "hp-unity-2"),
    r("hp-victus", "unity", "idle", "hp-unity-3"),
    r("hp-victus", "light", "offline" if mode == "offline" else "idle", "hp-light-1"),
    r("aws-burst-1", "unity", aws, "aws-unity-1", "120", site="cloud", repo="playground", pr="1300",
      workflow="Tests", job_name="EditMode"),
    r("aws-burst-1", "unity", aws, "aws-unity-2", "30", site="cloud", repo="playground", pr="1301",
      workflow="Tests", job_name="EditMode"),
]
out("runners", runners)
out("withheld", [({"name": "hp-unity-3"}, "1")])
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
  assert_line --index 5 --regexp "^unity +3/4 .*5</span> +5h15m +40  95%$"
  assert_line --index 6 --regexp "^local:workstation +2/4 .*1</span> +- +20  <span color='#ef5734'>50%</span>$"
}

# The burst slots open only with room, so they are a legend line, never a +N in the cell.
@test "a local row is busy of its open slots, and its burst slots are a legend line" {
  run "$MODULE"
  run tip
  refute_output --partial "2/4+6"
  assert_line --index 9 "local:workstation has 6 burst slots more, opened only while the CPU has room"
}

@test "a local row running burst slots reads busy of busy" {
  python3 - "$FX/cc.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
for r in d["data"]["result"]:
    if r["metric"]["__name__"] == "cc:host_local_busy":
        r["value"][1] = "6"
json.dump(d, open(sys.argv[1], "w"))
PY
  run "$MODULE"
  assert_equal "$(jq -r .text <<< "$output")" "<span color='#ffcc2f'>CI</span> 9/12 <span color='#ffcc2f'>q6</span>"
  run tip
  assert_line --index 6 --regexp "^local:workstation +6/6 "
}

@test "a pool with finished jobs but no slots still gets a row, with no busy count" {
  run "$MODULE"
  run tip
  assert_line --index 7 --regexp "^github-hosted +- +0 +- +50  100%$"
  assert_line --index 8 --regexp "^light +0/2 +0 +- +10  <span color='#ef5734'>60%</span>$"
}

@test "finished jobs stay off the bar; the hover paints them by the pass rate over all of them" {
  run "$MODULE"
  refute_output --partial "120</span>"
  run tip
  assert_line --index 3 "finished 24h: 120, <span color='#ffcc2f'>87%</span> passed"
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
  assert_line --index 3 "finished 24h: 120, <span color='#ef5734'>50%</span> passed"
}

# Negative control: with no finished series the count is -, never a 0 nobody measured.
@test "no finished series reads none reported, never 0" {
  NO_DONE=1 fixtures idle
  run "$MODULE"
  assert_equal "$(jq -r .text <<< "$output")" "<span color='#ffcc2f'>CI</span> 5/10 <span color='#ffcc2f'>q6</span>"
  run tip
  assert_line --index 3 "finished 24h: none reported"
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

@test "running counts local and cloud, naming each cloud machine and GitHub's runners" {
  run "$MODULE"
  run tip
  assert_line --index 2 "running: local 5/9  cloud 5 (aws-burst-1 2/2, github-hosted 3)"
}

# A cloud machine is kept stopped when idle: it reads off, not 0/0, and not missing.
@test "a cloud machine with no runner up reads off" {
  fixtures cloud-off
  run "$MODULE"
  run tip
  assert_line --index 2 "running: local 5/9  cloud 5 (aws-burst-1 off, github-hosted 3)"
  refute_line --regexp "^aws-burst-1 +cloud"
}

# Negative control: with no job on GitHub's runners the list does not name them.
@test "no GitHub-hosted job running leaves github-hosted out" {
  python3 - "$FX/cc.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
for r in d["data"]["result"]:
    if r["metric"]["__name__"] == "cc:github_hosted_running":
        r["value"][1] = "0"
json.dump(d, open(sys.argv[1], "w"))
PY
  run "$MODULE"
  run tip
  assert_line --index 2 "running: local 5/9  cloud 2 (aws-burst-1 2/2)"
}

@test "no cc:site series says so instead of a 0/0 nobody measured" {
  NO_SITE=1 fixtures idle
  run "$MODULE"
  run tip
  assert_line --index 2 "running: no cc:site_* series (recording rules not loaded?)"
}

@test "one row per machine: where, busy/slots and per pool, busiest first" {
  run "$MODULE"
  run tip
  assert_line --index 10 --regexp "^MACHINE +WHERE +BUSY +POOLS$"
  assert_line --index 11 --regexp "^aws-burst-1 +cloud +2/2  unity 2/2$"
  assert_line --index 12 --regexp "^razer-laptop +local +2/3  light 0/1 unity 2/2$"
  assert_line --index 13 --regexp "^workstation +local +2/4  gates 2/4$"
  assert_line --index 14 --regexp "^hp-victus +local +1/3  light 0/1 unity 1/2 unity withheld 0/1$"
}

# The per-job list is the board's CI tab now: the hover never names a job.
@test "the hover lists no job lines" {
  run "$MODULE"
  run tip
  refute_output --partial "PlayMode"
  refute_output --partial "Release: Mac"
}

# Negative control for the withheld count: a machine with none withheld never says so.
@test "a machine with no withheld runner has no withheld count" {
  run "$MODULE"
  run tip
  refute_line --regexp "^razer-laptop .*withheld"
}

@test "only jobs past an hour are listed under long runs, painted amber" {
  run "$MODULE"
  run tip
  assert_output --partial "long runs: razer-unity-2 playground#1183 <span color='#ffcc2f'>1h06m</span>"
  refute_output --partial "razer-unity-1 playground#1210"
}

@test "with no job past an hour there is no long runs line" {
  python3 - "$FX/runners.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
for r in d["data"]["result"]:
    r["value"][1] = "60" if r["metric"]["state"] == "running" else r["value"][1]
json.dump(d, open(sys.argv[1], "w"))
PY
  run "$MODULE"
  refute_output --partial "long runs"
}

@test "the output stays valid JSON" {
  run "$MODULE"
  jq -e . <<< "$output" > /dev/null
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

@test "a missed exporter scrape says so, and does not blame GitHub" {
  EXPORTER_UP=0 fixtures idle
  run "$MODULE"
  run tip
  assert_output --partial "runner exporter missed its last scrape, runner rows may be missing"
  refute_output --partial "GitHub not answering"
}

@test "no exporter up series reads as a missed scrape too" {
  EXPORTER_UP=none fixtures idle
  run "$MODULE"
  run tip
  assert_output --partial "runner exporter missed its last scrape"
}

@test "GitHub not answering the runner calls says so" {
  API_OK=0 fixtures idle
  run "$MODULE"
  run tip
  assert_output --partial "GitHub not answering the exporter, runner rows may be missing"
  refute_output --partial "missed its last scrape"
}

@test "a spent rate limit says so, ahead of the vaguer GitHub line" {
  API_OK=0 RATE_LEFT=0 fixtures idle
  run "$MODULE"
  run tip
  assert_output --partial "GitHub rate limit spent, runner jobs and history unread until it resets"
  refute_output --partial "GitHub not answering"
}

# Negative control: a healthy exporter adds neither line.
@test "a healthy exporter adds no exporter line" {
  run "$MODULE"
  run tip
  refute_output --partial "missed its last scrape"
  refute_output --partial "GitHub not answering"
  refute_output --partial "rate limit spent"
}

# One repo's run list failing must not doubt the runner rows: api_ok reads runner sources.
@test "api_ok is read from the runner sources only" {
  run "$MODULE"
  run grep -c 'github_runner_exporter_api_ok{kind="runners"}' "$FX/queries"
  assert_output 1
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

@test "phone: the bar, the finished line, the ci status and each pool with slots" {
  run "$MODULE"
  run jq -r .phone <<< "$output"
  assert_line --index 0 "<b><span color='#ffcc2f'>CI</span></b> 5/10 <span color='#ffcc2f'>q6</span>, finished 24h: 120, <span color='#ffcc2f'>87%</span> passed"
  assert_line --index 1 --partial "ci:"
  assert_line --index 2 --partial "unity 3/4 <span color='#ffcc2f'>q5</span>"
  assert_line --index 2 --partial "light 0/2"
  refute_output --partial "github-hosted"
  refute_output --partial "<tt>"
  refute_output --partial "DOWN:"
}

@test "phone: what is down is one line" {
  fixtures offline
  run "$MODULE"
  run jq -r .phone <<< "$output"
  assert_line --index 3 --partial "DOWN:"
}

# Negative control: a failed read has no phone lines, so fleet-overview shows its hover instead.
@test "phone: an unreadable Prometheus has no phone lines to go stale" {
  CURL_FAIL=1 run "$MODULE"
  assert_equal "$(jq -r 'has("phone")' <<< "$output")" false
}
