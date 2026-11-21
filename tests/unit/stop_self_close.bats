#!/usr/bin/env bats
# stop-post.d/94-self-close.sh: a dispatched session whose queue item is closed and whose close
# verdict is now is told to run /wind-down auto in that turn, rather than wait an hour for the
# shepherd to type it into a cold context. Every other session passes untouched.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic
  CHECK="$REPO_ROOT/.claude/hooks/stop-post.d/94-self-close.sh"
  export CLAUDE_CODE_SESSION_ATTENDED=1 AGENT_QUEUE_ITEM=item-1 AGENT_SPIN_DOWN_DIR="$SANDBOX/spin" XDG_STATE_HOME="$SANDBOX/state" CALLS="$SANDBOX/calls"
  mkdir -p "$AGENT_SPIN_DOWN_DIR" "$SANDBOX/bin"
  : > "$CALLS"
  # agent-queue show <slug> --json: the item's state and sessions, from $ITEM_STATE and $ITEM_SESSIONS.
  cat > "$SANDBOX/bin/agent-queue" <<'EOF'
#!/bin/bash
echo "agent-queue $*" >> "$CALLS"
[ "$1 $2" = "show item-1" ] || exit 1
jq -n --arg st "$ITEM_STATE" --arg s "$ITEM_SESSIONS" '{slug: "item-1", state: $st, sessions: $s}'
EOF
  # fleet-sessions close --self <sid>: prints $VERDICT, exit 0 only on now.
  cat > "$SANDBOX/bin/fleet-sessions" <<'EOF'
#!/bin/bash
echo "fleet-sessions $*" >> "$CALLS"
printf '%s\nblocker: none\n' "$VERDICT"
case "$VERDICT" in now*) exit 0 ;; *) exit 1 ;; esac
EOF
  chmod +x "$SANDBOX/bin/agent-queue" "$SANDBOX/bin/fleet-sessions"
  export AGENT_QUEUE_BIN="$SANDBOX/bin/agent-queue" FLEET_SESSIONS_BIN="$SANDBOX/bin/fleet-sessions"
  export ITEM_STATE=done ITEM_SESSIONS="other-sid sid-1" VERDICT="now: DONE PR #12 merged, tree clean"
}

stop_payload() { printf '{"session_id":"%s","stop_hook_active":%s}' "${1:-sid-1}" "${2:-false}"; }

@test "a dispatched session with its item closed and a now verdict is blocked with /wind-down auto" {
  run bash "$CHECK" <<<"$(stop_payload)"
  assert_success
  [ "$(jq -r .decision <<<"$output")" = block ]
  [[ "$(jq -r .reason <<<"$output")" == "self-close: "*"item-1"*"now: DONE PR #12 merged, tree clean"*"/wind-down auto"* ]]
  grep -qxF "fleet-sessions close --self sid-1" "$CALLS"
}

@test "a session the human opened (no queue item) passes and reads nothing" {
  unset AGENT_QUEUE_ITEM
  run bash "$CHECK" <<<"$(stop_payload)"
  assert_success
  assert_output ''
  [ ! -s "$CALLS" ]
}

@test "an item still running, or in review, passes without the slow close check" {
  ITEM_STATE=running run bash "$CHECK" <<<"$(stop_payload)"
  assert_success
  assert_output ''
  ITEM_STATE=review run bash "$CHECK" <<<"$(stop_payload)"
  assert_success
  assert_output ''
  ! grep -q fleet-sessions "$CALLS"
}

@test "it blocks once per session: a resumed finished session is not told again" {
  run bash "$CHECK" <<<"$(stop_payload)"
  [ "$(jq -r .decision <<<"$output")" = block ]
  : > "$CALLS"
  run bash "$CHECK" <<<"$(stop_payload)"
  assert_success
  assert_output ''
  [ ! -s "$CALLS" ]
}

@test "an unattended (headless) run passes and reads nothing" {
  CLAUDE_CODE_SESSION_ATTENDED=0 run bash "$CHECK" <<<"$(stop_payload)"
  assert_success
  assert_output ''
  [ ! -s "$CALLS" ]
}

@test "an item that does not name this session (an inherited env) passes without the close check" {
  ITEM_SESSIONS="other-sid" run bash "$CHECK" <<<"$(stop_payload)"
  assert_success
  assert_output ''
  ! grep -q fleet-sessions "$CALLS"
}

@test "a keep or after verdict passes: the shepherd stays the backstop" {
  VERDICT="keep: unlanded work: PR #12 open" run bash "$CHECK" <<<"$(stop_payload)"
  assert_success
  assert_output ''
  VERDICT="after: close its item" run bash "$CHECK" <<<"$(stop_payload)"
  assert_success
  assert_output ''
}

@test "a Stop already blocked this turn, or one with wind-down armed, passes and reads nothing" {
  run bash "$CHECK" <<<"$(stop_payload sid-1 true)"
  assert_success
  assert_output ''
  : > "$AGENT_SPIN_DOWN_DIR/sid-1.request"
  run bash "$CHECK" <<<"$(stop_payload)"
  assert_success
  assert_output ''
  [ ! -s "$CALLS" ]
}

@test "an unknown item or a broken queue passes" {
  AGENT_QUEUE_ITEM=gone run bash "$CHECK" <<<"$(stop_payload)"
  assert_success
  assert_output ''
}
