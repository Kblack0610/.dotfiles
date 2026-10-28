#!/usr/bin/env bats
# fleet-bench ledger: the counts that say whether the fleet is consolidating or growing.
#
# Runners, timers and direct headless launches may only shrink. `ledger --check` holds
# them to a committed baseline; every fixture here is a sandbox directory, because the
# live roster lives in the private overlay that CI cannot see.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic
  SUBJECT="$REPO_ROOT/.local/bin/fleet-bench"
  export FLEET_BENCH_DIR="$HOME/.agent/bench"
  export AGENTCTL_STATE_DIR="$HOME/.local/state/agentctl"
  export BENCH_LIB_DIR="$REPO_ROOT/.local/lib"
  export LEDGER_CONF_DIR="$SANDBOX/confs" LEDGER_TIMER_DIR="$SANDBOX/timers"
  export LEDGER_SRC="$SANDBOX/src" LEDGER_BASELINE="$SANDBOX/baseline"
  export LEDGER_BOARDS="$SANDBOX/board.md"
  export BENCH_ASKS_CMD=asks-stub BENCH_NOW=1793160000
  mkdir -p "$LEDGER_CONF_DIR" "$LEDGER_TIMER_DIR" "$LEDGER_SRC" "$AGENTCTL_STATE_DIR"
  for n in alpha beta; do
    printf 'NAME=%s\nKIND=oneshot\n' "$n" > "$LEDGER_CONF_DIR/$n.conf"
    : > "$LEDGER_TIMER_DIR/agentctl-$n.timer"
  done
  printf 'exec claude "${flags[@]}" "$@"\n' > "$LEDGER_SRC/harness.sh"
  printf 'runners=2\ntimers=2\nlaunches_direct=0\n' > "$LEDGER_BASELINE"
  # One ask filed 20 days before BENCH_NOW, one filed 1 day before.
  printf '#!/usr/bin/env bash\nprintf "old\\tp\\t\\tpending\\tgate\\tq\\ta|b\\t\\t\\t\\t\\t2026-10-07T00:00:00+0000\\t\\nnew\\tp\\t\\tpending\\tgate\\tq\\ta|b\\t\\t\\t\\t\\t2026-10-26T00:00:00+0000\\t\\n"\n' > "$SANDBOX/bin/asks-stub"
  chmod +x "$SANDBOX/bin/asks-stub"
  printf '%s\n' '- [ ] open one' '- [/] in progress' '- [x] done one' > "$LEDGER_BOARDS"
}

@test "counts runners, the ones switched on, timers and direct launches" {
  echo 'ENABLED=no' >> "$LEDGER_CONF_DIR/beta.conf"
  run "$SUBJECT" ledger
  assert_success
  assert_line 'runners=2'
  assert_line 'runners_on=1'
  assert_line 'timers=2'
  assert_line 'launches_direct=0'
}

@test "asks older than ASK_STALE_DAYS are stale, and open board rows count todo and in-progress" {
  run "$SUBJECT" ledger
  assert_line 'asks_pending=2'
  assert_line 'asks_stale=1'
  assert_line 'board_open=2'
}

@test "verdict words counts the distinct last-outcome verdicts" {
  for n in a b c; do mkdir -p "$AGENTCTL_STATE_DIR/$n"; done
  echo WORKED > "$AGENTCTL_STATE_DIR/a/last-outcome"
  echo WORKED > "$AGENTCTL_STATE_DIR/b/last-outcome"
  echo FAILED > "$AGENTCTL_STATE_DIR/c/last-outcome"
  run "$SUBJECT" ledger
  assert_line 'verdict_words=2'
}

@test "check holds at the baseline" {
  run "$SUBJECT" ledger --check
  assert_success
  assert_output ''
}

@test "a new conf fails the check and names the count that grew (negative control)" {
  printf 'NAME=gamma\nKIND=oneshot\n' > "$LEDGER_CONF_DIR/gamma.conf"
  run "$SUBJECT" ledger --check
  assert_failure
  assert_output 'runners grew: 3 > baseline 2'
}

@test "a direct claude -p fails the check" {
  printf '#!/bin/sh\nclaude -p "do it"\n' > "$LEDGER_SRC/runner"
  run "$SUBJECT" ledger --check
  assert_failure
  assert_output 'launches_direct grew: 1 > baseline 0'
}

@test "a missing baseline fails rather than reading as held" {
  rm "$LEDGER_BASELINE"
  run "$SUBJECT" ledger --check
  assert_equal "$status" 2
}

@test "the scan skips gitignored build output" {
  mkdir -p "$LEDGER_SRC/target"
  printf 'claude -p x\n' > "$LEDGER_SRC/target/built"
  printf 'target/\n' > "$LEDGER_SRC/.gitignore"
  run "$SUBJECT" ledger --launches "$LEDGER_SRC"
  assert_output ''
}

@test "--json is one object with numeric counts" {
  run bash -c '"$0" ledger --json | jq -e ".runners == 2 and .timers == 2"' "$SUBJECT"
  assert_success
}
