#!/usr/bin/env bats
# tests/Makefile test-pr: the local gate runs the files tests/pick.sh picks for the change from
# PR_BASE to the working tree, untracked files included, never the whole fast tier (ar-1652).

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  SRC="$BATS_TEST_DIRNAME/../.."
  FIX="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$FIX/tests/unit" "$FIX/tests/integ" "$FIX/tests/vendor/bats-core/bin" "$FIX/.local/lib" "$FIX/bin"
  cp "$SRC/tests/Makefile" "$SRC/tests/pick.sh" "$SRC/tests/run-bats.sh" "$FIX/tests/"
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

gate() { env -u CI -u PR_BASE make -s --no-print-directory -C "$FIX/tests" test-pr; }

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

@test "no change against the base runs nothing, never the whole tier" {
  run gate
  assert_success
  assert_output --partial "no change against"
  refute_output --partial "ran "
}

@test "a missing origin/main is an error naming the fix, never a silent full run" {
  git -C "$FIX" update-ref -d refs/remotes/origin/main
  echo "echo changed" > "$FIX/bin/alpha.sh"
  run gate
  assert_failure 2
  assert_output --partial "git fetch origin, or pass PR_BASE"
  refute_output --partial "ran "
}

@test "a base git cannot read fails instead of running the whole tier" {
  echo "echo changed" > "$FIX/bin/alpha.sh"
  run env -u CI make -s --no-print-directory -C "$FIX/tests" test-pr PR_BASE=no-such-rev
  assert_failure
  refute_output --partial "ran "
}

@test "a harness change runs every file, as the PR gate does" {
  echo "# touch" >> "$FIX/tests/pick.sh"
  run gate
  assert_success
  assert_output --partial "ran unit/a.bats"
  assert_output --partial "ran unit/b.bats"
  assert_output --partial "ran integ/c.bats"
}

@test "PR_BASE picks the diff from that revision, committed work included" {
  echo "echo changed" > "$FIX/bin/beta.sh"
  git -C "$FIX" -c user.name=t -c user.email=t@t commit -qam beta
  run env -u CI make -s --no-print-directory -C "$FIX/tests" test-pr PR_BASE=HEAD~1
  assert_success
  assert_output --partial "ran unit/b.bats"
  refute_output --partial "a.bats"
}
