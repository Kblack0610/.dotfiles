#!/usr/bin/env bats
# Tier 3: agentctl-host's tmux path against a REAL tmux server.
#
# The whole point of HOST=tmux is that systemd's view of a run does not change: the
# runner becomes attachable, but Restart=, Result= and the proof-of-work gate still
# see COMMAND's real exit status. That contract is only provable against a real
# server, because it rests on `tmux wait-for` actually blocking and releasing.
#
# ISOLATION: set AGENTCTL_TMUX to a bare `tmux` and let the harness's PATH shim pin
# the socket. That is the ONLY mechanism in play, which matters twice over:
#   * agentctl-host's own default appends `-L <server>`, which tmux resolves AFTER
#     the shim's `-S` and would silently escape onto the developer's real server.
#   * passing our own `-S`/`-f` on top of the shim duplicates both flags. The first
#     run of this suite did exactly that and every tmux-path case failed.

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

  # Bare `tmux`: the shim on PATH supplies -S <sandbox socket> -f /dev/null.
  export AGENTCTL_TMUX="tmux"
  tmux new-session -d -s host -c "$BATS_TEST_TMPDIR"
}

teardown() {
  tmux kill-server 2>/dev/null
  ui_teardown
}

# printf %q, not a hand-rolled '...': the conf is SOURCED, so a COMMAND containing
# quotes has to survive as a single shell word. Wrapping it in literal single quotes
# turned the quote-round-trip case into COMMAND='test 'a b' = 'a b'', which sourced
# as a stray command and left COMMAND unset.
mkconf() { # NAME HOST COMMAND
  {
    printf 'NAME=%s\nKIND=oneshot\nHOST=%s\n' "$1" "$2"
    printf 'COMMAND=%q\n' "$3"
  } > "$AGENTCTL_CONF_DIR/$1.conf"
  mkdir -p "$AGENTCTL_STATE_DIR/$1"
}

@test "tmux-hosted run returns the command's exit code, not tmux's" {
  mkconf ok tmux 'exit 0'
  run "$HOST_BIN" ok
  [ "$status" -eq 0 ]
}

@test "a FAILING tmux-hosted run still propagates its exit code" {
  # The regression this guards: if the window's trailer used `&&` instead of `;`, a
  # non-zero command would never write the rc file nor raise the signal, and the
  # caller would block forever rather than report failure.
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
  wait_until 'tmux list-windows -a -F "#W" 2>/dev/null | grep -q "^agent:named$"'
  wait "$pid" || true
}

@test "the window is gone once the run completes" {
  mkconf tidy tmux 'exit 0'
  run "$HOST_BIN" tidy
  [ "$status" -eq 0 ]
  run bash -c 'tmux list-windows -a -F "#W" 2>/dev/null | grep -c "^agent:tidy$" || true'
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
  before=$(tmux list-windows -a 2>/dev/null | wc -l)
  run "$HOST_BIN" plain
  after=$(tmux list-windows -a 2>/dev/null | wc -l)
  [ "$status" -eq 5 ]
  [ "$before" = "$after" ]
}

@test "an unreachable tmux server falls back to headless rather than failing the unit" {
  mkconf orphan tmux 'exit 9'
  AGENTCTL_TMUX="tmux -S $BATS_TEST_TMPDIR/nonexistent.sock" run "$HOST_BIN" orphan
  # Degrades to a normal run: a monitoring or dispatch runner must not stop working
  # just because the cockpit server is down.
  [ "$status" -eq 9 ]
}

@test "--cleanup removes a leftover window and never fails" {
  mkconf leftover tmux 'sleep 30'
  tmux new-window -d -n "agent:leftover" 'sleep 30'
  run "$HOST_BIN" --cleanup leftover
  [ "$status" -eq 0 ]
  run bash -c 'tmux list-windows -a -F "#W" 2>/dev/null | grep -c "^agent:leftover$" || true'
  [ "${output:-0}" = "0" ]
}
