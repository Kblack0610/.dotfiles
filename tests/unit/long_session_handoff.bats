#!/usr/bin/env bats
# .claude/hooks/long-session-handoff.sh: a dispatched session on a pilot repo that passes
# AGENT_HANDOFF_TURNS responses or a compaction is told once to hand its item to a fresh session.
# Every other session (a hand one, a subagent's call, another repo, a short run) is left alone.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic
  HOOK="$REPO_ROOT/.claude/hooks/long-session-handoff.sh"
  export AGENT_QUEUE_ITEM=item-1 AGENT_HANDOFF_STATE="$SANDBOX/state" AGENT_HANDOFF_EVERY=1 AGENT_HANDOFF_TURNS=3 CALLS="$SANDBOX/calls"
  : > "$CALLS"
  cat > "$SANDBOX/bin/agent-queue" <<'EOF'
#!/bin/bash
echo "agent-queue $*" >> "$CALLS"
[ "$1 $2" = "show item-1" ] || exit 1
jq -n --arg st "${ITEM_STATE:-running}" --arg s "${ITEM_SESSIONS:-sid-1}" --arg h "${ITEM_HANDOFFS:-}" \
  '{slug: "item-1", state: $st, sessions: $s} + (if $h != "" then {handoffs: $h} else {} end)'
EOF
  chmod +x "$SANDBOX/bin/agent-queue"
  export AGENT_QUEUE_BIN="$SANDBOX/bin/agent-queue"
  # A worktree of the pilot repo: its common dir is unity-core-playground/.git.
  PILOT="$SANDBOX/repos/unity-core-playground"
  git init -q "$PILOT"
  git -C "$PILOT" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
  git -C "$PILOT" worktree add -q "$SANDBOX/wt/unity-core-playground-fix" -b fix 2>/dev/null
  WT="$SANDBOX/wt/unity-core-playground-fix"
  OTHER="$SANDBOX/repos/game"
  git init -q "$OTHER"
  T="$SANDBOX/transcript.jsonl"
}

# transcript <responses> [compactions]: that many main-thread responses (each split over two lines,
# as Claude writes them), a subagent's sidechain response and a synthetic one that never count.
transcript() {
  local i
  : > "$T"
  for ((i = 1; i <= $1; i++)); do
    printf '{"type":"assistant","message":{"id":"msg_%s","model":"claude-opus-5-5","usage":{"input_tokens":1}}}\n' "$i" "$i" >> "$T"
  done
  printf '{"type":"assistant","isSidechain":true,"message":{"id":"msg_side","model":"m","usage":{"input_tokens":1}}}\n' >> "$T"
  printf '{"type":"assistant","message":{"id":"msg_syn","model":"<synthetic>","usage":{"input_tokens":0}}}\n' >> "$T"
  printf 'not json, a line cut mid-write\n' >> "$T"
  for ((i = 1; i <= ${2:-0}; i++)); do printf '{"type":"system","subtype":"compact_boundary"}\n' >> "$T"; done
}

payload() { jq -nc --arg c "${1:-$WT}" --arg t "$T" --arg a "${2:-}" '{session_id: "sid-1", transcript_path: $t, cwd: $c} + (if $a != "" then {agent_id: $a} else {} end)'; }

@test "a dispatched session on the pilot repo past the turn mark is told once to hand off" {
  transcript 3
  run bash "$HOOK" <<<"$(payload)"
  assert_success
  ctx=$(jq -r .hookSpecificOutput.additionalContext <<<"$output")
  [ "$(jq -r .hookSpecificOutput.hookEventName <<<"$output")" = PostToolUse ]
  [[ "$ctx" == *"has run 3 responses"* ]]
  [[ "$ctx" == *"agent-queue handoff item-1 --note"* ]]
  [[ "$ctx" == *"/wind-down"* ]]
  # Once: the next call says nothing and asks the queue nothing.
  : > "$CALLS"
  run bash "$HOOK" <<<"$(payload)"
  assert_success
  assert_output ''
  [ ! -s "$CALLS" ]
}

@test "a compaction before the turn mark tells it too" {
  transcript 1 1
  run bash "$HOOK" <<<"$(payload)"
  assert_success
  [[ "$(jq -r .hookSpecificOutput.additionalContext <<<"$output")" == *"has run 1 responses and 1 compaction."* ]]
}

@test "under the mark (negative control): nothing, and it is asked again later" {
  transcript 2
  run bash "$HOOK" <<<"$(payload)"
  assert_success
  assert_output ''
  transcript 3
  run bash "$HOOK" <<<"$(payload)"
  [[ "$output" == *additionalContext* ]]
}

@test "the transcript is counted only every AGENT_HANDOFF_EVERY calls" {
  transcript 5
  export AGENT_HANDOFF_EVERY=3
  run bash "$HOOK" <<<"$(payload)"; assert_output ''
  run bash "$HOOK" <<<"$(payload)"; assert_output ''
  run bash "$HOOK" <<<"$(payload)"
  [[ "$output" == *additionalContext* ]]
}

@test "a hand session, a subagent's call and another repo are never told" {
  transcript 9
  run env -u AGENT_QUEUE_ITEM bash "$HOOK" <<<"$(payload)"
  assert_output ''
  run bash "$HOOK" <<<"$(payload "$WT" agent-7)"
  assert_output ''
  run bash "$HOOK" <<<"$(payload "$OTHER")"
  assert_output ''
  [ ! -s "$CALLS" ]
  # Another repo is settled for the session: it is not looked at again.
  [ -e "$AGENT_HANDOFF_STATE/sid-1.told" ]
}

@test "AGENT_HANDOFF_REPOS names the pilot repos" {
  transcript 9
  AGENT_HANDOFF_REPOS="game" run bash "$HOOK" <<<"$(payload "$OTHER")"
  [[ "$output" == *"(game pilot)"* ]]
}

@test "an item that is not running, names another session, or is out of handoffs is not told" {
  transcript 9
  ITEM_STATE=review run bash "$HOOK" <<<"$(payload)"
  assert_output ''
  rm -f "$AGENT_HANDOFF_STATE"/*
  ITEM_SESSIONS="sid-other" run bash "$HOOK" <<<"$(payload)"
  assert_output ''
  rm -f "$AGENT_HANDOFF_STATE"/*
  ITEM_HANDOFFS=2 run bash "$HOOK" <<<"$(payload)"
  assert_output ''
  rm -f "$AGENT_HANDOFF_STATE"/*
  ITEM_HANDOFFS=1 run bash "$HOOK" <<<"$(payload)"
  [[ "$output" == *additionalContext* ]]
}
