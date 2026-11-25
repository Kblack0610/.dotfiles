#!/usr/bin/env bats
# shape-grow: a function over 150 lines that a change makes longer is listed, in each language it
# reads; with the repo's copy.conf at base, a copy the change adds is listed too. The copy fixtures
# model the 11-18b stack-review copies the gate can see (~/.agent/evals/dotfiles/stack-review-2026-11-18b):
# a helper re-added under its name in a second tool, a pasted block, a constant set twice. The
# stack-review skill adds one here for each copy a review finds that this missed.
# stdout is the list; the hint on a failure goes to stderr.

bats_require_minimum_version 1.5.0

load '../vendor/bats-support/load'
load '../vendor/bats-assert/load'

SG="$BATS_TEST_DIRNAME/../../.local/bin/shape-grow"

setup() {
  R="$BATS_TEST_TMPDIR/r"
  git init -q "$R"
  git -C "$R" config user.email t@t
  git -C "$R" config user.name t
}

# commit -> a commit of whatever is in the work tree
commit() { git -C "$R" add -A && git -C "$R" commit -qm c --allow-empty; git -C "$R" rev-parse HEAD; }

# py <file> <name> <body lines> -> a Python function of 1 + n lines
py() { { printf 'def %s():\n' "$2"; for i in $(seq "$3"); do printf '    x = %s\n' "$i"; done; } >"$R/$1"; }
# shf <file> <name> <body lines> -> a shell function of 2 + n lines
shf() { { printf '#!/usr/bin/env bash\n%s() {\n' "$2"; for i in $(seq "$3"); do printf '  echo %s\n' "$i"; done; printf '}\n'; } >"$R/$1"; }
# rs <file> <name> <body lines> -> a Rust fn of 2 + n lines, behind a trait declaration that has no body
rs() { { printf 'trait T {\n    fn %s(&self);\n}\nfn %s() {\n' "$2" "$2"; for i in $(seq "$3"); do printf '    let _ = %s;\n' "$i"; done; printf '}\n'; } >"$R/$1"; }

@test "a Python function that crosses 150 lines, or grows past it, is listed" {
  py a.py decide 139; a=$(commit)
  py a.py decide 159; b=$(commit)
  run --separate-stderr "$SG" -C "$R" "$a" "$b"
  assert_failure 1
  assert_output 'a.py:1 decide 140->160'
  py a.py decide 169; c=$(commit)
  run --separate-stderr "$SG" -C "$R" "$b" "$c"
  assert_output 'a.py:1 decide 160->170'
}

@test "a long function that shrinks or stays the same is clean (negative control)" {
  py a.py decide 199; a=$(commit)
  py a.py decide 189; b=$(commit)
  run --separate-stderr "$SG" -C "$R" "$a" "$b"
  assert_success
  assert_output ''
  printf 'y = 1\n' >>"$R/a.py"; c=$(commit)
  run --separate-stderr "$SG" -C "$R" "$b" "$c"
  assert_success
  assert_output ''
}

@test "a new long function counts from 0" {
  : >"$R/README"; a=$(commit)
  py new.py fresh 151; b=$(commit)
  run --separate-stderr "$SG" -C "$R" "$a" "$b"
  assert_failure 1
  assert_output 'new.py:1 fresh 0->152'
}

@test "a shell script, by extension or by shebang, is measured" {
  shf run.sh go 150; shf tool go 150; a=$(commit)
  shf run.sh go 160; shf tool go 160; b=$(commit)
  run --separate-stderr "$SG" -C "$R" "$a" "$b"
  assert_failure 1
  assert_line 'run.sh:2 go 152->162'
  assert_line 'tool:2 go 152->162'
}

@test "a Rust fn is measured, and a trait declaration with no body is not a function" {
  rs lib.rs handle 150; a=$(commit)
  rs lib.rs handle 160; b=$(commit)
  run --separate-stderr "$SG" -C "$R" "$a" "$b"
  assert_failure 1
  assert_output 'lib.rs:4 handle 152->162'
}

@test "a .bats file is not measured" {
  shf t.bats go 150; a=$(commit)
  shf t.bats go 200; b=$(commit)
  run --separate-stderr "$SG" -C "$R" "$a" "$b"
  assert_success
  assert_output ''
}

@test "a bad ref or missing argument exits 2" {
  run "$SG" -C "$R" nope HEAD
  assert_failure 2
  assert_output --partial 'shape-grow: git diff nope HEAD'
  run "$SG" HEAD
  assert_failure 2
}

