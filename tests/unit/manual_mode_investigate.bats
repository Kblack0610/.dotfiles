#!/usr/bin/env bats
# manual-mode-investigate.sh: manual (default) permission mode is investigate-only.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  HOOK="$BATS_TEST_DIRNAME/../../.claude/hooks/manual-mode-investigate.sh"
}

prompt() { printf '{"hook_event_name":"UserPromptSubmit","permission_mode":"%s","prompt":"why"}' "$1"; }
tool() { printf '{"hook_event_name":"PreToolUse","permission_mode":"%s","tool_name":"%s","tool_input":{}}' "$1" "$2"; }

@test "manual mode injects the investigate posture on a prompt" {
  run bash "$HOOK" <<< "$(prompt default)"
  assert_success
  assert_output --partial '"hookEventName":"UserPromptSubmit"'
  assert_output --partial 'investigate-only'
}

@test "other modes get no posture" {
  for m in plan acceptEdits bypassPermissions; do
    run bash "$HOOK" <<< "$(prompt "$m")"
    assert_success
    assert_output ""
  done
}

@test "manual mode denies a tool the matcher routes here" {
  run bash "$HOOK" <<< "$(tool default Edit)"
  assert_success
  assert_output --partial '"permissionDecision":"deny"'
  assert_output --partial '"permissionDecisionReason":"manual-mode-investigate: '
}

@test "an edit in bypass mode passes" {
  run bash "$HOOK" <<< "$(tool bypassPermissions Edit)"
  assert_success
  assert_output ""
}

@test "a payload with no permission_mode is a no-op" {
  run bash "$HOOK" <<< '{"hook_event_name":"PreToolUse","tool_name":"Edit"}'
  assert_success
  assert_output ""
}
