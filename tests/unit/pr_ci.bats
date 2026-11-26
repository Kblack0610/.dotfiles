#!/usr/bin/env bats
# .local/lib/pr-ci.sh: CI_JQ's infra and red_runs, over a PR's statusCheckRollup as gh returns it.
# 2026-11-25: #3516, #3538 and #3576 read red with every job cancelled at ~617s on starved runners and
# the aggregate `gate` failing on its cancelled needs; fleet-dispatch spent two fix-ci tries on each.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  # shellcheck source=../../.local/lib/pr-ci.sh
  . "$BATS_TEST_DIRNAME/../../.local/lib/pr-ci.sh"
}

# job <name> <conclusion> <run> <started> <completed> -> one check run of the rollup
job() {
  jq -cn --arg n "$1" --arg c "$2" --arg r "$3" --arg s "$4" --arg e "$5" '{__typename: "CheckRun", name: $n,
    workflowName: "shell tests", status: "COMPLETED", conclusion: $c, startedAt: $s, completedAt: $e,
    detailsUrl: "https://github.com/o/r/actions/runs/\($r)/job/1"}'
}

# verdict <check json>... -> "<ci> <infra> <red_runs>" for a PR whose rollup holds those checks
verdict() { jq -sc '{statusCheckRollup: .}' <<<"$(printf '%s\n' "$@")" | jq -r "$CI_JQ"' [ci, infra, red_runs] | map(tostring) | join(" ")'; }

@test "infra: every job cut at its timeout and the aggregate failing after them is the runners' red" {
  run verdict "$(job 'fast (1/2)' CANCELLED 7 2026-11-25T15:54:24Z 2026-11-25T16:04:41Z)" \
    "$(job 'fast (2/2)' TIMED_OUT 7 2026-11-25T15:54:24Z 2026-11-25T16:04:40Z)" \
    "$(job lint SUCCESS 7 2026-11-25T15:54:24Z 2026-11-25T15:55:00Z)" \
    "$(job gate FAILURE 7 2026-11-25T16:08:00Z 2026-11-25T16:08:04Z)"
  assert_output 'FAIL true 7'
}

@test "infra: one real failure beside the cancelled jobs is a code red" {
  # NEGATIVE CONTROL: ui failed while the shards still ran, so it is no aggregate of them
  run verdict "$(job 'fast (1/2)' CANCELLED 7 2026-11-25T15:54:24Z 2026-11-25T16:04:41Z)" \
    "$(job ui FAILURE 7 2026-11-25T15:54:30Z 2026-11-25T15:59:06Z)" \
    "$(job gate FAILURE 7 2026-11-25T16:08:00Z 2026-11-25T16:08:04Z)"
  assert_output 'FAIL false 7'
  run verdict "$(job ui FAILURE 7 2026-11-25T15:54:30Z 2026-11-25T15:59:06Z)" "$(job gate FAILURE 7 2026-11-25T16:08:00Z 2026-11-25T16:08:04Z)"
  assert_output 'FAIL false 7'
}

@test "infra: an aggregate reads only the cancelled jobs of its own run, and a status with no run is a code red" {
  run verdict "$(job 'fast (1/2)' CANCELLED 7 2026-11-25T15:54:24Z 2026-11-25T16:04:41Z)" \
    "$(job 'E2E Summary' FAILURE 8 2026-11-25T16:08:00Z 2026-11-25T16:08:04Z)"
  assert_output 'FAIL false 7,8'
  run verdict "$(job 'fast (1/2)' CANCELLED 7 2026-11-25T15:54:24Z 2026-11-25T16:04:41Z)" \
    '{"__typename": "StatusContext", "context": "ci/legacy", "state": "ERROR"}'
  assert_output 'FAIL false 7'
}

@test "infra: green and running are never infra" {
  run verdict "$(job lint SUCCESS 7 2026-11-25T15:54:24Z 2026-11-25T15:55:00Z)"
  assert_output 'PASS false -'
  run verdict "$(job 'fast (1/2)' CANCELLED 7 2026-11-25T15:54:24Z 2026-11-25T16:04:41Z)" \
    '{"__typename": "CheckRun", "name": "gate", "workflowName": "shell tests", "status": "IN_PROGRESS", "conclusion": "", "detailsUrl": "https://github.com/o/r/actions/runs/7/job/2"}'
  assert_output 'PENDING false 7'
}
