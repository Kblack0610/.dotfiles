#!/usr/bin/env bats
# `sessions prompts`, behind ctrl-t in prefix R: one row per prompt the human typed, oldest
# first, with tool results, meta records and harness wrappers left out; a slash command
# shows as its name. Piped, it prints the plain list.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic

  SUBJECT="$REPO_ROOT/.local/bin/sessions"
  export TZ=UTC
  T="$HOME/.claude/projects/-w/dddddddd-1.jsonl"
  E="$HOME/.claude/projects/-w/eeeeeeee-2.jsonl"
  mkdir -p "$(dirname "$T")" "$HOME/.agent/sessions/proj"
  {
    printf '%s\n' '{"type":"user","timestamp":"2026-11-20T09:12:00.100Z","message":{"role":"user","content":"set up aerc for my gmail"}}'
    printf '%s\n' '{"type":"assistant","timestamp":"2026-11-20T09:12:05.000Z","message":{"role":"assistant","content":[{"type":"text","text":"ok"}]}}'
    printf '%s\n' '{"type":"user","timestamp":"2026-11-20T09:12:06.000Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"x","content":"tool noise"}]}}'
    printf '%s\n' '{"type":"user","isMeta":true,"timestamp":"2026-11-20T09:13:00.000Z","message":{"role":"user","content":"meta noise"}}'
    printf '%s\n' '{"type":"user","timestamp":"2026-11-20T09:14:00.000Z","message":{"role":"user","content":"<local-command-stdout>wrapper noise</local-command-stdout>"}}'
    printf '%s\n' '{"type":"user","isSidechain":true,"timestamp":"2026-11-20T09:15:00.000Z","message":{"role":"user","content":"subagent noise"}}'
    printf '%s\n' '{"type":"user","timestamp":"2026-11-20T09:40:00.000Z","message":{"role":"user","content":[{"type":"text","text":"make the labels\nshow as folders"}]}}'
    printf '%s\n' '{"type":"user","timestamp":"2026-11-20T10:31:00.000Z","message":{"role":"user","content":"<command-name>/one-shot</command-name><command-args>ship it</command-args>"}}'
    printf '%s\n' '{"type":"user","timestamp":"2026-11-20T10:40:00.000Z","message":{"role":"user","content":"<command-message>fix-ci</command-message>\n<command-name>/fix-ci</command-name>\n<command-args>2861 <b>red</b>\nnow</command-args>"}}'
    printf '%s\n' '{"type":"user","isCompactSummary":true,"timestamp":"2026-11-20T10:45:00.000Z","message":{"role":"user","content":"This session is being continued, compact noise"}}'
    printf '%s\n' '{"type":"user","timestamp":"2026-11-20T10:46:00.000Z","message":{"role":"user","content":"<task-notification>agent noise</task-notification>"}}'
    printf '%s\n' '{"type":"user","timestamp":"2026-11-20T10:50:00.000Z","message":{"role":"user","content":"<div class=\"chip\"> why does this overflow"}}'
    printf '%s\n' '{"type":"user","timestamp":"2026-11-20T10:55:00.000Z","message":{"role":"user","content":"<bash-input>git status</bash-input>"}}'
  } > "$T"
  printf '%s\n' '{"type":"assistant","timestamp":"2026-11-20T09:00:00.000Z","message":{"role":"assistant","content":[{"type":"text","text":"hi"}]}}' > "$E"
  for s in "dddddddd-1:$T" "eeeeeeee-2:$E"; do
    jq -nc --arg id "${s%%:*}" --arg t "${s#*:}" '{session_id:$id, transcript:$t, project:"proj", updated:1}'
  done > "$HOME/.agent/sessions/proj/sessions.jsonl"
}

@test "lists only the prompts the human typed, oldest first" {
  run "$SUBJECT" prompts dddddddd
  assert_success
  assert_equal "${#lines[@]}" 6
  assert_line --index 0 '11-20 09:12  set up aerc for my gmail'
  assert_line --index 1 '11-20 09:40  make the labels show as folders'
  assert_line --index 2 '11-20 10:31  /one-shot ship it'
  assert_line --index 3 '11-20 10:40  /fix-ci 2861 <b>red</b> now'
  assert_line --index 4 '11-20 10:50  <div class="chip"> why does this overflow'
  assert_line --index 5 '11-20 10:55  ! git status'
  refute_output --partial 'noise'
}

@test "the time column is local time" {
  TZ=America/New_York run "$SUBJECT" prompts dddddddd
  assert_line --index 0 '11-20 04:12  set up aerc for my gmail'
}

@test "no id prints nothing and succeeds" {
  run "$SUBJECT" prompts
  assert_success
  assert_output ''
}

@test "a session with no typed prompt prints nothing and succeeds" {
  run "$SUBJECT" prompts eeeeeeee
  assert_success
  assert_output ''
}

@test "an unknown id fails" {
  run "$SUBJECT" prompts ffffffff
  assert_failure
}
