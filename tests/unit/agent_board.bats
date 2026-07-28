#!/usr/bin/env bats
# agent-board.sh — the ONE sprint-blackboard parser, shared by notes-cockpit,
# wave-session, delivery-loop and captain-watchdog.
#
# Why this file is worth its length: divergence between board readers is not a loud
# failure, it is SILENCE. A board delivery-loop cannot parse reports as "no active
# queue" — byte-identical to a board with genuinely nothing to do. Three of the five
# real boards on disk were invisible to both headless daemons for weeks.
#
# So each parser bug that actually happened gets a test that reproduces it.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic
  # shellcheck source=/dev/null
  . "$AGENT_BOARD_LIB"
  BB="$BATS_TEST_TMPDIR/sprint.md"
}

write_bb() { cat > "$BB"; }
nrows() { board_rows "$BB" | grep -c . || true; }
field() { board_rows "$BB" | sed -n "${1}p" | cut -d$'\037' -f"$2"; }

# ── the header-shape bug (wave-session's rows_of returned ZERO rows) ──────────

@test "a board headed Ticket-first is read, not silently skipped" {
  # THE regression. wave-session's parser keyed the header on a literal `#` first
  # column, so this real on-disk shape matched nothing and it returned zero rows —
  # which reads exactly like an empty queue.
  write_bb <<'EOF'
## Queue
| Ticket | P | Title | Lane | Agent | Status | Sentinel |
|--------|---|-------|------|-------|--------|----------|
| 559 | P1 | Stale core L1 smoke checks | api | kb-dev | merged | `STATUS: DONE` |
EOF
  assert_equal "$(nrows)" '1'
  assert_equal "$(field 1 1)" '559'
  assert_equal "$(field 1 2)" 'merged'
}

@test "the old #-keyed header still works, so both real shapes parse" {
  write_bb <<'EOF'
## Queue
| # | Ticket | Title | Status |
|---|--------|-------|--------|
| 1 | 601 | a thing | in-progress |
EOF
  assert_equal "$(nrows)" '1'
  assert_equal "$(field 1 2)" 'working'
}

# ── the table-latch bug (six phantom rows) ───────────────────────────────────

@test "a new H2 ends the table instead of eating every later pipe table" {
  # The wave schema's `## Wave gate` table (Step|Gate|Status|Evidence) was parsed
  # with the QUEUE's column indices and rendered as phantom work items — including
  # its own header row.
  write_bb <<'EOF'
## Queue
| # | Ticket | Title | Status |
|---|--------|-------|--------|
| 1 | 601 | the only real row | in-progress |

## Wave gate
| Step | Gate | Status | Evidence |
|------|------|--------|----------|
| 1 | freshness | PASS | contains main tip |
| 2 | review | PASS | rev:PASS |
| 3 | qa | PENDING | - |
EOF
  assert_equal "$(nrows)" '1'
  assert_equal "$(field 1 3)" 'the only real row'
}

# ── the empty-ticket bug (a whole proposal invisible) ─────────────────────────

@test "a PROPOSED row with an empty ticket cell still renders" {
  # A wave writes its stub board BEFORE the approval gate on purpose, so a gate stop
  # leaves a durable artifact. Every row legitimately has an empty Ticket until the
  # human approves — dropping them hid the proposal at exactly the moment it mattered.
  write_bb <<'EOF'
## Queue
| # | Ticket | Title | Status |
|---|--------|-------|--------|
| 1 |  | first proposed fix | queued |
| 2 |  | second proposed fix | queued |
EOF
  assert_equal "$(nrows)" '2'
  assert_equal "$(field 1 1)" '~1'
  assert_equal "$(field 2 1)" '~2'
}

@test "the header row itself is never emitted as work" {
  write_bb <<'EOF'
## Queue
| # | Ticket | Title | Status |
|---|--------|-------|--------|
EOF
  assert_equal "$(nrows)" '0'
}

# ── stage vocabulary ─────────────────────────────────────────────────────────

@test "in-wave is TERMINAL, not working" {
  # `in-wave` means the fix is squashed onto the wave branch and is done. Read as
  # `working` it would earn a tmux window for finished work.
  assert_equal "$(board_stage_of 'in-wave')" 'merged'
  run board_is_open merged
  assert_failure
}

@test "a prose status still classifies instead of falling through to working" {
  # Real boards write prose: three of five on disk contain none of the canonical
  # status words. This is why the daemons' keyword grep saw nothing.
  assert_equal "$(board_stage_of '**DONE — PR #1036 merged `31f11fd6`, 13/13 CI green**')" 'merged'
  # A bare "PENDING" is not in the queued vocabulary, so it lands on the `working`
  # fallback. Left as-is: both are OPEN, so every daemon predicate behaves the same
  # and only the cockpit glyph differs. Widening the vocabulary is a separate change.
  assert_equal "$(board_stage_of 'PENDING (only remaining step) - add internal tester group')" 'working'
}

