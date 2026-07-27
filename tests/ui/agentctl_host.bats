#!/usr/bin/env bats
# Tier 3: agentctl-host's tmux path against a REAL tmux server.
#
# The whole point of HOST=tmux is that systemd's view of a run does not change: the
# runner becomes attachable, but Restart=, Result= and the proof-of-work gate still
# see COMMAND's real exit status. That contract is only provable against a real
# server, because it rests on `tmux wait-for` actually blocking and releasing.
#
# Isolation: agentctl-host routes every tmux call through $AGENTCTL_TMUX, so these
# tests pin it at the sandbox socket directly rather than relying on the PATH shim.
# That is deliberate - the shim pins `-S`, and agentctl-host's own default appends
# `-L`, which tmux resolves LAST and would silently escape onto the developer's real
# server. Injecting the whole command string removes the ambiguity.

setup() {
  load '../vendor/bats-support/load'
  load '../helpers/sandbox'
  load '../helpers/tmux_harness'
  sandbox_init basic
  require_tmux || return 1

  HOST_BIN="$REPO_ROOT/.local/bin/agentctl-host"
  export AGENTCTL_CONF_DIR="$BATS_TEST_TMPDIR/agents"
  export AGENTCTL_STATE_DIR="$BATS_TEST_TMPDIR/state"
  mkdir -p "$AGENTCTL_CONF_DIR" "$AGENTCTL_STATE_DIR"

  HOST_SOCK="$BATS_TEST_TMPDIR/host.sock"
  export AGENTCTL_TMUX="tmux -S $HOST_SOCK -f /dev/null"
  $AGENTCTL_TMUX new-session -d -s host -c "$BATS_TEST_TMPDIR"
}

teardown() {
  [ -n "${AGENTCTL_TMUX:-}" ] && $AGENTCTL_TMUX kill-server 2>/dev/null
  ui_teardown
}

mkconf() { # NAME HOST COMMAND
  cat > "$AGENTCTL_CONF_DIR/$1.conf" <<EOF
NAME=$1
KIND=oneshot
HOST=$2
COMMAND='$3'
EOF
  mkdir -p "$AGENTCTL_STATE_DIR/$1"
}

@test "tmux-hosted run returns the command's exit code, not tmux's" {
  mkconf ok tmux 'exit 0'
  run "$HOST_BIN" ok
  [ "$status" -eq 0 ]
}

@test "a FAILING tmux-hosted run still propagates its exit code" {
  # The regression this guards: if the window's trailer used `&&` instead of `;`,
  # a non-zero command would never write the rc file nor raise the signal, and the
  # caller would block forever instead of reporting failure.
  mkconf bad tmux 'exit 42'
  run "$HOST_BIN" bad
  [ "$status" -eq 42 ]
}

@test "the run is synchronous - it does not return before the command finishes" {
  mkconf slow tmux 'sleep 2; exit 3'
  start=$(date +%s)
  run "$HOST_BIN" slow
  elapsed=$(( $(date +%s) - start ))
  [ "$status" -eq 3 ]
  [ "$elapsed" -ge 2 ]
}

@test "it creates an attachable window named for the agent" {
  mkconf named tmux 'sleep 3'
  "$HOST_BIN" named &
  local pid=$!
  # The window must exist WHILE the command runs; that is the entire feature.
  wait_until '$AGENTCTL_TMUX list-windows -a -F "#W" 2>/dev/null | grep -q "^agent:named$"'
  wait "$pid" || true
}

@test "the window is gone once the run completes" {
  mkconf tidy tmux 'exit 0'
  run "$HOST_BIN" tidy
  [ "$status" -eq 0 ]
  run bash -c '$AGENTCTL_TMUX list-windows -a -F "#W" 2>/dev/null | grep -c "^agent:tidy$" || true'
  [ "${output:-0}" = "0" ]
}

@test "a command containing single quotes survives the round trip" {
  # COMMAND is interpolated into a `bash -c '...'` inside a tmux command string, so
  # quoting is the obvious place for this to break.
  mkconf quoted tmux "test 'a b' = 'a b'"
  run "$HOST_BIN" quoted
  [ "$status" -eq 0 ]
}

@test "HOST=headless never touches tmux" {
  mkconf plain headless 'exit 5'
  local before after
  before=$($AGENTCTL_TMUX list-windows -a 2>/dev/null | wc -l)
  run "$HOST_BIN" plain
  after=$($AGENTCTL_TMUX list-windows -a 2>/dev/null | wc -l)
  [ "$status" -eq 5 ]
  [ "$before" = "$after" ]
}

@test "an unreachable tmux server falls back to headless rather than failing the unit" {
  mkconf orphan tmux 'exit 9'
  AGENTCTL_TMUX="tmux -S $BATS_TEST_TMPDIR/nonexistent.sock -f /dev/null" \
    run "$HOST_BIN" orphan
  # Degrades to a normal run: a monitoring/dispatch runner must not stop working
  # just because the cockpit server is down.
  [ "$status" -eq 9 ]
}

@test "--cleanup removes a leftover window and never fails" {
  mkconf leftover tmux 'sleep 30'
  $AGENTCTL_TMUX new-window -d -n "agent:leftover" 'sleep 30'
  run "$HOST_BIN" --cleanup leftover
  [ "$status" -eq 0 ]
  run bash -c '$AGENTCTL_TMUX list-windows -a -F "#W" 2>/dev/null | grep -c "^agent:leftover$" || true'
  [ "${output:-0}" = "0" ]
}