@test "a renamed file is measured against its old path, so a git mv is clean" {
  shf old.sh go 160; a=$(commit)
  git -C "$R" mv old.sh new.sh; b=$(commit)
  run --separate-stderr "$SG" -C "$R" "$a" "$b"
  assert_success
  assert_output ''
}

@test "a one-line Rust fn ends on its own line, not at a later item's brace" {
  { printf 'fn tiny() -> i32 { 1 }\nstruct S {\n'; for i in $(seq 160); do printf '    f%s: u8,\n' "$i"; done; printf '}\n'; } >"$R/l.rs"
  : >"$R/README"; a=$(git -C "$R" add README && git -C "$R" commit -qm c && git -C "$R" rev-parse HEAD)
  b=$(commit)
  run --separate-stderr "$SG" -C "$R" "$a" "$b"
  assert_success
  assert_output ''
}

@test "a shell function written as function name { is measured" {
  { printf '#!/bin/bash\nfunction decide {\n'; for i in $(seq 150); do printf '  echo %s\n' "$i"; done; printf '}\n'; } >"$R/d.sh"; a=$(commit)
  { printf '#!/bin/bash\nfunction decide {\n'; for i in $(seq 170); do printf '  echo %s\n' "$i"; done; printf '}\n'; } >"$R/d.sh"; b=$(commit)
  run --separate-stderr "$SG" -C "$R" "$a" "$b"
  assert_failure 1
  assert_output 'd.sh:2 decide 152->172'
}

