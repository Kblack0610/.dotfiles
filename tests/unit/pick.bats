#!/usr/bin/env bats
# tests/pick.sh: the files one CI run of the fast tier tests. A pull request gets the picked set
# plus tests/broad.txt; anything the picker cannot judge gets the whole tier, and says why.

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

@test "every broad.txt entry is a real fast-tier file" {
  local f n=0
  while read -r f; do
    [ -f "$BATS_TEST_DIRNAME/../$f" ] || fail "broad.txt names $f, which does not exist"
    n=$((n + 1))
  done < <(sed -n 's#^\([a-z]*/[^[:space:]#]*\.bats\).*#\1#p' "$BATS_TEST_DIRNAME/../broad.txt")
  [ "$n" -gt 0 ]
}
