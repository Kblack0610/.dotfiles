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

@test "a board with NO Title column does not emit the whole raw row as the title" {
  # In awk an unset col[k] is "", and $("") is $0 - so this shape emitted the ENTIRE
  # RAW ROW as every title. sprint-2026-07-12-time-tangle.md is headed exactly like
  # this and did precisely that.
  write_bb <<'EOF'
## Queue
| # | Wave | Ticket | Branch | Agent | Status | Sentinel |
|---|------|--------|--------|-------|--------|----------|
| 1 | Playable mobile UX | none | feat/x | kb-dev | MERGED (PR #1004) | STATUS: DONE |
EOF
  # The whole-row bug is caught by asserting the title contains no pipe, which no
  # legitimate title does.
  run field 1 3
  assert_output 'Playable mobile UX'
  refute_output --partial '|'
}

@test "a Title column still wins over the fallback" {
  # Negative control for the test above: the fallback must not shadow a real Title.
  write_bb <<'EOF'
## Queue
| # | Wave | Ticket | Title | Status |
|---|------|--------|-------|--------|
| 1 | some wave | 601 | the real title | queued |
EOF
  assert_equal "$(field 1 3)" 'the real title'
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
  #
  # THE NEWEST BOARD MUST BE THE ONE THAT SORTS LAST BY NAME, or this test cannot
  # fail. It could not, for its whole life: it used to make sprint-2026-07-27.md the
  # newest, and '2' precedes 'v', so plain `ls -1` returned the same answer as `ls
  # -1t` and dropping the `t` broke nothing. Found by breaking the subject on purpose.
  local d="$HOME/.agent/plans/probe"; mkdir -p "$d"
  echo old > "$d/sprint-2026-07-27.md"
  echo new > "$d/sprint-v1.10.1.md"
  touch -d '2026-07-27 10:00' "$d/sprint-2026-07-27.md"
  touch -d '2026-08-02 10:00' "$d/sprint-v1.10.1.md"
  assert_equal "$(basename "$(board_newest probe)")" 'sprint-v1.10.1.md'
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

# ── the mapping is ONE implementation ────────────────────────────────────────
# board_stage_of and board_rows used to hold separate copies of the stage mapping, under
# a comment asserting they "can never disagree". They did: the shell arm `*done*` is a
# substring match, so "abandoned" was `merged` via board_stage_of and `working` via
# board_rows. These tests exist to make that class of drift impossible to reintroduce.

# stage_via_rows <status> -- what the ROW PARSER makes of a status cell.
stage_via_rows() {
  local f="$BATS_TEST_TMPDIR/agree.md"
  printf '| Ticket | Status |\n|---|---|\n| T1 | %s |\n' "$1" > "$f"
  board_rows "$f" | cut -d$'\037' -f2
}

@test "\"abandoned\" is not merged - substring matching was the drift" {
  # The regression itself. A row a human marked abandoned read as DONE to one consumer.
  assert_equal "$(board_stage_of abandoned)" 'working'
  assert_equal "$(stage_via_rows abandoned)" 'working'
}

@test "board_stage_of and board_rows agree on every status shape we have seen" {
  # Rule of three and then some: real cells from the boards on disk, plus the words that
  # broke earlier parsers. Any future edit that touches one path and not the other fails
  # here rather than in the cockpit.
  local s
  for s in 'abandoned' 'done' 'PR done' 'work abandoned mid-flight' \
           'merged' 'STATUS: DONE' 'in-wave' 'reverted-from-wave' \
           'blocked' 'blocked - PR #1036 merged, CI red' 'error' 'failed' \
           'skipped' 'pr-open' 'pr open' 'PR #1036' 'pull/1036' 'merge it' 'ready' \
           'queued' 'filed' 'not dispatched' 'n/a' 'returns assessment' \
           'in-progress' '**DONE - PR #1036 merged**' 'something nobody wrote yet'; do
    assert_equal "$(board_stage_of "$s")|$s" "$(stage_via_rows "$s")|$s"
  done
}

@test "attention still beats terminal after the consolidation" {
  # The ordering that every earlier parser got wrong: a blocked row that MENTIONS a merged
  # PR is blocked, and must keep asking for the human.
  assert_equal "$(board_stage_of 'blocked - PR #1036 merged, CI red')" 'blocked'
  assert_equal "$(stage_via_rows 'blocked - PR #1036 merged, CI red')" 'blocked'
}

# ── pipefail safety ──────────────────────────────────────────────────────────
# Every consumer of this library opens with `set -uo pipefail`. Under pipefail the
# `ls ... | head -1` in board_newest took its status from a failing `ls`, so a project
# that simply had no board yet reported FAILURE for the ordinary case. It was invisible
# because the only test that could have caught it sed-extracted functions into a bare
# shell, where pipefail was never set.

@test "board_newest is silent AND successful for a project with no board, under pipefail" {
  run bash -c '
    set -uo pipefail
    . "$1"
    export AGENT_PLANS_DIR="$2"
    mkdir -p "$AGENT_PLANS_DIR/alpha"
    board_newest alpha
  ' _ "$AGENT_BOARD_LIB" "$BATS_TEST_TMPDIR/plans"
  assert_success
  assert_output ''
}

@test "board_sentinel_of is successful for a checkpoint with no sentinel, under pipefail" {
  printf 'just a note\n' > "$BATS_TEST_TMPDIR/ckpt.md"
  run bash -c '
    set -uo pipefail
    . "$1"
    board_sentinel_of "$2"
  ' _ "$AGENT_BOARD_LIB" "$BATS_TEST_TMPDIR/ckpt.md"
  assert_success
  assert_output ''
}

# ── discovery: board_list / board_newest / board_find ────────────────────────
# Six files used to write out `ls -1t "$dir"/sprint-*.md` themselves. The glob is
# the easy part; what each copy also re-decided, silently, was WHAT COUNTS as a
# board and IN WHAT ORDER. These tests pin both facts to one implementation.

# Boards named so that NAME order and MTIME order DISAGREE. That is the only
# arrangement under which these tests can fail: '2' precedes 'v', so if the newest
# board were the dated one, `ls -1` and `ls -1t` would return the same order and
# dropping the `t` would break nothing. The newest here must sort LAST by name.
#
# The shape is realistic, not contrived: a wave cuts `sprint-v1.10.1.md` for a patch
# release after a dated `/kb:sprint` board is already sitting in the directory.
seed_boards() { # $1=project — leaves `sprint-v1.10.1.md` newest, `sprint-2026-08-01.md` older
  local d="$AGENT_PLANS_DIR/$1"
  mkdir -p "$d"
  printf '## Queue\n' > "$d/sprint-v1.10.1.md"
  printf '## Queue\n' > "$d/sprint-2026-08-01.md"
  touch -d '2026-08-01 10:00' "$d/sprint-2026-08-01.md"
  touch -d '2026-08-02 10:00' "$d/sprint-v1.10.1.md"
}

setup_discovery() {
  export AGENT_PLANS_DIR="$BATS_TEST_TMPDIR/plans"
  seed_boards alpha
}

@test "board_list orders by mtime, not by name" {
  setup_discovery
  # If this ever sorts by name the two lines swap under a C locale. Named boards and
  # dated boards coexist because a wave is a patch version, so this is not theoretical.
  assert_equal "$(board_list alpha | xargs -n1 basename | tr '\n' ' ')" \
    'sprint-v1.10.1.md sprint-2026-08-01.md '
}

@test "board_list lists every board, board_newest only the first" {
  setup_discovery
  assert_equal "$(board_list alpha | grep -c .)" '2'
  assert_equal "$(basename "$(board_newest alpha)")" 'sprint-v1.10.1.md'
}

@test "board_list is silent AND successful for an unknown project, under pipefail" {
  # Same class of bug as board_newest's: a timer-driven daemon asking about a quiet
  # project must not see a failure status.
  # Each case reports ITSELF. Chaining them as `board_list nosuch; board_list` and
  # asserting on the final status cannot work: the no-arg case returns 0 early, so it
  # overwrites the status of the case being tested and the whole test goes vacuous.
  run bash -c '
    set -uo pipefail
    . "$1"; export AGENT_PLANS_DIR="$2"
    board_list nosuchproject || echo "NONZERO: unknown project"
    board_list               || echo "NONZERO: no argument"
    mkdir -p "$AGENT_PLANS_DIR/empty"
    board_list empty         || echo "NONZERO: registered project with no board"
  ' _ "$AGENT_BOARD_LIB" "$BATS_TEST_TMPDIR/plans"
  assert_output ''
}

@test "board_find returns the newest board its predicate accepts, skipping newer ones" {
  # THE behaviour every scheduled reader wants and each had reimplemented: a newer
  # board that is entirely terminal must not mask an older one that still has work.
  # Getting this backwards is silent — the daemon reports 'nothing to drain'.
  setup_discovery
  # newest board: nothing left to do. Older board: still working. The daemon must
  # look past the first one rather than stopping at it.
  cat > "$AGENT_PLANS_DIR/alpha/sprint-v1.10.1.md" <<'EOF'
## Queue
| Ticket | Title | Status |
|---|---|---|
| 1 | done thing | merged |
EOF
  cat > "$AGENT_PLANS_DIR/alpha/sprint-2026-08-01.md" <<'EOF'
## Queue
| Ticket | Title | Status |
|---|---|---|
| 2 | live thing | working |
EOF
  touch -d '2026-08-01 10:00' "$AGENT_PLANS_DIR/alpha/sprint-2026-08-01.md"
  touch -d '2026-08-02 10:00' "$AGENT_PLANS_DIR/alpha/sprint-v1.10.1.md"
  assert_equal "$(basename "$(board_find alpha board_needs_eyes)")" 'sprint-2026-08-01.md'
}

@test "board_find is silent AND successful when no board matches, or with no predicate" {
  setup_discovery
  rm "$AGENT_PLANS_DIR/alpha/sprint-v1.10.1.md"
  cat > "$AGENT_PLANS_DIR/alpha/sprint-2026-08-01.md" <<'EOF'
## Queue
| Ticket | Title | Status |
|---|---|---|
| 1 | done thing | merged |
EOF
  run bash -c '
    set -uo pipefail
    . "$1"; export AGENT_PLANS_DIR="$2"
    board_find alpha board_needs_eyes; board_find alpha
  ' _ "$AGENT_BOARD_LIB" "$BATS_TEST_TMPDIR/plans"
  assert_success
  assert_output ''
}

# ── the class vocabulary: board_in_class / board_count ───────────────────────

@test "eyes is open OR attention, and an unknown class matches nothing" {
  # `eyes` is a class rather than an `||` at each call site because every consumer
  # that open-coded it got it slightly different. An unknown class must return
  # no-match rather than error: a typo must not take down a timer-driven daemon.
  for s in queued working review; do
    board_in_class "$s" open      || fail "$s should be open"
    board_in_class "$s" eyes      || fail "$s should be eyes"
    board_in_class "$s" attention && fail "$s should not be attention"
  done
  for s in blocked error; do
    board_in_class "$s" attention || fail "$s should be attention"
    board_in_class "$s" eyes      || fail "$s should be eyes"
    board_in_class "$s" open      && fail "$s should not be open"
  done
  for s in merged skipped; do
    board_in_class "$s" eyes && fail "$s is terminal, not eyes"
  done
  board_in_class working nosuchclass && fail "an unknown class must match nothing"
  return 0
}

@test "board_count counts per class and prints 0 rather than nothing" {
  # Printing empty for zero is the bug this pins: session-preflight interpolates the
  # count into a message and the caller before it used `${n:-1}`, so an empty count
  # silently rendered as the plausible-looking '1 in-flight row(s)'.
  write_bb <<'EOF'
## Queue
| Ticket | Title | Status |
|---|---|---|
| 1 | a | working |
| 2 | b | blocked on access |
| 3 | c | merged |
| 4 | d | queued |
EOF
  assert_equal "$(board_count "$BB" open)"      '2'
  assert_equal "$(board_count "$BB" attention)" '1'
  assert_equal "$(board_count "$BB" eyes)"      '3'

  write_bb <<'EOF'
## Queue
| Ticket | Title | Status |
|---|---|---|
| 1 | a | merged |
EOF
  assert_equal "$(board_count "$BB" eyes)" '0'
  assert_equal "$(( $(board_count "$BB" eyes) + 1 ))" '1'
}

@test "board_needs_eyes agrees with board_count eyes on every board" {
  # The invariant the refactor rests on: board_needs_eyes is now board_has_stage eyes,
  # so a board the daemons act on and a count the human reads can never disagree.
  for status in working blocked merged skipped queued 'in-wave' 'PR #12 open'; do
    printf '## Queue\n| Ticket | Title | Status |\n|---|---|---|\n| 1 | a | %s |\n' "$status" > "$BB"
    if board_needs_eyes "$BB"; then
      [ "$(board_count "$BB" eyes)" -gt 0 ] || fail "needs_eyes yes but count 0 for '$status'"
    else
      assert_equal "$(board_count "$BB" eyes)" '0'
    fi
  done
}
