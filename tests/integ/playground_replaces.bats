#!/usr/bin/env bats
# playground-headless-test's metadata.replaces rows, read from the real SKILL.md: each deny row
# refuses its hand form inside a playground checkout and allows the script it names; outside the
# playground nothing is denied; the report row never denies.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic
  GUARD="$REPO_ROOT/.claude/hooks/hand_methods.py"
  export CLAUDE_SKILLS="$SANDBOX/skills" XDG_CACHE_HOME="$SANDBOX/cache"
  mkdir -p "$CLAUDE_SKILLS"
  ln -s "$REPO_ROOT/.claude/skills/ops/playground-headless-test" "$CLAUDE_SKILLS/"
  PG=/home/u/.worktrees/unity-core-playground-x
}

# guard <command> [cwd]: prints deny, or nothing when the call is allowed.
guard() {
  jq -nc --arg c "$1" --arg d "${2:-$PG}" '{tool_name:"Bash",tool_input:{command:$c},cwd:$d}' \
    | python3 "$GUARD" | jq -r '.hookSpecificOutput.permissionDecision // empty'
}

@test "the rows parse with no lint problem" {
  run python3 "$GUARD" --check "$CLAUDE_SKILLS/playground-headless-test/SKILL.md"
  assert_success
  assert_output ""
}

@test "the hand gate block is denied; gate-and-land.sh and other body writes are allowed" {
  run guard "{ grep '^CI gate green' Logs/gate.txt || true; } >> Logs/pr-body.md && gh pr create --body-file Logs/pr-body.md"
  assert_output deny
  run guard 'scripts/test/gate-and-land.sh --title t --item s --partial'
  assert_output ""
  run guard 'echo "- note" >> Logs/pr-body.md'
  assert_output ""
}

@test "a bare Unity -runTests or -executeMethod is denied; the scripts are allowed" {
  run guard '"$U" -batchmode -projectPath . -runTests -testPlatform PlayMode'
  assert_output deny
  run guard '"$U" -batchmode -quit -executeMethod A.B.C'
  assert_output deny
  run guard 'scripts/test/run.sh --filter A.B'
  assert_output ""
  run guard 'scripts/authoring/unity-method.sh A.B.C'
  assert_output ""
  run guard 'rg -n "runTests" scripts/test/run.sh'
  assert_output ""
}

@test "negative controls: asset-library, another repo, and the report row" {
  run guard 'cd External/asset-library && "$U" -batchmode -executeMethod A.B.C'
  assert_output ""
  run guard '"$U" -batchmode -runTests' /home/u/src/other-game
  assert_output ""
  run guard 'scripts/test/affected-classes.py base HEAD'
  assert_output ""
}
