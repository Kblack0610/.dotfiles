#!/usr/bin/env bats
# wave-session.sh: the per-APP work session — one window per in-flight wave ticket.
#
# Only the PURE helpers are exercised here. Anything that touches a tmux server belongs
# in the ui tier, which runs in the disposable container: starting a real server on a
# real machine has already destroyed live sessions once.
#
# The parsing is the part worth pinning. `sync` decides which windows to CREATE and,
# more dangerously, which to KILL — so a misread status column silently closes a window
# an agent is working in, and a misread ticket column could collect a window that was
# never ours.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic
  WS="$REPO_ROOT/.local/src/tmux/wave-session.sh"
  # Source only the pure helpers — the file's dispatch block would otherwise run.
  eval "$(sed -n '/^rows_of()/,/^}/p; /^_is_live()/,/^}/p; /^slugify()/,/^}/p; /^session_of()/,/^}/p' "$WS")"
  BB="$BATS_TEST_TMPDIR/sprint.md"
}

write_bb() { cat > "$BB"; }

# ── rows_of ──────────────────────────────────────────────────────────────────

@test "rows_of reads ticket, status and title from the queue table" {
  write_bb <<'EOF'
## Queue
| # | Ticket | Title | Pri | Conflicts | Status | Sub-branch | Wave commit | Gate | Result |
|---|--------|-------|-----|-----------|--------|------------|-------------|------|--------|
| 1 | 601 | Thumbnail squished | P1 | - | in-progress | fix/x | - | rev:PASS | - |
EOF
  run rows_of "$BB"
  assert_output $'601\tin-progress\tThumbnail squished'
}

@test "rows_of keys on HEADER NAME, so an added column cannot shift what it reads" {
  # The wave schema adds Sub-branch/Wave commit/Gate. A positional parser would read
  # the wrong cell as Status the moment the schema grew.
  write_bb <<'EOF'
## Queue
| # | Ticket | Title | Status |
|---|--------|-------|--------|
| 1 | 601 | Thumbnail squished | blocked |
EOF
  run rows_of "$BB"
  assert_output $'601\tblocked\tThumbnail squished'
}

@test "rows_of skips the separator row" {
  write_bb <<'EOF'
## Queue
| # | Ticket | Title | Status |
|---|--------|-------|--------|
| 1 | 601 | a | in-progress |
EOF
  run bash -c "$(declare -f rows_of); rows_of '$BB' | wc -l"
  assert_output '1'
}

@test "rows_of returns nothing for a blackboard with no queue rows" {
  write_bb <<'EOF'
## Queue
| # | Ticket | Title | Status |
|---|--------|-------|--------|
EOF
  run rows_of "$BB"
  assert_output ''
}

@test "rows_of is a no-op on a missing file" {
  run rows_of "$BATS_TEST_TMPDIR/nope.md"
  assert_success
  assert_output ''
}

# ── _is_live: which rows deserve a window ────────────────────────────────────

@test "a row an agent is on gets a window" {
  run _is_live in-progress
  assert_success
}

@test "a blocked row gets a window, because that is where you take over" {
  run _is_live blocked
  assert_success
}

@test "an errored row gets a window" {
  run _is_live error
  assert_success
}

@test "a queued row gets NO window — nothing is running yet" {
  run _is_live queued
  assert_failure
}

@test "an in-wave row gets NO window — that work is done" {
  # If this regressed, finished tickets would accumulate windows forever and the work
  # session would become as unglanceable as putting them in the cockpit.
  run _is_live in-wave
  assert_failure
}

@test "a merged or skipped row gets no window" {
  run _is_live merged
  assert_failure
  run _is_live skipped
  assert_failure
}

# ── slugify ──────────────────────────────────────────────────────────────────

@test "slugify makes a window-name-safe slug" {
  run slugify 'Facility save fails with 400 "Invalid url"'
  assert_output 'facility-save-fails-with'
}

@test "slugify collapses runs of punctuation and trims the edges" {
  run slugify '  --Provider // cannot remove!!  '
  assert_output 'provider-cannot-remove'
}

@test "slugify caps the length so window names stay readable" {
  run bash -c "$(declare -f slugify); slugify 'a very long ticket title that would otherwise run off the window list entirely' | wc -c"
  # 24 chars + newline
  assert_output '25'
}

@test "slugify survives a title that is entirely punctuation" {
  run slugify '!!!'
  assert_output ''
}

# ── session naming ───────────────────────────────────────────────────────────

@test "the work session is named after the app, matching the dotfiles/hub convention" {
  run session_of alpha
  assert_output 'alpha'
}
