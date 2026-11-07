#!/usr/bin/env bats
# pre-pr-verify.sh: a push or PR from a tree whose picked tests fail is denied; a pass is
# remembered per tree state; any other command never runs the check.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  HOOK="$BATS_TEST_DIRNAME/../../.claude/hooks/pre-pr-verify.sh"
  T="$BATS_TEST_TMPDIR"
  export XDG_CACHE_HOME="$T/cache" PRE_PR_CHECK="$T/check.sh"
  REPO="$T/repo"
  git init -q "$REPO" && git -C "$REPO" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
  # The check stub records each run and the tree it was given, and exits $CHECK_RC.
  cat > "$PRE_PR_CHECK" <<STUB
#!/bin/sh
echo "\$CLAUDE_PROJECT_DIR" >> "$T/runs"
echo "not ok 1 the picked test"
exit \${CHECK_RC:-0}
STUB
}

hook() { jq -nc --arg c "$1" --arg d "${2:-$REPO}" '{tool_name:"Bash", cwd:$d, tool_input:{command:$c}}' | bash "$HOOK"; }
runs() { if [ -f "$T/runs" ]; then grep -c . "$T/runs"; else echo 0; fi; }

@test "a red check denies the push, with the failing lines in the reason" {
  export CHECK_RC=2
  run hook 'git push -u origin feat/x'
  assert_success
  run jq -r .hookSpecificOutput.permissionDecision <<<"$output"
  assert_output deny
  run bash -c "jq -nc --arg d '$REPO' '{cwd:\$d, tool_input:{command:\"gh pr create --fill\"}}' | bash '$HOOK' | jq -r .hookSpecificOutput.permissionDecisionReason"
  assert_output --partial 'pre-pr-verify: '
  assert_output --partial 'not ok 1 the picked test'
}

@test "a green check allows, and the PR after the push reuses the pass" {
  run hook 'git push -u origin feat/x'
  assert_success
  assert_output ''
  run hook 'gh pr create --fill'
  assert_output ''
  [ "$(runs)" = 1 ]
  grep -q ' cached ' "$XDG_CACHE_HOME/claude-stop-hook/pre-pr.log"
}

@test "a new commit runs the check again" {
  hook 'git push'
  git -C "$REPO" -c user.name=t -c user.email=t@t commit -q --allow-empty -m two
  hook 'git push'
  [ "$(runs)" = 2 ]
}

@test "the tree checked is the one a leading cd or git -C names" {
  other="$T/other repo"
  git init -q "$other" && git -C "$other" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
  hook "cd '$other' && git push" "$T"
  hook "git -C $REPO push" "$T"
  run cat "$T/runs"
  assert_line "$other"
  assert_line "$REPO"
}

@test "negative control: other commands, a branch delete and a non-repo cwd never run the check" {
  export CHECK_RC=2
  for c in 'git status' 'echo git push' 'gh pr view 1' 'git push origin --delete old' 'git commit -m "then git push"'; do
    run hook "$c"
    assert_output ''
  done
  run hook 'git push' "$T"
  assert_output ''
  [ "$(runs)" = 0 ]
}

@test "PRE_PR_VERIFY=main-red lets a known main red through, and is logged" {
  export CHECK_RC=2
  run hook 'PRE_PR_VERIFY=main-red git push'
  assert_output ''
  [ "$(runs)" = 0 ]
  grep -q ' main-red ' "$XDG_CACHE_HOME/claude-stop-hook/pre-pr.log"
}

@test "a check that cannot say red (a warn or a timeout) allows, and nothing is remembered" {
  export CHECK_RC=1
  run hook 'git push'
  assert_output ''
  run hook 'git push'
  [ "$(runs)" = 2 ]
}
