#!/usr/bin/env bats
# Tier 2: editor.sh's `$SELF <verb>` contract, as a real subprocess.
#
# The verbs that touch tmux cannot be driven meaningfully here -- that is the ui tier's job,
# in the container, against a real server. What CAN be pinned without one is the contract
# every panel in this repo is supposed to honour, and which two panels historically did not:
#
#   * an unknown verb must REJECT. Falling through to the default action means a typo
#     silently does something, and in a headless run it blocks instead of failing.
#   * a tmux verb run OUTSIDE tmux must fail LOUDLY. This is the exact bug panel_new_window
#     exists to prevent (panel-lib.sh:233) -- notes-cockpit.sh swallowed the failure with
#     2>/dev/null, so outside tmux the key simply did nothing and read as broken.
#
# sandbox_init unsets $TMUX, so "outside tmux" is this tier's default state and costs nothing
# to arrange.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic
}

@test "the subject is where the harness says it is, and is runnable" {
  # Guards every `run "$EDITOR_SH"` below: a bad path would make bats report status 127,
  # which several of these tests would happily read as "failed as expected".
  [ -n "${EDITOR_SH:-}" ] || fail "EDITOR_SH is unset -- sandbox.bash did not export it"
  [ -f "$EDITOR_SH" ] || fail "EDITOR_SH does not exist: $EDITOR_SH"
  [ -x "$EDITOR_SH" ] || fail "EDITOR_SH is not executable: $EDITOR_SH"
}

@test "--help prints the header block, not a usage stub" {
  run "$EDITOR_SH" --help
  assert_success
  assert_output --partial 'Verbs:'
  assert_output --partial 'toggle'
  assert_output --partial 'ensure'
  # panel_usage prints the WHOLE header, so the rationale travels with the tool. If someone
  # swaps it for a hardcoded two-line usage, this catches it.
  assert_output --partial 'NEVER BY NAME'
  refute_output --partial '#!'
}

@test "-h is the same as --help" {
  run "$EDITOR_SH" -h
  assert_success
  assert_output --partial 'Verbs:'
}

@test "an unknown verb is rejected, not quietly treated as a default action" {
  run "$EDITOR_SH" togle
  assert_failure
  assert_output --partial 'unknown verb'
}

@test "no verb at all is also rejected" {
  # There is no picker here to fall back to, so an argless call is a caller bug.
  run "$EDITOR_SH"
  assert_failure
  assert_output --partial 'unknown verb'
}

@test "toggle outside tmux fails loudly instead of silently doing nothing" {
  [ -z "${TMUX:-}" ] || fail "sandbox_init did not unset TMUX -- this test proves nothing"
  run "$EDITOR_SH" toggle
  assert_failure
  assert_output --partial 'not inside tmux'
}

@test "ensure outside tmux fails loudly too" {
  run "$EDITOR_SH" ensure
  assert_failure
  assert_output --partial 'not inside tmux'
}

@test "root answers without a tmux server, because it is a pure question" {
  # It is split out from ensure precisely so the resolution order is assertable headlessly.
  run "$EDITOR_SH" root
  assert_success
  assert_output "$HOME"
}

@test "root honours EDITOR_ROOT, so the editor can be pinned elsewhere" {
  EDITOR_ROOT="$SANDBOX/pinned" run "$EDITOR_SH" root
  assert_success
  assert_output "$SANDBOX/pinned"
}

@test "ensure never creates a window when it is not inside tmux" {
  # The failure above must be a REFUSAL, not a message printed on the way to doing it
  # anyway. The stub records every tmux invocation, so this is checkable.
  run "$EDITOR_SH" ensure
  assert_failure
  assert_not_called 'new-window'
}
