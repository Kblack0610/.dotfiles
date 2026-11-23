#!/usr/bin/env bats
# stop-post.d/86-empty-wakes.sh: a session waking on empty Monitor expiries is told to stop
# re-arming. 2026-11-22 a coordinator re-armed a watch on an all-ticked ledger 58 times over 29h.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic
  CHECK="$REPO_ROOT/.claude/hooks/stop-post.d/86-empty-wakes.sh"
  export CLAUDE_CODE_SESSION_ATTENDED=1 FLEET_SHEPHERD_DIR="$SANDBOX/shep" EMPTY_WAKE_MAX=3 EMPTY_WAKE_STATE="$SANDBOX/ew"
  mkdir -p "$FLEET_SHEPHERD_DIR/labels" "$SANDBOX/bin"
  TX="$SANDBOX/t.jsonl"; : > "$TX"
  # The label and page commands record their calls; the label stub also edits the file as the real one does.
  cat > "$SANDBOX/bin/fleet-sessions" <<STUB
#!/bin/bash
echo "label \$*" >> "$SANDBOX/calls"
f="$FLEET_SHEPHERD_DIR/labels/\$2"; n="\${3#[+-]}"
grep -vxF "\$n" "\$f" 2>/dev/null > "\$f.t"; [ "\${3:0:1}" = + ] && echo "\$n" >> "\$f.t"; mv "\$f.t" "\$f"
STUB
  printf '#!/bin/sh\necho notify >> "%s/calls"\n' "$SANDBOX" > "$SANDBOX/bin/agent-notify"
  chmod +x "$SANDBOX/bin/"*
  export PATH="$SANDBOX/bin:$PATH"
}

user() { jq -cn --arg t "$1" '{type: "user", isSidechain: false, message: {role: "user", content: $t}}' >> "$TX"; }
expiry() { user $'<task-notification>\n<task-id>b1</task-id>\n<summary>Monitor event: "w"</summary>\n<event>[Monitor expired after 30m with no events delivered. Re-arm it if you still need the watch.]</event>\n</task-notification>'; }
result() { jq -cn '{type: "user", message: {content: [{type: "tool_result", content: "Monitor started (task b2)"}]}}' >> "$TX"; }
wake() { expiry; result; }
run_check() { run bash "$CHECK" <<<"$(jq -cn --arg t "$TX" '{session_id: "sid-1", transcript_path: $t, cwd: "/r/dotfiles", stop_hook_active: false}')"; }

@test "EMPTY_WAKE_MAX empty expiries since the human's prompt block once with the step and label the session spinning" {
  user "please watch the PR"; wake; wake; wake
  run_check
  assert_success
  [ "$(jq -r .decision <<<"$output")" = block ]
  [[ "$(jq -r .reason <<<"$output")" == "empty-wakes: this is wake 3 in a row"*"TaskStop"*"reopen-on-answer"*"background Bash"* ]]
  grep -qxF spinning "$FLEET_SHEPHERD_DIR/labels/sid-1"
  run grep -q notify "$SANDBOX/calls"
  assert_failure
}

@test "from twice the limit the block did not take: the human is paged once per run, and a new run pages again" {
  user "go"; for _ in 1 2 3 4 5; do wake; done
  run_check
  [ "$(jq -r .decision <<<"$output")" = block ]
  run grep -c notify "$SANDBOX/calls"; assert_output 0
  wake; run_check
  run grep -c notify "$SANDBOX/calls"; assert_output 1
  wake; run_check; wake; run_check
  run grep -c notify "$SANDBOX/calls"; assert_output 1
  user "keep going"; run_check
  for _ in 1 2 3 4 5 6; do wake; done; run_check
  run grep -c notify "$SANDBOX/calls"; assert_output 2
}

@test "a compaction, a skill load and a Stop-hook note neither count nor reset the run" {
  user "go"; wake; user "This session is being continued from a previous conversation that ran out of context."
  user "Base directory for this skill: /x"; wake; user "Stop hook feedback: x"; wake
  run_check
  [ "$(jq -r .decision <<<"$output")" = block ]
}

@test "negative control: under the limit, a human prompt or a background event with content resets, and spinning is removed" {
  user "go"; wake; wake
  run_check; assert_output ''
  wake; user "ok stop"; wake
  printf 'spinning\n' > "$FLEET_SHEPHERD_DIR/labels/sid-1"
  run_check; assert_output ''
  run grep -qxF spinning "$FLEET_SHEPHERD_DIR/labels/sid-1"
  assert_failure
  wake; wake; user $'<task-notification>\n<task-id>b3</task-id>\n<status>completed</status>\n</task-notification>'; wake
  run_check; assert_output ''
}

@test "negative control: a coordinator, the loop guard and a headless run pass" {
  user "go"; wake; wake; wake
  printf 'manual\ncoordinator\n' > "$FLEET_SHEPHERD_DIR/labels/sid-1"
  run_check; assert_output ''
  rm "$FLEET_SHEPHERD_DIR/labels/sid-1"
  run bash "$CHECK" <<<"$(jq -cn --arg t "$TX" '{session_id: "sid-1", transcript_path: $t, stop_hook_active: true}')"
  assert_output ''
  CLAUDE_CODE_SESSION_ATTENDED=0 run_check; assert_output ''
}
