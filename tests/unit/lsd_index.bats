#!/usr/bin/env bats
# .local/src/docs/README.md is the index of the cross-repo doctrine docs. Its value is that it
# lists every doc and nothing else, so a new doc without a row, or a row whose doc moved,
# fails here instead of leaving the index quietly incomplete.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  PUB="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  DIR="$PUB/.local/src/docs"
}

# Prints "unlisted <f>" for any file in $1 with no link in $1/README.md, and "missing <f>" for
# a link whose file is not there. A link's #anchor and leading ./ are dropped; web links are
# skipped.
index_drift() {
  local dir="$1" f
  local linked
  linked="$(grep -oE '\]\([^) ]+\)' "$dir/README.md" \
    | sed -E 's/^\]\(//; s/\)$//; s/#.*//; s|^\./||' | grep -v '://' | sort -u)"
  for f in "$dir"/*; do
    [ -f "$f" ] || continue
    f="${f##*/}"
    [ "$f" = README.md ] && continue
    grep -qxF "$f" <<<"$linked" || echo "unlisted $f"
  done
  while IFS= read -r f; do
    [ -n "$f" ] && [ ! -e "$dir/$f" ] && echo "missing $f"
  done <<<"$linked"
  return 0
}

@test "docs README: every doc has a row and every row has a doc" {
  run index_drift "$DIR"
  assert_success
  assert_output ''
}

@test "docs README: an unlisted doc and a dead row are both reported" {
  # NEGATIVE CONTROL: the check above must be able to fail both ways. Rows with an anchor or
  # a leading ./ still count as listed.
  mkdir -p "$BATS_TEST_TMPDIR/d"
  printf '| [a.md](a.md#sec) | x |\n| [b.md](./b.md) | x |\n| [gone.md](gone.md) | y |\n' \
    >"$BATS_TEST_TMPDIR/d/README.md"
  : >"$BATS_TEST_TMPDIR/d/a.md"
  : >"$BATS_TEST_TMPDIR/d/b.md"
  : >"$BATS_TEST_TMPDIR/d/new.json"
  run index_drift "$BATS_TEST_TMPDIR/d"
  assert_output --partial 'unlisted new.json'
  assert_output --partial 'missing gone.md'
  refute_output --partial 'a.md'
  refute_output --partial 'b.md'
}
