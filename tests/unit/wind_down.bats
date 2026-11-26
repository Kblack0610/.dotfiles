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
  run bash -c 'source "$1"; declare -F cmd_arm cmd_fire cmd_note >/dev/null && echo DEFINED' _ "$WIND_DOWN"
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
  assert_output --partial 'aaa.request'
  assert_output --partial 'bbb.request'
  refute_output --partial '__'
}

@test "the sentinel name does not depend on the cwd arm runs from" {
  # 2026-11-08: arm ran from a cwd outside the project and wrote "_unscoped__<sid>.request"
  # while the Stop hook looked for "<project>__<sid>.request"; the window never closed.
  CLAUDE_CODE_SESSION_ID="$SID_A" CLAUDE_PROJECT_DIR=/nowhere/outside wd arm
  assert_success
  [ -f "$SPIN_DIR/$SID_A.request" ] || fail "sentinel is not <sid>.request: $(ls "$SPIN_DIR")"
  assert_equal "$(ls "$SPIN_DIR"/*.request | wc -l)" '1'
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

@test "fire schedules the window close against the stable window id" {
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
  assert_output --partial "close.sh window '@7'"
  refute_output --partial 'close.sh session'
}

@test "fire saves the pane's whole history on the kill's server before the close, and no empty file when there is none" {
  export WIND_DOWN_HISTORY_DIR="$BATS_TEST_TMPDIR/hist"
  mk_sentinel <<'EOF'
scope=window
target=@7
session=cockpit
pane=%12
sid=abc-123
EOF
  printf '@7\n' > "$NOTES_FIXTURE/tmux.window_ids"
  printf '@7 cockpit:3\n' > "$NOTES_FIXTURE/tmux.window_labels"
  printf 'the conversation\n> a draft never sent\n' > "$NOTES_FIXTURE/tmux.capture.%12"
  run bash "$WIND_DOWN" fire "$SENTINEL"
  assert_success
  run grep -h 'a draft never sent' "$WIND_DOWN_HISTORY_DIR"/*-cockpit_3-abc-123.txt
  assert_success
  run grep -n 'capture-pane' "$NOTES_FIXTURE/calls.log"
  assert_output --partial '-S - -t %12'
  # Nothing captured (the pane printed nothing): no file left behind.
  rm -f "$WIND_DOWN_HISTORY_DIR"/* "$NOTES_FIXTURE/tmux.capture.%12"
  run bash "$WIND_DOWN" fire "$SENTINEL"
  assert_success
  [ -z "$(ls -A "$WIND_DOWN_HISTORY_DIR")" ]
}

@test "session scope schedules the session close through tmux-close, and only then" {
  mk_sentinel <<'EOF'
scope=session
target=@7
session=cockpit
EOF
  run bash "$WIND_DOWN" fire "$SENTINEL"
  assert_success
  run grep 'run-shell' "$NOTES_FIXTURE/calls.log"
  # tmux-close gets the window too: it closes only that when cockpit is a world session.
  assert_output --partial "close.sh session 'cockpit' --window '@7'"
  refute_output --partial 'close.sh window'
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
  # From /, not the hook's cwd: a job started in the worktree holds it against the reap.
  assert_output --partial 'run-shell -b -c /'
}

@test "a protected window keeps its note and is never closed" {
  # Window tags (Prefix+t). A pinned window is exactly the one a teardown must not take.
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
  assert_output --partial "close.sh session 'cockpit'"
}

# ── note ─────────────────────────────────────────────────────────────────────

@test "note appends the draft to today's note on the agent runtime axis, never over another session's block (ar-3365)" {
  # The wrap-up is agent runtime state: in ~/.notes it would put an agent's scratch into the
  # human's journal. Every session of the day shares the file, so a whole-file write cut it.
  # The first draft has no final newline: the next block still starts on its own line.
  printf '# Session wrap-up - one' > "$BATS_TEST_TMPDIR/a.md"
  printf '# Session wrap-up - two\n' > "$BATS_TEST_TMPDIR/b.md"
  run bash "$WIND_DOWN" note "$BATS_TEST_TMPDIR/a.md"
  assert_success
  assert_output --regexp "^$HOME/\.agent/sessions/[^/]+/[0-9]{4}-[0-9]{2}-[0-9]{2}-wind-down\.md$"
  local note="$output"
  run bash "$WIND_DOWN" note "$BATS_TEST_TMPDIR/b.md"
  assert_success
  run cat "$note"
  assert_output "$(printf '# Session wrap-up - one\n\n# Session wrap-up - two')"
}

@test "note with no draft, or an empty one, refuses and writes nothing" {
  : > "$BATS_TEST_TMPDIR/empty.md"
  run bash "$WIND_DOWN" note "$BATS_TEST_TMPDIR/empty.md"
  assert_failure 2
  run bash "$WIND_DOWN" note
  assert_failure 2
  assert [ -z "$(find "$HOME/.agent/sessions" -name '*-wind-down.md' 2>/dev/null)" ]
}

# ── the worktree hand-off (wt reap) ──────────────────────────────────────────
#
# One session per worktree means the worktree should go when the session does. wind-down
# does NOT decide whether that is safe -- `wt reap` owns that policy and refuses anything
# dirty, unpushed, or still holding a live session. All wind-down owes is: record the right
# path at arm time, and run the reap strictly AFTER the kill.

# A real linked worktree under $WT_ROOT, plus the `wt` that fire gates on.
mk_worktree() {
  export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@e.com
  export GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@e.com
  git init --quiet -b main "$HOME/repo"
  printf 'x\n' > "$HOME/repo/f.txt"
  git -C "$HOME/repo" add f.txt
  git -C "$HOME/repo" commit --quiet -m seed
  mkdir -p "$HOME/.worktrees"
  git -C "$HOME/repo" worktree add --quiet "$HOME/.worktrees/repo-agent-1" -b agent-1 main
  mkdir -p "$HOME/.local/bin"
  printf '#!/bin/sh\necho "wt $*"\n' > "$HOME/.local/bin/wt"
  chmod +x "$HOME/.local/bin/wt"
}

@test "arm records the worktree ROOT when the pane sits inside one" {
  mk_worktree
  # A pane one directory DOWN is still in the worktree, but `git worktree remove` on a
  # subdirectory is simply an error -- so what gets recorded must be --show-toplevel.
  mkdir -p "$HOME/.worktrees/repo-agent-1/tests"
  STUB_PANE_PATH="$HOME/.worktrees/repo-agent-1/tests" wd arm
  assert_success
  local s; s="$(ls "$SPIN_DIR"/*.request | head -1)"
  run grep '^worktree=' "$s"
  assert_output "worktree=$HOME/.worktrees/repo-agent-1"
}

@test "arm records NO worktree for an ordinary checkout" {
  # The guard that keeps a main checkout away from `reap`. Winding down a normal session
  # must not put its repo root in the sentinel at all.
  mk_worktree
  STUB_PANE_PATH="$HOME/repo" wd arm
  assert_success
  local s; s="$(ls "$SPIN_DIR"/*.request | head -1)"
  run grep '^worktree=' "$s"
  assert_output 'worktree='
}

@test "fire runs the reap AFTER the kill, in the same backgrounded chain" {
  # ORDER IS THE WHOLE POINT. `wt reap` refuses while a tmux session for the worktree is
  # live, which is the correct answer right up until this window is gone. Reaping first
  # would always refuse; reaping in a separate process would race the kill.
  mk_worktree
  mk_sentinel <<EOF
scope=session
target=@7
session=repo-agent-1
worktree=$HOME/.worktrees/repo-agent-1
EOF
  run bash "$WIND_DOWN" fire "$SENTINEL"
  assert_success
  run grep 'run-shell' "$NOTES_FIXTURE/calls.log"
  assert_success
  assert_output --partial 'run-shell -b'
  assert_output --partial "wt reap --after-kill '$HOME/.worktrees/repo-agent-1'"
  # The close must appear BEFORE the reap in the chain, not after it.
  local chain="$output"
  [ "${chain%%close.sh session*}" != "$chain" ] || fail "no kill in the chain at all"
  local before_kill="${chain%%close.sh session*}"
  case "$before_kill" in
    *"wt reap"*) fail "the reap is scheduled BEFORE the kill -- it would always refuse" ;;
  esac
}

@test "fire schedules no reap when the session was not in a worktree" {
  mk_worktree
  mk_sentinel <<'EOF'
scope=session
target=@7
session=cockpit
worktree=
EOF
  run bash "$WIND_DOWN" fire "$SENTINEL"
  assert_success
  run grep 'run-shell' "$NOTES_FIXTURE/calls.log"
  refute_output --partial 'wt reap'
}

@test "fire schedules no reap when the recorded worktree is already gone" {
  mk_worktree
  mk_sentinel <<EOF
scope=session
target=@7
session=repo-agent-1
worktree=$HOME/.worktrees/vanished
EOF
  run bash "$WIND_DOWN" fire "$SENTINEL"
  assert_success
  run grep 'run-shell' "$NOTES_FIXTURE/calls.log"
  refute_output --partial 'wt reap'
}

# -- the session scratchpad --
#
# /tmp is a tmpfs on this fleet, so a scratchpad left behind is RAM that never comes back.
# fire removes THIS session's dir after the kill; agentctl-tmp-gc reclaims the dirs of sessions
# that never wound down.

SID_A="11111111-2222-3333-4444-555555555555"

@test "armed from a cwd outside the project, the Stop hook in the project still finds it" {
  # The 2026-11-08 failure end to end: arm resolves one project, the hook another.
  CLAUDE_CODE_SESSION_ID="$SID_A" CLAUDE_PROJECT_DIR=/nowhere/outside wd arm
  assert_success
  run env -u CLAUDE_CODE_SESSION_ID CLAUDE_PROJECT_DIR="$REPO_ROOT" \
    bash "$REPO_ROOT/.claude/hooks/stop-post.d/95-wind-down.sh" <<<"{\"session_id\":\"$SID_A\"}"
  assert_success
  [ ! -e "$SPIN_DIR/$SID_A.request" ] || fail "the hook did not consume the sentinel: $(ls "$SPIN_DIR")"
  [ -e "$SPIN_DIR/$SID_A.fired" ] || fail "the hook did not fire it: $(ls "$SPIN_DIR")"
}

@test "an inherited FAIL result of another session does not defer; this session's own does" {
  # The outer Stop hook exports its CI_RESULT_FILE to the suite it runs (2026-11-09).
  printf 'status=FAIL\n' > "$BATS_TEST_TMPDIR/ci-result-outer.txt"
  printf 'status=FAIL\n' > "$BATS_TEST_TMPDIR/ci-result-$SID_A.txt"
  CLAUDE_CODE_SESSION_ID="$SID_A" CLAUDE_PROJECT_DIR="$REPO_ROOT" wd arm
  run env CI_RESULT_FILE="$BATS_TEST_TMPDIR/ci-result-$SID_A.txt" CLAUDE_PROJECT_DIR="$REPO_ROOT" \
    bash "$REPO_ROOT/.claude/hooks/stop-post.d/95-wind-down.sh" <<<"{\"session_id\":\"$SID_A\"}"
  assert_output --partial 'wind-down deferred'
  [ -e "$SPIN_DIR/$SID_A.request" ] || fail "its own FAIL did not keep the request"
  run env CI_RESULT_FILE="$BATS_TEST_TMPDIR/ci-result-outer.txt" CLAUDE_PROJECT_DIR="$REPO_ROOT" \
    bash "$REPO_ROOT/.claude/hooks/stop-post.d/95-wind-down.sh" <<<"{\"session_id\":\"$SID_A\"}"
  refute_output --partial 'wind-down deferred'
  [ -e "$SPIN_DIR/$SID_A.fired" ] || fail "another session's FAIL held it: $(ls "$SPIN_DIR")"
}

@test "arm records the Claude session id, and an empty one outside Claude" {
  CLAUDE_CODE_SESSION_ID="$SID_A" wd arm
  assert_success
  run grep '^sid=' "$SPIN_DIR/$SID_A.request"
  assert_output "sid=$SID_A"

  rm -f "$SPIN_DIR"/*.request
  CLAUDE_CODE_SESSION_ID='' wd arm
  assert_success
  run grep '^sid=' "$SPIN_DIR"/*.request
  assert_output 'sid='
}

@test "fire removes the session scratchpad AFTER the kill, in the same chain" {
  mk_sentinel <<EOF
scope=session
target=@7
session=cockpit
sid=$SID_A
EOF
  CLAUDE_SCRATCH_ROOT="$HOME/scratch" run bash "$WIND_DOWN" fire "$SENTINEL"
  assert_success
  run grep 'run-shell' "$NOTES_FIXTURE/calls.log"
  assert_output --partial "rm -rf -- '$HOME/scratch'/*/'$SID_A'"
  local before_kill="${output%%close.sh session*}"
  case "$before_kill" in
    *"rm -rf"*) fail "the scratchpad goes BEFORE the kill -- Claude would lose it mid-turn" ;;
  esac
}

