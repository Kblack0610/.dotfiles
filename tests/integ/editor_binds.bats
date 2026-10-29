#!/usr/bin/env bats
# Tier 2: the editor's BINDINGS, read out of .tmux.conf as text.
#
# A keybinding has no other test. tmux does not validate that a bound path exists -- it
# registers the bind happily and the first symptom is a key that does nothing under a
# finger. So the bind is checked the same way panel_conformance.bats checks the popups:
# as data, cross-referenced against the filesystem.
#
# The editor deliberately took a key nothing else wanted (Space, whose stock binding is
# next-layout), so no existing surface was rebound to make room. That is worth ASSERTING
# rather than trusting: an earlier revision of this feature moved mail off prefix+e, and a
# rekey is exactly the kind of change that silently strands a key you use daily. e is the
# infra board now (mail retired 2026-10-28), and is pinned here for the same reason.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic
  load '../helpers/panel'
  EDITOR_REL='.local/src/tmux/editor.sh'
}

# root_binds / bind_for live in helpers/panel.bash, shared with watch_bind.bats.

@test "the bind parser can actually see the config" {
  # Without this every assertion below passes vacuously the moment the awk stops matching:
  # "no bindings found" and "all bindings correct" print the same green.
  local n
  n="$(root_binds | grep -c .)"
  [ "$n" -ge 20 ] || fail "parsed only $n root bindings from .tmux.conf -- the parser broke"
  # And it must resolve a binding this file does not otherwise touch, so the parser is
  # proved against something stable rather than only against its own subject.
  assert_equal "$(bind_for C-g)" 'display-popup -E -w 100% -h 100% "$HOME/.local/src/tmux/fleet.sh"'
}

# ── The editor keys ──────────────────────────────────────────────────────────

@test "prefix+Space toggles the editor" {
  assert_equal "$(bind_for Space)" "run-shell \"\$HOME/$EDITOR_REL toggle '#{window_id}'\""
}

@test "the bind hands the editor the window the key was pressed in" {
  # Not cosmetic. run-shell leaves TMUX_PANE EMPTY, so a toggle with no argument reads
  # tmux's current window -- which ensure's move-window has already changed by the time the
  # second press asks, and the toggle-back then goes to the wrong window. Dropping
  # '#{window_id}' from the bind reintroduces that silently, since the verb still runs.
  grep -qF "toggle '#{window_id}'" <<< "$(bind_for Space)" \
    || fail "the editor bind does not pass '#{window_id}': $(bind_for Space)"
}

@test "the editor is bound on exactly one key" {
  # Two keys for one action drift: the second gets edited and the first does not. If a
  # second key is ever wanted, this number is the deliberate place to change it.
  local n
  n="$(root_binds | awk -F'\t' '$2 ~ /editor\.sh/' | grep -c .)"
  [ "$n" -eq 1 ] || fail "editor.sh is bound to $n keys, expected 1"
}

@test "the editor takes NO key from any existing surface" {
  # Space's stock binding is next-layout, which is tmux's own and not a surface in this
  # repo. Every other key in .tmux.conf must still point where it did.
  local k
  for k in e i I o p g w m a f S A W r N H; do
    [ -n "$(bind_for "$k")" ] || fail "prefix+$k lost its binding -- the editor displaced something"
  done
}

@test "the editor is a window, never a display-popup" {
  # A popup is torn down by the keypress that opens it, so there would be nothing to toggle
  # back TO -- and CONVENTIONS.md:193 rules out load-bearing popups anyway. This is also
  # what keeps editor.sh correctly ABSENT from tests/panels.manifest, whose closure
  # assertion covers popups only.
  run grep -nE '^[[:space:]]*(bind|bind-key)[[:space:]].*editor\.sh.*display-popup' "$TMUX_CONF"
  assert_failure
  run grep -cF "$EDITOR_REL" "$PANEL_MANIFEST"
  assert_output '0'
}

# ── prefix+e, which this feature must NOT have touched ───────────────────────

@test "infra is still on prefix+e, exactly where it was" {
  local infra
  infra="$(bind_for e)"
  [ -n "$infra" ] || fail "prefix+e is not bound -- infra was dropped"
  grep -qF 'hub:infra' <<< "$infra" || fail "prefix+e is bound to something that is not infra: $infra"
}

@test "prefix+e is bound exactly once" {
  # A duplicate bind is silent: tmux keeps the LAST one, so a stray editor bind on e
  # further down the file would beat infra with no diagnostic at load.
  local n
  n="$(root_binds | awk -F'\t' '$1 == "e"' | grep -c .)"
  [ "$n" -eq 1 ] || fail "prefix+e is bound $n times -- tmux silently keeps only the last"
}

@test "the editor claimed no Alt key, so nvim and the shell still see them" {
  # A root-table (-n) bind is swallowed by tmux everywhere. The pane nav owns M-hjkl/HJKL
  # by design; the editor must not have quietly added to that set.
  local extra
  extra="$(grep -E '^[[:space:]]*bind(-key)? -n ' "$TMUX_CONF" \
    | grep -vE ' -n M-[hjklHJKL] ' | grep -c . || true)"
  [ "$extra" -eq 0 ] || fail "$extra unexpected no-prefix binding(s) -- a global key was taken"
}

# ── What the binds point at ──────────────────────────────────────────────────

@test "the bound script exists, is executable, and is tracked" {
  # The check that catches "renamed the script, forgot the bind". Stats a file rather than
  # running anything, so it passes on a CI runner with no tmux installed.
  [ -f "$REPO_ROOT/$EDITOR_REL" ] || fail "$EDITOR_REL does not exist"
  [ -x "$REPO_ROOT/$EDITOR_REL" ] || fail "$EDITOR_REL is not executable"
  run git -C "$REPO_ROOT" ls-files --error-unmatch "$EDITOR_REL"
  assert_success
}

@test "every verb the binds invoke has a dispatch arm" {
  # Two lists, comm'd: a verb named in a bind but absent from
  # the case block fails silently inside run-shell, where nobody sees the error.
  local invoked dispatched v
  invoked="$(grep -oE "editor\.sh [a-z-]+" "$TMUX_CONF" | awk '{print $2}' | sort -u)"
  dispatched="$(sed -n '/^case "\${1:-}" in$/,/^esac$/p' "$REPO_ROOT/$EDITOR_REL" \
    | grep -oE '^[a-z-]+\)' | tr -d ')' | sort -u)"
  [ -n "$invoked" ] || fail "no editor.sh verbs found in .tmux.conf -- the grep broke"
  [ -n "$dispatched" ] || fail "no dispatch arms found in $EDITOR_REL -- the sed broke"
  for v in $invoked; do
    grep -qx "$v" <<< "$dispatched" || fail "bind invokes '$v' but editor.sh has no arm for it"
  done
}
