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

@test "a prompt typed into the session answers its asks; ending the session leaves the rest pending" {
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
  # The old SessionEnd call: it no longer closes anything or copies the question to a board.
  run bash "$SETTLE" stale <<<'{"session_id":"sid-2","reason":"prompt_input_exit"}'
  assert_success
  run "$AGENT_ASK" show "$b"
  assert_line 'status: pending'
  assert_not_called 'ptask'
}

@test "a task notification or a peer message is not the human answering" {
  local a
  a="$(CLAUDE_CODE_SESSION_ID=sid-1 "$AGENT_ASK" post "ship it?")"
  bash "$SETTLE" answered <<<'{"session_id":"sid-1","prompt":"<task-notification> <task-id>x</task-id>"}'
  bash "$SETTLE" answered <<<'{"session_id":"sid-1","prompt":"<cross-session-message from=\"uds:/run/x.sock\"> do not arm"}'
  run "$AGENT_ASK" show "$a"
  assert_line 'status: pending'
  bash "$SETTLE" answered <<<'{"session_id":"sid-1","prompt":"yes, arm it"}'
  run "$AGENT_ASK" show "$a"
  assert_line 'status: answered'
}

@test "a prompt a /loop or cron fired before is not the human answering, in either form" {
  local a
  a="$(CLAUDE_CODE_SESSION_ID=sid-1 "$AGENT_ASK" post "dispatch is starting nothing; lift the gate?")"
  # The transcript records the schedule's earlier fires: a slash command and a plain prompt.
  {
    echo '{"type":"user","turnOrigin":"human","message":{"role":"user","content":"yes, arm it"}}'
    echo '{"type":"user","turnOrigin":"scheduled","message":{"role":"user","content":"<command-message>fleet-lead</command-message>\n<command-name>/fleet-lead</command-name>\n<command-args>pass</command-args>"}}'
    echo '{"type":"user","turnOrigin":"scheduled","message":{"role":"user","content":[{"type":"text","text":"check the deploy"}]}}'
  } > "$SANDBOX/t.jsonl"
  settle() { printf '{"session_id":"sid-1","transcript_path":"%s","prompt":"%s"}' "$SANDBOX/t.jsonl" "$1" | bash "$SETTLE" answered; }
  settle '/fleet-lead pass'
  settle 'check the deploy '
  run "$AGENT_ASK" show "$a"
  assert_line 'status: pending'
  # Negative control: a prompt the human typed once before is still an answer.
  settle 'yes, arm it'
  run "$AGENT_ASK" show "$a"
  assert_line 'status: answered'
}

@test "an answer no live session takes and nothing resumes becomes one plain board row" {
  local a
  a="$(CLAUDE_CODE_SESSION_ID=sid-2 "$AGENT_ASK" post --project demo 'ship #it?')"
  run "$AGENT_ASK" answer "$a" now
  assert_success
  assert_called "ptask demo --agent add ship it? -> answered: now (ask $a)"
  [ "$(calls | grep -c 'ptask demo --agent add')" -eq 1 ]
  assert_not_called '#'
}

@test "an answer a live session takes or a resume consumes files no row, and neither does a cancel" {
  local live resumed dropped
  printf '{"session_id":"sid-1","pane":"lab/%%1","status":"idle"}\n' > "$NOTES_FIXTURE/agent-panel.list"
  live="$(CLAUDE_CODE_SESSION_ID=sid-1 "$AGENT_ASK" post --project demo 'one?')"
  resumed="$("$AGENT_ASK" post --project demo --resume '/captain resume' 'two?')"
  dropped="$("$AGENT_ASK" post --project demo 'three?')"
  "$AGENT_ASK" answer "$live" yes 2>/dev/null
  AGENT_ASK_NO_RESUME=1 "$AGENT_ASK" answer "$resumed" yes 2>/dev/null
  "$AGENT_ASK" cancel "$dropped" 'on the human sheet' 2>/dev/null
  assert_not_called 'ptask'
}

@test "a board that refuses the row does not fail the answer" {
  local a
  a="$("$AGENT_ASK" post --project demo 'ship it?')"
  printf '#!/bin/sh\nexit 1\n' > "$SANDBOX/bin/notes"
  run "$AGENT_ASK" answer "$a" yes
  assert_success
  run "$AGENT_ASK" show "$a"
  assert_line 'status: answered'
}

@test "the settle hook never fails its caller" {
  run bash "$SETTLE" answered <<<'not json'
  assert_success
  run bash "$SETTLE" bogus </dev/null
  assert_success
}