@test "fire removes no scratchpad for an empty or malformed session id" {
  # The id lands inside a glob. Anything that is not exactly a UUID could widen it.
  local bad
  for bad in '' '*' '../x' "$SID_A extra"; do
    : > "$NOTES_FIXTURE/calls.log"
    mk_sentinel <<EOF
scope=session
target=@7
session=cockpit
sid=$bad
EOF
    run bash "$WIND_DOWN" fire "$SENTINEL"
    assert_success
    run grep 'run-shell' "$NOTES_FIXTURE/calls.log"
    refute_output --partial 'rm -rf'
  done
}

@test "fire sets this session's own pending asks to reopen it on the answer, and no other ask" {
  # 2026-11-18: a session closed over its pending ask with resume empty, so the answer reopened nothing.
  local asks="$HOME/.agent/asks/demo"
  mkdir -p "$asks"
  printf 'id: mine\nstatus: pending\nclaude_session: %s\n' "$SID_A" > "$asks/mine.md"
  printf 'id: joined\nstatus: pending\nclaude_session: %s\nclaude_session: %s\n' "$SID_B" "$SID_A" > "$asks/joined.md"
  printf 'id: other\nstatus: pending\nclaude_session: %s\n' "$SID_B" > "$asks/other.md"
  printf 'id: done\nstatus: answered\nclaude_session: %s\n' "$SID_A" > "$asks/done.md"
  printf 'id: own\nstatus: pending\nclaude_session: %s\nresume: run: elsewhere\n' "$SID_A" > "$asks/own.md"
  mk_sentinel <<EOF
scope=window
target=@7
session=cockpit
sid=$SID_A
EOF
  printf '@7\n' > "$NOTES_FIXTURE/tmux.window_ids"
  run bash "$WIND_DOWN" fire "$SENTINEL"
  assert_success
  grep -qx 'resume: run: agent-ask reopen' "$asks/mine.md"
  grep -qxF "reopen: $SID_A" "$asks/joined.md"
  run grep -E '^(resume|reopen):' "$asks/other.md" "$asks/done.md"
  assert_failure
  run grep '^resume:' "$asks/own.md"
  assert_output 'resume: run: elsewhere'
  run grep 'run-shell' "$NOTES_FIXTURE/calls.log"
  assert_output --partial "window '@7'"
  # An ask with its own resume keeps it, and that is no refusal: the answer runs it headless.
  run grep -s 'fire: ask own not set to reopen' "$SPIN_DIR/fire.log"
  assert_failure
}

