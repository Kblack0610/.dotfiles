#!/usr/bin/env bats
# The hunk agent-request extension's pure functions (note -> `agent-request add` argv, session
# choices), run by `bun test` because the extension is TypeScript. Skips where bun is absent
# (the CI runner); the local stop-hook fast tier is where it gates.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  command -v bun >/dev/null 2>&1 || skip "bun not installed"
}

@test "agent-request extension: bun unit tests pass" {
  run bun test "$BATS_TEST_DIRNAME/../hunk/agent-request.test.ts"
  assert_success
}
