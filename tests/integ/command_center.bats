#!/usr/bin/env bats
# command-center.sh lays out what Prometheus says and judges nothing itself. These pin the
# two things that make it trustworthy: it shows exactly what the series say (which runner
# runs which PR, what waits, what is down), and when Prometheus cannot be read it shows
# NOTHING rather than the last (possibly green) frame.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic
  CC="$REPO_ROOT/.local/src/tmux/command-center.sh"
  export NO_COLOR=1 COLUMNS=160 LINES=50 CC_PROM_URL=http://prom.test CC_HOSTS=workstation
  export FX="$BATS_TEST_TMPDIR"
  # curl stub: answers each board query from its fixture file, and fails outright when
  # CURL_FAIL is set.
  cat > "$SANDBOX/bin/curl" <<'STUB'
#!/usr/bin/env bash
[ -n "${CURL_FAIL:-}" ] && exit 7
case "$*" in
  *'cc:.+'*) cat "$FX/cc.json" ;;
  *github_runner_state*) cat "$FX/runners.json" ;;
  *github_actions_job_waiting*) cat "$FX/waiting.json" ;;
  *github_runs_finished*) cat "$FX/finished.json" ;;
  *github_runner_exporter_api_ok*) cat "$FX/api.json" ;;
  *cc:host_local_gate*) cat "$FX/local.json" ;;
  *mqtt_tripped*) printf '{"status":"success","data":{"result":[{"metric":{"item":"watch mac_studio_mlx"},"value":[0,"1"]}]}}' ;;
  *) exit 22 ;;
esac
STUB
  chmod +x "$SANDBOX/bin/curl"
  python3 - "$FX" <<'PY'
import json, sys
d = sys.argv[1]
def out(name, rows):
    res = [{"metric": m, "value": [0, v]} for m, v in rows]
    json.dump({"status": "success", "data": {"result": res}}, open(f"{d}/{name}.json", "w"))
cc = [({"__name__": "cc:overall_status"}, "2"), ({"__name__": "cc:domain_status", "domain": "k3s"}, "0"),
      ({"__name__": "cc:domain_status", "domain": "llm"}, "2"), ({"__name__": "cc:ci_online"}, "13"),
      ({"__name__": "cc:ci_expected"}, "14"), ({"__name__": "cc:k3s_nodes_ready"}, "8"),
      ({"__name__": "cc:k3s_nodes_total"}, "8"), ({"__name__": "cc:asks_open"}, "0"),
      ({"__name__": "cc:sessions_attention"}, "0")]
for n, v in [("cc:host_cpu_busy_ratio", "0.91"), ("cc:host_cpu_busy_ratio:avg6h", "0.31"), ("cc:host_load1", "9.84"), ("cc:host_cores", "16"),
             ("cc:host_mem_used_ratio", "0.6"), ("cc:host_temp_c", "84.2")]:
    cc.append(({"__name__": n, "host": "razer-laptop"}, v))
cc.append(({"__name__": "cc:host_cpu_busy_ratio", "host": "mac-mini"}, "0.03"))
# windows has slots and nothing waiting: it must read 0, never vanish.
# windows has no finished series: DONE and PASS read -, never 0.
for pool, slots, busy, waiting, oldest, done, ratio in [("unity", "4", "3", "3", "8880", "72", "0.24"),
                                                        ("pmp-light", "2", "0", "1", "60", "40", "0.8"),
                                                        ("windows", "1", "0", "0", None, None, None)]:
    cc += [({"__name__": "cc:pool_slots", "pool": pool}, slots), ({"__name__": "cc:pool_busy", "pool": pool}, busy),
           ({"__name__": "cc:pool_waiting", "pool": pool}, waiting)]
    if oldest:
        cc.append(({"__name__": "cc:pool_oldest_wait_seconds", "pool": pool}, oldest))
    if done:
        cc += [({"__name__": "cc:pool_done_24h", "pool": pool}, done), ({"__name__": "cc:pool_pass_ratio_24h", "pool": pool}, ratio)]
