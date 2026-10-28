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
  *github_actions_run_recent*) cat "$FX/recent.json" ;;
  *github_runner_exporter_api_ok*) cat "$FX/api.json" ;;
  *mqtt_tripped*) printf '{"status":"success","data":{"result":[{"metric":{"item":"watch mac_studio_mlx"},"value":[0,"1"]}]}}' ;;
  *) exit 22 ;;
esac
STUB
  chmod +x "$SANDBOX/bin/curl"
  python3 - "$FX" <<'PY'
import json, sys, time
d = sys.argv[1]
def out(name, rows):
    res = [{"metric": m, "value": [0, v]} for m, v in rows]
    json.dump({"status": "success", "data": {"result": res}}, open(f"{d}/{name}.json", "w"))
cc = [({"__name__": "cc:overall_status"}, "2"), ({"__name__": "cc:domain_status", "domain": "k3s"}, "0"),
      ({"__name__": "cc:domain_status", "domain": "llm"}, "2"), ({"__name__": "cc:ci_online"}, "13"),
      ({"__name__": "cc:ci_expected"}, "14"), ({"__name__": "cc:k3s_nodes_ready"}, "8"),
      ({"__name__": "cc:k3s_nodes_total"}, "8"), ({"__name__": "cc:asks_open"}, "0"),
      ({"__name__": "cc:sessions_attention"}, "0")]
for n, v in [("cc:host_cpu_busy_ratio", "0.91"), ("cc:host_load1", "9.84"), ("cc:host_cores", "16"),
             ("cc:host_mem_used_ratio", "0.6"), ("cc:host_temp_c", "84.2")]:
    cc.append(({"__name__": n, "host": "razer-laptop"}, v))
cc.append(({"__name__": "cc:host_cpu_busy_ratio", "host": "mac-mini"}, "0.03"))
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
    runner("mac-mini", "mini-1", "offline", "0", pool="macos"),
])
out("waiting", [({"labels": "self-hosted,unity", "repo": "unity-core-playground", "pr": "412",
                  "branch": "feat/apociseum-third"}, v) for v in ("600", "8880", "120")] +
               [({"labels": "self-hosted,pmp-light", "repo": "platform", "branch": "develop"}, "60")])
now = int(time.time())
out("recent", [({"conclusion": "failure", "repo": "unity-core-playground", "workflow": "Tests",
                 "branch": "feat/x"}, str(now - 240))])
out("api", [({}, "1")])
PY
}


@test "a busy runner's row names its repo, PR, job, time in job, branch and run title" {
  run "$CC" --once
  assert_success
  assert_output --regexp 'razer-laptop +91% +9\.8/16 +60% +84C +2/3 busy +unity +unity-core-playground +#412 +PlayMode 2 +36m +feat/apociseum-third - Apociseum third arena'
}

@test "a run with no PR shows -, and a title that only repeats the workflow is not shown" {
  run "$CC" --once
  assert_line --regexp ' +unity +platform +- +E2E +5m +develop$'
}

@test "a machine with no exporter series reads - in every column, never 0" {
  run "$CC" --once
  assert_line --regexp '^workstation +- +- +- +- +- '
  assert_line --regexp '^mac-mini +3% +- +- +- +0/1 busy'
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

@test "recent runs show how long ago and GitHub's own verdict" {
  run "$CC" --once
  assert_output --regexp '4m +failure +unity-core-playground +Tests +feat/x'
}

@test "the domain strip and numbers come straight from the cc:* series; ci with no status is NODATA" {
  run "$CC" --once
  assert_output --partial 'OVERALL RED'
  assert_output --partial 'k3s OK ci NODATA llm RED'
  assert_output --partial 'ci slots 13/14'
  assert_output --partial 'red now: watch mac_studio_mlx'
}

@test "a narrow terminal drops columns but keeps machine, repo and PR, and nothing wraps" {
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
