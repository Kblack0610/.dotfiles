#!/usr/bin/env bats
# window-name.sh: the .zshrc precmd hook that names a tmux window after the git branch.
#
# It once ran `tmux rename-window "$name"` with no -t, which renames the session's ACTIVE
# window: a background shell's prompt renamed the window you were looking at, and a declared
# window (tmx's hub:watch) lost its name the moment it was selected, so tmx ensure built a
# duplicate on every Prefix+o. The library is sourced under bash with a stub tmux, so no tmux
# server is involved.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic
  source "$REPO_ROOT/.local/src/tmux/window-name.sh"
  declare -F _tmux_rename_window >/dev/null || fail "window-name.sh did not define _tmux_rename_window"
  export TMUX=/tmp/fake,1,0 TMUX_PANE=%42
  CALLS="$BATS_TEST_TMPDIR/tmux.calls"; : > "$CALLS"
  DECLARED=""
  tmux() {
    echo "$*" >> "$CALLS"
    [ "$1" = show-options ] && printf '%s' "$DECLARED"
    return 0
  }
  git() { [ "$1 $2" = "rev-parse --is-inside-work-tree" ] && return 0; echo feat/x; }
}

@test "renames its own window, by pane, not the session's active one" {
  _tmux_rename_window
  assert_equal "$(grep rename-window "$CALLS")" 'rename-window -t %42 feat/x'
}

@test "leaves a window tmx declared alone" {
  DECLARED=infra
  _tmux_rename_window
  run grep -c rename-window "$CALLS"
  assert_output 0
}

@test "does nothing outside tmux" {
  unset TMUX
  run _tmux_rename_window
  [ ! -s "$CALLS" ]
}
