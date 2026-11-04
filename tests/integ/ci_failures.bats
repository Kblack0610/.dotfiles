#!/usr/bin/env bats
# ci-failures.py: the counting script behind the ci-failures skill. It reads a cache of gh
# responses (run-*.json, jobs-<run>-<attempt>.json, ann-<job>.json, log-<job>.txt), so the
# fixture in tests/fixtures/ci-failures/ is a cache and --offline runs it with no network.
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
  export GH_FIXTURE="$SANDBOX/gh"
  mkdir -p "$GH_FIXTURE"
}

count() { python3 "$SCRIPT" --repo o/r --cache "$CACHE" --offline --until 2026-11-04T00:00:00Z --days 3 "$@"; }

# Print one field of the --json output, by a python expression over `d`.
field() { count --json | python3 -c "import json,sys; d=json.load(sys.stdin); print($1)"; }

sig() { field "[s for s in d['signatures'] if '$1' in s['signature']][0]['$2']"; }

@test "offline makes no gh call" {
  run count
  assert_success
  assert [ ! -e "$GH_FIXTURE/calls.log" ]
}

@test "a cancelled run is not red, and a run before the window is not read (107, 108)" {
  assert_equal "$(field "d['runs'], d['red_runs'], d['cancelled']")" "7 5 1"
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
  rm "$CACHE/run-101.json"
  assert_equal "$(sig PlayTests.Broken main)" "False"
  assert_equal "$(field "d['base']")" "[0, 0]"
}

@test "negative control: without the green run, the docs red is no longer green@sha" {
  rm "$CACHE/run-105.json"
  assert_equal "$(sig 'words N > N' green_sha)" "False"
}
