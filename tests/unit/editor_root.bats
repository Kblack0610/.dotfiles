#!/usr/bin/env bats
# Tier 1: editor.sh's pure decisions, sourced rather than run.
#
# Two things are worth pinning here and neither needs a tmux server.
#
# ROOT RESOLUTION is a four-step fallback chain, and every step of it answers "where does
# the editor open". Get the order wrong and the editor opens in $HOME instead of the
# project, which is the one thing the feature exists to do. The chain is only visible by
# driving each step in isolation, so each gets a test.
#
# THE RETURN-ID CHECK is what stops the toggle sending you to a stranger. Window ids are
# used precisely because indexes are renumbered by the insert (editor.sh's move-window -r),
# so a stale id must be REJECTED rather than followed.
#
# `tmux` here is a bats-local shell FUNCTION, not the sandbox's stub binary. Bash resolves
# functions before PATH, and the subject is sourced into this same shell, so the override
# reaches it -- which lets each test hand back a different canned answer without editing a
# stub shared by forty other files.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic

  # What the fake tmux reports, per format. Empty = "tmux knows nothing about that".
  STUB_SESSION_PATH=""
  STUB_PANE_PATH=""
  STUB_WINDOW_LIST=""

  STUB_DEFAULT_SHELL=""

  # shellcheck disable=SC2317  # called indirectly, by the sourced subject
  tmux() {
    case "$*" in
    *'#{session_path}'*) printf '%s\n' "$STUB_SESSION_PATH" ;;
    *'#{pane_current_path}'*) printf '%s\n' "$STUB_PANE_PATH" ;;
    *'#{window_id}'*) printf '%s\n' "$STUB_WINDOW_LIST" ;;
    *'default-shell'*) printf '%s\n' "$STUB_DEFAULT_SHELL" ;;
    *) : ;;
    esac
  }

  # EDITOR_ROOT is inherited from the environment by design (it is a ${VAR:-default}
  # tunable), so a stray value in the runner's env would silently win every assertion below.
  unset EDITOR_ROOT
  # shellcheck source=/dev/null
  source "$EDITOR_SH"
}

# ── The guard, before the assertions are trusted ─────────────────────────────

@test "the subject really was sourced, and the override really is in effect" {
  # Without this, a failed `source` or a shadowed function would make every test below
  # pass vacuously -- an empty answer and a correct empty answer read identically.
  declare -F _root_dir > /dev/null || fail "_root_dir is not defined -- the source seam did not work"
  declare -F _window_exists > /dev/null || fail "_window_exists is not defined"
  [ "$(tmux display-message -p '#{session_path}')" = "" ] \
    || fail "the tmux override is not being reached"
  STUB_SESSION_PATH=/etc
  [ "$(tmux display-message -p '#{session_path}')" = "/etc" ] \
    || fail "the tmux override does not answer per-format"
}

# ── The root chain, one step per test ────────────────────────────────────────

@test "root: EDITOR_ROOT wins over everything tmux says" {
  EDITOR_ROOT="$SANDBOX/pinned"
  STUB_SESSION_PATH="$SANDBOX"
  STUB_PANE_PATH="$SANDBOX"
  # Deliberately NOT created on disk: an explicit pin is an instruction, not a guess, so it
  # must not be second-guessed by a -d test the way the inferred answers are.
  assert_equal "$(_root_dir)" "$SANDBOX/pinned"
}

@test "root: the session's own directory is the answer when it has one" {
  mkdir -p "$SANDBOX/proj" "$SANDBOX/elsewhere"
  STUB_SESSION_PATH="$SANDBOX/proj"
  STUB_PANE_PATH="$SANDBOX/elsewhere"
  # The pane's path is the WRONG answer here -- it is wherever you happened to cd to -- so
  # this also asserts session_path is consulted first, not merely that it is consulted.
  assert_equal "$(_root_dir)" "$SANDBOX/proj"
}