out("cc", cc)
def runner(host, name, state, val, **kw):
    m = {"host": host, "name": name, "state": state, "pool": "unity"}
    m.update(kw)
    return (m, val)
out("runners", [
    runner("razer-laptop", "razer-1", "running", "2160", repo="unity-core-playground", pr="412",
           branch="feat/apociseum-third", job_name="PlayMode 2", workflow="Tests", title="Apociseum third arena"),
    runner("razer-laptop", "razer-2", "running", "300", repo="platform", branch="develop",
           job_name="E2E", workflow="E2E", title="E2E"),
    runner("razer-laptop", "razer-3", "idle", "0"),
    runner("razer-laptop", "razer-4", "running", "5580", repo="unity-core-playground", pr="1110",
           branch="feat/automatch-phase", job_name="PlayMode 4", workflow="Tests", title="Tests"),
    runner("mac-mini", "mini-1", "offline", "0", pool="macos"),
])
out("waiting", [({"pool": "unity", "repo": "unity-core-playground", "pr": "412", "stuck": "false",
                  "branch": "feat/apociseum-third"}, v) for v in ("600", "8880", "120")] +
               [({"pool": "pmp-light", "repo": "platform", "branch": "develop", "stuck": "false"}, "60"),
                # A run queued 45 days with no jobs: DOWN's, and never the queue's age.
                ({"pool": "other", "repo": "platform", "branch": "develop", "stuck": "true"}, "3949200")])
def fin(repo, wf, **by):
    return [({"repo": repo, "workflow": wf, "conclusion": c}, str(n)) for c, n in by.items()]
out("finished", fin("unity-core-playground", "Tests", success=12, failure=38, cancelled=22)
                + fin("unity-core-playground", "Game catalog", failure=39)
                + fin("unity-core-playground", "Multi", failure=14)
                + fin("unity-core-playground", "Docs", success=5, cancelled=3)
                + fin("platform", "Checks", success=30) + fin("platform", "E2E", success=8))
out("api", [({}, "1")])
out("local", [])
PY
}


@test "a busy runner's row names its host, pool, repo, PR, job, time in job, branch and run title" {
  run "$CC" --once
  assert_success
  assert_line --regexp '^razer-laptop +unity +unity-core-playground +#412 +PlayMode 2 +36m +feat/apociseum-third - Apociseum third arena$'
}

@test "a run with no PR shows -, and a title that only repeats the workflow is not shown" {
  run "$CC" --once
  assert_line --regexp '^razer-laptop +unity +platform +- +E2E +5m +develop$'
}

@test "a machine's row carries its load, 6h CPU and busy of its registered slots per pool" {
  run "$CC" --once
  assert_line --regexp '^razer-laptop +91% +31% +9\.8/16 +60% +84C +unity 3/4$'
}

@test "a machine with no exporter series reads - in every column, never 0" {
  run "$CC" --once
  assert_line --regexp '^workstation +- +- +- +- +- +-$'
  assert_line --regexp '^mac-mini +3% +- +- +- +- +-$'
}

@test "pools show busy of slots, waiting, oldest, the last day's done and pass rate, and the hosts, longest queue first" {
  run "$CC" --once
  assert_line --regexp '^unity +3/4 +3 +2h28m +72 +24% +razer-laptop:4$'
  assert_line --regexp '^pmp-light +0/2 +1 +1m +40 +80% +-$'
  assert_line --regexp '^windows +0/1 +0 +- +- +- +-$'
  local order
  order="$(awk '/^POOL /{on=1; next} on && NF == 0 {exit} on {print $1}' <<< "$output" | paste -sd' ')"
  assert_equal "$order" "unity pmp-light windows"
}

@test "a job past an hour is marked, and painted amber when colour is on" {
  run "$CC" --once
  assert_line --regexp '^razer-laptop +unity +unity-core-playground +#1110 +PlayMode 4 +1h33m! +feat/automatch-phase$'
  refute_output --partial '36m!'
  NO_COLOR= run "$CC" --once
  assert_output --partial $'\033[1;30;43m1h33m!'
}

