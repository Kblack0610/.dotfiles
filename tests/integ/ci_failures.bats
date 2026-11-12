#!/usr/bin/env bats
# ci-failures.py: the counting script behind the ci-failures skill. It lists runs from the run
# ledger (runs.jsonl and sync.json) and their jobs from the job archive (jobs.jsonl), both read by
# this tree's schedules-sync, and reads a cache of gh responses (ann-<job>.json, log-<job>.txt, and
# jobs-<run>-<attempt>.json for an attempt the archive lacks), so the fixture in
# tests/fixtures/ci-failures/ is a ledger, an archive and a cache and --offline runs it with no network.
# The fixture holds one case per bucket and flag; each test names the run it pins.

setup() {
  bats_require_minimum_version 1.5.0
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic
  SCRIPT="$REPO_ROOT/.claude/skills/ops/ci-failures/ci-failures.py"
  CACHE="$SANDBOX/cache"
  cp -r "$REPO_ROOT/tests/fixtures/ci-failures" "$CACHE"
  export SCHEDULES_SYNC="$REPO_ROOT/.local/bin/schedules-sync" SCHEDULES_RUNS_LEDGER="$CACHE/runs.jsonl" SCHEDULES_JOBS_LEDGER="$CACHE/jobs.jsonl"
  export SCHEDULES_NOW=1793750700 # 2026-11-04T00:05Z, the fixture's sync.json synced_at
  export GH_FIXTURE="$SANDBOX/gh"
  mkdir -p "$GH_FIXTURE"
}

count() { python3 "$SCRIPT" --repo o/r --cache "$CACHE" --offline --until 2026-11-04T00:00:00Z --days 3 "$@"; }

# Print one field of the --json output, by a python expression over `d`.
field() { count --json | python3 -c "import json,sys; d=json.load(sys.stdin); print($1)"; }

# drop_run <id>: that run gone from the ledger
drop_run() { jq -c --argjson id "$1" 'select(.id != $id)' "$CACHE/runs.jsonl" > "$CACHE/l" && mv "$CACHE/l" "$CACHE/runs.jsonl"; }

sig() { field "[s for s in d['signatures'] if '$1' in s['signature']][0]['$2']"; }

@test "offline makes no gh call" {
  run count
  assert_success
  assert [ ! -e "$GH_FIXTURE/calls.log" ]
}

@test "a cancelled run is not red, and a run before the window is not read (107, 108)" {
  assert_equal "$(field "d['runs'], d['red_runs'], d['cancelled']")" "8 5 1"
}

@test "each red run lands in one bucket; the gate job that failed after the suite is derived (101)" {
  assert_equal "$(field "sorted(d['buckets'].items())")" "[('check', 1), ('infra', 2), ('test', 2)]"
  assert_equal "$(field "d['derived_jobs']")" "1"
}

@test "the same test red on main and a branch is one signature, flagged main (101, 102)" {
  assert_equal "$(sig PlayTests.Broken runs)" "2"
  assert_equal "$(sig PlayTests.Broken bucket)" "test"
  assert_equal "$(sig PlayTests.Broken main)" "True"
}

@test "a green sibling shard in the same run is not green@sha: shard names stay distinct (102)" {
  assert_equal "$(sig PlayTests.Broken green_sha)" "False"
}

@test "the signature is the output line, not the echoed script or post-job cleanup (101)" {
  run count
  refute_output --partial "source, not output"
  refute_output --partial "orphan processes"
}

@test "a job killed with exit 137 is infra (106)" {
  assert_equal "$(sig 'Unit tests' bucket)" "infra"
  assert_equal "$(sig 'Unit tests' why)" "killed (exit 137: OOM or runner)"
}

@test "a job canceled mid-run is infra, not a test red (103)" {
  assert_equal "$(sig 'operation was canceled' bucket)" "infra"
}

@test "a docs check red then green on the same commit is flagged green@sha, with paths and numbers normalized (104, 105)" {
  assert_equal "$(sig 'words N > N' bucket)" "check"
  assert_equal "$(sig 'words N > N' green_sha)" "True"
  assert_equal "$(sig 'words N > N' signature)" "Checks / Checks / Docs within their budgets :: <path>: words N > N"
}

@test "negative control: without the main run, the shared test red is no longer flagged main" {
  drop_run 101
  assert_equal "$(sig PlayTests.Broken main)" "False"
  assert_equal "$(field "d['base']")" "[0, 0]"
}

@test "negative control: without the green run, the docs red is no longer green@sha" {
  drop_run 105
  assert_equal "$(sig 'words N > N' green_sha)" "False"
}

