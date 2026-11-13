#!/usr/bin/env bats
# .github/workflows/tests.yml's gate job, the one check branch protection requires: its `needs`
# names every job but the ones that are not gates, and its step is red on any result but success.

bats_require_minimum_version 1.5.0

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  WF="$BATS_TEST_DIRNAME/../../.github/workflows/tests.yml"
  # weights may fail (fast falls back to test counts); report only draws; gate is the aggregate.
  NOT_GATES='gate report weights'
}

# jobs <wf>: every job id, one a line, sorted
jobs() { sed -nE '/^jobs:$/,$ s/^  ([a-z][a-z0-9_-]*):$/\1/p' "$1" | sort; }

# gate_needs <wf>: the gate job's needs, one a line, sorted
gate_needs() { sed -n '/^  gate:$/,/^  [a-z]/{s/^    needs: *\[\(.*\)\]$/\1/p}' "$1" | tr -d ' ' | tr ',' '\n' | sort; }

# missing <wf>: jobs that are neither in gate's needs nor named as not gates
missing() { comm -23 <(jobs "$1") <({ gate_needs "$1"; tr ' ' '\n' <<<"$NOT_GATES"; } | sort); }

@test "the gate needs every job but the ones that are not gates" {
  [ -n "$(gate_needs "$WF")" ] || fail "no needs read from the gate job"
  run missing "$WF"
  assert_success
  assert_output ''
  # Negative control: a new job that nobody added to the gate is named.
  sed '/^  gate:$/i\  newjob:\n    runs-on: ubuntu-24.04\n' "$WF" >"$BATS_TEST_TMPDIR/new.yml"
  run missing "$BATS_TEST_TMPDIR/new.yml"
  assert_output 'newjob'
}

@test "the gate step is green only when every needed job succeeded" {
  local check
  check=$(sed -n '/^  gate:$/,/^  [a-z]/{s/^ *\(jq -e .*\)$/\1/p}' "$WF")
  [ -n "$check" ] || fail "no jq -e line read from the gate job"
  for case in '{"a":{"result":"success"},"b":{"result":"success"}}:0' \
    '{"a":{"result":"success"},"b":{"result":"skipped"}}:1' \
    '{"a":{"result":"failure"}}:1' \
    '{"a":{"result":"cancelled"}}:1' \
    '{}:1'; do
    NEEDS=${case%:*} run bash -c "$check"
    [ "$status" -eq "${case##*:}" ] || fail "NEEDS=${case%:*}: exit $status, want ${case##*:}"
  done
}
