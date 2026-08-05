#!/usr/bin/env bats
# The parser, against boards that actually exist.
#
# Every other board fixture in this suite was written by someone reading the parser.
# All of them are headed `| # | Ticket | Title | Status |` -- a shape NO real board has
# ever had. That is how a parser returning zero rows on all three real boards passed 19
# tests: a fixture derived from the implementation agrees with the implementation,
# including where it is wrong.
#
# These fixtures come the other way round, from tests/fixtures/boards/ (see its README
# for provenance). If the parser cannot read one of these, it cannot read the corpus,
# and no amount of green elsewhere means anything.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic
  # shellcheck source=/dev/null
  . "$AGENT_BOARD_LIB"
  BOARDS="$TESTS_DIR/fixtures/boards"
}

nrows() { board_rows "$1" | grep -c . || true; }

@test "the corpus directory is not empty" {
  # A corpus test over zero fixtures passes vacuously, which is the failure mode this
  # whole file exists to end.
  run bash -c 'ls "$1"/*.md | grep -v README | wc -l' _ "$BOARDS"
  [ "$output" -ge 3 ]
}

@test "every real board shape parses to at least one row" {
  local f n
  for f in "$BOARDS"/*.md; do
    case "$f" in */README.md) continue ;; esac
    n="$(nrows "$f")"
    [ "$n" -gt 0 ] || fail "$(basename "$f") parsed to ZERO rows — this is the original bug"
  done
}

@test "the Ticket-first shape reads all five rows and their real statuses" {
  # wave-session's parser keyed the header on a literal `#` first column, so this shape
  # matched nothing and returned zero rows -- indistinguishable from an empty queue.
  local f="$BOARDS/queue-ticket-first.md"
  assert_equal "$(nrows "$f")" '5'
  # `**DONE — PR #1036 merged**` is prose a human wrote, not an enum value.
  assert_equal "$(board_rows "$f" | sed -n 1p | cut -d$'\037' -f2)" 'merged'
  # `filed, not dispatched` must be queued, not the `working` fallthrough.
  assert_equal "$(board_rows "$f" | sed -n 2p | cut -d$'\037' -f2)" 'queued'
  assert_equal "$(board_rows "$f" | sed -n 3p | cut -d$'\037' -f2)" 'working'
}

@test "the numbered wave shape has NO Title column and still says what each row is" {
  # Guarded lookups matter here: in awk an unset col[k] is "", and $("") is $0, so this
  # board used to emit its ENTIRE RAW ROW as the title.
  local f="$BOARDS/wave-numbered.md" t
  assert_equal "$(nrows "$f")" '7'
  t="$(board_rows "$f" | sed -n 1p | cut -d$'\037' -f3)"
  assert_equal "$t" 'Playable mobile UX'
}

@test "in-wave is terminal and blocked still beats a merged-looking status" {
  local f="$BOARDS/wave-numbered.md"
  # row 6: "blocked on access". Tested BEFORE terminal on purpose -- "blocked - PR #1036
  # merged, CI red" is BLOCKED, and the reverse order (which every pre-#170 parser used)
  # read it as done, so the row stopped asking for the human it needed.
  assert_equal "$(board_rows "$f" | sed -n 6p | cut -d$'\037' -f2)" 'blocked'
  # row 7: "in-wave" — done pending delivery, must not read as working
  assert_equal "$(board_rows "$f" | sed -n 7p | cut -d$'\037' -f2)" 'merged'
}

@test "prose naming ANOTHER PR as (merged) no longer marks a live row terminal" {
  # This was a KNOWN LIMITATION test asserting the bug, added when the real corpus first
  # surfaced it. Row 5 is verbatim from the real board and is ACTIVELY IN FLIGHT:
  #   "1st run: IPA built OK but submit REJECTED - dup buildNumber 1.
  #    FIX: PR #1008 bumped ->2 (merged). RE-RUN building 1.0.0(2). Background-watched."
  # It classified as `merged` because the mapping tested `merged` as a bare substring and
  # this cell mentions a DIFFERENT PR having been merged.
  #
  # The verdict rules now read only LEAD -- the text before the first sentence break --
  # so elaboration cannot cast the verdict.
  assert_equal "$(board_rows "$BOARDS/wave-numbered.md" | sed -n 5p | cut -d$'\037' -f2)" 'working'
}

