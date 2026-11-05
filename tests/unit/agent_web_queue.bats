#!/usr/bin/env bats
# agent-web's Queue tab matches an item to its pane and its asks in the page, so the matching
# is tested against the real scripts (tests/agent-web/queue.test.mjs); skips where node is absent.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  command -v node >/dev/null 2>&1 || skip "node not installed"
}

@test "agent-web queue.js: node unit tests pass" {
  run node --test "$BATS_TEST_DIRNAME/../agent-web/queue.test.mjs"
  assert_success
}
