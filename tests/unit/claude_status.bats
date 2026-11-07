#!/usr/bin/env bats
# claude-status.sh generates the tmux status-left string: the !n / ~n / checkmark-n / dot-n
# counts that tell you at a glance which agent windows need you. It classifies nothing from
# pane text: it joins `agent-panel list` (the live glyph) to the fleet state document (the
# bucket) by target, so every branch is drivable from a canned list and a canned document.
#
# This is the surface where a wrong answer is worst: a missed `!` means an agent sat blocked
# on a permission prompt while the status bar said everything was fine.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic
  export FLEET_STATE_FILE="$NOTES_FIXTURE/state.json"
  source "$STATUS_SH"
}

# agent <server> <session> <idx> <glyph> -- one live agent in the fake `agent-panel list`
agent() {
  printf '%s/%s:%s\t%s\tproj\tsummary\n' "$1" "$2" "$3" "$4" >> "$NOTES_FIXTURE/agent-panel.list"
}
# bucket <server> <session> <idx> <BUCKET> -- that agent's row in the fleet state document
bucket() {
  local f="$FLEET_STATE_FILE" row
  row=$(printf '{"target":"%s/%s:%s","bucket":"%s"}' "$1" "$2" "$3" "$4")
  printf '%s\n' "$row" >> "$NOTES_FIXTURE/state.rows"
  printf '{"generated_epoch":%s,"unreadable":%s,"sessions":[%s]}\n' \
    "${STATE_EPOCH:-$(date +%s)}" "${STATE_UNREADABLE:-[]}" "$(paste -sd, "$NOTES_FIXTURE/state.rows")" > "$f"
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

@test "a pending ask (bucket NEEDS) counts as needing attention while the pane looks idle" {
  agent hub work 0 '✓'
  bucket hub work 0 NEEDS
  run get_session_status work
  assert_output '!1'
}

@test "attention wins over working even when the pane is busy" {
  agent hub work 0 '~'
  bucket hub work 0 NEEDS
  run get_session_status work
  assert_output '!1'
}

@test "multiple blocked agents are counted, not collapsed to one" {
  agent hub work 0 '!'
  agent hub work 1 '✓'; bucket hub work 1 NEEDS
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

@test "an idle agent counts as idle, whatever its bucket other than NEEDS" {
  agent hub work 0 '✓'; bucket hub work 0 STALLED
  run get_session_status work
  assert_output '✓1'
}

@test "working outranks idle when both are present" {
  agent hub work 0 '~'
  agent hub work 1 '✓'
  run get_session_status work
  assert_output '~1'
}

@test "a missing state document degrades to the glyphs alone" {
  agent hub work 0 '✓'
  run get_session_status work
  assert_output '✓1'
}

@test "a stale state document is ignored, leaving the glyphs alone" {
  STATE_EPOCH=$(( $(date +%s) - 3600 ))
  agent hub work 0 '✓'; bucket hub work 0 NEEDS
  run get_session_status work
  assert_output '✓1'
}

@test "a document written without agent-panel is ignored, leaving the glyphs alone" {
  STATE_UNREADABLE='["agent-panel"]'
  agent hub work 0 '✓'; bucket hub work 0 NEEDS
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
  agent hub beta  1 '✓'; bucket hub beta 1 NEEDS
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

@test "a NEEDS bucket on another server's same-named session does not leak" {
  export STUB_SOCKET=/tmp/tmux-1000/hub
  agent hub work 0 '✓'
  agent lab work 0 '✓'; bucket lab work 0 NEEDS
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
