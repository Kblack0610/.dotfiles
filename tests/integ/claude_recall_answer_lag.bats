#!/usr/bin/env bats
# claude-recall answer-lag: tool calls before the first answer to a question the human typed
# (comms-standard, Answers in chat). Pins the count, edit-first, unanswered, and the negative
# controls: a work order, a `?` only in pasted text, and a subagent transcript are not questions.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  RECALL="$BATS_TEST_DIRNAME/../../.local/bin/claude-recall"
  D="$BATS_TEST_TMPDIR"
  mkdir -p "$D/projects/p/s1/subagents"
  export CLAUDE_TRANSCRIPTS="$D/projects"
  now=$(date -u +%Y-%m-%dT%H)
  cwd='"cwd":"/home/u/proj"'
  # U <text>: a typed prompt; A <content blocks>: one assistant record
  U() { echo "{\"type\":\"user\",$cwd,\"timestamp\":\"$now:00:00Z\",\"message\":{\"content\":\"$1\"}}"; }
  A() { echo "{\"type\":\"assistant\",$cwd,\"timestamp\":\"$now:00:01Z\",\"message\":{\"content\":[$1]}}"; }
  T() { echo "{\"type\":\"tool_use\",\"id\":\"t\",\"name\":\"$1\",\"input\":{}}"; }
  X() { echo "{\"type\":\"text\",\"text\":\"$1\"}"; }
  {
    # answered after 3 calls
    U "why is it stuck?"
    A "$(T Bash)"; A "$(T Read)"; A "$(T Bash)"
    A "$(X 'It is stuck because')"
    A "$(T Bash)"
    # a work order: never a question, however many calls
    U "fix the thing"
    A "$(T Bash)"; A "$(T Edit)"; A "$(T Bash)"; A "$(T Bash)"; A "$(T Bash)"; A "$(T Bash)"
    # a ? only in pasted text is not the human asking
    U "look at this <pasted_content id=\\\"ab\\\">is it red?</pasted_content id=\\\"ab\\\">"
    A "$(T Bash)"
    # edited before answering, and a whitespace-only text block is not an answer
    U "how did this happen?"
    A "$(T Bash)"; A "$(X '  ')"; A "$(T Edit)"
    A "$(X 'It happened because')"
    # never answered before the next prompt
    U "is it done?"
    A "$(T Bash)"; A "$(T Bash)"
    U "[Request interrupted by user]"
    U "ok thanks"
  } > "$D/projects/p/s1.jsonl"
  {
    U "where is X?"
    A "$(T Grep)"; A "$(T Grep)"; A "$(T Grep)"; A "$(T Grep)"; A "$(T Grep)"; A "$(T Grep)"; A "$(T Grep)"
  } > "$D/projects/p/s1/subagents/agent-a1.jsonl"
}

@test "answer-lag counts calls before the first text for typed questions only" {
  run "$RECALL" answer-lag --days 1 --json
  assert_success
  run jq -c '[.questions, .edited_first, .unanswered, .over, ([.slowest[].calls] | sort)]' <<<"$output"
  assert_output '[3,1,1,0,[2,2,3]]'
}

@test "answer-lag --over counts the slow ones and the text report names them" {
  run "$RECALL" answer-lag --days 1 --over 2
  assert_success
  assert_line --partial "3 questions typed"
  assert_line --partial "1 over 2"
  assert_line --partial "edit-first"
  assert_line --partial "unanswered"
  refute_output --partial "fix the thing"
  refute_output --partial "where is X"
}
