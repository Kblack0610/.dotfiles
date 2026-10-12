#!/usr/bin/env bats
# The hunk `#task` extension's pure functions (tag parsing, row text, routing), run by
# `bun test` because the extension is TypeScript. Skips where bun is absent (the CI runner);
# the local stop-hook fast tier is where it gates.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  command -v bun >/dev/null 2>&1 || skip "bun not installed"
}

@test "task-tag extension: bun unit tests pass" {
  run bun test "$BATS_TEST_DIRNAME/../hunk/task-tag.test.ts"
  assert_success
}