# cnf <line>... -> the repo's copy.conf
cnf() { mkdir -p "$R/.config/shape-grow"; printf '%s\n' "$@" >"$R/.config/shape-grow/copy.conf"; }
# blk -> six significant shell lines, the default-branch lookup N4 found pasted across tools
blk() {
  cat <<'EOF'
default_branch=$(git symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null)
default_branch=${default_branch#origin/}
[ -n "$default_branch" ] || default_branch=main
git fetch -q origin "$default_branch"
base=$(git merge-base HEAD "origin/$default_branch")
echo "base: $base"
EOF
}

@test "copy: a function another tool already defines is listed, and only a Dup: line naming it covers it" {
  cnf 'block-lines 6'; shf lib.sh merge_proof_branch 1; a=$(commit)
  shf tool.sh merge_proof_branch 2; b=$(commit)
  run --separate-stderr "$SG" -C "$R" "$a" "$b"
  assert_failure 1
  assert_output 'tool.sh:2 copy function merge_proof_branch, also lib.sh:2'
  [[ "$stderr" == *"use or extend the one it names"* ]]
  run --separate-stderr "$SG" -C "$R" --body - "$a" "$b" <<<'Dup: ar-12 other_name'
  assert_failure 1
  run --separate-stderr "$SG" -C "$R" --body - "$a" "$b" <<<'Dup: ar-12 merge_proof_branch'
  assert_success
  assert_output 'tool.sh:2 copy function merge_proof_branch, also lib.sh:2 [Dup: ar-12]'
  printf 'x\n  Dup: ar-12 a, merge_proof_branch\n' >"$BATS_TEST_TMPDIR/body"
  run --separate-stderr "$SG" -C "$R" --body "$BATS_TEST_TMPDIR/body" "$a" "$b"
  assert_success
}

@test "copy: a Split: line covers a grown function the same way" {
  py a.py decide 139; a=$(commit)
  py a.py decide 159; b=$(commit)
  run --separate-stderr "$SG" -C "$R" --body - "$a" "$b" <<<'Split: ar-3 decide'
  assert_success
  assert_output 'a.py:1 decide 140->160 [Split: ar-3]'
}

@test "copy: a constant set to the same value in another file is listed; another value is not" {
  cnf 'block-lines 6'; printf 'DEFAULT_REMOTE = "origin/main"\n' >"$R/a.py"; a=$(commit)
  printf 'DEFAULT_REMOTE = "origin/main"\n' >"$R/b.py"
  printf 'DEFAULT_REMOTE = "upstream/main"\n' >"$R/c.py"; b=$(commit)
  run --separate-stderr "$SG" -C "$R" "$a" "$b"
  assert_failure 1
  assert_output 'b.py:1 copy constant DEFAULT_REMOTE, also a.py:1'
}

@test "copy: a pasted block of six significant lines is listed; five are not" {
  cnf 'block-lines 6'; { echo '#!/usr/bin/env bash'; blk; } >"$R/a.sh"; a=$(commit)
  { echo '#!/usr/bin/env bash'; echo 'echo start'; blk; } >"$R/b.sh"
  { echo '#!/usr/bin/env bash'; blk | head -n 5; } >"$R/c.sh"; b=$(commit)
  run --separate-stderr "$SG" -C "$R" "$a" "$b"
  assert_failure 1
  assert_output 'b.sh:3 copy block of 6 lines, also a.sh:2'
}

@test "copy: a function and block moved to another file, or re-indented in place, is no copy (negative control)" {
  cnf 'block-lines 6'
  { echo '#!/usr/bin/env bash'; echo 'lookup() {'; blk | sed 's/^/  /'; echo '}'; } >"$R/a.sh"; a=$(commit)
  { echo '#!/usr/bin/env bash'; echo 'echo other'; } >"$R/a.sh"
  { echo '#!/usr/bin/env bash'; echo 'lookup() {'; blk | sed 's/^/  /'; echo '}'; } >"$R/b.sh"; b=$(commit)
  run --separate-stderr "$SG" -C "$R" "$a" "$b"
  assert_success
  assert_output ''
  { echo '#!/usr/bin/env bash'; echo 'lookup() {'; echo '  if true; then'; blk | sed 's/^/    /'; echo '  fi'; echo '}'; } >"$R/b.sh"; c=$(commit)
  run --separate-stderr "$SG" -C "$R" "$b" "$c"
  assert_success
  assert_output ''
}

@test "copy: the checks run only when the base has copy.conf, so a change cannot turn its own off or on" {
  shf lib.sh helper 1; a=$(commit)
  cnf 'block-lines 6'; shf b.sh helper 1; b=$(commit)
  run --separate-stderr "$SG" -C "$R" "$a" "$b"
  assert_success
  assert_output ''
  shf c.sh helper 1; c=$(commit)
  run --separate-stderr "$SG" -C "$R" "$b" "$c"
  assert_failure 1
  assert_output 'c.sh:2 copy function helper, also b.sh:2'
  rm "$R/.config/shape-grow/copy.conf"; shf d.sh helper 1; d=$(commit)
  run --separate-stderr "$SG" -C "$R" "$c" "$d"
  assert_failure 1
  assert_output 'd.sh:2 copy function helper, also b.sh:2'
}

@test "copy: a conf name, a skipped path, a Rust fn, a Rust test module and a .bats file are not checked" {
  cnf 'name main cmd_*' 'skip vendor/*'
  shf a.sh main 1; shf b.sh cmd_go 1; shf lib.sh helper 1
  { printf 'fn parse() -> u8 {\n    1\n}\n#[cfg(test)]\nmod tests {\n'; blk | sed 's/^/    let _ = r#"/; s/$/"#;/'; printf '}\n'; } >"$R/a.rs"
  { echo '#!/usr/bin/env bash'; blk; } >"$R/t.bats"; a=$(commit)
  shf c.sh main 2; shf d.sh cmd_go 2; mkdir -p "$R/vendor"; shf vendor/x.sh helper 2
  { printf 'fn parse() -> u8 {\n    2\n}\n#[cfg(test)]\nmod tests {\n'; blk | sed 's/^/    let _ = r#"/; s/$/"#;/'; printf '}\n'; } >"$R/b.rs"
  { echo '#!/usr/bin/env bash'; blk; } >"$R/u.bats"; b=$(commit)
  run --separate-stderr "$SG" -C "$R" "$a" "$b"
  assert_success
  assert_output ''
}

@test "copy: --conf reads the conf from a file; a bad conf line exits 2" {
  shf lib.sh helper 1; a=$(commit)
  shf b.sh helper 1; b=$(commit)
  printf 'block-lines 6\n' >"$BATS_TEST_TMPDIR/c.conf"
  run --separate-stderr "$SG" -C "$R" --conf "$BATS_TEST_TMPDIR/c.conf" "$a" "$b"
  assert_failure 1
  assert_output 'b.sh:2 copy function helper, also lib.sh:2'
  printf 'block-lines one\n' >"$BATS_TEST_TMPDIR/c.conf"
  run --separate-stderr "$SG" -C "$R" --conf "$BATS_TEST_TMPDIR/c.conf" "$a" "$b"
  assert_failure 2
  [[ "$stderr" == *"copy.conf:1: not"* ]]
}
