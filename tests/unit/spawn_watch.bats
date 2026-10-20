#!/usr/bin/env bats
# spawn-watch.sh - the per-session fan-out alert on PreToolUse(Agent|Task|Workflow).
#
# The contract that matters is the one the user asked for: it ALERTS and never STOPS.
# A hook that exits 2 or prints a deny blocks the tool call, so every test also asserts
# exit 0 and empty stdout - including when the hook's own dependencies are broken.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic

  HOOK="$REPO_ROOT/.claude/hooks/spawn-watch.sh"
  export SPAWN_WATCH_DIR="$SANDBOX/spawns" SPAWN_ALERT_AT=3
  NOTIFY_LOG="$SANDBOX/notify.log"
  # agent-notify stub: record each call so the tests can count pings.
  printf '#!/usr/bin/env bash\necho "$*" >> "%s"\n' "$NOTIFY_LOG" > "$SANDBOX/bin/agent-notify"
  chmod +x "$SANDBOX/bin/agent-notify"
}

call() {
  printf '{"session_id":"%s","cwd":"/w/demo","tool_name":"Agent"}' "${1:-s1}" | bash "$HOOK"
}
pings() { [ -f "$NOTIFY_LOG" ] && grep -c . "$NOTIFY_LOG" || echo 0; }

@test "below the threshold: allowed, silent, no ping" {
  run call; assert_success; assert_output ''
  run call; assert_success; assert_output ''
  assert_equal "$(pings)" 0
}

@test "pings once at 1x, 2x and 4x the threshold and never blocks" {
  for i in $(seq 1 13); do
    run call; assert_success; assert_output ''
  done
  assert_equal "$(pings)" 3
  grep -q 'made 3 Agent calls' "$NOTIFY_LOG"
  grep -q 'made 6 Agent calls' "$NOTIFY_LOG"
  grep -q 'made 12 Agent calls' "$NOTIFY_LOG"
}

@test "sessions are counted separately" {
  for i in 1 2; do call s1; call s2; done
  assert_equal "$(pings)" 0
  call s1
  assert_equal "$(pings)" 1
}

@test "concurrent calls count exactly" {
  for i in $(seq 1 20); do call s1 & done; wait
  assert_equal "$(cat "$SPAWN_WATCH_DIR/s1")" 20
}

@test "a failing notifier does not block" {
  printf '#!/usr/bin/env bash\nexit 7\n' > "$SANDBOX/bin/agent-notify"
  for i in 1 2 3; do run call; assert_success; assert_output ''; done
}

@test "an unwritable count dir does not block" {
  export SPAWN_WATCH_DIR=/proc/nope/spawns
  run call; assert_success; assert_output ''
}

@test "garbage stdin does not block" {
  run bash -c "echo 'not json' | bash '$HOOK'"
  assert_success; assert_output ''
}
