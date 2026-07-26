#!/usr/bin/env bats
# Harness smoke test. If this fails, nothing else in the suite means anything.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic
  # `load` only handles .bash files, and the subject is .sh -- source it directly.
  source "$COCKPIT"
}

@test "sourcing the cockpit does not launch the UI" {
  # The source guard returned before the fzf preflight, so we got here at all.
  # Prove the functions came with us.
  declare -F classify   >/dev/null
  declare -F _task_row  >/dev/null
  declare -F rail       >/dev/null
}

@test "sandbox redirects HOME and TMPDIR away from the real ones" {
  refute [ "$HOME" = "/home/kblack0610" ]
  assert [ -d "$HOME" ]
  [[ "$HOME" == *"$BATS_TEST_TMPDIR"* ]]
  [[ "$TMPDIR" == *"$BATS_TEST_TMPDIR"* ]]
}

@test "sandbox path contains a space, so unquoted expansions fail loudly here" {
  [[ "$HOME" == *" "* ]]
}

@test "the notes stub is on PATH ahead of the real one" {
  run command -v notes
  assert_success
  [[ "$output" == "$SANDBOX/bin/notes" ]]
}

@test "the notes stub serves fixture data and records its calls" {
  run notes config --profiles
  assert_success
  assert_line 'personal'
  assert_line 'work'
  assert_called 'notes config --profiles'
}

@test "cockpit state files land in the sandbox, not the real TMPDIR" {
  [[ "$STATE"   == "$TMPDIR"/* ]]
  [[ "$MODEF"   == "$TMPDIR"/* ]]
  [[ "$PFILTER" == "$TMPDIR"/* ]]
}
