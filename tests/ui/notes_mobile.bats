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

@test "an unsaved edit in yesterday's note does not block the switch, and stays in its buffer" {
  printf '%s' "$SANDBOX/day1.md" >"$SANDBOX/today"
  tmux_start "$TAP"
  wait_until 'notes_shows DAY-ONE'
  _tm send-keys -t '=notes:' o 'UNSAVED-EDIT' Escape
  wait_until 'notes_shows UNSAVED-EDIT'

  printf '%s' "$SANDBOX/day2.md" >"$SANDBOX/today"
  _tm new-window -d -t "$(_tm display -p -t "$TM_TARGET" '#{session_name}'):" "$TAP"
  wait_until 'notes_shows DAY-TWO'
  # Yesterday's buffer is hidden, still modified, and nothing was written to disk.
  [ "$(timeout 3 nvim --server "$TMPDIR/notes-mobile-notes.sock" --remote-expr "getbufinfo('$SANDBOX/day1.md')[0].changed" </dev/null)" = 1 ]
  run cat "$SANDBOX/day1.md"
  assert_output 'DAY-ONE yesterday'
}

@test "a session from before the socket is started over on today's note" {
  _tm new-session -d -s notes nvim "$SANDBOX/day1.md"
  wait_until 'notes_shows DAY-ONE'

  printf '%s' "$SANDBOX/day2.md" >"$SANDBOX/today"
  tmux_start "$TAP"
  wait_until 'notes_shows DAY-TWO'
}

# A stub ssh in the sandbox PATH. The reachability probe (last word `true`) exits with
# <probe rc>; the hub call logs its words, prints HUB-SESSION, then stands in for a live
# session (cat waits on the pane) or exits with <session rc>.
ssh_stub() {
  printf '%s' "$1" >"$SANDBOX/probe_rc"
  printf '%s' "${2:-live}" >"$SANDBOX/session_rc"
  cat >"$SANDBOX/bin/ssh" <<STUB
#!/bin/sh
case "\$*" in *' true') exit "\$(cat '$SANDBOX/probe_rc')" ;; esac
printf '%s\n' "\$@" >>'$SANDBOX/ssh_args'
echo HUB-SESSION
rc="\$(cat '$SANDBOX/session_rc')"
[ "\$rc" = live ] && exec cat
exit "\$rc"
STUB
  chmod +x "$SANDBOX/bin/ssh"
  mkdir -p "$HOME/.config/notes-mobile"
  echo 'pc-test' >"$HOME/.config/notes-mobile/host"
  printf '%s' "$SANDBOX/day1.md" >"$SANDBOX/today"
}

hub_shows() { _tm capture-pane -p -t '=notes-hub:' 2>/dev/null | grep -q "$1"; }

@test "with a hub PC named, a tap opens that PC's hub with every key passed through, and no phone copy" {
  ssh_stub 0
  tmux_start "$TAP"
  wait_until 'hub_shows HUB-SESSION'
  run grep -x '~/.local/bin/tmx root hub' "$SANDBOX/ssh_args"
  assert_success
  run grep -x 'pc-test' "$SANDBOX/ssh_args"
  assert_success
  [ "$(_tm show -v -t '=notes-hub:' prefix)" = None ]
  [ "$(_tm show -v -t '=notes-hub:' status)" = off ]
  run _tm has-session -t '=notes'
  assert_failure
}

@test "a second hub tap starts a fresh hub session and the previous tap's session exits 0" {
  ssh_stub 0
  tmux_start "$TAP"
  _tm set-option -p -t "$TM_TARGET" remain-on-exit on
  wait_until 'hub_shows HUB-SESSION'

  _tm new-window -d -t "$(_tm display -p -t "$TM_TARGET" '#{session_name}'):" "$TAP"
  wait_until '[ "$(_tm display -p -t "$TM_TARGET" "#{pane_dead} #{pane_dead_status}")" = "1 0" ]'
  wait_until '[ "$(grep -cx "pc-test" "$SANDBOX/ssh_args")" -eq 2 ]'
  wait_until '[ "$(_tm list-clients -t "=notes-hub" | wc -l)" -eq 1 ]'
}

@test "a hub PC that cannot be reached opens the phone copy and says so" {
  ssh_stub 255
  tmux_start "$TAP 2>'$SANDBOX/tap.err'"
  wait_until 'notes_shows DAY-ONE'
  run cat "$SANDBOX/tap.err"
  assert_output 'hub unreachable (pc-test): opening the phone copy'
}

@test "a failure on a reachable hub PC stays on screen and opens no phone copy" {
  ssh_stub 0 1
  tmux_start "$TAP"
  wait_until 'hub_shows "hub failed on pc-test (exit 1)"'
  run _tm has-session -t '=notes'
  assert_failure
}