@test "a stuck run is listed in DOWN and left out of the queue and its oldest wait" {
  run "$CC" --once
  assert_output --partial 'stuck run: platform develop, 45d17h, no jobs'
  assert_output --partial 'QUEUED  4 jobs in 2 groups, oldest waiting 2h28m'
}

@test "an offline runner lands in DOWN by name" {
  run "$CC" --once
  assert_output --partial 'DOWN    mini-1 offline'
}

@test "the queue groups by pool, repo, PR and branch, with the count and the oldest wait" {
  run "$CC" --once
  assert_output --partial 'QUEUED  4 jobs in 2 groups, oldest waiting 2h28m'
  assert_output --regexp 'unity +unity-core-playground +#412 +3 +2h28m +feat/apociseum-third'
  assert_output --regexp 'pmp-light +platform +- +1 +1m +develop'
}

@test "finished runs list the worst pass rate first, cancels apart, and fold the green workflows" {
  run "$CC" --once
  # Pass is success of success + failure: Tests 12 of 50 is 24%, its 22 cancels are not failures.
  # Multi (0%, 14 failed) sorts above Tests (24%, 38 failed): the worst rate first, not the most fails.
  assert_output --partial 'FINISHED 24H  171 runs, 38% pass, 91 failed, 25 cancelled'
  local order
  order="$(awk '/^ *PASS +RUNS /{on=1; next} on && /^ *[0-9-]/ {print $NF} on && !/^ *[0-9-]/ {exit}' <<< "$output" | paste -sd' ')"
  assert_equal "$order" "catalog Multi Tests Docs"
  assert_line --regexp '^ *0% +39 +39 +0 +unity-core-playground +Game catalog$'
  assert_line --regexp '^ *24% +72 +38 +22 +unity-core-playground +Tests$'
  assert_line --regexp '^ *100% +8 +0 +3 +unity-core-playground +Docs$'
  assert_output --partial '+2 green workflows, 38 runs'
  refute_output --partial 'Checks'
}

@test "finished: past the row limit the rest are counted, not dropped silently" {
  python3 - "$FX/finished.json" <<'PY'
import json, sys
rows = [{"metric": {"repo": "r", "workflow": f"w{i}", "conclusion": "failure"}, "value": [0, "1"]} for i in range(9)]
json.dump({"status": "success", "data": {"result": rows}}, open(sys.argv[1], "w"))
PY
  run "$CC" --once
  assert_output --partial '+3 more workflows with failures'
}

@test "finished: no series says so instead of an empty section" {
  printf '{"status":"success","data":{"result":[]}}' > "$FX/finished.json"
  run "$CC" --once
  assert_success
  assert_output --partial 'FINISHED 24H  no finished-run series yet'
}

@test "a pass rate is painted red under 70% and amber under 90% when colour is on" {
  NO_COLOR= run "$CC" --once
  assert_output --partial $'\033[1;37;41m24%'
  assert_output --partial $'\033[1;30;43m80%'
  assert_output --regexp $'[^m]100%'
}

@test "the domain strip and numbers come straight from the cc:* series; ci with no status is NODATA" {
  run "$CC" --once
  assert_output --partial 'OVERALL RED'
  assert_output --partial 'k3s OK ci NODATA llm RED'
  assert_output --partial 'ci busy 3/7 waiting 4'
  assert_output --partial 'red now: watch mac_studio_mlx'
}

@test "narrowing the machines drops TEMP, then MEM, then 6H, never CPU, LOAD or SLOTS" {
  COLUMNS=46 run "$CC" --once
  assert_line --regexp '^razer-laptop +91% +31% +9\.8/16 +60% +unity 3/4$'
  COLUMNS=40 run "$CC" --once
  assert_line --regexp '^razer-laptop +91% +9\.8/16 +unity 3/4$'
}

@test "a narrow terminal keeps each run's machine, repo and PR, and nothing wraps" {
  COLUMNS=60 run "$CC" --once
  assert_success
  assert_line --regexp '^razer-laptop +unity-core-playground +#412'
  local wide
  wide="$(awk 'length($0) > 60' <<< "$output" | wc -l)"
  assert_equal "$wide" 0
}