@test "fire sets no ask to reopen for a malformed session id" {
  mkdir -p "$HOME/.agent/asks/demo"
  printf 'id: mine\nstatus: pending\nclaude_session: not-a-sid\n' > "$HOME/.agent/asks/demo/mine.md"
  mk_sentinel <<'EOF'
scope=window
target=@7
session=cockpit
sid=not-a-sid
EOF
  printf '@7\n' > "$NOTES_FIXTURE/tmux.window_ids"
  run bash "$WIND_DOWN" fire "$SENTINEL"
  assert_success
  run grep -E '^(resume|reopen):' "$HOME/.agent/asks/demo/mine.md"
  assert_failure
}

# -- disarm (the UserPromptSubmit hook) --
# A new prompt means the work is not over, so a teardown that failing Stop checks
# deferred must not fire at the next clean Stop.

SID_A=11111111-2222-3333-4444-555555555555
SID_B=66666666-7777-8888-9999-aaaaaaaaaaaa

disarm() { run bash -c 'printf "%s" "$2" | env -u CLAUDE_CODE_SESSION_ID bash "$1" disarm' _ "$WIND_DOWN" "$1"; }

@test "disarm removes this session's sentinel, keyed by sid alone or by an older project prefix" {
  mkdir -p "$SPIN_DIR"
  touch "$SPIN_DIR/$SID_A.request" "$SPIN_DIR/dotfiles__$SID_A.request" "$SPIN_DIR/elsewhere__$SID_A.request"
  disarm "{\"session_id\":\"$SID_A\"}"
  assert_success
  assert_output --partial 'wind-down disarmed'
  [ ! -e "$SPIN_DIR/$SID_A.request" ] || fail "own sentinel survived"
  [ ! -e "$SPIN_DIR/dotfiles__$SID_A.request" ] || fail "own sentinel survived"
  [ ! -e "$SPIN_DIR/elsewhere__$SID_A.request" ] || fail "sentinel armed from another dir survived"
}

