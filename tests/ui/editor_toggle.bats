#!/usr/bin/env bats
# Tier 3: the editor window, driven through a REAL tmux server.
#
# This tier exists because the interesting half of editor.sh is not text and not a pure
# function -- it is what tmux's window list looks like afterwards. Nothing below asserts on
# a rendered screen; the subject's whole output IS server state, so the assertions read it
# back with list-windows.
#
# Every call goes through `run-shell`, which is how the bind invokes it for real. That
# matters: run-shell is the context that supplies $TMUX and $TMUX_PANE, so calling the
# script directly from the test shell would exercise a path the keybinding never takes.
#
# EDITOR_WINDOW_CMD is overridden per call. The container has no nvim, and more importantly
# a test must not depend on one: the subject's contract is "run the configured command in a
# window that survives it", and `sleep` proves that as well as an editor does.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  load '../helpers/tmux_harness'
  sandbox_init basic
  require_tmux || return 1
  tmux_shim
}

teardown() { ui_teardown; }

# A session with FOUR windows, one of them the editor.
#
# Three plus the editor, not one plus the editor. With a single origin window, "went back
# where I came from" and "went to the only other window" are the same observation, and
# `last-window` alone would satisfy every assertion here. The third window is the negative
# control that makes the return address load-bearing.
start_session() {
  _tm new-session -d -s work -c "$SANDBOX" -n one "sleep 300" </dev/null
  _tm set-option -g window-size manual 2>/dev/null || true
  _tm new-window -d -t work: -n two "sleep 300"
  _tm new-window -d -t work: -n three "sleep 300"
  wait_until '[ "$(win_count)" = 3 ]'
}

# Run the subject the way the keybinding does, from a given window.
#
# `toggle` is handed the origin window id, because that is what the bind does -- tmux expands
# '#{window_id}' before the script starts. Passing it here rather than relying on the implicit
# target is not a convenience: run-shell leaves TMUX_PANE empty, so a toggle that inferred its
# own window would read tmux's current one, which ensure's move-window has already changed.
ed() {
  local win="$1" verb="$2" cmd="${3:-sleep 300}"
  local id; id="$(_tm display-message -p -t "work:$win" '#{window_id}')"
  if [ "$verb" = toggle ]; then
    _tm run-shell -t "work:$win" "EDITOR_WINDOW_CMD='$cmd' '$EDITOR_SH' toggle '$id'"
  else
    _tm run-shell -t "work:$win" "EDITOR_WINDOW_CMD='$cmd' '$EDITOR_SH' $verb"
  fi
}

win_count()   { _tm list-windows -t work: -F '#{window_id}' | grep -c .; }
marked()      { _tm list-windows -t work: -F '#{window_id} #{@editor}' | awk 'NF > 1 {print $1}'; }
current_win() { _tm display-message -p -t work: '#{window_id}'; }
name_of()     { _tm display-message -p -t "$1" '#{window_name}'; }
index_of()    { _tm display-message -p -t "$1" '#{window_index}'; }
id_of_name()  { _tm list-windows -t work: -F '#{window_name} #{window_id}' | awk -v n="$1" '$1==n {print $2; exit}'; }

# ── The harness itself, before anything is trusted ───────────────────────────

@test "the fixture session really has three distinct windows and no editor" {
  start_session
  assert_equal "$(win_count)" 3
  [ -z "$(marked)" ] || fail "something is already marked @editor -- every test below is void"
  # Three DIFFERENT ids. If the helper resolved them all to the same window, the return
  # assertions would pass without proving anything.
  local a b c
  a="$(id_of_name one)"; b="$(id_of_name two)"; c="$(id_of_name three)"
  [ -n "$a" ] && [ -n "$b" ] && [ -n "$c" ] || fail "could not resolve all three window ids"
  [ "$a" != "$b" ] && [ "$b" != "$c" ] && [ "$a" != "$c" ] || fail "window ids are not distinct: $a $b $c"
}

# ── ensure ───────────────────────────────────────────────────────────────────

@test "ensure creates exactly one marked editor window" {
  start_session
  ed two ensure
  wait_until '[ "$(win_count)" = 4 ]'
  assert_equal "$(marked | grep -c .)" 1
}