@test "root: a session_path that no longer exists is skipped, not returned" {
  mkdir -p "$SANDBOX/elsewhere"
  STUB_SESSION_PATH="$SANDBOX/deleted-since"
  STUB_PANE_PATH="$SANDBOX/elsewhere"
  assert_equal "$(_root_dir)" "$SANDBOX/elsewhere"
}

@test "root: with no session_path, the pane's GIT ROOT beats the pane's own path" {
  mkdir -p "$SANDBOX/repo/deep/nested"
  git -C "$SANDBOX/repo" init -q
  STUB_SESSION_PATH=""
  STUB_PANE_PATH="$SANDBOX/repo/deep/nested"
  # `git -C` resolves symlinks; the sandbox lives under $BATS_TEST_TMPDIR which may be one.
  assert_equal "$(_root_dir)" "$(cd "$SANDBOX/repo" && pwd -P)"
}

@test "root: outside a repo, the pane's own path is the answer" {
  mkdir -p "$SANDBOX/loose"
  STUB_SESSION_PATH=""
  STUB_PANE_PATH="$SANDBOX/loose"
  assert_equal "$(_root_dir)" "$SANDBOX/loose"
}

@test "root: when tmux knows nothing at all, fall back to HOME" {
  STUB_SESSION_PATH=""
  STUB_PANE_PATH=""
  assert_equal "$(_root_dir)" "$HOME"
}

# ── The return-id check ──────────────────────────────────────────────────────

@test "a window id is accepted only when it is still in the live list" {
  # THREE ids, not two. With two, "matched the right one" and "matched whichever came
  # first" are the same observation, and the assertion would hold for a broken check.
  STUB_WINDOW_LIST="$(printf '@4\n@7\n@11\n')"
  _window_exists '@4' || fail "@4 is listed but was rejected"
  _window_exists '@7' || fail "@7 is listed but was rejected"
  _window_exists '@11' || fail "@11 is listed but was rejected"
  ! _window_exists '@9' || fail "@9 is NOT listed but was accepted -- a stale id would be followed"
  ! _window_exists '' || fail "an empty id was accepted"
}

# ── The fallback shell ───────────────────────────────────────────────────────
#
# This is what keeps the editor window ALIVE after you quit the editor. Get it wrong and
# the window command ends in `exec ""`, the window closes, and its place in the list is
# gone -- which is exactly what happened: $SHELL is UNSET under `run-shell`, so the obvious
# spelling was broken everywhere the keybinding actually runs.

@test "the shell comes from tmux's default-shell, not from \$SHELL" {
  STUB_DEFAULT_SHELL=/bin/sh
  SHELL=/nonexistent/zsh
  assert_equal "$(_fallback_shell)" /bin/sh
}

@test "an UNSET \$SHELL cannot produce an empty exec target" {
  # The live bug, pinned. run-shell hands the script an environment with no SHELL at all.
  STUB_DEFAULT_SHELL=""
  unset SHELL
  local s; s="$(_fallback_shell)"
  [ -n "$s" ] || fail "resolved to an EMPTY shell -- the window command would be 'exec \"\"'"
  [ -x "$s" ] || fail "resolved to something not executable: $s"
}

@test "a default-shell that does not exist is not believed" {
  STUB_DEFAULT_SHELL=/opt/removed-in-an-upgrade/zsh
  SHELL=/bin/sh
  assert_equal "$(_fallback_shell)" /bin/sh
}

@test "with nothing usable anywhere, it still names a real shell" {
  STUB_DEFAULT_SHELL=/nope/a
  SHELL=/nope/b
  local s; s="$(_fallback_shell)"
  [ -x "$s" ] || fail "last-resort shell is not executable: $s"
}

@test "the id match is exact, so @1 never matches @11" {
  # grep without -x would make a killed @1 resolve to the live @11 and silently send you to
  # a window you have never seen. This is the whole reason the check is anchored.
  STUB_WINDOW_LIST="$(printf '@11\n@12\n@13\n')"
  ! _window_exists '@1' || fail "@1 matched a prefix of @11 -- the id check is not anchored"
}
