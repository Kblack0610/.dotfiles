#!/usr/bin/env bats
# tests/pick.sh: the files one CI run of the fast tier tests. A pull request gets the picked set
# plus tests/broad.txt; anything the picker cannot judge gets the whole tier, and says why.

bats_require_minimum_version 1.5.0

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  SUBJECT="$BATS_TEST_DIRNAME/../pick.sh"
  ALL_UNIT=$(cd "$BATS_TEST_DIRNAME/.." && printf '%s\n' unit/*.bats)
}

@test "no base (main, the schedule, a manual run) runs the whole tier" {
  run --separate-stderr "$SUBJECT" unit
  assert_success
  [ "$output" = "$ALL_UNIT" ]
  [[ "$stderr" == *"full: not a pull request"* ]]
}

@test "a pull request runs the files its change can affect plus the broad set" {
  PICK_CHANGED=.local/bin/fleet-dispatch run --separate-stderr "$SUBJECT" unit HEAD
  assert_success
  assert_line unit/fleet_dispatch.bats
  assert_line unit/smoke.bats
  refute_line unit/shard.bats
  [ "${#lines[@]}" -lt "$(wc -l <<<"$ALL_UNIT")" ]
  [[ "$stderr" == *"unit: picked ${#lines[@]} of "* ]]
}

@test "a change the picker cannot judge runs the whole tier, and says why" {
  local c
  for c in tests/helpers/sandbox.bash tests/shard.sh tests/broad.txt .github/workflows/tests.yml .local/lib/test-pick.sh; do
    PICK_CHANGED=$c run --separate-stderr "$SUBJECT" unit HEAD
    assert_success
    [ "$output" = "$ALL_UNIT" ]
    [[ "$stderr" == *"full: the change touches the test harness"* ]]
  done
  PICK_CHANGED='' run --separate-stderr "$SUBJECT" unit HEAD
  [ "$output" = "$ALL_UNIT" ]
  [[ "$stderr" == *"full: no change against HEAD"* ]]
  run --separate-stderr "$SUBJECT" unit no-such-rev
  assert_success
  [ "$output" = "$ALL_UNIT" ]
  [[ "$stderr" == *"full: git diff no-such-rev failed"* ]]
}

@test "rust: main runs every crate; a pull request runs the crates it touches and their path dependents" {
  local all n
  all=$(cd "$BATS_TEST_DIRNAME/../.." && tests/rust-crates.sh)
  n=$(wc -l <<<"$all")
  run --separate-stderr "$SUBJECT" rust
  assert_success
  [ "$output" = "$all" ]
  [[ "$stderr" == *"rust: all $n crates (full: not a pull request)"* ]]
  # hub-core and agent-web name agent-panel by path, hub-tui names hub-core: two levels.
  PICK_CHANGED=.local/src/agent-panel/src/main.rs run --separate-stderr "$SUBJECT" rust HEAD
  assert_success
  assert_line .local/src/agent-panel
  assert_line .local/src/hub-core
  assert_line .local/src/hub-tui
  refute_line .local/src/notes-cli
  [[ "$stderr" == *"rust: picked ${#lines[@]} of $n crates for 1 changed"* ]]
  PICK_CHANGED=.local/src/timebox/crates/timebox-core/src/lib.rs run --separate-stderr "$SUBJECT" rust HEAD
  [ "$output" = .local/src/timebox ]
  PICK_CHANGED=.local/src/web-kit/shell.css run --separate-stderr "$SUBJECT" rust HEAD
  [ "$output" = .local/src/agent-web ]
  PICK_CHANGED=$'.local/bin/agent-land\ntests/helpers/sandbox.bash' run --separate-stderr "$SUBJECT" rust HEAD
  assert_success
  [ -z "$output" ]
  [[ "$stderr" == *"rust: picked 0 of $n crates for 2 changed"* ]]
}

@test "rust: a change to the rust gate runs every crate" {
  local c all
  all=$(cd "$BATS_TEST_DIRNAME/../.." && tests/rust-crates.sh)
  for c in tests/rust.sh tests/rust-crates.sh tests/rust-inputs.txt tests/pick.sh tests/Makefile .github/workflows/tests.yml; do
    PICK_CHANGED=$c run --separate-stderr "$SUBJECT" rust HEAD
    assert_success
    [ "$output" = "$all" ]
    [[ "$stderr" == *"(full: the change touches the rust gate)"* ]]
  done
}

# A path a crate source names outside its own directory: include_str!/include_bytes! resolve
# from the source file, a CARGO_MANIFEST_DIR path from the crate. A literal that lands on the
# repo root (a test that then names files under it) is listed by hand and skipped here.
@test "rust-inputs.txt lists every outside path a crate source names, and each entry exists" {
  local root c f line lit base path cov p missing=""
  root=$(cd "$BATS_TEST_DIRNAME/../.." && pwd -P)
  while read -r c p; do
    [ -e "$root/$p" ] || missing+=" stale:$c:$p"
  done < <(grep -v '^#' "$BATS_TEST_DIRNAME/../rust-inputs.txt" | grep .)
  for c in $(cd "$root" && tests/rust-crates.sh); do
    while IFS=: read -r f _ line; do
      while read -r lit; do
        lit=${lit//\"/}
        if [[ "$line" == *include_str!* || "$line" == *include_bytes!* ]]; then
          base=$(dirname "$root/$f")
        elif [[ "$lit" == /* || "$line" == *CARGO_MANIFEST_DIR* ]]; then
          base=$root/$c
        else
          continue
        fi
        path=$(realpath -m "$base/${lit#/}")
        [[ "$path/" == "$root/$c/"* || "$path" == "$root" ]] && continue
        cov=0
        while read -r p; do
          [[ "${path#"$root"/}/" == "$p"* ]] && cov=1
        done < <(sed -n "s#^${c}[[:space:]]\{1,\}\([^[:space:]]*\).*#\1#p" "$BATS_TEST_DIRNAME/../rust-inputs.txt")
        [ "$cov" = 1 ] || missing+=" $f:${path#"$root"/}"
      done < <(grep -oE '"/?(\.\./)+[^"{}]*"' <<<"$line")
    done < <(git -C "$root" grep -n -E '"/?(\.\./)+' -- "$c/*.rs")
  done
  [ -z "$missing" ] || fail "not in tests/rust-inputs.txt:$missing"
}

@test "every broad.txt entry is a real fast-tier file" {
  local f n=0
  while read -r f; do
    [ -f "$BATS_TEST_DIRNAME/../$f" ] || fail "broad.txt names $f, which does not exist"
    n=$((n + 1))
  done < <(sed -n 's#^\([a-z]*/[^[:space:]#]*\.bats\).*#\1#p' "$BATS_TEST_DIRNAME/../broad.txt")
  [ "$n" -gt 0 ]
}
