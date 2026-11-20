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
jobs() { sed -nE '/^jobs:$/,$ s/^  ([A-Za-z0-9_][A-Za-z0-9_-]*):$/\1/p' "$1" | sort; }

# gate_needs <wf>: the gate job's needs, one a line, sorted
gate_needs() { sed -n '/^  gate:$/,/^  [a-z]/{s/^    needs: *\[\(.*\)\]$/\1/p}' "$1" | tr -d ' ' | tr ',' '\n' | sort; }

# missing <wf>: jobs that are neither in gate's needs nor named as not gates
missing() { comm -23 <(jobs "$1") <({ gate_needs "$1"; tr ' ' '\n' <<<"$NOT_GATES"; } | sort); }

# unknown <wf>: names in gate's needs that are not jobs (a renamed or deleted job)
unknown() { comm -13 <(jobs "$1") <(gate_needs "$1"); }

@test "the gate needs every job but the ones that are not gates" {
  [ -n "$(gate_needs "$WF")" ] || fail "no needs read from the gate job"
  run missing "$WF"
  assert_success
  assert_output ''
  # Negative control: a new job that nobody added to the gate is named.
  awk '/^  gate:$/ { print "  Newjob-2:"; print "    runs-on: ubuntu-24.04" } { print }' "$WF" >"$BATS_TEST_TMPDIR/new.yml"
  run missing "$BATS_TEST_TMPDIR/new.yml"
  assert_output 'Newjob-2'
}

@test "every job the gate needs exists" {
  run unknown "$WF"
  assert_success
  assert_output ''
  # Negative control: a renamed job leaves its old name in needs.
  sed 's/^  lint:$/  lints:/' "$WF" >"$BATS_TEST_TMPDIR/renamed.yml"
  run unknown "$BATS_TEST_TMPDIR/renamed.yml"
  assert_output 'lint'
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

# cargo_keys <wf>: the cargo cache key every job restores, one a line
cargo_keys() { grep -E '^ +key: cargo-target-' "$1"; }

@test "the rust and notes jobs restore the same cargo cache key" {
  run cargo_keys "$WF"
  assert_success
  [ "$(wc -l <<<"$output")" -eq 2 ] || fail "want the rust restore and the notes restore: $output"
  [ "$(sort -u <<<"$output" | wc -l)" -eq 1 ] || fail "the cargo cache keys differ: $output"
  # Negative control: a notes key that drifted is named.
  sed '/^  notes:$/,$ s/cargo-target-\${{ runner.os }}/cargo-target-x-${{ runner.os }}/' "$WF" >"$BATS_TEST_TMPDIR/drift.yml"
  run cargo_keys "$BATS_TEST_TMPDIR/drift.yml"
  [ "$(sort -u <<<"$output" | wc -l)" -gt 1 ]
}

# rust_gate_step <wf>: the Rust gate step's text, up to the next step
rust_gate_step() { sed -n '/^      - name: Rust gate$/,/^      - name: /p' "$1"; }

@test "the Rust gate runs clippy on a pull request: no step sets CLIPPY" {
  run rust_gate_step "$WF"
  assert_success
  [[ "$output" == *"tests/pick.sh rust"* ]] || fail "the Rust gate step was not found: $output"
  [[ "$output" != *CLIPPY* ]] || fail "the Rust gate sets CLIPPY, so a pull request skips or forces clippy: $output"
  # Negative control: a pull-request-only CLIPPY=0 is named.
  sed "s/^          BASE: /          CLIPPY: \${{ github.event_name == 'pull_request' \&\& '0' || '1' }}\n          BASE: /" "$WF" >"$BATS_TEST_TMPDIR/skip.yml"
  run rust_gate_step "$BATS_TEST_TMPDIR/skip.yml"
  [[ "$output" == *CLIPPY* ]]
}
