#!/usr/bin/env bats
# Tier 3: `fleet-shepherd lease` tags the tmux session it ran in with @shepherd, against REAL
# tmux servers. The lease sweeps every server in the socket dir, so this uses
# tmux_passthrough_shim (the servers_isolation.bats pattern): two named servers under the
# sandbox's $TMUX_TMPDIR, inside the container and nowhere else.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  load '../helpers/tmux_harness'
  sandbox_init basic
  require_tmux || return 1
  tmux_passthrough_shim

  SH="$REPO_ROOT/.local/bin/fleet-shepherd"
  export FLEET_SHEPHERD_DIR="$HOME/.agent/shepherd" FLEET_SHEPHERD_LEASE_MIN=30
  SRV_A="batsalpha$$"
  SRV_B="batsbeta$$"
  SOCK_A="$TMUX_TMPDIR/tmux-$(id -u)/$SRV_A"
  for s in one two; do t "$SRV_A" new-session -d -s "$s"; done
  for s in three; do t "$SRV_B" new-session -d -s "$s"; done
  PANE_ONE="$(t "$SRV_A" list-panes -t '=one:' -F '#{pane_id}')"
  # A tag left on another session, on each server, by an earlier shepherd.
  t "$SRV_A" set-option -t '=two:' @shepherd 1
  t "$SRV_B" set-option -t '=three:' @shepherd 1
}

teardown() {
  tmux_kill_named "${SRV_A:-}" "${SRV_B:-}"
  return 0
}

t() { local srv="$1"; shift; "$REAL_TMUX" -L "$srv" -f /dev/null "$@"; }
tag() { t "$1" show-options -qv -t "=$2:" @shepherd; }

# lease_from <holder> [pane]: a pass run inside pane (on server A), or outside tmux.
lease_from() {
  if [ -n "${2:-}" ]; then
    TMUX="$SOCK_A,1,0" TMUX_PANE="$2" FLEET_SHEPHERD_HOLDER="$1" "$SH" lease
  else
    FLEET_SHEPHERD_HOLDER="$1" "$SH" lease
  fi
}

@test "an interactive lease tags its own session with the expiry and clears every other one" {
  local before; before="$(date +%s)"
  run lease_from interactive "$PANE_ONE"
  assert_success
  local at; at="$(tag "$SRV_A" one)"
  [ "$at" -ge $(( before + 30 * 60 )) ] && [ "$at" -le $(( $(date +%s) + 30 * 60 )) ] ||
    fail "one carries '$at', not the lease expiry"
  assert_equal "$(tag "$SRV_A" two)" ''
  assert_equal "$(tag "$SRV_B" three)" ''
}

@test "the runner's lease and a lease outside tmux tag nothing and still clear" {
  run lease_from runner "$PANE_ONE"
  assert_success
  assert_equal "$(tag "$SRV_A" one)" ''
  assert_equal "$(tag "$SRV_A" two)" ''
  assert_equal "$(tag "$SRV_B" three)" ''

  t "$SRV_B" set-option -t '=three:' @shepherd 1
  run lease_from interactive
  assert_success
  assert_equal "$(tag "$SRV_B" three)" ''
}

@test "the .tmux.conf formats show [shepherd] only while the lease is fresh" {
  # The conf's own lines, not a copy: @shepherd_live and the status-right that reads it.
  grep -E "^set -g (@shepherd_live|status-right) " "$REPO_ROOT/.tmux.conf" > "$SANDBOX/shepherd.conf"
  [ "$(wc -l < "$SANDBOX/shepherd.conf")" -eq 2 ] || fail "conf lines moved: $(cat "$SANDBOX/shepherd.conf")"
  t "$SRV_A" source-file "$SANDBOX/shepherd.conf"
  local now; now="$(date +%s)"
  t "$SRV_A" set-option -t '=one:' @shepherd $(( now + 600 ))
  t "$SRV_A" set-option -t '=two:' @shepherd $(( now - 600 ))
  assert_equal "$(t "$SRV_A" display-message -p -t '=one:' '#{T:status-right}' | grep -c shepherd)" 1
  assert_equal "$(t "$SRV_A" display-message -p -t '=two:' '#{T:status-right}' | grep -c shepherd)" 0
  t "$SRV_A" new-session -d -s four
  assert_equal "$(t "$SRV_A" display-message -p -t '=four:' '#{T:status-right}' | grep -c shepherd)" 0
}