@test "disarm leaves another session's sentinel and the legacy project-only one" {
  mkdir -p "$SPIN_DIR"
  touch "$SPIN_DIR/$SID_B.request" "$SPIN_DIR/dotfiles.request"
  disarm "{\"session_id\":\"$SID_A\"}"
  assert_success
  assert_output ''
  [ -e "$SPIN_DIR/$SID_B.request" ] || fail "removed another session's sentinel"
  [ -e "$SPIN_DIR/dotfiles.request" ] || fail "removed the legacy sentinel"
}

@test "disarm after a fired teardown says nothing is armed and clears the marker" {
  mkdir -p "$SPIN_DIR"
  touch "$SPIN_DIR/$SID_A.fired" "$SPIN_DIR/$SID_B.fired"
  disarm "{\"session_id\":\"$SID_A\"}"
  assert_success
  assert_output --partial 'wind-down is not armed'
  assert_output --partial "spent at a Stop"
  [ ! -e "$SPIN_DIR/$SID_A.fired" ] || fail "own fired marker survived"
  [ -e "$SPIN_DIR/$SID_B.fired" ] || fail "removed another session's fired marker"
  disarm "{\"session_id\":\"$SID_A\"}"
  assert_output ''
}

@test "disarm with a fresh arm over a fired one reports the disarm" {
  mkdir -p "$SPIN_DIR"
  touch "$SPIN_DIR/$SID_A.fired" "$SPIN_DIR/$SID_A.request"
  disarm "{\"session_id\":\"$SID_A\"}"
  assert_success
  assert_output --partial 'wind-down disarmed'
  refute_output --partial 'not armed'
  [ ! -e "$SPIN_DIR/$SID_A.fired" ] && [ ! -e "$SPIN_DIR/$SID_A.request" ] || fail "a marker survived"
}

