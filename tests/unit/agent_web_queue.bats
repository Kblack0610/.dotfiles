#!/usr/bin/env bats
# agent-web's Queue, answer and Home cards decide what a waiting item or ask shows, so they are tested
# against the real scripts (tests/agent-web/{queue,waiting,home}.test.mjs); skips where node is absent.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  command -v node >/dev/null 2>&1 || skip "node not installed"
}

@test "agent-web queue.js: node unit tests pass" {
  run node --test "$BATS_TEST_DIRNAME/../agent-web/queue.test.mjs"
  assert_success
}

@test "agent-web waiting.js: node unit tests pass" {
  run node --test "$BATS_TEST_DIRNAME/../agent-web/waiting.test.mjs"
  assert_success
}

@test "agent-web home.js: node unit tests pass" {
  run node --test "$BATS_TEST_DIRNAME/../agent-web/home.test.mjs"
  assert_success
}
