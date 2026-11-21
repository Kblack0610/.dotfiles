#!/usr/bin/env bats
# The hunk agent-request extension's pure functions (note -> `agent-request add` argv, session
# choices), run by `bun test` because the extension is TypeScript. Skips where bun is absent off
# CI; on CI (`CI` set) a missing bun fails, since tests.yml's fast job installs it for each shard
# holding a file that runs `bun test`, and a skip there would pass a gate that tested nothing.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  command -v bun >/dev/null 2>&1 || { [ -z "${CI-}" ] || fail "bun not installed on CI"; skip "bun not installed"; }
}

@test "agent-request extension: bun unit tests pass" {
  # Names the extension so tests/pick.sh picks this file when .config/hunk/extensions/agent-request.ts changes.
  [ -f "$BATS_TEST_DIRNAME/../../.config/hunk/extensions/agent-request.ts" ]
  run bun test "$BATS_TEST_DIRNAME/../hunk/agent-request.test.ts"
  assert_success
}
