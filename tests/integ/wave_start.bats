#!/usr/bin/env bats
# wave-start: does a pass report what actually happened?
#
# The founding incident: `/wave` was invoked as a slash command that did not
# resolve, so `claude -p` printed "Unknown command: /wave" and exited 1 after one
# second. The human pressed W, was notified "start finished - === done <ts>", and
# nothing appeared in any panel. The wave had never run.
#
# Two defects made that invisible, and these tests pin both:
#   1. the exit status was discarded (`... 2>&1 || true` inside a brace group)
#   2. the "diagnostic" was the last non-empty log line, which is always our own
#      `=== done` boilerplate - so every pass reported the same thing
#
# A `start` that writes no blackboard is also a failure even when it exits 0:
# writing one is the whole job.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic

  WAVE_START="$REPO_ROOT/.local/bin/wave-start"
  export WAVE_START
  export AGENTCTL_STATE_DIR="$SANDBOX/state"
  export NOTIFY_LOG="$SANDBOX/notify.log"
  mkdir -p "$AGENTCTL_STATE_DIR" "$HOME/.agent/plans/demoapp"
  : > "$NOTIFY_LOG"

  cat > "$SANDBOX/bin/agent-notify" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$NOTIFY_LOG"
EOF
  chmod +x "$SANDBOX/bin/agent-notify"

  # captain-watchdog must never arm during a test
  cat > "$SANDBOX/bin/captain-watchdog" <<'EOF'
#!/usr/bin/env bash
echo "watchdog $*" >> "$NOTIFY_LOG.watchdog"
EOF
  chmod +x "$SANDBOX/bin/captain-watchdog"
}

# stub_claude <exit-code> <output> [write-board]
stub_claude() {
  local rc="$1" out="$2" board="${3:-}"
  {
    echo '#!/usr/bin/env bash'
    printf 'echo %q\n' "$out"
    [ -n "$board" ] && printf 'touch %q\n' "$HOME/.agent/plans/demoapp/sprint-2026-01-01.md"
    echo "exit $rc"
  } > "$SANDBOX/bin/claude"
  chmod +x "$SANDBOX/bin/claude"
}

@test "a pass whose claude exits non-zero is reported as FAILED" {
  stub_claude 1 'Unknown command: /wave. Did you mean /name?'
  run "$WAVE_START" demoapp --now
  assert_failure
  assert_output --partial 'FAILED (exit 1)'
}

@test "the failure carries the real error, not the === done boilerplate" {
  # Assert on the VERDICT line, not the whole run: --now also tails the log, so
  # `=== done` appears there legitimately. What must never happen is the verdict
  # itself being that boilerplate, which is what used to be reported.
  stub_claude 1 'Unknown command: /wave. Did you mean /name?'
  run "$WAVE_START" demoapp --now
  local verdict
  verdict="$(printf '%s\n' "$output" | grep '^wave-start: ')"
  assert_equal "$verdict" 'wave-start: demoapp start FAILED (exit 1) — Unknown command: /wave. Did you mean /name?'
}

@test "the notification says FAILED rather than finished" {
  stub_claude 1 'Unknown command: /wave. Did you mean /name?'
  run "$WAVE_START" demoapp --now
  run cat "$NOTIFY_LOG"
  assert_output --partial 'FAILED'
  assert_output --partial 'Unknown command: /wave'
}

@test "a start that exits 0 but writes no blackboard is still FAILED" {
  # The quiet one: the pass 'succeeded' and produced nothing, which is how a wave
  # can look fine while no panel has anything to show.
  stub_claude 0 'I did nothing useful'
  run "$WAVE_START" demoapp --now
  assert_failure
  assert_output --partial 'FAILED (no blackboard written)'
}

@test "a pre-existing blackboard cannot vouch for a pass that wrote nothing" {
  # Backdated well before the pass: if the check were merely "does a board exist",
  # last week's board would make every future failure look like a success.
  touch -d '2020-01-01' "$HOME/.agent/plans/demoapp/sprint-2020-01-01.md"
  stub_claude 0 'still did nothing'
  run "$WAVE_START" demoapp --now
  assert_failure
  assert_output --partial 'no blackboard written'
}

@test "a pass that writes a blackboard succeeds and reports what it did" {
  stub_claude 0 'wave scoped 3 tickets, PR #99 opened' board
  run "$WAVE_START" demoapp --now
  assert_success
  run cat "$NOTIFY_LOG"
  assert_output --partial 'start ok'
  assert_output --partial 'wave scoped 3 tickets'
  refute_output --partial 'FAILED'
}

@test "the overseer is armed only when the pass actually produced a board" {
  stub_claude 1 'boom'
  run "$WAVE_START" demoapp --now
  refute [ -f "$NOTIFY_LOG.watchdog" ]

  stub_claude 0 'ok' board
  run "$WAVE_START" demoapp --now
  assert [ -f "$NOTIFY_LOG.watchdog" ]
}

