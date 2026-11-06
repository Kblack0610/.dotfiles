#!/usr/bin/env bats
# block-poll.py: PreToolUse deny for the poll shapes that spend turns on waiting. Every allow
# case is the negative control for the deny case above it: same loop, one thing different.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  GUARD="$BATS_TEST_DIRNAME/../../.claude/hooks/block-poll.py"
}

fg() { jq -nc --arg c "$1" '{tool_name:"Bash", tool_input:{command:$c}}' | python3 "$GUARD"; }
bg() { jq -nc --arg c "$1" '{tool_name:"Bash", tool_input:{command:$c, run_in_background:true}}' | python3 "$GUARD"; }

# the reason leads with the hook's name: session-outcomes counts a denial by it (guards)
denied() { assert_success; assert_output --partial '"permissionDecision": "deny"'; assert_output --partial '"permissionDecisionReason": "block-poll: '; }
allowed() { assert_success; assert_output ""; }

@test "gh run watch is denied, foreground or background, and names agent-land" {
  run fg 'gh run watch 123456 --exit-status'
  denied
  assert_output --partial 'agent-land'
  run bg 'cd x && gh run watch'
  denied
}

@test "gh run view, gh run list, and a quoted pgrep pattern are allowed" {
  run fg "pgrep -fc 'gh run watch'"
  allowed
  run fg 'gh run view 123456 --log-failed | tail -n 40'
  allowed
  run fg 'gh run list --limit 5'
  allowed
}

@test "the overnight timeout-bash-until form is denied in the foreground" {
  run fg 'timeout 590 bash -c "until grep -q landed /tmp/x/tasks/b1.output; do sleep 20; done"; tail -n 5 /tmp/x/tasks/b1.output'
  denied
  assert_output --partial 'run_in_background'
}

@test "the same wait with run_in_background is allowed" {
  run bg 'timeout 590 bash -c "until grep -q landed /tmp/x/tasks/b1.output; do sleep 20; done"'
  allowed
}

@test "plain until, while-true and while-not loops that sleep are denied" {
  run fg 'until gh pr view 12 --json state -q .state | grep -q MERGED; do sleep 30; done'
  denied
  run fg 'while true; do gh pr checks 12 && break; sleep 15; done'
  denied
  run fg $'while ! test -f out.txt\ndo\n  sleep 5\ndone'
  denied
  run bash -c "jq -nc --arg c \"until x; do sleep 1; done\" '{tool_name:\"Bash\", tool_input:{command:\$c}}' | python3 '$GUARD'"
  denied
}

@test "a bash -lc payload is checked as code" {
  run fg "bash -lc 'until test -f done.flag; do sleep 2; done'"
  denied
}

@test "a for loop that sleeps and breaks out is a poll; one that only paces is not" {
  run fg 'for i in $(seq 60); do gh pr checks 12 >/dev/null && break; sleep 20; done'
  denied
  run fg 'for f in a b c; do curl -s "https://x/$f"; sleep 1; done'
  allowed
}

@test "loops that do not sleep, and while-read with a sleep, are allowed" {
  run fg 'git ls-files | while read -r f; do wc -l "$f"; done'
  allowed
  run fg 'until [ $n -ge 3 ]; do n=$((n+1)); done'
  allowed
  run fg 'cat urls | while read u; do curl -s "$u"; sleep 1; done'
  allowed
}

@test "a sleep after the loop is not a sleep inside it" {
  run fg 'for f in *.md; do echo "$f"; done; sleep 2'
  allowed
}

@test "a script file that loops is allowed" {
  run fg 'bash scripts/test/run.sh --filter Foo.Bar'
  allowed
}

@test "loop words in quoted text and in a heredoc body are not code" {
  run fg 'git commit -m "deny until/while loops that do sleep, and gh run watch; done"'
  allowed
  run fg $'cat > poll.sh <<\'EOF\'\nuntil test -f x; do sleep 5; done\nEOF\nchmod +x poll.sh'
  allowed
}

@test "a loop after a heredoc is still checked" {
  run fg $'cat > a.txt <<EOF\nhi\nEOF\nuntil test -f x; do sleep 5; done'
  denied
}

@test "a second loop is checked when the first is innocent" {
  run fg 'for f in a b; do echo $f; done; until test -f x; do sleep 5; done'
  denied
}

@test "other tools and bad input fail open" {
  run bash -c "echo '{\"tool_name\":\"Read\",\"tool_input\":{\"file_path\":\"/x\"}}' | python3 '$GUARD'"
  allowed
  run bash -c "echo 'not json' | python3 '$GUARD'"
  allowed
}

@test "the settings.json command fails open when the hook file is missing" {
  # python3 exits 2 on a missing script, and exit 2 from a PreToolUse hook blocks every Bash call.
  cmd=$(jq -r '.hooks.PreToolUse[].hooks[].command | select(test("block-poll"))' "$BATS_TEST_DIRNAME/../../.claude/settings.json")
  [ -n "$cmd" ]
  run env HOME="$BATS_TEST_TMPDIR" bash -c "echo '{}' | $cmd"
  assert_success
}

# A live background run holds its tasks/<id>.output open; the guard scans /proc for that holder (lsof where there is no /proc).
# The id is unique to the test, since the unit tier runs tests in parallel and every process is scanned.
live_task() {
  TASK_ID="bp${$}x${BATS_TEST_NUMBER}x${RANDOM}"
  OUT="$BATS_TEST_TMPDIR/sess/tasks/$TASK_ID.output"
  mkdir -p "${OUT%/*}"
  sleep 60 > "$OUT" &
  HOLDER=$!
}

@test "reading a live background task's output in the foreground is denied" {
  live_task
  run fg "tail -n 20 $OUT"
  kill "$HOLDER"
  denied
  assert_output --partial "$TASK_ID is still running"
  assert_output --partial 'Monitor'
}

@test "the same read is allowed once the run exits, and in the background while it runs" {
  live_task
  run bg "until grep -q done $OUT; do sleep 5; done"
  allowed
  kill "$HOLDER"; wait "$HOLDER" 2>/dev/null || true
  run fg "tail -n 20 $OUT"
  allowed
  run fg "cat $BATS_TEST_TMPDIR/sess/tasks/nobody${RANDOM}.output"
  allowed
}
