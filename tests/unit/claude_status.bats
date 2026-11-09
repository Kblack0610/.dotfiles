#!/usr/bin/env bats
# claude-status.sh generates the tmux status-left string: the !n / ~n / checkmark-n / dot-n
# counts that tell you at a glance which agent windows need you. It classifies nothing from
# pane text: it counts `agent-panel list --needs` (the live glyph and needs column), so every
# branch is drivable from a canned list.
#
# This is the surface where a wrong answer is worst: a missed `!` means an agent sat blocked
# on a permission prompt while the status bar said everything was fine.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic
  source "$STATUS_SH"
}

# agent <server> <session> <idx> <glyph> [needs] -- one live agent in the fake list; `!` needs
# the human on its own, any other glyph when the fifth argument says so (a pending ask)
agent() {
  local needs="${5:-0}"
  [ "$4" = '!' ] && needs=1
  printf '%s/%s:%s\t%s\tproj\tsummary\t%s\n' "$1" "$2" "$3" "$4" "$needs" >> "$NOTES_FIXTURE/agent-panel.list"
}

# ── no agents ────────────────────────────────────────────────────────────────

@test "an empty agent list yields an empty status, not a stray glyph" {
  run get_session_status ""
  assert_success
  assert_output ''
}

@test "agent-panel failing yields an empty status" {
  printf '#!/bin/sh\nexit 1\n' > "$SANDBOX/bin/agent-panel"
  run get_session_status work
  assert_success
  assert_output ''
}

# ── attention: the branch that matters most ──────────────────────────────────

@test "a prompt glyph counts as needing attention" {
  agent hub work 0 '!'
  run get_session_status work
  assert_output '!1'
}

@test "a pending ask counts as needing attention while the pane looks idle" {
  agent hub work 0 '✓' 1
  run get_session_status work
  assert_output '!1'
  grep -qx 'agent-panel list --needs' "$NOTES_FIXTURE/calls.log"
}

@test "attention wins over working even when the pane is busy" {
  agent hub work 0 '~' 1
  run get_session_status work
  assert_output '!1'
}

@test "multiple blocked agents are counted, not collapsed to one" {
  agent hub work 0 '!'
  agent hub work 1 '✓' 1
  run get_session_status work
  assert_output '!2'
}

@test "attention outranks working when both are present" {
  agent hub work 0 '!'
  agent hub work 1 '~'
  run get_session_status work
  assert_output '!1'
}

# ── working / idle ───────────────────────────────────────────────────────────

@test "a busy glyph counts as working" {
  agent hub work 0 '~'
  run get_session_status work
  assert_output '~1'
}

@test "an idle agent counts as idle" {
  agent hub work 0 '✓'
  run get_session_status work
  assert_output '✓1'
}

@test "working outranks idle when both are present" {
  agent hub work 0 '~'
  agent hub work 1 '✓'
  run get_session_status work
  assert_output '~1'
}

@test "a state document a pass behind cannot keep an answered session in the count" {
  export FLEET_STATE_FILE="$NOTES_FIXTURE/state.json" XDG_STATE_HOME="$NOTES_FIXTURE/xdg"
  mkdir -p "$XDG_STATE_HOME/fleet"
  printf '{"generated_epoch":%s,"unreadable":[],"sessions":[{"target":"hub/work:0","bucket":"NEEDS"}]}\n' "$(date +%s)" |
    tee "$FLEET_STATE_FILE" > "$XDG_STATE_HOME/fleet/state.json"
  agent hub work 0 '✓'
  run get_session_status work
  assert_output '✓1'
}

@test "an unknown glyph shows the bare count, not a check" {
  agent hub work 0 '?'
  run get_session_status work
  assert_output '·1'
}

# ── session and server scoping ───────────────────────────────────────────────

@test "status is scoped to the requested session" {
  agent hub alpha 0 '!'
  agent hub beta  0 '~'
  run get_session_status alpha
  assert_output '!1'
  run get_session_status beta
  assert_output '~1'
}

@test "a session name that prefixes another is not matched" {
  agent hub work-2 0 '!'
  run get_session_status work
  assert_output ''
}

@test "an empty target session counts every agent" {
  agent hub alpha 0 '!'
  agent hub beta  1 '✓' 1
  run get_session_status ""
  assert_output '!2'
}

@test "only agents on this tmux server count" {
  export STUB_SOCKET=/tmp/tmux-1000/hub
  agent hub  work 0 '!'
  agent lab  work 0 '!'
  agent lab  work 1 '!'
  run get_session_status work
  assert_output '!1'
}

@test "another server's same-named session needing attention does not leak" {
  export STUB_SOCKET=/tmp/tmux-1000/hub
  agent hub work 0 '✓'
  agent lab work 0 '✓' 1
  run get_session_status work
  assert_output '✓1'
}

# ── get_short_name ───────────────────────────────────────────────────────────

@test "get_short_name maps the known sessions" {
  run get_short_name dotfiles;  assert_output 'dot'
  run get_short_name platform;  assert_output 'plt'
  run get_short_name hub;       assert_output 'hub'
  run get_short_name network;   assert_output 'net'
}

@test "get_short_name truncates an unknown session to three characters" {
  run get_short_name somethinglong
  assert_output 'som'
}

@test "get_short_name tolerates a short session name" {
  run get_short_name ab
  assert_output 'ab'
}

@test "get_short_name tolerates an empty session name" {
  run get_short_name ""
  assert_success
  assert_output ''
}
