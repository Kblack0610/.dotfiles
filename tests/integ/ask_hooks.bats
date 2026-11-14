#!/usr/bin/env bats
# The hooks that keep the ask file the one record of a session waiting on the human:
#   stop-post.d/88-ask-filed.sh   blocks a turn that ends asking the human with nothing filed
#   shared-hooks/ask-settle.sh    closes a session's asks when the human answers or it ends
# 2026-10-28: agent-27 waited on a `! ssh` step asked only in the chat, and agent-2's ask stayed
# pending after its session was gone.

setup() {
  bats_require_minimum_version 1.5.0
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
  [[ "$(jq -r .reason <<<"$output")" == "ask-filed: "* ]]
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

@test "an answer no live session takes and nothing resumes becomes one typed board row" {
  local a
  a="$(CLAUDE_CODE_SESSION_ID=sid-2 "$AGENT_ASK" post --project demo 'ship #it?')"
  run "$AGENT_ASK" answer "$a" now
  assert_success
  assert_not_called 'ptask demo'
  "$AGENT_ASK" deliver --all 2>/dev/null
  assert_called "ptask demo --agent add chore(ask): ship it? -> answered: now (ask $a) #size/s"
  [ "$(calls | grep -c 'ptask demo --agent add')" -eq 1 ]
  assert_not_called '#it'
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
  "$AGENT_ASK" deliver --all 2>/dev/null
  assert_not_called 'ptask'
}

@test "an answer to a live session is typed into its pane through agent-panel send" {
  local a
  printf '{"session_id":"sid-1","pane":"lab/%%1","status":"idle"}\n' > "$NOTES_FIXTURE/agent-panel.list"
  a="$(CLAUDE_CODE_SESSION_ID=sid-1 "$AGENT_ASK" post --project demo --session dotfiles 'one?')"
  "$AGENT_ASK" answer "$a" yes 2>/dev/null
  # The sandbox sets AGENT_ASK_NO_RESUME, which also skips typing into the session.
  assert_not_called "agent-panel send"
  AGENT_ASK_NO_RESUME='' run "$AGENT_ASK" deliver "$a"
  assert_success
  assert_called "agent-panel send --pane lab/%1 Answer to ask $a: yes"
  refute_output --partial 'did not submit'
  run "$AGENT_ASK" show "$a"
  assert_line 'delivery: done'; assert_line 'delivery_note: typed into dotfiles'
}

@test "an answer the pane did not take still records, and says where the text is" {
  local a
  printf '{"session_id":"sid-1","pane":"lab/%%1","status":"idle"}\n' > "$NOTES_FIXTURE/agent-panel.list"
  : > "$NOTES_FIXTURE/agent-panel.unsent"
  a="$(CLAUDE_CODE_SESSION_ID=sid-1 "$AGENT_ASK" post --project demo --session dotfiles 'one?')"
  "$AGENT_ASK" answer "$a" yes 2>/dev/null
  # The sandbox sets AGENT_ASK_NO_RESUME, which also skips typing into the session.
  AGENT_ASK_NO_RESUME='' run "$AGENT_ASK" deliver "$a"
  assert_success
  assert_output --partial "did not submit in dotfiles"
  run "$AGENT_ASK" show "$a"
  assert_line 'status: answered'; assert_line 'delivery: failed'
  assert_line "delivery_note: it did not submit in dotfiles; the answer is in that session's input box"
}

# -- delivery: the answer is recorded at once and delivered in the background --

delivery() { sed -n 's/^delivery: //p' "$HOME/.agent/asks/demo/$1.md"; }

@test "answer records and queues the delivery, rewrites its trigger, and delivers nothing itself" {
  local a; a="$("$AGENT_ASK" post --project demo 'ship it?')"
  rm -f "$HOME/.agent/asks/.deliver"
  "$AGENT_ASK" answer "$a" now 2>/dev/null
  assert [ -e "$HOME/.agent/asks/.deliver" ]
  assert_equal "$(delivery "$a")" queued
  assert_not_called 'ptask'
  run "$AGENT_ASK" trace "$a"
  assert_output --partial 'queued      waiting for agent-ask deliver'
  "$AGENT_ASK" deliver --all 2>/dev/null
  assert_equal "$(delivery "$a")" done
  run "$AGENT_ASK" trace "$a"
  assert_output --partial 'delivered   a board row'
}

@test "deliver runs an answer once: a second run, or one on an ask answered before deliveries, does nothing" {
  local a old; a="$("$AGENT_ASK" post --project demo 'ship it?')"
  old="$("$AGENT_ASK" post --project demo 'from before?')"
  "$AGENT_ASK" answer "$a" now 2>/dev/null
  "$AGENT_ASK" answer "$old" yes 2>/dev/null
  sed -i '/^delivery/d' "$HOME/.agent/asks/demo/$old.md"
  "$AGENT_ASK" deliver --all 2>/dev/null
  "$AGENT_ASK" deliver --all 2>/dev/null
  run --separate-stderr "$AGENT_ASK" deliver "$a"
  assert_success; [[ "$stderr" == *"$a has no delivery waiting"* ]]
  [ "$(calls | grep -c 'ptask demo --agent add')" -eq 1 ]
  assert_not_called "(ask $old)"
}

@test "deliver leaves a fresh claim to its run, takes a stale one, and keeps an answer queued during its run" {
  local a f; a="$("$AGENT_ASK" post --project demo 'ship it?')"; f="$HOME/.agent/asks/demo/$a.md"
  "$AGENT_ASK" answer "$a" now 2>/dev/null
  sed -i 's/^delivery: queued/delivery: delivering/' "$f"
  "$AGENT_ASK" deliver --all 2>/dev/null
  assert_not_called 'ptask'
  AGENT_ASK_DELIVERY_STALE=0 "$AGENT_ASK" deliver --all 2>/dev/null
  assert_equal "$(delivery "$a")" done
  [ "$(calls | grep -c 'ptask demo --agent add')" -eq 1 ]
  # An answer queued while a run delivers stays queued for the next pass, which --all runs.
  local real; real="$(command -v notes)"
  printf '#!/usr/bin/env bash\n[ -e %q ] || { : > %q; sed -i "s/^delivery: delivering/delivery: queued/" %q; }\nexec %q "$@"\n' \
    "$SANDBOX/once" "$SANDBOX/once" "$f" "$real" > "$SANDBOX/notes"; chmod +x "$SANDBOX/notes"
  sed -i 's/^delivery: done/delivery: queued/' "$f"
  PATH="$SANDBOX:$PATH" "$AGENT_ASK" deliver --all 2>/dev/null
  assert_equal "$(delivery "$a")" done
  [ "$(calls | grep -c 'ptask demo --agent add')" -eq 3 ]
}

@test "a failed delivery stays on the record until the human reads it" {
  local a
  printf '{"session_id":"sid-1","pane":"lab/%%1","status":"waiting"}\n' > "$NOTES_FIXTURE/agent-panel.list"
  a="$(CLAUDE_CODE_SESSION_ID=sid-1 "$AGENT_ASK" post --project demo --session dotfiles 'one?')"
  "$AGENT_ASK" answer "$a" yes 2>/dev/null
  AGENT_ASK_NO_RESUME='' "$AGENT_ASK" deliver --all 2>/dev/null
  assert_not_called 'agent-panel send'
  assert_equal "$(delivery "$a")" failed
  run "$AGENT_ASK" show "$a"; assert_line 'delivery_note: its session is in a dialog, so the answer was not typed into it'
  "$AGENT_ASK" delivery-seen "$a"
  assert_equal "$(delivery "$a")" seen
  run "$AGENT_ASK" trace "$a"; assert_output --partial 'the human read it'
  # negative control: a delivered ask is not marked seen
  local b; b="$("$AGENT_ASK" post --project demo 'two?')"
  "$AGENT_ASK" answer "$b" yes 2>/dev/null; "$AGENT_ASK" deliver --all 2>/dev/null
  "$AGENT_ASK" delivery-seen "$b"
  assert_equal "$(delivery "$b")" done
}

@test "a human answer beside a judge answer still queued delivers the judge's first, then the human's" {
  local a; a="$("$AGENT_ASK" post --project demo --options 'fix=fix it|wait=wait' 'fix it?')"
  "$AGENT_ASK" answer --by judge "$a" fix 2>/dev/null
  "$AGENT_ASK" answer "$a" wait 2>/dev/null
  assert_called "fix it? -> answered: fix (the judge; to override"
  assert_not_called "fix it? -> answered: wait"
  run "$AGENT_ASK" show "$a"
  assert_line 'answer: fix'; assert_line 'delivery_answer: wait'; assert_line 'delivery: queued'
  "$AGENT_ASK" deliver --all 2>/dev/null
  assert_called "fix it? -> answered: wait (ask $a)"
  assert_equal "$(delivery "$a")" done
  # The human's text is spent once it went, and the note names only the place it went.
  run "$AGENT_ASK" show "$a"
  assert_line 'delivery_answer: '; assert_line 'delivery_note: a board row: no live session, resume or held item takes it'
}

@test "an answer typed in its own session queues no delivery" {
  local a; a="$(CLAUDE_CODE_SESSION_ID=sid-1 "$AGENT_ASK" post --project demo --options 'yes=do it|no=leave it' 'arm it?')"
  printf '{"session_id":"sid-1","transcript_path":"%s","prompt":"yes"}' "$SANDBOX/t.jsonl" | bash "$SETTLE" answered
  run "$AGENT_ASK" show "$a"; assert_line 'status: answered'; refute_line --partial 'delivery'
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
