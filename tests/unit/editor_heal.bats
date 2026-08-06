#!/usr/bin/env bats
# Tier 1: WHEN the toggle is allowed to type into the editor window.
#
# The self-heal exists for one situation: you quit the editor, the window fell through to its
# shell, and the next press should put you back in the editor rather than at a bare prompt.
# Everything else must leave the window alone.
#
# That distinction cannot be tested through a real tmux server, because the failure is a RACE.
# A freshly created pane runs `<editor>; exec <shell>` through sh, so for the first instants
# `pane_current_command` is the WRAPPING SHELL rather than the editor -- and a heal fired then
# types the editor's own name into the editor that is still starting up. It arrives as
# keystrokes, not a command, and leaves a scratch buffer containing "vim". That is a real
# observed failure, and reproducing it against a live server would mean racing a millisecond
# window on purpose.
#
# So the subject is driven with a RECORDING tmux, and the assertion is on the calls it made.
# send-keys either happened or it did not; there is no timing to lose.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic

  CALLS="$BATS_TEST_TMPDIR/tmux-calls"
  : > "$CALLS"

  EXISTING_EDITOR=""   # the editor window's id, or empty for "this session has none yet"
  PANE_CMD="zsh"       # what the editor window's pane is running

  # Faithful to real tmux in one way that matters: `list-windows` SUCCEEDS and prints a row
  # per window whether or not any carries the marker. An earlier version returned rc 1 for
  # "no editor", which real tmux never does -- and since the subject pipes list-windows into
  # awk under `pipefail`, that made the lookup itself look like a failure. The stub was
  # lying, and it took a red test with it.
  #
  # shellcheck disable=SC2317  # called indirectly, by the sourced subject
  tmux() {
    printf '%s\n' "$*" >> "$CALLS"
    case "$*" in
    # ORDER IS LOAD-BEARING. The marker lookup asks for '#{window_id} #{@editor}', which
    # CONTAINS '#{window_id}' -- so the bare window-id list must be matched second or every
    # _window_exists call would answer with the marker row instead.
    *list-windows*@editor*)
      printf '@1 \n@2 \n'
      [ -n "$EXISTING_EDITOR" ] && printf '%s 1\n' "$EXISTING_EDITOR"
      ;;
    *list-windows*'#{window_id}'*)
      printf '@1\n@2\n'
      [ -n "$EXISTING_EDITOR" ] && printf '%s\n' "$EXISTING_EDITOR"
      ;;
    *pane_current_command*) printf '%s\n' "$PANE_CMD" ;;
    *session_name*) printf 'work\n' ;;
    *new-window*) printf '@9\n' ;;
    *session_path*) printf '%s\n' "$SANDBOX" ;;
    *default-shell*) printf '/bin/sh\n' ;;
    *'#{window_id}'*) printf '@1\n' ;;
    *) : ;;
    esac
    return 0
  }

  TMUX=fake            # panel_in_tmux
  unset EDITOR_WINDOW_CMD EDITOR_ROOT
  # shellcheck source=/dev/null
  source "$EDITOR_SH"
}

sent_keys() { grep -q '^send-keys' "$CALLS"; }
made_window() { grep -q '^new-window' "$CALLS"; }

@test "the recording stub is actually wired up" {
  # Guards every assertion below: if the override were not reached, CALLS would stay empty
  # and "no send-keys" would be true for the wrong reason.
  declare -F cmd_toggle > /dev/null || fail "cmd_toggle is not defined -- the source seam failed"
  EXISTING_EDITOR="@5"
  cmd_toggle '@1'
  [ -s "$CALLS" ] || fail "no tmux calls recorded -- the override is not in effect"
}

# ── The bug ──────────────────────────────────────────────────────────────────

@test "a freshly CREATED editor window is never typed into" {
  # No editor yet, so this press creates one. The stub reports the pane as a shell, which is
  # exactly what the real race reports while the editor is still starting -- so if the create
  # path healed, it would fire here every single time.
  EXISTING_EDITOR=""
  PANE_CMD="zsh"
  cmd_toggle '@1'
  made_window || fail "the editor window was not created at all -- this test proves nothing"
  ! sent_keys || fail "typed into a window created moments ago: $(grep '^send-keys' "$CALLS")"
}

# ── The behaviour it must not cost us ────────────────────────────────────────

@test "an EXISTING editor window sitting at a shell IS healed" {
  # The whole reason the heal exists. Losing it would mean the toggle delivers you to a bare
  # prompt after you quit the editor.
  EXISTING_EDITOR="@5"
  PANE_CMD="zsh"
  cmd_toggle '@1'
  sent_keys || fail "an existing window at a shell was not re-entered"
  grep -q 'send-keys .*nvim' "$CALLS" || fail "healed with the wrong command: $(grep '^send-keys' "$CALLS")"
}

@test "an existing window already RUNNING the editor is left alone" {
  # Healing here is the same defect as healing on create: the keystrokes land in the editor.
  EXISTING_EDITOR="@5"
  PANE_CMD="nvim"
  cmd_toggle '@1'
  ! sent_keys || fail "typed into a window that was already running the editor"
}

@test "the heal is skipped for every shell dialect, not just zsh" {
  # _at_shell matches a list. If it only knew one name, a machine whose default-shell is
  # something else would silently stop healing -- and the container's IS /bin/sh.
  local s
  for s in sh bash zsh fish dash ksh; do
    : > "$CALLS"
    EXISTING_EDITOR="@5"
    PANE_CMD="$s"
    cmd_toggle '@1'
    sent_keys || fail "a pane running '$s' was not recognised as a shell, so it was not healed"
  done
}

# ── The default command ──────────────────────────────────────────────────────

@test "the editor opens the directory, not an empty buffer" {
  # `nvim` alone lands in a [No Name] scratch buffer, which is useless for an editor that is
  # supposed to BE the project. The dot is what makes neo-tree open the root tree.
  assert_equal "$EDITOR_WINDOW_CMD" 'nvim .'
}

@test "EDITOR_WINDOW_CMD is still overridable" {
  EDITOR_WINDOW_CMD='hx .'
  # shellcheck source=/dev/null
  source "$EDITOR_SH"
  assert_equal "$EDITOR_WINDOW_CMD" 'hx .'
}