@test "disarm with nothing armed is silent and succeeds" {
  disarm "{\"session_id\":\"$SID_A\"}"
  assert_success
  assert_output ''
}

@test "disarm with a malformed session id removes nothing" {
  mkdir -p "$SPIN_DIR"
  touch "$SPIN_DIR/x.request" "$SPIN_DIR/$SID_A.request"
  disarm '{"session_id":"*"}'
  assert_success
  [ -e "$SPIN_DIR/x.request" ] || fail "a glob id reached rm"
  [ -e "$SPIN_DIR/$SID_A.request" ] || fail "a glob id reached rm"
}

@test "disarm falls back to CLAUDE_CODE_SESSION_ID when stdin has no payload" {
  mkdir -p "$SPIN_DIR"
  touch "$SPIN_DIR/$SID_A.request"
  run env CLAUDE_CODE_SESSION_ID="$SID_A" bash "$WIND_DOWN" disarm </dev/null
  assert_success
  [ ! -e "$SPIN_DIR/$SID_A.request" ] || fail "env fallback did not disarm"
}

# ── dispatch ─────────────────────────────────────────────────────────────────

@test "an unknown verb is a usage error, not a silent no-op" {
  run bash "$WIND_DOWN" detonate
  assert_failure
  assert_output --partial 'usage:'
}

# -- close (fleet-shepherd's close of a session that was told to close and did not) --

