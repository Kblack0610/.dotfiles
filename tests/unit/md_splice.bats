#!/usr/bin/env bats
# md-splice.sh replaces three byte-identical awk clones, of which only ONE compared
# before writing. The tests that matter are therefore about what is PRESERVED and
# what is NOT WRITTEN:
#
#   unchanged_content_is_not_written   the guard two of the three copies lacked,
#                                      and the reason the .path watcher self-triggered
#                                      and ~/.notes sat permanently dirty
#   nested_region_survives             lab-sync's TRACKER block is re-emitted from a
#                                      capture taken BEFORE the splice; if the splice
#                                      loses it, the headless weekly run silently
#                                      strips every tracker row
#
# Preservation is asserted byte-for-byte, not "contains" — the failure mode here is a
# generator quietly eating a hand-written line, which no `grep -q` would catch.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic
  source "$MD_SPLICE_LIB"

  FILE="$BATS_TEST_TMPDIR/doc.md"
  START='<!-- AUTO:START -->'
  END='<!-- AUTO:END -->'
}

seed() {
  cat > "$FILE" <<EOF
# hand-written title

Prose a human typed. Do not touch.

$START
old generated content
more old content
$END

## A section below the block
- a hand-written bullet
EOF
}

emit_v2() { echo "$START"; echo "new generated content"; echo "$END"; }
emit_same() { echo "$START"; echo "old generated content"; echo "more old content"; echo "$END"; }

# ── the core contract ────────────────────────────────────────────────────────

@test "md_splice: replaces the block and preserves everything around it byte-for-byte" {
  seed
  run md_splice "$FILE" 'AUTO:START' 'AUTO:END' emit_v2
  assert_success

  # Compared as one exact string, NOT line-by-line: `$lines` drops blank lines, and
  # a generator eating a blank line is exactly the kind of quiet damage this asserts
  # against.
  local expected
  expected=$(cat <<EOF
# hand-written title

Prose a human typed. Do not touch.

$START
new generated content
$END

## A section below the block
- a hand-written bullet
EOF
)
  assert_equal "$(cat "$FILE")" "$expected"
}

@test "md_splice: identical content is NOT written (mtime and git stay stable)" {
  # The guard regen-lab-feed.sh and regen-anchor.sh both lacked.
  seed
  local before after
  before=$(stat -c %Y "$FILE")
  local snapshot="$BATS_TEST_TMPDIR/snapshot"
  cp "$FILE" "$snapshot"
  sleep 1.1   # coarse enough for a 1-second mtime granularity

  # Called directly, NOT through `run`: `run` executes in a subshell, so an
  # out-variable set inside it never reaches the assertion.
  md_splice "$FILE" 'AUTO:START' 'AUTO:END' emit_same
  assert_equal "$MD_SPLICE_CHANGED" 0

  after=$(stat -c %Y "$FILE")
  assert_equal "$before" "$after"
  run cmp -s "$snapshot" "$FILE"
  assert_success
}

@test "md_splice: a real change sets MD_SPLICE_CHANGED=1" {
  # The positive half of the pair above — without it, a function that never writes
  # at all would pass the guard test.
  seed
  run md_splice "$FILE" 'AUTO:START' 'AUTO:END' emit_v2
  assert_success
  md_splice "$FILE" 'AUTO:START' 'AUTO:END' emit_same
  assert_equal "$MD_SPLICE_CHANGED" 1
}

@test "md_splice: a missing start marker returns 2 and writes nothing" {
  printf '# no markers here\njust prose\n' > "$FILE"
  local snapshot="$BATS_TEST_TMPDIR/snapshot"
  cp "$FILE" "$snapshot"

  run md_splice "$FILE" 'AUTO:START' 'AUTO:END' emit_v2
  assert_equal "$status" 2

  run cmp -s "$snapshot" "$FILE"
  assert_success
}

@test "md_splice: a missing file returns 1" {
  run md_splice "$BATS_TEST_TMPDIR/nope.md" 'AUTO:START' 'AUTO:END' emit_v2
  assert_equal "$status" 1
}

# ── the nested-region invariant lab-sync depends on ──────────────────────────

@test "md_splice: a captured nested region survives a splice, and a second splice of the result" {
  # regen-lab-feed.sh captures its TRACKER inner block BEFORE splicing and re-emits
  # it from auto_block. This pins that the round trip is lossless — including the
  # SECOND pass, where the emitted block is now also the file's existing content.
  cat > "$FILE" <<EOF
# project

$START
**shipped v1.0.0**

<!-- TRACKER:START -->
- Area: a ticket nobody wants to lose
<!-- TRACKER:END -->
$END
EOF

  # Capture exactly as the generator does, then re-emit it inside the new block.
  local captured
  captured=$(sed -n '/TRACKER:START/,/TRACKER:END/p' "$FILE")
  emit_with_tracker() {
    echo "$START"
    echo "**shipped v1.1.0**"
    echo
    printf '%s\n' "$captured"
    echo "$END"
  }

  run md_splice "$FILE" 'AUTO:START' 'AUTO:END' emit_with_tracker
  assert_success
  run cat "$FILE"
  assert_output --partial '- Area: a ticket nobody wants to lose'
  assert_output --partial '**shipped v1.1.0**'

  # Second splice of the already-spliced output: still exactly one tracker block.
  md_splice "$FILE" 'AUTO:START' 'AUTO:END' emit_with_tracker
  run grep -c 'TRACKER:START' "$FILE"
  assert_output '1'
  run grep -c 'a ticket nobody wants to lose' "$FILE"
  assert_output '1'
}

@test "md_splice: refuses rather than double-splicing when the body holds a literal sentinel" {
  # A line equal to the sentinel inside the PRESERVED text would gain a second copy
  # of the generated block. The original awk copies did this silently.
  cat > "$FILE" <<EOF
# doc
$MD_SPLICE_SENTINEL
$START
old
$END
EOF
  local snapshot="$BATS_TEST_TMPDIR/snapshot"
  cp "$FILE" "$snapshot"

  run md_splice "$FILE" 'AUTO:START' 'AUTO:END' emit_v2
  assert_equal "$status" 1
  assert_output --partial 'refusing to splice'

  run cmp -s "$snapshot" "$FILE"
  assert_success
}
