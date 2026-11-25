#!/usr/bin/env bats
# shared-state-guard.py: a session may not take the top of the stash stack every worktree shares,
# leave an unnamed stash, or switch an agentctl unit off behind its conf (ar-5505). The guard only
# parses the command; nothing here runs git stash or systemctl.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  GUARD="$BATS_TEST_DIRNAME/../../.claude/hooks/shared-state-guard.py"
  mkdir -p "$BATS_TEST_TMPDIR/work"
}

at() { jq -nc --arg c "$1" --arg d "$BATS_TEST_TMPDIR/work" '{tool_name:"Bash", cwd:$d, tool_input:{command:$c}}' | python3 "$GUARD"; }

denied() { assert_success; assert_output --partial '"deny"'; assert_output --partial 'shared-state-guard:'; }
allowed() { assert_success; assert_output ''; }

@test "a stash command that takes the top entry, clears the stack or leaves an unnamed entry is denied" {
  local c
  for c in 'git stash' 'git stash -u' 'git stash push' 'git stash push -u -- a.txt' 'git stash save' \
    'git stash pop' 'git stash pop stash@{1}' 'git stash apply' 'git stash apply --index' 'git stash drop' \
    'git stash drop -q' 'git stash clear' 'git stash branch tmp' 'git -C /w stash pop' \
    "bash -c 'git stash pop'" 'cd /w && git stash' 'sudo git stash pop'; do
    run at "$c"
    denied
  done
  assert_output --partial 'git stash push -u -m'
  assert_output --partial 'git stash apply <sha>'
}

@test "a named push and a stash command that names its entry pass, and so do the read-only ones" {
  local c
  for c in 'git stash push -u -m "p7-ab"' 'git stash push --message=p7-ab' 'git stash -um p7-ab' 'git stash save p7-ab' \
    'git stash apply 3f2a9c1' 'git stash apply stash@{2}' 'git stash drop stash@{0}' 'git stash branch tmp stash@{1}' \
    'git stash list' "git stash list --format='%H %gs'" 'git stash show -p' 'git stash create' 'git stash store 3f2a9c1' \
    'git commit -m "git stash pop"' 'rg "git stash pop" docs'; do
    run at "$c"
    allowed
  done
}

@test "systemctl stop, disable or mask of an agentctl timer or service is denied, naming agentctl disable" {
  local c
  for c in 'systemctl --user stop agentctl-comms.timer' 'systemctl stop --user agentctl@comms.service' \
    'systemctl --user disable --now agentctl-comms.timer' 'systemctl --user mask agentctl-dream.timer' \
    "systemctl --user stop 'agentctl-*.timer'" 'systemctl --user stop foo.service agentctl-comms.timer' \
    'systemctl -q --user stop agentctl-comms.timer'; do
    run at "$c"
    denied
  done
  assert_output --partial 'agentctl disable <name>'
  assert_output --partial 'agentctl reload'
}

@test "reading an agentctl unit, starting one and stopping another unit pass" {
  local c
  for c in 'systemctl --user status agentctl-comms.timer' 'systemctl --user list-timers --all agentctl-*' \
    'systemctl --user start agentctl@comms.service' 'systemctl --user restart agentctl@comms.service' \
    'systemctl --user stop pipewire.service' 'agentctl disable comms' 'agentctl stop comms' \
    'systemctl --user show -p ActiveState agentctl-comms.timer'; do
    run at "$c"
    allowed
  done
}

@test "a payload for another tool, or one it cannot read, is allowed" {
  run bash -c "jq -nc '{tool_name:\"Read\", tool_input:{file_path:\"/x\"}}' | python3 '$GUARD'"
  allowed
  run bash -c "printf 'not json' | python3 '$GUARD'"
  allowed
}