@test "blocked beats a merged PR mentioned in the same cell" {
  # "blocked - PR #1036 merged, CI red" is BLOCKED. Ordering the merged test first
  # (as one earlier parser did) silently reports the row as done.
  assert_equal "$(board_stage_of 'blocked - PR #1036 merged, CI red')" 'blocked'
}

@test "open, attention and terminal partition the vocabulary" {
  for s in queued working review; do run board_is_open "$s"; assert_success; done
  for s in blocked error; do run board_is_attention "$s"; assert_success; done
  for s in merged skipped; do
    run board_is_open "$s";      assert_failure
    run board_is_attention "$s"; assert_failure
  done
}

# ── the approval gate ────────────────────────────────────────────────────────

@test "board_approved is true ONLY for the exact marker" {
  write_bb <<'EOF'
## Meta
- Approval: APPROVED-FOR-AUTONOMOUS-DELIVERY
EOF
  run board_approved "$BB"; assert_success
}

@test "board_approved is false for PENDING and for a missing key" {
  # Both negative controls matter: delivery-loop fails CLOSED, so a parser that
  # returned true here would drain an unapproved board and merge code unattended.
  write_bb <<'EOF'
## Meta
- Approval: PENDING
EOF
  run board_approved "$BB"; assert_failure
  write_bb <<'EOF'
## Meta
- Started: 2026-07-27
EOF
  run board_approved "$BB"; assert_failure
}

@test "board_drainable needs BOTH approval and open work" {
  write_bb <<'EOF'
## Meta
- Approval: APPROVED-FOR-AUTONOMOUS-DELIVERY
## Queue
| # | Ticket | Title | Status |
|---|--------|-------|--------|
| 1 | 601 | a thing | queued |
EOF
  run board_drainable "$BB"; assert_success

  # approved, but every row terminal -> nothing to drain
  write_bb <<'EOF'
## Meta
- Approval: APPROVED-FOR-AUTONOMOUS-DELIVERY
## Queue
| # | Ticket | Title | Status |
|---|--------|-------|--------|
| 1 | 601 | a thing | merged |
EOF
  run board_drainable "$BB"; assert_failure

  # open work, but not approved -> fail closed
  write_bb <<'EOF'
## Meta
- Approval: PENDING
## Queue
| # | Ticket | Title | Status |
|---|--------|-------|--------|
| 1 | 601 | a thing | queued |
EOF
  run board_drainable "$BB"; assert_failure
}

@test "board_needs_eyes ignores approval and includes blocked rows" {
  # captain-watchdog is observe-only: an UNAPPROVED board is exactly what a human
  # wants surfaced, and a board whose every row is blocked is precisely when it must
  # NOT self-disarm.
  write_bb <<'EOF'
## Meta
- Approval: PENDING
## Queue
| # | Ticket | Title | Status |
|---|--------|-------|--------|
| 1 | 601 | a thing | blocked |
EOF
  run board_needs_eyes "$BB"; assert_success
  run board_drainable  "$BB"; assert_failure   # ... while the runner still refuses it
}

@test "board_needs_eyes is false when every row is terminal" {
  write_bb <<'EOF'
## Queue
| # | Ticket | Title | Status |
|---|--------|-------|--------|
| 1 | 601 | a thing | merged |
| 2 | 602 | another | skipped |
EOF
  run board_needs_eyes "$BB"; assert_failure
}

# ── board discovery ──────────────────────────────────────────────────────────

@test "board_newest picks by MTIME, not by name" {
  # A wave IS a patch version, so boards are named both sprint-2026-07-27.md and
  # sprint-v1.10.1.md. Those two sort differently under different collations.
  local d="$HOME/.agent/plans/probe"; mkdir -p "$d"
  echo old > "$d/sprint-v1.10.1.md"
  sleep 1.1
  echo new > "$d/sprint-2026-07-27.md"
  assert_equal "$(basename "$(board_newest probe)")" 'sprint-2026-07-27.md'
}

@test "board_newest is silent for a project with no board" {
  run board_newest nosuchproject
  assert_success
  assert_output ''
}

# ── checkpoint sentinel ──────────────────────────────────────────────────────

@test "board_sentinel_of reads the LAST terminal sentinel" {
  local f="$BATS_TEST_TMPDIR/559.md"
  printf 'x | STATUS: PARTIAL something\ny | STATUS: DONE\n' > "$f"
  assert_equal "$(board_sentinel_of "$f")" 'DONE'
}

@test "board_sentinel_of is empty for a checkpoint with no sentinel" {
  # The real checkpoints/559.md had five timestamped lines and NO sentinel while its
  # board row claimed STATUS: DONE. Empty is what makes that detectable.
  local f="$BATS_TEST_TMPDIR/559.md"
  printf '2026-07-15T09:59:44 | branch created\n2026-07-15T10:22:01 | MERGED: PR #1036\n' > "$f"
  assert_equal "$(board_sentinel_of "$f")" ''
}

@test "board_sentinel_of and board_rows are no-ops on a missing file" {
  run board_sentinel_of "$BATS_TEST_TMPDIR/nope.md"; assert_success; assert_output ''
  run board_rows        "$BATS_TEST_TMPDIR/nope.md"; assert_success; assert_output ''
}
