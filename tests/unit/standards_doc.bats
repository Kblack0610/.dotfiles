#!/usr/bin/env bats
# Every test the agent runtime standards name must exist, so a renamed test cannot leave a
# standard pointing at nothing.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  DOC="$REPO_ROOT/.local/src/docs/standards.md"
}

# refs <doc> -> "file<TAB>test name" for each `tests/...bats` "name" pair in a Test(s): clause
refs() {
  grep -oE '`tests/[^`]+\.bats`( "[^"]+")?' "$1" | sed -E 's/^`([^`]+)`( "(.*)")?$/\1\t\3/'
}

check() {
  local f name bad=0
  while IFS=$'\t' read -r f name; do
    if [ ! -f "$REPO_ROOT/$f" ]; then echo "missing file: $f"; bad=1
    elif [ -n "$name" ] && ! grep -qF "@test \"$name\"" "$REPO_ROOT/$f"; then echo "missing test in $f: $name"; bad=1
    fi
  done < <(refs "$1")
  return "$bad"
}

@test "every test the standards doc names exists" {
  [ "$(refs "$DOC" | wc -l)" -ge 5 ]
  run check "$DOC"
  assert_success
}

@test "a renamed test is caught (negative control)" {
  sed 's/no post script calls a model/no post script calls a modle/' "$DOC" > "$BATS_TEST_TMPDIR/doc.md"
  run check "$BATS_TEST_TMPDIR/doc.md"
  assert_failure
  assert_output --partial 'missing test in tests/integ/stop_hook_quiet.bats'
}
