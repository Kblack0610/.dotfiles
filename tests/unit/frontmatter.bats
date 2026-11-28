#!/usr/bin/env bats
# .local/lib/frontmatter.sh is the one reader and writer of a `key: value` header (agent-queue items,
# asks, holds): fm_get, and fm_set, one atomic rewrite under flock. The lock tests hold the lock from
# the test and bound fm_set's wait with FM_LOCK_WAIT, so none sleeps or races.

bats_require_minimum_version 1.5.0

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic
  LIB="$REPO_ROOT/.local/lib/frontmatter.sh"
  . "$LIB"
  F="$BATS_TEST_TMPDIR/item.md"
  printf 'slug: a\nrow: r1\nnote: old\n---\nbrief\nrow: in the body\nonly: body\n' > "$F"
}

# held_write <lib>: fm_set from <lib> on $F while this shell holds $F's lock; 0 when the write went through.
held_write() {
  exec 7>>"$BATS_TEST_TMPDIR/.lock"
  flock 7
  local rc=0
  bash -c '. "$1"; FM_LOCK_WAIT=1 fm_set "$2" locked yes' _ "$1" "$F" 2>/dev/null || rc=$?
  exec 7>&-
  return "$rc"
}

@test "fm_get reads a present key, nothing for a missing key, and never past the --- line" {
  run fm_get "$F" slug
  assert_output a
  run fm_get "$F" nope
  assert_output ''
  # a key that only the body has
  run fm_get "$F" only
  assert_output ''
  # the first line of the header wins over a body line of the same key
  run fm_get "$F" row
  assert_output r1
}

@test "fm_get with an empty operand returns at once and never reads the caller's stdin (ar-3455)" {
  mkfifo "$BATS_TEST_TMPDIR/open-stdin"
  exec 4<>"$BATS_TEST_TMPDIR/open-stdin"
  run timeout 10 bash -c '. "$1"; [ -z "$(fm_get "" slug)" ]' _ "$LIB" <&4
  exec 4>&-
  assert_success
}

@test "fm_set replaces a key in place, adds a new one above the ---, and leaves the body alone" {
  run fm_set "$F" note new extra 'two words'
  assert_success
  run cat "$F"
  assert_output $'slug: a\nrow: r1\nnote: new\nextra: two words\n---\nbrief\nrow: in the body\nonly: body'
}

@test "fm_set on a file with no --- appends a new key at the end" {
  printf 'by: me\nsince: 1\n' > "$F"
  fm_set "$F" since 2 granted yes
  run cat "$F"
  assert_output $'by: me\nsince: 2\ngranted: yes'
}

@test "fm_set keeps a value with backslashes, a dollar sign and an ampersand as typed, and writes an empty value" {
  fm_set "$F" note 'a\nb \\ $x & "q"' row ''
  run fm_get "$F" note
  assert_output 'a\nb \\ $x & "q"'
  run grep -c '^row: $' "$F"
  assert_output 1
}

@test "fm_set drops a repeat of a key it set, and a key that merely starts with it is left" {
  printf 'row: 1\nrow_x: keep\nrow: 2\n' > "$F"
  fm_set "$F" row 3
  run cat "$F"
  assert_output $'row: 3\nrow_x: keep'
}

@test "fm_set on a file that is gone fails and creates nothing, so a released hold stays released" {
  run fm_set "$BATS_TEST_TMPDIR/gone.md" a 1
  assert_failure 1
  [ ! -e "$BATS_TEST_TMPDIR/gone.md" ]
  [ -z "$(ls -A "$BATS_TEST_TMPDIR" | grep -F '.gone.md')" ]
}

@test "fm_set refuses a value that spans lines, a key that is not one word and a dangling key, writing nothing" {
  local before; before="$(cat "$F")"
  run -2 fm_set "$F" note $'two\nlines'
  assert_output --partial 'cannot span lines'
  run -2 fm_set "$F" 'a key' v
  assert_output --partial 'not a header key'
  run -2 fm_set "$F" note
  assert_output --partial usage
  [ "$(cat "$F")" = "$before" ]
}

@test "FM_FLAT=1 reads the whole file as the header, so a --- value line ends nothing" {
  printf 'a: 1\nnotes: x\n---\nstatus: pending\n' > "$F"
  FM_FLAT=1 fm_set "$F" status answered
  run cat "$F"
  assert_output $'a: 1\nnotes: x\n---\nstatus: answered'
}

@test "fm_set exits through the caller's die when it has one" {
  run bash -c '. "$1"; die() { echo "tool: $*" >&2; exit 9; }; fm_set "$2" note $'"'"'a\nb'"'"'' _ "$LIB" "$F"
  assert_failure 9
  assert_output 'tool: a value cannot span lines: note'
}

@test "fm_set leaves no temp file behind" {
  fm_set "$F" note new
  run ls -A "$BATS_TEST_TMPDIR"
  refute_output --partial '.item.md.'
}

@test "fm_set waits for the file's lock, and fails with the file unchanged when it is held past FM_LOCK_WAIT" {
  local before; before="$(cat "$F")"
  run held_write "$LIB"
  assert_failure
  [ "$(cat "$F")" = "$before" ]
  # released: the same write goes through
  run fm_set "$F" locked yes
  assert_success
  run fm_get "$F" locked
  assert_output yes
}

@test "NEGATIVE CONTROL: the same lock check fails against a fm_set with its flock removed" {
  grep -v flock "$LIB" > "$BATS_TEST_TMPDIR/nolock.sh"
  run grep -c flock "$BATS_TEST_TMPDIR/nolock.sh"
  assert_output 0
  run held_write "$BATS_TEST_TMPDIR/nolock.sh"
  assert_success
}

@test "FM_LOCK names the lock file, and FM_LOCKED=1 takes none, for a caller already inside its own lock" {
  exec 7>>"$BATS_TEST_TMPDIR/other.lock"
  flock 7
  FM_LOCK="$BATS_TEST_TMPDIR/other.lock" FM_LOCK_WAIT=1 run fm_set "$F" a 1
  assert_failure
  FM_LOCK="$BATS_TEST_TMPDIR/other.lock" FM_LOCKED=1 FM_LOCK_WAIT=1 run fm_set "$F" a 1
  assert_success
  exec 7>&-
}

@test "parallel writers of different keys all land" {
  local i
  for i in 1 2 3 4 5 6 7 8 9 10 11 12; do fm_set "$F" "k$i" "$i" & done
  wait
  for i in 1 2 3 4 5 6 7 8 9 10 11 12; do
    run fm_get "$F" "k$i"
    assert_output "$i"
  done
  run fm_get "$F" slug
  assert_output a
}
