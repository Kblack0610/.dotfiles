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
  } > "$T"
  printf '%s\n' '{"type":"assistant","timestamp":"2026-11-20T09:00:00.000Z","message":{"role":"assistant","content":[{"type":"text","text":"hi"}]}}' > "$E"
  for s in "dddddddd-1:$T" "eeeeeeee-2:$E"; do
    jq -nc --arg id "${s%%:*}" --arg t "${s#*:}" '{session_id:$id, transcript:$t, project:"proj", updated:1}'
  done > "$HOME/.agent/sessions/proj/sessions.jsonl"
}

@test "lists only the prompts the human typed, oldest first" {
  run "$SUBJECT" prompts dddddddd
  assert_success
  assert_equal "${#lines[@]}" 3
  assert_line --index 0 '11-20 09:12  set up aerc for my gmail'
  assert_line --index 1 '11-20 09:40  make the labels show as folders'
  assert_line --index 2 '11-20 10:31  /one-shot ship it'
  refute_output --partial 'noise'
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
