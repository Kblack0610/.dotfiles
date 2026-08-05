#!/usr/bin/env bats
# wind-down.sh — arm/fire a teardown of Claude's OWN tmux window.
#
# This file is the highest blast radius in the repo: it schedules `kill-window` and
# `kill-session` against a live server, and until now it had no tests at all. Not
# because nobody tried — the script had no source guard, so sourcing it fell into the
# verb dispatch, hit the usage arm and `exit 2`'d the runner. Untestable by
# construction. The guard came with this file.
#
# Everything here runs against the tmux STUB. That is not a compromise for this
# subject, it is the point: a test that drives a real server to check "does it kill
# the right window" has to kill a window to find out. The contract is entirely about
# WHICH target the script names, which calls.log records exactly.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic
  WIND_DOWN="$REPO_ROOT/.local/src/tmux/wind-down.sh"
  SPIN_DIR="$HOME/.agent/spin-down"
  export TMUX="fake" TMUX_PANE="%12"
}

# Run a verb as a subprocess, the way the Stop hook does.
wd() { run env TMUX="${TMUX:-}" TMUX_PANE="${TMUX_PANE:-}" bash "$WIND_DOWN" "$@"; }

mk_sentinel() { SENTINEL="$BATS_TEST_TMPDIR/s.request"; cat > "$SENTINEL"; }

# ── the source guard ─────────────────────────────────────────────────────────

@test "sourcing defines the functions without dispatching a verb" {
  # The guard this file's existence depends on. Without it, `source` reaches the case
  # statement with $1 unset and exits 2.
  run bash -c 'source "$1"; declare -F cmd_arm cmd_fire cmd_note_path >/dev/null && echo DEFINED' _ "$WIND_DOWN"
  assert_success
  assert_output 'DEFINED'
}

# ── arm ──────────────────────────────────────────────────────────────────────

@test "arm resolves the target against THIS pane, never the session's active window" {
  # THE 2026-06-18 BUG. Claude runs `arm` non-interactively and is usually NOT the
  # focused window, so a bare `display-message` returns whatever window the human is
  # looking at — and the hook then killed that innocent window. Every resolution must
  # carry `-t <pane>`.
  wd arm
  assert_success
  run grep -c 'display-message -p -t %12' "$NOTES_FIXTURE/calls.log"
  refute_output '0'
  # and no bare resolution slipped through
  run grep -E 'display-message -p (#|.#)' "$NOTES_FIXTURE/calls.log"
  assert_failure
}

@test "arm records the stable window_id, not the window index" {
  # `kill-window -t 3` is a different window after any renumber. @N never moves.
  STUB_WINDOW_ID='@7' STUB_LABEL='cockpit:3' wd arm
  assert_success
  local s; s="$(ls "$SPIN_DIR"/*.request | head -1)"
  assert_equal "$(grep '^target=' "$s" | cut -d= -f2-)" '@7'
  # the index-bearing label is recorded too, but only as a human string
  assert_equal "$(grep '^label=' "$s" | cut -d= -f2-)" 'cockpit:3'
}

@test "the sentinel is keyed by Claude session id so two windows cannot cross wires" {
  # Multiple Claude windows can run in the SAME project's tmux session. A single
  # shared "<proj>.request" let one session's Stop hook consume another's sentinel
  # and kill the wrong window.
  CLAUDE_CODE_SESSION_ID=aaa wd arm
  CLAUDE_CODE_SESSION_ID=bbb wd arm
  assert_equal "$(ls "$SPIN_DIR"/*.request | wc -l)" '2'
  run ls "$SPIN_DIR"
  assert_output --partial '__aaa.request'
  assert_output --partial '__bbb.request'
}

@test "arm outside tmux refuses and arms nothing" {
  TMUX="" TMUX_PANE="" wd arm
  assert_failure
  assert_output --partial 'not inside tmux'
  run bash -c 'ls "$1"/*.request 2>/dev/null | wc -l' _ "$SPIN_DIR"
  assert_output '0'
}

@test "arm rejects an unknown argument instead of guessing a scope" {
  wd arm --sessionn
  assert_failure
  assert_output --partial "unknown arg"
}

