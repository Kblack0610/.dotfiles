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