@test "the editor window lands FIRST in the list" {
  start_session
  ed two ensure
  wait_until '[ "$(win_count)" = 4 ]'
  local ed_id base expected
  ed_id="$(marked)"
  assert_equal "$(index_of "$ed_id")" "$(_tm list-windows -t work: -F '#{window_index}' | head -1)"
  # And the others kept their order behind it, renumbered gapless.
  assert_equal "$(_tm list-windows -t work: -F '#{window_name}' | tr '\n' ' ')" "edit one two three "

  # base-index is read from the server rather than assumed. The harness pins `-f /dev/null`
  # so this tier runs at tmux's stock 0, while .tmux.conf sets 1 -- hardcoding either would
  # make the test assert the environment instead of the subject.
  base="$(_tm show-option -gv base-index)"
  expected="$(seq "$base" $((base + 3)) | tr '\n' ' ')"
  assert_equal "$(_tm list-windows -t work: -F '#{window_index}' | tr '\n' ' ')" "$expected"
}

@test "ensure is idempotent -- a second call creates nothing" {
  start_session
  ed two ensure
  wait_until '[ "$(win_count)" = 4 ]'
  local first; first="$(marked)"
  ed two ensure
  ed three ensure
  sleep 0.3   # give a wrong implementation time to actually create the extra windows
  assert_equal "$(win_count)" 4
  assert_equal "$(marked)" "$first"
}

@test "the editor opens in the session's directory, not the caller's" {
  start_session
  _tm new-window -d -t work: -n four -c /tmp "sleep 300"
  ed four ensure
  wait_until '[ -n "$(marked)" ]'
  local ed_id
  ed_id="$(marked)"
  assert_equal "$(_tm display-message -p -t "$ed_id" '#{pane_current_path}')" "$(cd "$SANDBOX" && pwd -P)"
}

# ── toggle ───────────────────────────────────────────────────────────────────

@test "toggle from a window goes to the editor" {
  start_session
  _tm select-window -t work:two
  ed two toggle
  wait_until '[ -n "$(marked)" ] && [ "$(current_win)" = "$(marked)" ]'
}

@test "toggle from the editor returns to the window it was called from, not just the last one" {
  start_session
  # Visit two, then three: `last-window` from the editor would now resolve to two, so an
  # implementation that ignores the stored return address fails here and only here.
  _tm select-window -t work:two
  _tm select-window -t work:three
  local three; three="$(id_of_name three)"

  ed three toggle
  wait_until '[ "$(current_win)" = "$(marked)" ]'

  ed "$(index_of "$(marked)")" toggle
  wait_until "[ \"\$(current_win)\" = \"$three\" ]"
  assert_equal "$(current_win)" "$three"
}

@test "the return address survives windows being added and renumbered" {
  start_session
  _tm select-window -t work:three
  local three; three="$(id_of_name three)"
  ed three toggle
  wait_until '[ "$(current_win)" = "$(marked)" ]'

  # The insert already renumbered once; do it again from underneath. An index-based return
  # address would now point at a different window entirely -- which is why it is an id.
  _tm new-window -d -t work: -n extra "sleep 300"
  _tm move-window -r -t work:

  ed "$(index_of "$(marked)")" toggle
  wait_until "[ \"\$(current_win)\" = \"$three\" ]"
}

@test "toggling back when the origin window is gone falls through instead of erroring" {
  start_session
  _tm select-window -t work:three
  ed three toggle
  wait_until '[ "$(current_win)" = "$(marked)" ]'

  _tm kill-window -t work:three
  local ed_id; ed_id="$(marked)"
  ed "$(index_of "$ed_id")" toggle
  # The only hard requirement is that we do not get stranded on the editor.
  wait_until "[ \"\$(current_win)\" != \"$ed_id\" ]"
}

# ── the self-heal ────────────────────────────────────────────────────────────

