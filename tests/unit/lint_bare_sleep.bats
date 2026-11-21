#!/usr/bin/env bats
# tests/lint-bare-sleep.awk: the match behind tests/lint.sh house rule 4, no bare sleep in a
# bats @test body. Each case is bats text it must flag or must pass, so a change to the quote
# scanner, the heredoc skip or the loop and background exemptions shows here.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  AWK="$BATS_TEST_DIRNAME/../lint-bare-sleep.awk"
}

# hits BODY -> what the matcher prints for one @test whose body is BODY.
hits() { printf '@test "t" {\n%s\n}\n' "$1" | awk -f "$AWK"; }

@test "negative control: a planted bare sleep in a test body is flagged, at its line" {
  run hits '  sleep 1'
  assert_output '-:2:sleep 1'
  run hits '  run foo; sleep 0.5'
  assert_output --partial ':2:'
  run hits '  true && sleep "$n"'
  assert_output --partial ':2:'
}

@test "a sleep outside an @test body is not flagged" {
  run bash -c "printf 'helper() { sleep 1; }\n@test \"t\" {\n  true\n}\nteardown() {\n  sleep 1\n}\n' | awk -f '$AWK'"
  assert_output ''
}

@test "sleep in quotes, a comment or as a pgrep name is not a delay" {
  run hits "  ed two ensure 'sleep 300'"
  assert_output ''
  run hits '  wait_until "! pgrep -P 1 -x sleep >/dev/null"'
  assert_output ''
  run hits '  # sleep 3 would hide the race'
  assert_output ''
  run hits $'  run fg $\'until x; do sleep 5; done\\nsleep 2\''
  assert_output ''
}

@test "a multi-line quoted string is not code" {
  run hits $'  x="one\nsleep 9\ntwo"'
  assert_output ''
}

@test "a heredoc stub script is not code, and code after it is again" {
  run hits $'  cat > "$f" <<\'EOS\'\nsleep 4\nEOS\n  true'
  assert_output ''
  run hits $'  cat > "$f" <<EOS\nsleep 4\nEOS\n  sleep 1'
  assert_output --partial ':5:sleep 1'
  run hits $'  grep x <<<"$v"\n  sleep 1'
  assert_output --partial ':3:sleep 1'
}

@test "a backgrounded sleep fixture is not flagged" {
  run hits '  sleep 300 & local child=$!'
  assert_output ''
  run hits '  sleep 60 3>&- &'
  assert_output ''
  run hits '  sleep 1 && foo'
  assert_output --partial ':2:'
}

@test "a sleep inside a do...done poll is not flagged, one after it is" {
  run hits '  for i in $(seq 100); do flock -n x true || break; sleep 0.05; done'
  assert_output ''
  run hits $'  until test -f x\n  do\n    sleep 1\n  done'
  assert_output ''
  run hits $'  for i in 1 2; do sleep 1; done\n  sleep 2'
  assert_output --partial ':3:sleep 2'
}

@test "a sleep after then, else, elif, run or a case arm is flagged" {
  local l
  for l in '  if true; then sleep 1; fi' '  if x; then y; else sleep 1; fi' '  run sleep 1' \
    '  case $x in a) sleep 1;; esac'; do
    run hits "$l"
    assert_output --partial ':2:'
  done
}

@test "only a sleep's own statement can background it" {
  run hits '  sleep 2 &>/dev/null'
  assert_output --partial ':2:'
  run hits '  sleep 1; start_thing &'
  assert_output --partial ':2:'
  run hits '  sleep 300 & pid=$!; sleep 2'
  assert_output --partial ':2:'
  run hits '  sleep 300 & pid=$!'
  assert_output ''
  run hits '  { sleep 60 && kill -TERM "$w"; } 3>&- &'
  assert_output ''
  run hits '  { sleep 60 && kill -TERM "$w"; }'
  assert_output --partial ':2:'
}

@test "sleep as an argument on a continued line is not a statement" {
  run hits $'  run foo \\\n    sleep 1'
  assert_output ''
}

@test "the whole tree is clean" {
  cd "$BATS_TEST_DIRNAME/../.." || return 1
  run bash -c "find tests -name '*.bats' -not -path 'tests/vendor/*' -print0 | xargs -0 awk -f '$AWK'"
  assert_output ''
}
