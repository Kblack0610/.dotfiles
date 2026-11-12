#!/usr/bin/env bats
# agent-web's Queue, answer, Home and Projects cards, the Daily tab, the Log's hour chart and project groups, the Sessions list and its conversation, the Fleet runner rows, Infra's Red fixes and the shared table on Infra's Jobs, the Schedules tab, the Costs tab and the tab skeleton they share (tblTab)
# are drawn by the real scripts, so they are tested against them (tests/agent-web/{queue,waiting,home,projects,focus,log,sessions,convo,fleet,alerts,infra,jobs,schedules,releases,costs,table,heads}.test.mjs); skips where node is absent.

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

@test "agent-web outbox.js: node unit tests pass" {
  run node --test "$BATS_TEST_DIRNAME/../agent-web/outbox.test.mjs"
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

@test "agent-web fleet.js runner rows: node unit tests pass" {
  run node --test "$BATS_TEST_DIRNAME/../agent-web/fleet.test.mjs"
  assert_success
}

@test "agent-web infra.js the Infra tab: node unit tests pass" {
  run node --test "$BATS_TEST_DIRNAME/../agent-web/infra.test.mjs"
  assert_success
}

@test "agent-web alerts.js the Alerts tab: node unit tests pass" {
  run node --test "$BATS_TEST_DIRNAME/../agent-web/alerts.test.mjs"
  assert_success
}

@test "agent-web table.js on Infra's Jobs: node unit tests pass" {
  run node --test "$BATS_TEST_DIRNAME/../agent-web/jobs.test.mjs"
  assert_success
}

@test "agent-web Log Actions table: node unit tests pass" {
  run node --test "$BATS_TEST_DIRNAME/../agent-web/actions.test.mjs"
  assert_success
}

@test "agent-web releases.js the Releases tab: node unit tests pass" {
  run node --test "$BATS_TEST_DIRNAME/../agent-web/releases.test.mjs"
  assert_success
}

@test "agent-web schedules.js the Schedules tab: node unit tests pass" {
  run node --test "$BATS_TEST_DIRNAME/../agent-web/schedules.test.mjs"
  assert_success
}

@test "agent-web costs.js: node unit tests pass" {
  run node --test "$BATS_TEST_DIRNAME/../agent-web/costs.test.mjs"
  assert_success
}

@test "agent-web convo.js: node unit tests pass" {
  run node --test "$BATS_TEST_DIRNAME/../agent-web/convo.test.mjs"
  assert_success
}

@test "agent-web table.js tblTab, the skeleton every shared-table tab draws with: node unit tests pass" {
  run node --test "$BATS_TEST_DIRNAME/../agent-web/table.test.mjs"
  assert_success
}

@test "agent-web section heads: every head is secHead, its title and count" {
  run node --test "$BATS_TEST_DIRNAME/../agent-web/heads.test.mjs"
  assert_success
}

@test "agent-web nav.js, the sidebar's outline: node unit tests pass" {
  run node --test "$BATS_TEST_DIRNAME/../agent-web/nav.test.mjs"
  assert_success
}