@test "GitHub API failing is said in DOWN, not hidden behind an empty runner list" {
  printf '{"status":"success","data":{"result":[{"metric":{},"value":[0,"0"]}]}}' > "$FX/api.json"
  run "$CC" --once
  assert_output --partial 'GitHub API not answering'
}

@test "Prometheus unreachable: the board says so and shows no machine at all" {
  CURL_FAIL=1 run "$CC" --once
  assert_failure
  assert_output --partial 'QUERY FAILED'
  refute_output --partial 'razer-laptop'
  refute_output --partial 'OK'
}

@test "one failed query blanks the whole board, not just its section" {
  printf '{"status":"error","error":"bad_data"}' > "$FX/waiting.json"
  run "$CC" --once
  assert_failure
  assert_output --partial 'QUERY FAILED'
  refute_output --partial 'razer-laptop'
}

@test "rules not loaded (no cc:* series) is a failure, not an empty green board" {
  printf '{"status":"success","data":{"result":[]}}' > "$FX/cc.json"
  run "$CC" --once
  assert_failure
  assert_output --partial 'recording rules not loaded'
}

# local_gates: two gates on the workstation, one on a branch with a PR in the queue (#412).
local_gates() {
  python3 - "$FX/local.json" <<'PY'
import json, sys
g = lambda wt, br, plat, repo, v: {"metric": {"__name__": "cc:host_local_gate", "host": "workstation", "worktree": wt,
                                            "branch": br, "platform": plat, "repo": repo}, "value": [0, v]}
json.dump({"status": "success", "data": {"result": [g("unity-core-playground-agent-7", "feat/apociseum-third", "PlayMode", "unity-core-playground", "2160"),
                                                    g("unity-core-playground-agent-9", "fix/x", "EditMode", "", "45")]}},
          open(sys.argv[1], "w"))
PY
}

# local_slots: the workstation publishes 10 local slots, 2 busy, 1 run queued for one.
local_slots() {
  python3 - "$FX/cc.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
for n, v in [("cc:host_local_slots", "10"), ("cc:host_local_busy", "2"), ("cc:host_local_queued", "1"),
             ("cc:host_local_done_24h", "14"), ("cc:host_local_pass_ratio_24h", "0.5")]:
    d["data"]["result"].append({"metric": {"__name__": n, "host": "workstation"}, "value": [0, v]})
json.dump(d, open(sys.argv[1], "w"))
PY
}

@test "a machine that is not a runner lists its local gates under its row, with the repo and the PR of its branch" {
  local_gates
  run "$CC" --once
  assert_success
  assert_line --regexp '^workstation +unity-local +unity-core-playground +#412 +PlayMode +36m +feat/apociseum-third$'
  # No repo label (an older fleet-assess): the worktree stands in, and no PR is guessed.
  assert_line --regexp '^workstation +unity-local +unity-core-playgroun~ +- +EditMode +45s +fix/x$'
}

@test "without published local slots the machine counts its gates and invents no capacity" {
  local_gates
  run "$CC" --once
  assert_line --regexp '^workstation +- +- +- +- +- +2 gates$'
  refute_output --regexp 'unity-local +[0-9?]+/'
  refute_output --regexp '^unity-local '
}

@test "published local slots read like a pool: busy of slots on the machine, a unity-local pool row, and in the ci totals" {
  local_gates
  local_slots
  run "$CC" --once
  assert_success
  assert_line --regexp '^workstation +- +- +- +- +- +unity-local 2/10$'
  assert_line --regexp '^unity-local +2/10 +1 +- +14 +50% +workstation$'
  assert_output --partial 'ci busy 5/17 waiting 5'
}

@test "the agent session count shows only when the rule has a value" {
  run "$CC" --once
  refute_output --partial 'agent sessions'
  python3 - "$FX/cc.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
d["data"]["result"].append({"metric": {"__name__": "cc:agent_sessions_running"}, "value": [0, "26"]})
json.dump(d, open(sys.argv[1], "w"))
PY
  run "$CC" --once
  assert_output --partial 'agent sessions 26'
}
