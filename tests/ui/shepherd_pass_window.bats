#!/usr/bin/env bats
# Tier 3: `fleet-shepherd run` starts its pass as window shepherd of the dotfiles session on a
# REAL tmux server, in ~/.dotfiles, and respawns that window in place on the next run. Every
# other collaborator is a stub; the pass's agentctl-run records its cwd and signals the test
# through tmux wait-for instead of calling a model. Container only, like every ui test.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  load '../helpers/tmux_harness'
  sandbox_init basic
  require_tmux || return 1
  tmux_passthrough_shim

  SH="$REPO_ROOT/.local/bin/fleet-shepherd"
  SRV="batsshep$$"
  export FLEET_SHEPHERD_SERVER="$SRV" FLEET_SHEPHERD_DIR="$HOME/.agent/shepherd" FLEET_STATE_FILE="$HOME/state.json"
  export AGENTCTL_NAME=shepherd-test AGENTCTL_STATE_DIR="$HOME/.local/state/agentctl"
  mkdir -p "$FLEET_SHEPHERD_DIR" "$HOME/.dotfiles"
  jq -n '{schema:1, main:[], sessions:[{target:"a", bucket:"DONE", nudged:false, escalated:false, labels:[], fact:"f"}]}' > "$FLEET_STATE_FILE"
  stub fleet-sessions ':'
  stub fleet-assess '[ "${1:-}" = --blocked ] || echo "verdict: CLEAR load 0.5x"'
  stub agent-hold ':'
  stub agent-notify ':'
  stub watch-companion-loop ':'
  stub fleet-bench ':'
  stub claude-acct 'exit 0'
  stub agentctl ':'
  stub tmx 'echo "$*" >> "$HOME/tmx.calls"'
  stub agentctl-run "pwd >> \"\$HOME/pass.cwd\"; \"$REAL_TMUX\" -L $SRV wait-for -S pass"
  export PROM_LIB="$HOME/prom-stub.sh"
  echo 'prom_q() { printf %s "{\"status\":\"success\",\"data\":{\"result\":[{\"value\":[0,\"0\"]}]}}"; }' > "$PROM_LIB"

  # The hub's dotfiles session with an agent window, a decoy named like the pass window, and the
  # session passes ran in before the move.
  t new-session -d -s dotfiles -n claude -c "$HOME"
  t set-option -g remain-on-exit on
  t new-window -d -t '=dotfiles:' -n shepherd-old
  t new-session -d -s shepherd
}

teardown() {
  tmux_kill_named "${SRV:-}"
  return 0
}

stub() { printf '#!/usr/bin/env bash\n%s\n' "$2" > "$SANDBOX/bin/$1"; chmod +x "$SANDBOX/bin/$1"; }
t() { "$REAL_TMUX" -L "$SRV" -f /dev/null "$@"; }
windows() { t list-windows -t '=dotfiles' -F '#{window_name}' | paste -sd' '; }
# ran: block until the pass's stub has run in its pane (it signals channel pass), 10s guard.
ran() { timeout 10 "$REAL_TMUX" -L "$SRV" wait-for pass || fail "the pass never ran in its pane"; }

@test "the pass is window shepherd of the dotfiles session, in ~/.dotfiles, and the next run respawns it in place" {
  run "$SH" run
  assert_success
  assert_output --partial "attach -t dotfiles:shepherd"
  ran
  assert_equal "$(windows)" 'claude shepherd-old shepherd'
  assert_equal "$(cat "$HOME/pass.cwd")" "$HOME/.dotfiles"
  # no session was made, and the old session stays: no pass was ever recorded in it
  assert_equal "$(t list-sessions -F '#{session_name}' | sort | paste -sd' ')" 'dotfiles shepherd'
  [ ! -e "$HOME/tmx.calls" ]
  # The pass ended (gone) having logged a move: the next run scores it WORKED and respawns the
  # same window, not a second one.
  echo "- moved a" >> "$FLEET_SHEPHERD_DIR/log.md"
  run "$SH" run
  assert_success
  ran
  assert_equal "$(windows)" 'claude shepherd-old shepherd'
  assert_equal "$(wc -l < "$HOME/pass.cwd")" 2
}

@test "an idle pass recorded in the old shepherd session closes that session; the new pass is a window" {
  printf '%s\t%s\t1\n' 11111111-2222-3333-4444-555555555555 "$(date +%s)" > "$FLEET_SHEPHERD_DIR/.pass"
  # it has no proof mark, so it scores STALLED; the verdict is not what this test is about
  run "$SH" run
  assert_output --partial 'closed session shepherd'
  ran
  assert_equal "$(t list-sessions -F '#{session_name}')" dotfiles
  assert_equal "$(windows)" 'claude shepherd-old shepherd'
}