@test "close resolves the pane on the named server, writes the sentinel as fired, and schedules the window close" {
  printf '@7\n' > "$NOTES_FIXTURE/tmux.window_ids"
  printf '@7 cockpit:3\n' > "$NOTES_FIXTURE/tmux.window_labels"
  sid=0b0e8a52-1111-4222-8333-444455556666
  STUB_WINDOW_ID='@7' wd close --server lab --pane %31 --sid "$sid"
  assert_success
  # Resolved against that pane on that server, not the shepherd's own pane or server.
  grep -q 'tmux -L lab display-message -p -t %31' "$NOTES_FIXTURE/calls.log"
  # Written as .fired, so fleet-dispatch restore does not bring the conversation back.
  [ -f "$SPIN_DIR/$sid.fired" ] && [ ! -e "$SPIN_DIR/$sid.request" ]
  grep -qx 'target=@7' "$SPIN_DIR/$sid.fired"
  grep -qx 'pane=%31' "$SPIN_DIR/$sid.fired"
  grep -qx "sid=$sid" "$SPIN_DIR/$sid.fired"
  run grep 'run-shell' "$NOTES_FIXTURE/calls.log"
  assert_output --partial "close.sh window '@7'"
}

@test "close refuses a missing pane or a malformed session id and touches nothing" {
  for args in "--server lab --sid 0b0e8a52-1111-4222-8333-444455556666" "--server lab --pane %31 --sid ../x" "--server lab --pane 31 --sid 0b0e8a52-1111-4222-8333-444455556666"; do
    # shellcheck disable=SC2086
    wd close $args
    assert_failure 2
  done
  wd close --bogus
  assert_failure 2
  [ ! -e "$NOTES_FIXTURE/calls.log" ] || ! grep -q 'run-shell' "$NOTES_FIXTURE/calls.log"
  [ -z "$(ls -A "$SPIN_DIR" 2>/dev/null)" ]
}

@test "close of a protected window or one already gone fails and leaves no fired marker" {
  # fire returns 0 on these no-op paths; the shepherd must not log them as closed, and restore
  # must not skip a conversation whose window is still open.
  sid=0b0e8a52-1111-4222-8333-444455556666
  printf '@7\n' > "$NOTES_FIXTURE/tmux.window_ids"
  mkdir -p "$HOME/.local/bin"
  printf '#!/usr/bin/env bash\necho pinned\nexit 0\n' > "$HOME/.local/bin/tmux-tags"
  chmod +x "$HOME/.local/bin/tmux-tags"
  STUB_WINDOW_ID='@7' wd close --server lab --pane %31 --sid "$sid"
  assert_failure 1
  [ ! -e "$SPIN_DIR/$sid.fired" ]
  rm "$HOME/.local/bin/tmux-tags" "$NOTES_FIXTURE/tmux.window_ids"
  STUB_WINDOW_ID='@7' wd close --server lab --pane %31 --sid "$sid"
  assert_failure 1
  [ ! -e "$SPIN_DIR/$sid.fired" ]
  run grep 'run-shell' "$NOTES_FIXTURE/calls.log"
  assert_failure
}

# --- a Claude background session (claude daemon, no tmux) ---
#
# 2026-11-19 (ar-3885): arm refused "not inside tmux" in a background session. The daemon's
# TMUX_PANE is the pane of the foreground claude that spawned it, a different live session, so
# the session ends itself with `claude stop <job>` and no pane is ever killed.

# Test-local claude and setsid: claude only logs its call; setsid only logs the chain it was
# handed, so nothing is detached or stopped for real.
bg_stubs() {
  local bin="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$bin"
  printf '#!/bin/sh\necho "claude $*" >> "$NOTES_FIXTURE/calls.log"\n' > "$bin/claude"
  printf '#!/bin/sh\nprintf "setsid %%s\\n" "$*" >> "$NOTES_FIXTURE/calls.log"\n' > "$bin/setsid"
  chmod +x "$bin/claude" "$bin/setsid"
  export PATH="$bin:$PATH"
}

# The daemon's job dir for <sid>, as `claude daemon` writes it; JOB is its path.
mk_job() {
  JOB="$HOME/.claude-x/jobs/72e3cb7a"
  mkdir -p "$JOB"
  printf '{"state":"working","sessionId":"%s","daemonShort":"72e3cb7a"}\n' "$1" > "$JOB/state.json"
}

# arm as a background session: KIND=bg, this sid, the job dir; extra env as leading args.
bg_arm() { run env CLAUDE_CODE_SESSION_KIND=bg CLAUDE_CODE_SESSION_ID="$SID_A" CLAUDE_JOB_DIR="$JOB" "$@"; }

