#!/usr/bin/env bats
# block-pkill-f.sh: a -f kill pattern is denied, a kill by name or PID is not.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  HOOK="$BATS_TEST_DIRNAME/../../.claude/hooks/block-pkill-f.sh"
}

# The hook prints nothing to allow, so an empty reply reads as allow.
decision() {
  local out
  out=$(jq -nc --arg c "$1" '{tool_name:"Bash", tool_input:{command:$c}}' | bash "$HOOK")
  if [ -z "$out" ]; then echo allow; else jq -r .hookSpecificOutput.permissionDecision <<<"$out"; fi
}

@test "pkill -f is denied in any clause and flag spelling, the reason leading with the hook's name" {
  for c in 'pkill -f foo' 'sleep 1; pkill -9 -f "bats.*x"' 'sudo pkill -f x' 'x && pkill --full y' 'pkill -9f z' 'LC_ALL=C pkill -f w'; do
    run decision "$c"
    assert_output deny
  done
  run bash -c "jq -nc '{tool_input:{command:\"pkill -f x\"}}' | bash '$HOOK' | jq -r .hookSpecificOutput.permissionDecisionReason"
  assert_output --partial 'block-pkill-f: '
  assert_output --partial 'pkill -x <name>'
}

@test "a pgrep -f whose matches get killed is denied" {
  run decision 'kill $(pgrep -f foo)'
  assert_output deny
  run decision 'pgrep -f foo | xargs kill -9'
  assert_output deny
}

@test "negative control: a kill by name, a read-only pgrep -f and text naming pkill -f all pass" {
  for c in 'pkill -x foo' 'pkill foo' 'pkill -9 foo' 'pgrep -af claude' 'grep -n "pkill -f" f' 'echo pkill -f' 'git commit -m "no pkill -f"' 'ls'; do
    run decision "$c"
    assert_output allow
  done
}