@test "quitting the editor leaves the window alive, and the next toggle re-enters it" {
  start_session
  # The editor is a `sleep 1` here: it EXITS NORMALLY on its own, which is exactly what `:q`
  # is, and it needs no keystroke to do it.
  #
  # Two rejected alternatives, both of which produced a lying test:
  #   send C-c to a `sleep 300` -- SIGINT goes to the whole foreground process group, so it
  #     kills the wrapping sh too and the window closes. That "failure" is not one the real
  #     :q path can ever reach.
  #   send C-d to a `cat` -- a pane spawned from a run-shell child gets a stdin that EOFs
  #     immediately (verified on 3.7b), so cat was already dead before the keystroke and the
  #     test was asserting against a window it had never actually seen running.
  ed two ensure 'sleep 1'
  wait_until '[ -n "$(marked)" ]'
  local ed_id; ed_id="$(marked)"

  # The editor exits; the shell tail catches the window.
  wait_until "_tm display-message -p -t '$ed_id' '#{pane_current_command}' | grep -qvx sleep"
  # THE assertion. Without a RESOLVED shell on the window command the tail is `exec \"\"`,
  # the window closes here, and its place in the list is gone. $SHELL is unset under
  # run-shell, so that is not a hypothetical.
  assert_equal "$(win_count)" 4
  assert_equal "$(marked)" "$ed_id"

  # And the toggle re-enters it rather than delivering you to a bare prompt.
  ed two toggle 'sleep 300'
  wait_until "_tm display-message -p -t '$ed_id' '#{pane_current_command}' | grep -qx sleep"
  assert_equal "$(current_win)" "$ed_id"
}

# ── the real .tmux.conf ──────────────────────────────────────────────────────
#
# editor_binds.bats reads the config as TEXT, which proves what is written but not what tmux
# makes of it. These two load the actual file into a real server and read the binding table
# back, which is the only way to catch a config that no longer parses (one bad line and every
# bind AFTER it is silently dropped) or a bind tmux quietly rewrote.
#
# `-f <the real config>` instead of the shim's `-f /dev/null`, so the socket flag is doing the
# isolating on its own -- which is the doctrine in tmux_harness.bash: isolation is a flag.

conf_server() {
  CONF_SOCKET="$SANDBOX/conf.sock"
  "$REAL_TMUX" -S "$CONF_SOCKET" -f "$REPO_ROOT/.tmux.conf" new-session -d </dev/null
}
conf_tmux() { "$REAL_TMUX" -S "$CONF_SOCKET" "$@"; }

@test "the real .tmux.conf still loads, and registers both editor keys" {
  conf_server || fail ".tmux.conf did not load -- a parse error drops every bind after it"

  # prefix+e, and Alt+e in the ROOT table (no prefix). The table is asserted, not just the
  # key: `bind e` and `bind -n e` are different bindings and only one of them is the point.
  local pfx root
  pfx="$(conf_tmux list-keys -T prefix | awk '$4 == "e" { $1=$2=$3=$4=""; sub(/^ +/,""); print }')"
  root="$(conf_tmux list-keys -T root | awk '$4 == "M-e" { $1=$2=$3=$4=""; sub(/^ +/,""); print }')"

  grep -qF "editor.sh toggle '#{window_id}'" <<< "$pfx" \
    || fail "prefix+e did not register as the editor toggle: [$pfx]"
  grep -qF "editor.sh toggle '#{window_id}'" <<< "$root" \
    || fail "Alt+e did not register in the root table: [$root]"

  conf_tmux kill-server 2>/dev/null || true
}

@test "mail really is on prefix+E after the rekey, per tmux itself" {
  conf_server
  local e
  e="$(conf_tmux list-keys -T prefix | awk '$4 == "E" { $1=$2=$3=$4=""; sub(/^ +/,""); print }')"
  grep -qF 'aerc' <<< "$e" || fail "prefix+E is not mail: [$e]"
  conf_tmux kill-server 2>/dev/null || true
}

# ── the marker ───────────────────────────────────────────────────────────────

@test "the editor is found by its option even after its name is rewritten" {
  # .zshrc's precmd hook renames every window to the git branch on each prompt, which is
  # why the marker is an option and not the name. Simulate the rename directly: the lookup
  # must not care.
  start_session
  ed two ensure
  wait_until '[ -n "$(marked)" ]'
  local ed_id; ed_id="$(marked)"
  _tm rename-window -t "$ed_id" 'feat/some-branch'
  assert_equal "$(name_of "$ed_id")" 'feat/some-branch'

  # Still found: ensure must NOT build a second one.
  ed three ensure
  sleep 0.3
  assert_equal "$(win_count)" 4
  assert_equal "$(marked)" "$ed_id"
}
