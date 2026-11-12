#!/usr/bin/env bats
# tests/Makefile test-pr: the local gate runs the files tests/pick.sh picks for the change from
# BASE to the working tree, untracked files included, never the whole fast tier (ar-1652).

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  SRC="$BATS_TEST_DIRNAME/../.."
  FIX="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$FIX/tests/unit" "$FIX/tests/integ" "$FIX/tests/vendor/bats-core/bin" "$FIX/.local/lib" "$FIX/bin"
  cp "$SRC/tests/Makefile" "$SRC/tests/pick.sh" "$FIX/tests/"
  cp "$SRC/.local/lib/test-pick.sh" "$FIX/.local/lib/"
  : > "$FIX/tests/broad.txt"
  # A stub bats: prints the files it was handed, one a line.
  printf '#!/bin/sh\nfor a; do case "$a" in *.bats) echo "ran ${a##*/tests/}";; esac; done\n' > "$FIX/tests/vendor/bats-core/bin/bats"
  chmod +x "$FIX/tests/vendor/bats-core/bin/bats"
  printf '@test "a" {\n  run alpha.sh\n}\n' > "$FIX/tests/unit/a.bats"
  printf '@test "b" {\n  run beta.sh\n}\n' > "$FIX/tests/unit/b.bats"
  printf '@test "c" {\n  run gamma.sh\n}\n' > "$FIX/tests/integ/c.bats"
  for s in alpha beta; do echo "echo $s" > "$FIX/bin/$s.sh"; done
  printf 'tests/vendor/\n' > "$FIX/.gitignore"
  git -C "$FIX" init -q -b main
  git -C "$FIX" add -A
  git -C "$FIX" -c user.name=t -c user.email=t@t commit -qm base
  git -C "$FIX" update-ref refs/remotes/origin/main HEAD
}

gate() { env -u CI make -s --no-print-directory -C "$FIX/tests" test-pr; }

@test "an uncommitted edit runs only the files that name it" {
  echo "echo changed" > "$FIX/bin/alpha.sh"
  run gate
  assert_success
  assert_output --partial "ran unit/a.bats"
  refute_output --partial "b.bats"
  refute_output --partial "c.bats"
}

@test "an untracked file counts as the change" {
  echo "echo new" > "$FIX/bin/gamma.sh"
  run gate
  assert_success
  assert_output --partial "ran integ/c.bats"
  refute_output --partial "a.bats"
}

@test "a change no file names runs nothing" {
  echo "notes" > "$FIX/README.txt"
  run gate
  assert_success
  assert_output --partial "no fast-tier file picked"
  refute_output --partial "ran "
}
