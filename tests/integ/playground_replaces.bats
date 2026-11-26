#!/usr/bin/env bats
# playground-headless-test's metadata.replaces rows, read from the real SKILL.md: each deny row
# refuses its hand form inside a playground checkout and allows the script it names; outside the
# playground, and in its asset-library project, nothing is denied.

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
  # the same copy in another shape is still the copy
  run guard 'tail -1 Logs/gate.txt | tee -a Logs/pr-body.md'
  assert_output deny
}

@test "a bare Unity -runTests or -executeMethod is denied; the scripts are allowed" {
  run guard '"$U" -batchmode -projectPath . -runTests -testPlatform PlayMode'
  assert_output deny
  run guard '"$U" -batchmode -quit -executeMethod A.B.C'
  assert_output deny
  run guard 'gh workflow run test.yml --ref feat/x -f classes=affected -f only=A.B'
  assert_output ""
  run guard 'scripts/authoring/unity-method.sh A.B.C'
  assert_output ""
  run guard 'rg -n "runTests" scripts/test/run.sh'
  assert_output ""
  run guard 'grep -n -- -runTests scripts/test/run.sh'
  assert_output ""
}

@test "an agent's local Unity test run is denied: run.sh, a suite that stays here, in-docker.sh (ar-4849)" {
  # Negative control: delete the run.sh, suite.sh and in-docker.sh rows from the skill and every
  # deny here reads "".
  for c in 'scripts/test/run.sh --filter A.B' './scripts/test/run.sh --platform EditMode' \
           'cd x && FOO=1 timeout -k 5 600 scripts/test/run.sh --filter A | tail -n 40' \
           '"$ROOT"/scripts/test/run.sh --filter A' 'bash -c "scripts/test/run.sh --filter A"' \
           'for c in A B; do scripts/test/run.sh --filter $c; done' \
           'scripts/test/suite.sh' 'scripts/test/suite.sh --only PlayMode --classes f' \
           'nohup scripts/test/suite.sh --classes f --all-red &' \
           'scripts/test/in-docker.sh --filter A' 'sh scripts/test/in-docker.sh --suite'; do
    run guard "$c"
    assert_output deny
  done
  # wrappers with flags, the other player scripts, and an allowed segment beside a denied one
  for c in 'env -i scripts/test/run.sh --filter A' 'nice -n 10 scripts/test/run.sh --filter A' \
           'echo A | xargs -n1 scripts/test/run.sh --filter' 'time -p scripts/test/run.sh --filter A' \
           '! scripts/test/run.sh --filter A' 'command scripts/test/run.sh --filter A' \
           'bash -x scripts/test/run.sh --filter A' 'scripts/test/two-process.sh --server p --filter A' \
           'scripts/test/multi-process.sh --filter A' 'scripts/test/suite.sh --classes f; scripts/test/suite.sh' \
           'scripts/test/in-docker.sh --build' 'scripts/test/in-docker.sh --suite --method A.B.C'; do
    run guard "$c"
    assert_output deny
  done
  # the pool forms, an editor method or build in docker, and reading or linting the scripts
  for c in 'scripts/test/suite.sh --classes f.txt' 'scripts/test/suite.sh --editmode-classes e --classes f' \
           'scripts/test/in-docker.sh --method A.B.C' 'scripts/test/gate-and-land.sh --title t --item s' \
           'cat a.sh scripts/test/run.sh' 'rg -n x scripts/test/run.sh' 'git diff scripts/test/suite.sh' \
           'shellcheck scripts/test/run.sh scripts/test/suite.sh' 'bash -n scripts/test/run.sh' \
           'git commit -m "scripts/test/run.sh refuses"'; do
    run guard "$c"
    assert_output ""
  done
  # another repo's run.sh and the asset-library project are not the playground's (a person's shell runs no hook)
  run guard 'scripts/test/run.sh --filter A.B' /home/u/src/other-game
  assert_output ""
  run guard 'scripts/test/run.sh --filter A.B' "$PG/External/asset-library"
  assert_output ""
}

@test "negative controls: asset-library by cd or by cwd, another repo, and the diagnosis pick" {
  run guard 'cd External/asset-library && "$U" -batchmode -executeMethod A.B.C'
  assert_output ""
  run guard '"$U" -batchmode -executeMethod A.B.C' "$PG/External/asset-library"
  assert_output ""
  run guard '"$U" -batchmode -runTests' /home/u/src/other-game
  assert_output ""
  run guard "{ grep '^CI gate green' Logs/gate.txt; } >> Logs/pr-body.md" /home/u/src/other-game
  assert_output ""
  # the nightly-red runbook runs affected-classes.py --why by hand to name a merge: not a bypass
  run guard 'scripts/test/affected-classes.py m^1 m --why'
  assert_output ""
}
