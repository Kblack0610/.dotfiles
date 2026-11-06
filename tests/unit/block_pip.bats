#!/usr/bin/env bats
# block-pip.sh: bare pip install is denied, uv's own pip is not.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  HOOK="$BATS_TEST_DIRNAME/../../.claude/hooks/block-pip.sh"
}

cmd() { jq -nc --arg c "$1" '{tool_name:"Bash", tool_input:{command:$c}}' | bash "$HOOK"; }

@test "bare pip install is denied, the reason leading with the hook's name" {
  run cmd 'pip install requests'
  assert_success
  run jq -r .hookSpecificOutput.permissionDecisionReason <<<"$output"
  assert_output --partial 'block-pip: Use `uv add'
  run cmd 'uv pip install x && pip3 install y'
  assert_output --partial '"deny"'
}

@test "uv pip install and other commands pass" {
  run cmd 'uv pip install requests'
  assert_success
  assert_output ''
  run cmd 'ls'
  assert_output ''
}
