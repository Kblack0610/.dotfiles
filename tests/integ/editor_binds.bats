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
# rekey is exactly the kind of change that silently strands a key you use daily.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic
  load '../helpers/panel'
  EDITOR_REL='.local/src/tmux/editor.sh'
}

# Every root-table binding, as "<key><TAB><command>". Flags other than -n are not used by
# the binds under test, so this stays deliberately small rather than duplicating
# panel_conf_bindings' full parser.
#
# "Is this a table bind" is decided by WHERE -T sits, not by whether the line contains one.
# `bind -T tags i ...` binds INTO a table; `bind a switch-client -T tags` is an ordinary root
# bind whose COMMAND happens to name one. A naive !/-T/ filter drops the second, which made
# prefix+a look unbound and this file report that the editor had displaced it.
root_binds() {
  awk '
    /^[[:space:]]*(bind|bind-key)[[:space:]]/ {
      line = $0
      if (line ~ /^[[:space:]]*(bind|bind-key)([[:space:]]+-[A-Za-z]+)*[[:space:]]+-T[[:space:]]/) next
      n = split(line, F, /[[:space:]]+/)
      key = ""
      for (i = 2; i <= n; i++) {
        if (F[i] == "-n" || F[i] ~ /^-/) continue
        key = F[i]; break
      }
      cmd = line
      sub(/^[[:space:]]*(bind|bind-key)[[:space:]]+(-n[[:space:]]+)?[^[:space:]]+[[:space:]]+/, "", cmd)
      printf "%s\t%s\n", key, cmd
    }
  ' "$TMUX_CONF"
}

bind_for() { root_binds | awk -F'\t' -v k="$1" '$1 == k { print $2; exit }'; }

@test "the bind parser can actually see the config" {
  # Without this every assertion below passes vacuously the moment the awk stops matching:
  # "no bindings found" and "all bindings correct" print the same green.
  local n
  n="$(root_binds | grep -c .)"
  [ "$n" -ge 20 ] || fail "parsed only $n root bindings from .tmux.conf -- the parser broke"
  # And it must resolve a binding this file does not otherwise touch, so the parser is
  # proved against something stable rather than only against its own subject.
  assert_equal "$(bind_for C)" 'run-shell "$HOME/.local/src/tmux/cockpit.sh attach"'
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
  for k in e i I s o t p g C w m a f S A W r N H; do
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

# ── Mail, which this feature must NOT have touched ───────────────────────────

@test "mail is still on prefix+e, exactly where it was" {
  local mail
  mail="$(bind_for e)"
  [ -n "$mail" ] || fail "prefix+e is not bound -- mail was dropped"
  grep -qF 'aerc' <<< "$mail" || fail "prefix+e is bound to something that is not mail: $mail"
}

@test "prefix+e is bound exactly once" {
  # A duplicate bind is silent: tmux keeps the LAST one, so a stray editor bind on e
  # further down the file would beat mail with no diagnostic at load.
  local n
  n="$(root_binds | awk -F'\t' '$1 == "e"' | grep -c .)"
  [ "$n" -eq 1 ] || fail "prefix+e is bound $n times -- tmux silently keeps only the last"
}

@test "aerc is bound exactly once, and not on a second key" {
  local n
  n="$(grep -cE '^[[:space:]]*(bind|bind-key)[[:space:]].*aerc' "$TMUX_CONF")"
  [ "$n" -eq 1 ] || fail "aerc appears in $n bindings, expected 1"
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
  # cockpit_binds.bats' trick, scoped to one script: a verb named in a bind but absent from
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