@test "arm in a background session records its daemon job and touches no tmux" {
  bg_stubs; mk_job "$SID_A"
  bg_arm TMUX="" TMUX_PANE="%29" bash "$WIND_DOWN" arm
  assert_success
  assert_output --partial "background session '72e3cb7a' will stop"
  run grep -E '^(scope|target|sid)=' "$SPIN_DIR/$SID_A.request"
  assert_output "$(printf 'scope=bg\ntarget=72e3cb7a\nsid=%s' "$SID_A")"
  run grep '^tmux ' "$NOTES_FIXTURE/calls.log"
  assert_failure
}

@test "arm in a background session with CLAUDE_CODE_SESSION_KIND unset still arms the stop (ar-4749)" {
  # 2026-11-23 job 72e3cb7a ran with KIND unset and JOB_DIR set: its own job state is the proof.
  bg_stubs; mk_job "$SID_A"
  run env -u CLAUDE_CODE_SESSION_KIND CLAUDE_CODE_SESSION_ID="$SID_A" CLAUDE_JOB_DIR="$JOB" TMUX="" TMUX_PANE="" bash "$WIND_DOWN" arm
  assert_success
  assert_output --partial "background session '72e3cb7a' will stop"
  run grep -E '^(scope|target)=' "$SPIN_DIR/$SID_A.request"
  assert_output "$(printf 'scope=bg\ntarget=72e3cb7a')"
  # Negative control: a job whose state names another session is not this one's, KIND unset or not.
  rm -f "$SPIN_DIR/$SID_A.request"; mk_job "$SID_B"
  run env -u CLAUDE_CODE_SESSION_KIND CLAUDE_CODE_SESSION_ID="$SID_A" CLAUDE_JOB_DIR="$JOB" TMUX="" TMUX_PANE="" bash "$WIND_DOWN" arm
  assert_failure
  assert_output --partial 'not inside tmux'
}

@test "arm in a background session that inherited TMUX still arms the stop, never the pane" {
  # The daemon can carry the TMUX and TMUX_PANE of the foreground claude that spawned it.
  bg_stubs; mk_job "$SID_A"
  bg_arm TMUX="fake" TMUX_PANE="%29" bash "$WIND_DOWN" arm --session
  assert_success
  assert_output --partial 'only it stops'
  run grep -E '^(scope|target|pane)=' "$SPIN_DIR/$SID_A.request"
  assert_output "$(printf 'scope=bg\ntarget=72e3cb7a')"
  run grep '^tmux ' "$NOTES_FIXTURE/calls.log"
  assert_failure
}

@test "a claude started inside a background session never arms a stop of its parent's job" {
  # It inherits JOB_DIR (and KIND) with a session id of its own: its own window closes, as any.
  bg_stubs; mk_job "$SID_B"
  bg_arm bash "$WIND_DOWN" arm
  assert_success
  run grep -E '^scope=' "$SPIN_DIR/$SID_A.request"
  assert_output 'scope=window'
  bg_arm TMUX="" TMUX_PANE="" bash "$WIND_DOWN" arm
  assert_failure
  assert_output --partial 'not inside tmux'
}

@test "arm in a background session records the worktree it runs in" {
  bg_stubs; mk_job "$SID_A"; mk_worktree
  cd "$HOME/.worktrees/repo-agent-1"
  bg_arm TMUX="" bash "$WIND_DOWN" arm
  assert_success
  run grep '^worktree=' "$SPIN_DIR/$SID_A.request"
  assert_output "worktree=$HOME/.worktrees/repo-agent-1"
}

@test "arm in a background session with no job dir, or with no setsid to detach the stop, arms nothing" {
  bg_stubs; mk_job "$SID_A"
  run env CLAUDE_CODE_SESSION_KIND=bg CLAUDE_CODE_SESSION_ID="$SID_A" CLAUDE_JOB_DIR='' TMUX='' bash "$WIND_DOWN" arm
  assert_failure
  rm "$BATS_TEST_TMPDIR/bin/setsid"
  # A PATH with bash, jq and git but no setsid.
  local bin="$BATS_TEST_TMPDIR/nosetsid"; mkdir -p "$bin"
  local t; for t in bash jq git dirname readlink mkdir date cat basename; do ln -s "$(command -v "$t")" "$bin/$t"; done
  bg_arm TMUX='' PATH="$bin" bash "$WIND_DOWN" arm
  assert_failure
  assert_output --partial 'claude stop 72e3cb7a'
  run bash -c 'ls "$1"/*.request 2>/dev/null | wc -l' _ "$SPIN_DIR"
  assert_output '0'
}

