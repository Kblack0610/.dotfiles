#!/usr/bin/env bats
# agent-web's markdown renderer (static/md.js) is the one place agent text becomes HTML in a
# page that can type into live sessions, so its escaping is tested, not eyeballed. The cases
# run under `node --test` (tests/agent-web/md.test.mjs); skips where node is absent.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  command -v node >/dev/null 2>&1 || skip "node not installed"
}

@test "agent-web md.js: node unit tests pass" {
  run node --test "$BATS_TEST_DIRNAME/../agent-web/md.test.mjs"
  assert_success
}
