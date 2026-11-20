#!/usr/bin/env bats
# Tier 3: notes-mobile, the phone's one-tap daily note, on a real tmux server with real nvim.
# Container only, like every ui test. Each harness pane stands in for one Termux session opened
# by a home-screen tap. A tap after the day turns must show today's note in the running editor,
# and the previous tap's session must exit 0, which is what makes Termux close it.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  load '../helpers/tmux_harness'
  sandbox_init basic
  require_tmux || return 1
  command -v nvim >/dev/null || fail "nvim missing from the test image"
  tmux_shim

  echo 'DAY-ONE yesterday' >"$SANDBOX/day1.md"
  echo 'DAY-TWO today' >"$SANDBOX/day2.md"
  # `notes path daily` prints whatever $SANDBOX/today names; `notes today` does nothing.
  printf '#!/bin/sh\n[ "$1 $2" = "path daily" ] && cat "%s/today"\nexit 0\n' "$SANDBOX" >"$SANDBOX/bin/notes"
  chmod +x "$SANDBOX/bin/notes"
  TAP="env -u TMUX NOTES_SYNC_CMD=/bin/true NOTES_MIRROR_CMD=/bin/true $REPO_ROOT/.local/bin/notes-mobile"
}

teardown() { ui_teardown; }

notes_shows() { _tm capture-pane -p -t '=notes:' 2>/dev/null | grep -q "$1"; }

@test "a tap after the day turns shows today's note, and the previous tap's session exits 0" {
  printf '%s' "$SANDBOX/day1.md" >"$SANDBOX/today"
  tmux_start "$TAP"
  _tm set-option -p -t "$TM_TARGET" remain-on-exit on
  wait_until 'notes_shows DAY-ONE'

  printf '%s' "$SANDBOX/day2.md" >"$SANDBOX/today"
  _tm new-window -d -t "$(_tm display -p -t "$TM_TARGET" '#{session_name}'):" "$TAP"
  wait_until 'notes_shows DAY-TWO'
  wait_until '[ "$(_tm display -p -t "$TM_TARGET" "#{pane_dead} #{pane_dead_status}")" = "1 0" ]'
  [ "$(_tm list-clients -t '=notes' | wc -l)" -eq 1 ]
}

@test "a session from before the socket is started over on today's note" {
  _tm new-session -d -s notes nvim "$SANDBOX/day1.md"
  wait_until 'notes_shows DAY-ONE'

  printf '%s' "$SANDBOX/day2.md" >"$SANDBOX/today"
  tmux_start "$TAP"
  wait_until 'notes_shows DAY-TWO'
}
