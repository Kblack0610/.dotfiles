#!/usr/bin/env bats
# The hooks that keep the ask file the one record of a session waiting on the human:
#   stop-post.d/88-ask-filed.sh   blocks a turn that ends asking the human with nothing filed
#   shared-hooks/ask-settle.sh    closes a session's asks when the human answers or it ends
# 2026-10-28: agent-27 waited on a `! ssh` step asked only in the chat, and agent-2's ask stayed
# pending after its session was gone.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic
  CHECK="$REPO_ROOT/.claude/hooks/stop-post.d/88-ask-filed.sh"
  SETTLE="$REPO_ROOT/.config/shared-hooks/ask-settle.sh"
  : > "$SANDBOX/t.jsonl"
}

stop_payload() { printf '{"session_id":"sid-1","transcript_path":"%s","stop_hook_active":%s}' "$SANDBOX/t.jsonl" "${1:-false}"; }

@test "a turn that asks the human with no ask filed is blocked with the instruction" {
  : > "$NOTES_FIXTURE/agent-panel.asks"
  run env CLAUDE_CODE_SESSION_ATTENDED=1 bash "$CHECK" <<<"$(stop_payload)"
  assert_success
  [ "$(jq -r .decision <<<"$output")" = block ]
  [[ "$(jq -r .reason <<<"$output")" == *"agent-ask post"* ]]
}

@test "the check passes once the session owns a pending ask, and never loops" {
  : > "$NOTES_FIXTURE/agent-panel.asks"
  CLAUDE_CODE_SESSION_ID=sid-1 "$AGENT_ASK" post --project demo 'merge it?' >/dev/null
  run env CLAUDE_CODE_SESSION_ATTENDED=1 bash "$CHECK" <<<"$(stop_payload)"
  assert_success
  assert_output ''
}

@test "the check stays quiet when nothing asks, headless, on re-entry, or skipped" {
  run env CLAUDE_CODE_SESSION_ATTENDED=1 bash "$CHECK" <<<"$(stop_payload)"
  assert_output ''
  : > "$NOTES_FIXTURE/agent-panel.asks"
  run bash "$CHECK" <<<"$(stop_payload)"
  assert_output ''
  run env CLAUDE_CODE_SESSION_ATTENDED=1 bash "$CHECK" <<<"$(stop_payload true)"
  assert_output ''
  run env CLAUDE_CODE_SESSION_ATTENDED=1 CLAUDE_SKIP_ASK_GATE=1 bash "$CHECK" <<<"$(stop_payload)"
  assert_output ''
}

@test "another session's pending ask does not satisfy the check" {
  : > "$NOTES_FIXTURE/agent-panel.asks"
  CLAUDE_CODE_SESSION_ID=sid-9 "$AGENT_ASK" post --project demo 'merge it?' >/dev/null
  run env CLAUDE_CODE_SESSION_ATTENDED=1 bash "$CHECK" <<<"$(stop_payload)"
  [ "$(jq -r .decision <<<"$output")" = block ]
}

@test "a prompt typed into the session answers its asks; ending the session stales them" {
  local a b
  a="$(CLAUDE_CODE_SESSION_ID=sid-1 "$AGENT_ASK" post --project demo 'merge it?')"
  b="$(CLAUDE_CODE_SESSION_ID=sid-2 "$AGENT_ASK" post --project demo 'ship it?')"
  run bash "$SETTLE" answered <<<'{"session_id":"sid-1","prompt":"merge it"}'
  assert_success
  run "$AGENT_ASK" show "$a"
  assert_line 'status: answered'
  assert_line 'answer: in session: merge it'
  run "$AGENT_ASK" show "$b"
  assert_line 'status: pending'
  run bash "$SETTLE" stale <<<'{"session_id":"sid-2","reason":"prompt_input_exit"}'
  assert_success
  run "$AGENT_ASK" show "$b"
  assert_line 'status: stale'
  assert_line 'closed_reason: session ended (prompt_input_exit)'
}

@test "the settle hook never fails its caller" {
  run bash "$SETTLE" answered <<<'not json'
  assert_success
  run bash "$SETTLE" bogus </dev/null
  assert_success
}