@test "a pre-approval wave renders its proposal rows despite empty Ticket cells" {
  # A wave writes its stub board BEFORE the approval gate, deliberately, so a gate stop
  # leaves a durable artifact -- which means every row legitimately has an empty Ticket
  # until the human approves. Skipping them hid the whole proposal at exactly the moment
  # the human needed to read it.
  local f="$BOARDS/wave-gated.md"
  assert_equal "$(nrows "$f")" '3'
  assert_equal "$(board_rows "$f" | sed -n 1p | cut -d$'\037' -f1)" '~1'
}

@test "the wave-gate table below the queue is not read as work" {
  # A new H2 ends the table. Without that, the column map latched on the first
  # ticket+status header and `## Wave gate` was parsed with the queue's indices,
  # rendering as phantom work items.
  run board_rows "$BOARDS/wave-gated.md"
  refute_output --partial 'freshness'
  refute_output --partial 'full e2e'
}

@test "approval is read correctly on both a gated and an approved real board" {
  # `- Approval: PENDING` is not the inverse of the approved token: a board whose line
  # is neither is misjudged by a `grep PENDING` check. wave-start used to do exactly that.
  board_approved "$BOARDS/queue-ticket-first.md" || fail "approved board read as unapproved"
  board_approved "$BOARDS/wave-gated.md" && fail "PENDING board read as approved"
  return 0
}

@test "drainable and needs-eyes disagree on the pre-approval board, as designed" {
  # delivery-loop fails closed on approval; captain-watchdog deliberately does not.
  local f="$BOARDS/wave-gated.md"
  board_drainable "$f"  && fail "an unapproved board must never be drainable"
  board_needs_eyes "$f" || fail "an unapproved board with queued rows is exactly what needs eyes"
  return 0
}

# ── where a verdict sits decides whether it is THIS row's verdict ─────────────

@test "a verdict in the FIRST clause is the row's verdict" {
  # Every real terminal cell states its verdict up front. These are verbatim shapes.
  assert_equal "$(board_stage_of 'MERGED (PR #1004, CI green)')" 'merged'
  assert_equal "$(board_stage_of '**DONE — PR #1036 merged `31f11fd6`, 13/13 CI green**')" 'merged'
  assert_equal "$(board_stage_of 'DONE - migration 014 applied, DB 68->182 cards, api healthy')" 'merged'
  assert_equal "$(board_stage_of 'filed, not dispatched')" 'queued'
}

@test "a verdict word AFTER the first sentence break is elaboration, not the verdict" {
  # The sentence break is what separates "what happened" from "and by the way".
  assert_equal "$(board_stage_of 'still building. an earlier PR was merged')" 'working'
  assert_equal "$(board_stage_of 'retrying the upload. PR #99 open for the fix')"  'working'
}

@test "a DONE verdict is not undone by elaboration that mentions more work" {
  # The converse must also hold, or the rule just moves the bug: a row that opens with
  # DONE is done, even if the sentence after it mentions something still happening.
  assert_equal "$(board_stage_of 'DONE - build success, IPA uploaded (app 6751792324). Apple now processing.')" 'merged'
}

@test "the SENTINEL is authoritative wherever it sits, unlike prose" {
  # board_rows appends the sentinel to the status, so a LEAD-only rule would discard it on
  # exactly the rows most likely to carry one: those whose status runs past one sentence.
  assert_equal "$(board_stage_of 'a long prose status that rambles on. and then some more' 'STATUS: DONE')" 'merged'
}

@test "ATTENTION still matches the whole cell, and still beats a terminal verdict" {
  # Getting attention wrong strands a human, so it keeps the broader match on purpose.
  assert_equal "$(board_stage_of '**blocked - PR #1036 merged, CI red**')" 'blocked'
  assert_equal "$(board_stage_of 'DONE with the build. later it turned out to be blocked')" 'blocked'
  assert_equal "$(board_stage_of 'shipped it. the deploy failed')" 'error'
}