@test "--session widens the scope, and the default does not" {
  wd arm --session
  local s; s="$(ls "$SPIN_DIR"/*.request | head -1)"
  assert_equal "$(grep '^scope=' "$s" | cut -d= -f2-)" 'session'
  rm -f "$SPIN_DIR"/*.request
  wd arm
  s="$(ls "$SPIN_DIR"/*.request | head -1)"
  assert_equal "$(grep '^scope=' "$s" | cut -d= -f2-)" 'window'
}

# ── fire: the refusals ───────────────────────────────────────────────────────

@test "fire on a window that is already gone kills NOTHING" {
  # The single most important property in this file. Never fall back to a guessed
  # index when the recorded window_id has vanished — that is exactly what killed the
  # wrong window before.
  mk_sentinel <<'EOF'
scope=window
target=@7
session=cockpit
pane=%12
EOF
  printf '@1\n@2\n' > "$NOTES_FIXTURE/tmux.window_ids"   # @7 absent
  run bash "$WIND_DOWN" fire "$SENTINEL"
  assert_success
  assert_output --partial 'already gone'
  run grep -E 'kill-window|kill-session|run-shell' "$NOTES_FIXTURE/calls.log"
  assert_failure
}

@test "fire on a vanished session aborts without killing" {
  mk_sentinel <<'EOF'
scope=window
target=@7
session=ghost
EOF
  : > "$NOTES_FIXTURE/tmux.no-session"
  run bash "$WIND_DOWN" fire "$SENTINEL"
  assert_success
  assert_output --partial 'gone'
  run grep -E 'kill-window|kill-session|run-shell' "$NOTES_FIXTURE/calls.log"
  assert_failure
}

@test "fire refuses a sentinel with no target" {
  mk_sentinel <<'EOF'
scope=window
session=cockpit
EOF
  run bash "$WIND_DOWN" fire "$SENTINEL"
  assert_failure
  assert_output --partial 'no target'
}

@test "fire refuses a sentinel path that does not exist" {
  run bash "$WIND_DOWN" fire "$BATS_TEST_TMPDIR/nope.request"
  assert_failure
  assert_output --partial 'not found'
}

@test "fire with no argument at all refuses" {
  run bash "$WIND_DOWN" fire
  assert_failure
  assert_output --partial 'not found'
}

# ── fire: the kill it does schedule ──────────────────────────────────────────

@test "fire schedules kill-window against the stable window id" {
  mk_sentinel <<'EOF'
scope=window
target=@7
session=cockpit
pane=%12
EOF
  printf '@7\n' > "$NOTES_FIXTURE/tmux.window_ids"
  printf '@7 cockpit:3\n' > "$NOTES_FIXTURE/tmux.window_labels"
  run bash "$WIND_DOWN" fire "$SENTINEL"
  assert_success
  run grep 'run-shell' "$NOTES_FIXTURE/calls.log"
  assert_success
  assert_output --partial "kill-window -t '@7'"
  refute_output --partial 'kill-session'
}

@test "session scope schedules kill-session, and only then" {
  mk_sentinel <<'EOF'
scope=session
target=@7
session=cockpit
EOF
  run bash "$WIND_DOWN" fire "$SENTINEL"
  assert_success
  run grep 'run-shell' "$NOTES_FIXTURE/calls.log"
  assert_output --partial "kill-session -t 'cockpit'"
  refute_output --partial 'kill-window'
}

@test "the scheduled kill is backgrounded on the tmux server, not a child of the hook" {
  # `run-shell -b`. A nohup'd child of the Stop hook was reaped before its sleep
  # elapsed (macOS, no setsid), so the window simply stayed open.
  mk_sentinel <<'EOF'
scope=session
target=@7
session=cockpit
EOF
  run bash "$WIND_DOWN" fire "$SENTINEL"
  run grep 'run-shell' "$NOTES_FIXTURE/calls.log"
  assert_output --partial 'run-shell -b'
}

@test "a protected window keeps its note and is never closed" {
  # Window tags (Prefix+a). A pinned window is exactly the one a teardown must not take.
  mk_sentinel <<'EOF'
scope=window
target=@7
session=cockpit
pane=%12
EOF
  printf '@7\n' > "$NOTES_FIXTURE/tmux.window_ids"
  mkdir -p "$HOME/.local/bin"
  printf '#!/usr/bin/env bash\necho pinned\nexit 0\n' > "$HOME/.local/bin/tmux-tags"
  chmod +x "$HOME/.local/bin/tmux-tags"
  run bash "$WIND_DOWN" fire "$SENTINEL"
  assert_success
  assert_output --partial 'pinned'
  assert_output --partial 'left open'
  run grep -E 'kill-window|kill-session' "$NOTES_FIXTURE/calls.log"
  assert_failure
}

@test "a protected window IS still torn down under an explicit --session ask" {
  # The asymmetry is deliberate: the tag guards the automatic window close, while
  # `--session` is a wider, deliberate request from the human.
  mk_sentinel <<'EOF'
scope=session
target=@7
session=cockpit
EOF
  mkdir -p "$HOME/.local/bin"
  printf '#!/usr/bin/env bash\necho pinned\nexit 0\n' > "$HOME/.local/bin/tmux-tags"
  chmod +x "$HOME/.local/bin/tmux-tags"
  run bash "$WIND_DOWN" fire "$SENTINEL"
  run grep 'run-shell' "$NOTES_FIXTURE/calls.log"
  assert_output --partial "kill-session -t 'cockpit'"
}

# ── note-path ────────────────────────────────────────────────────────────────

@test "note-path lands on the agent runtime axis, not the notes vault" {
  # The wrap-up is agent runtime state. Writing it into ~/.notes would put an agent's
  # own scratch into the human's journal.
  run bash "$WIND_DOWN" note-path
  assert_success
  assert_output --partial "$HOME/.agent/sessions/"
  refute_output --partial '.notes'
  assert_output --regexp '[0-9]{4}-[0-9]{2}-[0-9]{2}-wind-down\.md$'
}

@test "note-path creates the directory it names" {
  run bash "$WIND_DOWN" note-path
  assert_success
  run test -d "$(dirname "$output")"
  assert_success
}

# ── dispatch ─────────────────────────────────────────────────────────────────

@test "an unknown verb is a usage error, not a silent no-op" {
  run bash "$WIND_DOWN" detonate
  assert_failure
  assert_output --partial 'usage:'
}
