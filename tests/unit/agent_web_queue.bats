#!/usr/bin/env bats
# agent-web's Queue, answer, Home and Projects cards, the Focus tab, the Log's hour chart and project groups and the Sessions list
# are drawn by the real scripts, so they are tested against them (tests/agent-web/{queue,waiting,home,projects,focus,log,sessions}.test.mjs); skips where node is absent.

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

@test "agent-web projects.js: node unit tests pass" {
  run node --test "$BATS_TEST_DIRNAME/../agent-web/projects.test.mjs"
  assert_success
}

@test "agent-web focus.js: node unit tests pass" {
  run node --test "$BATS_TEST_DIRNAME/../agent-web/focus.test.mjs"
  assert_success
}

@test "agent-web log.js: node unit tests pass" {
  run node --test "$BATS_TEST_DIRNAME/../agent-web/log.test.mjs"
  assert_success
}

@test "agent-web Sessions list (app.js, watch.js, shepherd.js): node unit tests pass" {
  run node --test "$BATS_TEST_DIRNAME/../agent-web/sessions.test.mjs"
  assert_success
}
