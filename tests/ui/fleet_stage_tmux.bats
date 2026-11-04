#!/usr/bin/env bats
# Tier 3: `fleet-sessions` copies each session's stage and labels onto its tmux window
# (tmux_project), and .tmux.conf's @fleet_fmt renders them, against REAL tmux servers under the
# sandbox's $TMUX_TMPDIR, inside the container and nowhere else (shepherd_lease.bats pattern).

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  load '../helpers/tmux_harness'
  sandbox_init basic
  require_tmux || return 1
  tmux_passthrough_shim

  export FLEET_SHEPHERD_DIR="$HOME/.agent/shepherd"
  SRV="batsfleet$$"
  t new-session -d -s one
  t new-window -d -t '=one:'
  t new-session -d -s two
  # A stage left on a window whose session has gone, by an earlier tick.
  t set-option -w -t '=two:0' @fleet_stage DONE
  # The repo's own format, not a copy.
  t set-option -g @fleet_fmt "$(sed -n "s/^set -g @fleet_fmt '\(.*\)'$/\1/p" "$REPO_ROOT/.tmux.conf")"
  DOC="$SANDBOX/state.json"
  jq -n --arg s "$SRV" '{sessions: [
    {session_id: "a", target: "\($s)/one:0", bucket: "STALLED", labels: ["manual"]},
    {session_id: "b", target: "\($s)/one:1", bucket: "WORKING", labels: []}]}' > "$DOC"
  # shellcheck source=/dev/null
  source "$REPO_ROOT/.local/bin/fleet-sessions"
}

teardown() {
  tmux_kill_named "${SRV:-}"
  return 0
}

t() { "$REAL_TMUX" -L "$SRV" -f /dev/null "$@"; }
# shown <window>: what @fleet_fmt renders there, styles stripped.
shown() { t display-message -p -t "$1" '#{E:@fleet_fmt}' | sed 's/#\[[^]]*\]//g'; }

@test "a tick puts stage and labels on each session's window and clears a window with none" {
  [ -n "$(t display-message -p '#{@fleet_fmt}')" ] || fail "@fleet_fmt not found in .tmux.conf"
  tmux_project "$DOC"
  assert_equal "$(t show-options -wv -t '=one:0' @fleet_stage)" STALLED
  assert_equal "$(t show-options -wv -t '=one:0' @fleet_labels)" manual
  assert_equal "$(t show-options -wv -t '=one:1' @fleet_stage)" WORKING
  assert_equal "$(t show-options -wqv -t '=one:1' @fleet_labels)" ''
  assert_equal "$(t show-options -wqv -t '=two:0' @fleet_stage)" ''
  assert_equal "$(shown '=one:0')" 'STALLED [manual] '
  assert_equal "$(shown '=one:1')" ''
}

@test "a label change lands on the window at once, without a tick" {
  tmux_project "$DOC"
  export FLEET_STATE_FILE="$DOC"
  STATE_FILE="$DOC"
  mkdir -p "$LABELS"
  echo quality:x > "$LABELS/b"
  tmux_labels b
  assert_equal "$(t show-options -wv -t '=one:1' @fleet_labels)" quality:x
  rm "$LABELS/b"
  tmux_labels b
  assert_equal "$(t show-options -wqv -t '=one:1' @fleet_labels)" ''
}
