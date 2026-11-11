#!/usr/bin/env bats
# claude-status.sh generates the tmux status-left string: the !n / ~n / checkmark-n / dot-n
# counts that tell you at a glance which agent windows need you. It classifies nothing from
# pane text: `!n` is the questions panel's own count (`questions.sh count`, stubbed here by a
# number in a file), `~n` and the check count `agent-panel list`'s live glyphs, so every branch
# is drivable from a canned list. That the panel and the bar read one number is the integ test
# in tests/integ/questions_panel.bats.
#
# This is the surface where a wrong answer is worst: a missed `!` means an agent sat blocked
# on a question while the status bar said everything was fine.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic
  printf '#!/bin/sh\n[ "$1" = count ] && cat "$NOTES_FIXTURE/questions.count" 2>/dev/null || echo 0\n' > "$NOTES_FIXTURE/questions.sh"
  chmod +x "$NOTES_FIXTURE/questions.sh"
  export QUESTIONS_SH="$NOTES_FIXTURE/questions.sh"
  source "$STATUS_SH"
}

# agent <server> <session> <idx> <glyph> -- one live agent in the fake list
agent() {
  printf '%s/%s:%s\t%s\tproj\tsummary\n' "$1" "$2" "$3" "$4" >> "$NOTES_FIXTURE/agent-panel.list"
}
# questions <n> -- what the panel counts: pending asks plus open dialogs
questions() { echo "$1" > "$NOTES_FIXTURE/questions.count"; }

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

@test "the questions the panel counts show as !n, with no agent in the session at all" {
  questions 3
  run get_session_status work
  assert_output '!3'
  grep -qx 'agent-panel list' "$NOTES_FIXTURE/calls.log"
}

@test "attention wins over working and idle: a pending ask on a busy or idle pane still counts" {
  agent hub work 0 '~'
  agent hub work 1 '✓'
  questions 1
  run get_session_status work
  assert_output '!1'
}

@test "the number is the panel's, not the agents': held asks with no live session count" {
  agent hub work 0 '✓'
  questions 30
  run get_session_status work
  assert_output '!30'
  run get_session_status ""
  assert_output '!30'
}

@test "no questions: a prompt glyph alone does not make a !, the panel count is the only source" {
  agent hub work 0 '!'
  questions 0
  run get_session_status work
  assert_output '·1'
}

@test "a questions reader that fails or prints junk counts as none" {
  agent hub work 0 '~'
  printf '#!/bin/sh\nexit 1\n' > "$QUESTIONS_SH"
  run get_session_status work
  assert_output '~1'
  printf '#!/bin/sh\necho oops\n' > "$QUESTIONS_SH"
  run get_session_status work
  assert_output '~1'
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
  agent hub alpha 0 '✓'
  agent hub beta  0 '~'
  run get_session_status alpha
  assert_output '✓1'
  run get_session_status beta
  assert_output '~1'
}

@test "a session name that prefixes another is not matched" {
  agent hub work-2 0 '~'
  run get_session_status work
  assert_output ''
}

@test "an empty target session counts every agent" {
  agent hub alpha 0 '~'
  agent hub beta  1 '~'
  run get_session_status ""
  assert_output '~2'
}

@test "only agents on this tmux server count" {
  export STUB_SOCKET=/tmp/tmux-1000/hub
  agent hub  work 0 '~'
  agent lab  work 0 '~'
  agent lab  work 1 '~'
  run get_session_status work
  assert_output '~1'
}

@test "another server's same-named session does not leak" {
  export STUB_SOCKET=/tmp/tmux-1000/hub
  agent hub work 0 '✓'
  agent lab work 0 '~'
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
