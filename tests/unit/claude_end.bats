#!/usr/bin/env bats
# claude-end.sh: the one parse of how a Claude Code transcript says its session ended. Its three callers
# (fleet-sessions api_error_stop, so_transcript_metrics, fleet-dispatch item_claude_end) have their own tests;
# this one holds the parse itself, and its negative controls.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  . "$REPO_ROOT/.local/lib/claude-end.sh"
  T="$BATS_TEST_TMPDIR/t.jsonl"
}

err() { printf '{"type":"assistant","timestamp":"2026-11-24T09:01:30.000Z","isApiErrorMessage":true,"message":{"content":[{"type":"text","text":"%s"}]}}\n' "$1"; }
msg() { printf '{"type":"%s","timestamp":"2026-11-24T09:05:00.000Z","message":{"content":"x"}}\n' "$1"; }

@test "claude_end: a last message that is an API Error line with a code is a provider end, with the code and the minute" {
  { msg user; err 'API Error: 529 overloaded'; } > "$T"
  run claude_end "$T"
  assert_success
  assert_output $'provider\t529\t2026-11-24T09:01'
}

@test "claude_end: a code-less error line that names a limit is the plan's usage limit" {
  err "You've hit your limit - resets 5pm" > "$T"
  run claude_end "$T"
  assert_output $'limit\t-\t2026-11-24T09:01'
}

@test "claude_end: a later message makes the error not the last one, and an error line of neither kind says nothing (negative controls)" {
  { err 'API Error: 529 overloaded'; msg user; } > "$T"
  run claude_end "$T"
  assert_output ''
  err 'something broke' > "$T"
  run claude_end "$T"
  assert_output ''
  err 'Context limit reached - start a new session' > "$T"
  run claude_end "$T"
  assert_output ''
  # a model that wrote the words is not the CLI's error line
  printf '{"type":"assistant","timestamp":"2026-11-24T09:01:00.000Z","message":{"content":[{"type":"text","text":"API Error: 500 in the log"}]}}\n' > "$T"
  run claude_end "$T"
  assert_output ''
  run claude_end "$BATS_TEST_TMPDIR/none.jsonl"
  assert_success
  assert_output ''
}

@test "claude_end: a first line cut by tail and a line that is no JSON are skipped, the last message still read" {
  { printf 'not json\n'; err 'API Error: 503 unavailable'; } > "$T"
  run claude_end "$T"
  assert_output $'provider\t503\t2026-11-24T09:01'
}