@test "a run red only on the gate line is pending, listed but not red (109)" {
  assert_equal "$(field "d['red_runs'], d['pending_runs']")" "5 1"
  assert_equal "$(sig 'Merge gate line' bucket)" "pending"
  run count
  assert_output --partial "1 pending"
}

@test "negative control: the same red on any other step is a check red (109)" {
  sed -i 's/Merge gate line/Docs gate line/' "$CACHE/jobs.jsonl"
  assert_equal "$(field "d['red_runs'], d['pending_runs']")" "6 0"
  assert_equal "$(sig 'Docs gate line' bucket)" "check"
}

@test "negative control: a ledger last synced before the window ends is PARTIAL, exit 3, never a quiet low count" {
  sed -i 's/2026-11-04T00:05:00Z/2026-11-03T23:59:00Z/' "$CACHE/sync.json"
  run count
  assert_failure 3
  assert_output --partial 'not yet past 2026-11-04T00:00:00Z'
  assert_output --partial 'PARTIAL'
}

@test "SENTINEL_SINCE starts the window at a watch's fix: the runs before it are not read; one before the window changes nothing (negative control)" {
  SENTINEL_SINCE=$(date -d 2026-11-03T13:15:00Z +%s) run field "d['since'], d['runs'], d['red_runs']"
  assert_success
  assert_output "2026-11-03T13:15:00Z 4 1"
  SENTINEL_SINCE=$(date -d 2026-10-01T00:00:00Z +%s) run field "d['since'], d['runs'], d['red_runs']"
  assert_output "2026-11-01T00:00:00Z 8 5"
  # a fix after the window's end leaves an empty window ending there, never one that ends before it starts
  SENTINEL_SINCE=$(date -d 2026-11-05T00:00:00Z +%s) run field "d['since'], d['until'], d['runs']"
  assert_output "2026-11-04T00:00:00Z 2026-11-04T00:00:00Z 0"
}

@test "jobs come from the job archive; an attempt it lacks is read from gh's cache and counted in jobs_from_gh (104)" {
  assert_equal "$(field "d['jobs_from_gh'], d['partial']")" "0 False"
  jq -c 'select(.run_id == 104) | {jobs: [.jobs[] | .html_url = .url | del(.url)]}' "$CACHE/jobs.jsonl" > "$CACHE/jobs-104-1.json"
  jq -c 'select(.run_id != 104)' "$CACHE/jobs.jsonl" > "$CACHE/j" && mv "$CACHE/j" "$CACHE/jobs.jsonl"
  assert_equal "$(field "d['jobs_from_gh'], d['red_runs']")" "1 5"
  assert_equal "$(sig 'words N > N' bucket)" "check"
}

@test "negative control: an attempt in neither the archive nor the cache has no jobs, so its red is not read (104)" {
  jq -c 'select(.run_id != 104)' "$CACHE/jobs.jsonl" > "$CACHE/j" && mv "$CACHE/j" "$CACHE/jobs.jsonl"
  assert_equal "$(field "d['red_runs']")" "4"
}

@test "negative control: a job archive that cannot be read is PARTIAL, exit 3" {
  rm "$CACHE/jobs.jsonl"
  run count
  assert_failure 3
  assert_output --partial PARTIAL
}

# online <gh stderr>: a run that reaches gh, whose `run view` (a job's log) fails with that message
online() {
  mkdir -p "$SANDBOX/ghbin"
  printf '#!/bin/sh\n[ "$1 $2" = "run view" ] && { echo "%s" >&2; exit 1; }\necho "[]"\n' "$1" > "$SANDBOX/ghbin/gh"
  chmod +x "$SANDBOX/ghbin/gh"
  rm "$CACHE/log-1061.txt"
  PATH="$SANDBOX/ghbin:$PATH" python3 "$SCRIPT" --repo o/r --cache "$CACHE" --until 2026-11-04T00:00:00Z --days 3 --json
}

@test "a job GitHub stored no log for is read from its annotations and listed, not PARTIAL (106)" {
  run --separate-stderr online "log not found: 1061"
  assert_success
  assert_equal "$(python3 -c "import json,sys; d=json.loads(sys.argv[1]); print(d['partial'], d['logs_missing'], d['red_runs'], d['buckets']['infra'])" "$output")" "False [1061] 5 2"
}

@test "negative control: any other gh error on a log is PARTIAL, exit 3" {
  run --separate-stderr online "HTTP 502: Bad Gateway"
  assert_failure 3
  assert_equal "$(python3 -c "import json,sys; print(json.loads(sys.argv[1])['partial'])" "$output")" "True"
}
