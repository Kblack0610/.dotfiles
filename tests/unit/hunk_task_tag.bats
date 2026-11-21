#!/usr/bin/env bats
# The hunk `#task` extension's pure functions (tag parsing, row text, routing), run by
# `bun test` because the extension is TypeScript. Skips where bun is absent off CI; on CI
# (`CI` set) a missing bun fails, since tests.yml's fast job installs it for each shard holding
# a file that runs `bun test`, and a skip there would pass a gate that tested nothing.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  command -v bun >/dev/null 2>&1 || { [ -z "${CI-}" ] || fail "bun not installed on CI"; skip "bun not installed"; }
}

@test "task-tag extension: bun unit tests pass" {
  # Names the extension so tests/pick.sh picks this file when .config/hunk/extensions/task-tag.ts changes.
  [ -f "$BATS_TEST_DIRNAME/../../.config/hunk/extensions/task-tag.ts" ]
  run bun test "$BATS_TEST_DIRNAME/../hunk/task-tag.test.ts"
  assert_success
}