# --- the lock: one wave per app at a time -------------------------------------------
#
# A wave scope-out takes minutes and the keypress that starts it returns instantly, so
# it looks like nothing happened. Pressing W again re-scopes the SAME `#ai` items, and
# both passes then file their own tickets, cut their own branches and open their own
# PRs. That is not hypothetical: three concurrent waves on one app came from# three presses.
#
# The lock has to fail in both directions to be worth having. It must hold while a pass
# is genuinely running, AND it must get out of the way when the holder is gone - a stale
# file from a killed run that locks an app out forever is the same outage inverted, and
# it is the failure mode nobody notices until they need the wave.

LOCK_FILE() { printf '%s' "$AGENTCTL_STATE_DIR/wave/demoapp.pid"; }
PASS_LOG()  { printf '%s' "$AGENTCTL_STATE_DIR/wave/demoapp.log"; }

# plant_lock <pid> — a lock file for demoapp holding <pid>, as run_pass would write it
plant_lock() {
  mkdir -p "$AGENTCTL_STATE_DIR/wave"
  printf '%s\n' "$1" > "$(LOCK_FILE)"
}

# live_holder — a real, running process, recorded so teardown always reaps it
live_holder() {
  sleep 60 >/dev/null 2>&1 &
  HOLDER=$!
  printf '%s' "$HOLDER"
}

# dead_pid — a pid number that is certainly not running: spawn one, reap it, reuse it
dead_pid() {
  local p
  sleep 0 >/dev/null 2>&1 &
  p=$!
  wait "$p" 2>/dev/null || true
  printf '%s' "$p"
}

teardown() {
  [ -n "${HOLDER:-}" ] && kill "$HOLDER" 2>/dev/null
  return 0
}

@test "a second pass is refused while a live one holds the lock" {
  local holder
  holder="$(live_holder)"
  plant_lock "$holder"
  stub_claude 0 'this pass must never run' board

  run "$WAVE_START" demoapp --now
  assert_equal "$status" 3
  assert_output --partial 'already has a wave running'
  assert_output --partial "pid $holder"
}

@test "the refused pass never reaches claude" {
  # Exit 3 alone is not the guarantee - what must not happen is a second scope-out
  # starting. run_pass is the only thing that writes the pass log, so its absence is
  # direct evidence that claude was never invoked.
  plant_lock "$(live_holder)"
  stub_claude 0 'this pass must never run' board

  run "$WAVE_START" demoapp --now
  assert_equal "$status" 3
  refute [ -f "$(PASS_LOG)" ]
}

@test "the refusal hands over the log and the way out" {
  # A bare "already running" leaves the human with no next move, which is what makes
  # them press W a third time.
  plant_lock "$(live_holder)"
  stub_claude 0 'nope' board

  run "$WAVE_START" demoapp --now
  assert_output --partial "$(PASS_LOG)"
  assert_output --partial 'WAVE_FORCE=1'
}

@test "a stale lock from a killed run does not lock the app out forever" {
  plant_lock "$(dead_pid)"
  stub_claude 0 'ran despite the stale lock' board

  run "$WAVE_START" demoapp --now
  assert_success
  refute_output --partial 'already has a wave running'
}

@test "a lock file that is not a pid is cleared rather than believed" {
  plant_lock 'not-a-pid'
  stub_claude 0 'ran anyway' board

  run "$WAVE_START" demoapp --now
  assert_success
  refute_output --partial 'already has a wave running'
}

@test "an empty lock file is cleared rather than believed" {
  # `kill -0 ''` is a syntax error, not a liveness answer, so an empty file has to be
  # handled before it ever reaches the check.
  mkdir -p "$AGENTCTL_STATE_DIR/wave"
  : > "$(LOCK_FILE)"
  stub_claude 0 'ran anyway' board

  run "$WAVE_START" demoapp --now
  assert_success
  refute_output --partial 'already has a wave running'
}

@test "WAVE_FORCE=1 overrides a live holder" {
  plant_lock "$(live_holder)"
  stub_claude 0 'forced through' board

  WAVE_FORCE=1 run "$WAVE_START" demoapp --now
  assert_success
  refute_output --partial 'already has a wave running'
}

@test "the lock is released when the pass finishes" {
  stub_claude 0 'clean pass' board
  run "$WAVE_START" demoapp --now
  assert_success
  refute [ -f "$(LOCK_FILE)" ]
}

@test "the lock is released even when the pass fails" {
  # The trap, not the happy path, is what keeps a crashed wave from wedging the app.
  # The sandbox path contains a space, so this also pins the quoting in the trap.
  stub_claude 1 'boom'
  run "$WAVE_START" demoapp --now
  assert_failure
  refute [ -f "$(LOCK_FILE)" ]
}
