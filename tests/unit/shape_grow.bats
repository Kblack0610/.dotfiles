#!/usr/bin/env bats
# shape-grow: a function over 150 lines that a change makes longer is listed, in each language it reads.

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
  run "$SG" -C "$R" "$a" "$b"
  assert_failure 1
  assert_output 'a.py:1 decide 140->160'
  py a.py decide 169; c=$(commit)
  run "$SG" -C "$R" "$b" "$c"
  assert_output 'a.py:1 decide 160->170'
}

@test "a long function that shrinks or stays the same is clean (negative control)" {
  py a.py decide 199; a=$(commit)
  py a.py decide 189; b=$(commit)
  run "$SG" -C "$R" "$a" "$b"
  assert_success
  assert_output ''
  printf 'y = 1\n' >>"$R/a.py"; c=$(commit)
  run "$SG" -C "$R" "$b" "$c"
  assert_success
  assert_output ''
}

@test "a new long function counts from 0" {
  : >"$R/README"; a=$(commit)
  py new.py fresh 151; b=$(commit)
  run "$SG" -C "$R" "$a" "$b"
  assert_failure 1
  assert_output 'new.py:1 fresh 0->152'
}

@test "a shell script, by extension or by shebang, is measured" {
  shf run.sh go 150; shf tool go 150; a=$(commit)
  shf run.sh go 160; shf tool go 160; b=$(commit)
  run "$SG" -C "$R" "$a" "$b"
  assert_failure 1
  assert_line 'run.sh:2 go 152->162'
  assert_line 'tool:2 go 152->162'
}

@test "a Rust fn is measured, and a trait declaration with no body is not a function" {
  rs lib.rs handle 150; a=$(commit)
  rs lib.rs handle 160; b=$(commit)
  run "$SG" -C "$R" "$a" "$b"
  assert_failure 1
  assert_output 'lib.rs:4 handle 152->162'
}

@test "a .bats file is not measured" {
  shf t.bats go 150; a=$(commit)
  shf t.bats go 200; b=$(commit)
  run "$SG" -C "$R" "$a" "$b"
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
