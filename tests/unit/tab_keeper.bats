#!/usr/bin/env bats
# Tab Keeper's dedupe and sweep decisions live in rules.js, free of browser APIs, so node tests them.

@test "tab-keeper rules" {
  run node --test "$BATS_TEST_DIRNAME/../tab-keeper/rules.test.mjs"
  [ "$status" -eq 0 ]
}
