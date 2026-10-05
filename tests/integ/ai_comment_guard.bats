#!/usr/bin/env bats
# ai-comment-guard.sh: PostToolUse warning on AI-tell comments. Pins the exit-code
# contract (0 clean, 2 flagged) and the path skips, so folding its three python3
# starts into one cannot quietly change what it flags.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  GUARD="$BATS_TEST_DIRNAME/../../.claude/hooks/ai-comment-guard.sh"
}

payload() { jq -nc --arg p "$1" --arg s "$2" '{tool_input:{file_path:$p, new_string:$s}}'; }

@test "clean code passes silently" {
  run bash -c "$(declare -f payload); payload /x/a.sh 'echo hi' | bash '$GUARD'"
  assert_success
  assert_output ""
}

@test "a changelog marker is flagged with the file path" {
  run bash -c "$(declare -f payload); payload /x/a.sh '# NEW: thing' | bash '$GUARD'"
  assert_failure 2
  assert_output --partial "written to /x/a.sh"
  assert_output --partial "changelog marker"
}

@test "MultiEdit edits are scanned" {
  run bash -c "jq -nc '{tool_input:{file_path:\"/x/m.ts\", edits:[{new_string:\"ok\"},{new_string:\"// ===== banner\"}]}}' | bash '$GUARD'"
  assert_failure 2
  assert_output --partial "section banner"
}

@test "vendored and changelog paths are skipped" {
  run bash -c "$(declare -f payload); payload /x/node_modules/a.js '// NEW: x' | bash '$GUARD'"
  assert_success
  run bash -c "$(declare -f payload); payload /x/CHANGELOG.md '# NEW: x' | bash '$GUARD'"
  assert_success
}

@test "malformed payload is ignored" {
  run bash -c "echo garbage | bash '$GUARD'"
  assert_success
  assert_output ""
}