@test "fire on a background session saves its screen, stops it detached, and reaps only after a stop that worked" {
  bg_stubs
  mk_worktree
  mk_sentinel <<EOF
scope=bg
target=72e3cb7a
label=bg-72e3cb7a
worktree=$HOME/.worktrees/repo-agent-1
sid=$SID_A
EOF
  run bash "$WIND_DOWN" fire "$SENTINEL"
  assert_success
  run grep '^setsid' "$NOTES_FIXTURE/calls.log"
  assert_success
  local chain="$output"
  assert_output --partial "stop '72e3cb7a'"
  # The screen is saved in the detached job, before the stop, never in the Stop hook.
  assert_output --partial "logs '72e3cb7a' > $(printf '%q' "$HOME/.local/share/tmux-history/")"
  assert_output --partial "bg-72e3cb7a-$SID_A.txt"
  [[ "${chain%%" stop '72e3cb7a'"*}" == *" logs '72e3cb7a'"* ]] || fail "the screen is saved after the stop"
  # The reap and the scratchpad removal sit in the branch a successful stop takes, and the
  # failed branch keeps both.
  local ok_branch="${chain#*"; then "}"; ok_branch="${ok_branch%%"; else "*}"
  [[ "$ok_branch" == *"wt reap --after-kill '$HOME/.worktrees/repo-agent-1'"* ]] || fail "no reap after a stop that worked"
  [[ "$ok_branch" == *"/*/'$SID_A'"* ]] || fail "no scratchpad removal after a stop that worked"
  local fail_branch="${chain#*"; else "}"
  [[ "$fail_branch" != *"wt reap"* && "$fail_branch" != *"rm -rf"* ]] || fail "a failed stop still reaps"
  [[ "${chain%%"; then "*}" == *" stop '72e3cb7a'"* ]] || fail "the branch does not test the stop"
  # Nothing ran in the foreground: logs and stop are the detached job's, and no pane is killed.
  run grep -E '^(claude|tmux) ' "$NOTES_FIXTURE/calls.log"
  assert_failure
}

@test "the detached background chain runs: a failed stop keeps the worktree, a stop that worked reaps it" {
  # The chain setsid is handed, run for real with a claude stub whose stop fails, then succeeds.
  bg_stubs
  mk_worktree
  mk_sentinel <<EOF
scope=bg
target=72e3cb7a
label=bg-72e3cb7a
worktree=$HOME/.worktrees/repo-agent-1
sid=$SID_A
EOF
  local stub="$BATS_TEST_TMPDIR/bin/setsid"
  printf '#!/bin/sh\nshift\nexec "$@"\n' > "$stub"
  # No real `sleep 1` in the test: the chain's sleep is a stub too.
  printf '#!/bin/sh\nexit 0\n' > "$BATS_TEST_TMPDIR/bin/sleep"; chmod +x "$BATS_TEST_TMPDIR/bin/sleep"
  printf '#!/bin/sh\necho "claude $*" >> "$NOTES_FIXTURE/calls.log"\n[ "$1" = stop ] && exit "${STOP_RC:-0}"\nexit 0\n' > "$BATS_TEST_TMPDIR/bin/claude"
  cp "$SENTINEL" "$SENTINEL.keep"
  STOP_RC=1 run bash "$WIND_DOWN" fire "$SENTINEL"
  assert_success
  run grep -c '^wt reap' "$SPIN_DIR/fire.log"
  assert_output '0'
  run grep 'claude stop 72e3cb7a failed' "$SPIN_DIR/fire.log"
  assert_success
  STOP_RC=0 run bash "$WIND_DOWN" fire "$SENTINEL.keep"
  assert_success
  run grep -c "^wt reap --after-kill $HOME/.worktrees/repo-agent-1" "$SPIN_DIR/fire.log"
  assert_output '1'
}

@test "fire on a background sentinel with a malformed job stops nothing" {
  bg_stubs
  mk_sentinel <<EOF
scope=bg
target=72e3cb7a; rm -rf ~
sid=$SID_A
EOF
  run bash "$WIND_DOWN" fire "$SENTINEL"
  assert_failure
  run grep -E 'setsid|claude' "$NOTES_FIXTURE/calls.log"
  assert_failure
}
