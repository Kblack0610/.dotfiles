#!/usr/bin/env bats
# hand_methods.py: the PreToolUse guard that denies a hand-typed form a skill's metadata.replaces
# names. Every allow case is the negative control for the deny case above it.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  REPO="$BATS_TEST_DIRNAME/../.."
  GUARD="$REPO/.claude/hooks/hand_methods.py"
  export CLAUDE_SKILLS="$BATS_TEST_TMPDIR/skills" XDG_CACHE_HOME="$BATS_TEST_TMPDIR/cache"
  mkdir -p "$CLAUDE_SKILLS"
  # The real row this PR moved out of block-poll.py, read from the skill that owns it.
  ln -s "$REPO/.claude/skills/ops/gh-workflows" "$CLAUDE_SKILLS/gh-workflows"
  mkdir -p "$CLAUDE_SKILLS/fixture"
  cat >"$CLAUDE_SKILLS/fixture/SKILL.md" <<'EOF'
---
name: fixture
description: test fixture
metadata:
  replaces:
    - match: '\s-executeMethod\s'
      use: scripts/authoring/unity-method.sh <Method>
      mode: deny
      where: unity-core-playground
      unless: 'cd [^;&|]*asset-library'
      why: a bare -batchmode skips the run slots
    - match: 'affected-classes\.py'
      use: scripts/test/gate-and-land.sh
      mode: report
    - match: '(unclosed'
      use: broken row, skipped
---
body
EOF
}

run_guard() { # <command> [cwd] [background]
  jq -nc --arg c "$1" --arg d "${2:-/tmp}" --argjson b "${3:-false}" \
    '{tool_name:"Bash", cwd:$d, tool_input:{command:$c, run_in_background:$b}}' | python3 "$GUARD"
}

# the reason leads with the hook's name: session-outcomes counts a denial by it (guards)
denied() { assert_success; assert_output --partial '"permissionDecision": "deny"'; assert_output --partial '"permissionDecisionReason": "hand-methods: '; }
allowed() { assert_success; assert_output ""; }

@test "gh run watch is denied, foreground or background, and names agent-land and gh-run-wait" {
  run run_guard 'gh run watch 123456 --exit-status'
  denied
  assert_output --partial 'agent-land <N>'
  assert_output --partial 'gh-run-wait <run-id>'
  assert_output --partial 'gh-workflows'
  run run_guard 'cd x && gh run watch' /tmp true
  denied
  run run_guard "bash -c 'gh run watch 1'"
  denied
}

@test "gh run view, gh run list, a quoted pgrep pattern and a commit message are allowed" {
  run run_guard "pgrep -fc 'gh run watch'"
  allowed
  run run_guard 'gh run view 123456 --log-failed | tail -n 40'
  allowed
  run run_guard 'gh run list --limit 5'
  allowed
  run run_guard 'git commit -m "deny gh run watch"'
  allowed
}

@test "gh run rerun and gh api .../rerun are denied unless the command names the infra fault" {
  run run_guard 'gh run rerun 1 --failed'
  denied
  assert_output --partial 'fix-ci'
  assert_output --partial '# infra: <fault>'
  run run_guard 'gh api -X POST repos/o/r/actions/runs/1/rerun-failed-jobs'
  denied
  run run_guard 'gh api -X POST repos/o/r/actions/jobs/2/rerun'
  denied
  run run_guard 'cd x && gh run rerun 1'
  denied
  # a quoted endpoint, a query string and a path-qualified gh do not slip past
  run run_guard 'gh api -X POST "repos/$R/actions/runs/$ID/rerun-failed-jobs"'
  denied
  run run_guard "gh api 'repos/o/r/actions/runs/1/rerun' --method POST"
  denied
  run run_guard 'gh api -X POST repos/o/r/actions/runs/1/rerun?x=1'
  denied
  run run_guard '/usr/bin/gh run rerun 1'
  denied
  # a quoted plain word is bare to the kill rows, but the rerun row still reads it as a quoted endpoint (ar-4588)
  run run_guard "gh api 'user' -X POST"
  denied
  run run_guard "gh api -X POST 'graphql'"
  denied
  # a bare marker with no fault, and a marker inside quotes, are not a named fault
  run run_guard 'gh run rerun 1 --failed  # infra:'
  denied
  run run_guard "echo '# infra: runner lost'; gh run rerun 1"
  denied
}

@test "a rerun that names its infra fault, and gh run view or a quoted mention, are allowed" {
  run run_guard 'gh run rerun 1 --failed  # infra: runner lost'
  allowed
  run run_guard 'gh api -X POST repos/o/r/actions/runs/1/rerun-failed-jobs # infra: registry 503'
  allowed
  run run_guard 'gh run view 1 --log-failed | tail -n 40'
  allowed
  run run_guard 'gh api repos/o/r/actions/runs/1'
  allowed
  run run_guard 'gh api repos/o/r/contents/rerun'
  allowed
  run run_guard 'gh api -X POST repos/o/r/issues/1/comments -f body="rerun"'
  allowed
  run run_guard 'git commit -m "no blind gh run rerun"'
  allowed
}

@test "gh run cancel and gh api .../runs/<id>/cancel are denied unless the command says own or stuck" {
  run run_guard 'gh run cancel 1'
  denied
  run run_guard 'for r in $(gh run list -q ".[].databaseId"); do gh run cancel "$r"; done'
  denied
  run run_guard 'gh api -X POST repos/o/r/actions/runs/1/cancel'
  denied
  run run_guard 'gh api -X POST repos/o/r/actions/runs/1/force-cancel'
  denied
  run run_guard '/usr/bin/gh run cancel 1 # own:'
  denied
  run run_guard 'gh run cancel 1 -R o/r'
  denied
  run run_guard 'gh -R o/r run cancel 1'
  denied
  run run_guard 'gh --repo=o/r run cancel 1'
  denied
  run run_guard 'gh api -X POST "repos/o/r/actions/runs/1/cancel"'
  denied
}

@test "the cancel denial carries its full why" {
  run run_guard 'gh run cancel 1'
  denied
  assert_output --partial 'ar-3299'
}

@test "a cancel that names its own superseded run or a stuck step is allowed; view and quoted mentions are too" {
  run run_guard 'gh run cancel 1  # own: #2526 superseded'
  allowed
  run run_guard 'gh api -X POST repos/o/r/actions/runs/1/cancel # stuck: Run tests, 40 min'
  allowed
  run run_guard 'gh run cancel 12 -R o/r # own: 2526'
  allowed
  run run_guard 'gh run view 1'
  allowed
  run run_guard 'gh api repos/o/r/actions/runs/1'
  allowed
  run run_guard 'git commit -m "never gh run cancel another PR"'
  allowed
}

@test "a substitution inside single quotes is literal; one inside double quotes runs" {
  run run_guard "git commit -m 'drop \`gh run watch\` and \$(gh run watch)'"
  allowed
  run run_guard 'echo "$(gh run watch 1)"'
  denied
  run run_guard 'echo `gh run watch 1`'
  denied
}

@test "frontmatter ends only at a line that is exactly ---, CRLF too" {
  printf -- '---\r\nname: crlf\r\ndescription: x\r\nmetadata:\r\n  replaces:\r\n    - match: zzcrlf\r\n      use: y\r\n---\r\nbody\r\n' > "$CLAUDE_SKILLS/fixture/SKILL.md"
  run python3 "$GUARD" --list
  assert_output --partial 'fixture#1'
  printf -- '---\nname: f\ndescription: x\nmetadata:\n  replaces:\n    - match: zzdash\n      use: y\n      why: "----"\n---\n' > "$CLAUDE_SKILLS/fixture/SKILL.md"
  run python3 "$GUARD" --check "$CLAUDE_SKILLS/fixture/SKILL.md"
  assert_output ""
  run python3 "$GUARD" --list
  assert_output --partial 'zzdash'
}

@test "a rebuild that could not read a skill is not cached, so the next call retries" {
  chmod 000 "$CLAUDE_SKILLS/fixture/SKILL.md"
  run run_guard 'gh run watch 1'
  denied
  run bash -c 'ls "$XDG_CACHE_HOME"/claude-hooks/replaces-*.json'
  assert_failure
  chmod 644 "$CLAUDE_SKILLS/fixture/SKILL.md"
  run run_guard 'U -batchmode -executeMethod A.B.C' /x/unity-core-playground
  denied
  run bash -c 'ls "$XDG_CACHE_HOME"/claude-hooks/replaces-*.json'
  assert_success
}

@test "where scopes a row to a working directory" {
  run run_guard 'U -batchmode -executeMethod A.B.C -quit' /home/u/.worktrees/unity-core-playground-x
  denied
  assert_output --partial 'unity-method.sh'
  assert_output --partial 'Why: a bare -batchmode skips the run slots'
  run run_guard 'U -batchmode -executeMethod A.B.C -quit' /home/u/dev/other-game
  allowed
}

@test "a playground run cancel goes through gh-run-cancel.sh, even with own or stuck" {
  ln -s "$REPO/.claude/skills/ops/playground-headless-test" "$CLAUDE_SKILLS/playground-headless-test"
  run run_guard 'gh run cancel 46041044210 # own: ucp-1456 superseded by 285c' /home/u/.worktrees/unity-core-playground-agent-3
  denied
  assert_output --partial 'gh-run-cancel.sh'
  run run_guard 'gh api -X POST repos/{owner}/{repo}/actions/runs/1/cancel # stuck: Run tests' /x/unity-core-playground
  denied
  run run_guard 'gh run cancel 45277619723 -R org/unity-core-playground # own: 9acd867773' /tmp
  denied
  run run_guard 'gh -R org/unity-core-playground run cancel 1 # own: #2' /tmp
  denied
  run run_guard 'gh api -X POST repos/org/unity-core-playground/actions/runs/1/cancel # own: #2' /tmp
  denied
  run run_guard 'scripts/test/gh-run-cancel.sh 1 "superseded by 285c"' /x/unity-core-playground
  allowed
  run run_guard 'gh run cancel 1 -R o/other # own: #2' /tmp
  allowed
  run run_guard 'GH_REPO=org/unity-core-playground gh run cancel 1 # own: #2' /tmp
  denied
  run run_guard 'cd ~/dev/unity-core-playground && gh run cancel 1 # own: x' /tmp
  denied
  run run_guard 'gh run cancel 1 -Rorg/unity-core-playground # own: #2' /tmp
  denied
  run run_guard 'gh --repo=org/unity-core-playground run cancel 1' /tmp
  denied
  run run_guard 'gh api -X POST repos/{owner}/{repo}/actions/runs/1/force-cancel' /x/unity-core-playground
  denied
  run run_guard 'gh run cancel 1 # own: #2' /home/u/.worktrees/other
  allowed
  run run_guard 'gh run cancel 9 -R o/other # own: #1' /x/unity-core-playground
  allowed
  run run_guard 'gh workflow run cancel.yml --ref x' /x/unity-core-playground
  allowed
  run run_guard 'gh run view 1 --json status' /x/unity-core-playground
  allowed
}

@test "unless lets a named exception through" {
  run run_guard 'cd ~/.worktrees/asset-library-fx && U -batchmode -executeMethod A.B.C' /x/unity-core-playground
  allowed
}

@test "a grep for the form is not the form" {
  run run_guard 'grep -n " -executeMethod " scripts/x.sh' /x/unity-core-playground
  allowed
}

@test "a report row and an invalid row never deny" {
  run run_guard 'scripts/test/affected-classes.py "$b" HEAD > Logs/classes.txt'
  allowed
  run run_guard 'echo (unclosed'
  allowed
}

@test "--list prints the valid rows and skips the invalid one" {
  run python3 "$GUARD" --list
  assert_success
  assert_output --partial 'gh-workflows#1'
  assert_output --partial 'fixture#1'
  assert_output --partial 'fixture#2'
  refute_output --partial 'fixture#3'
}

@test "the cache follows a SKILL.md edit" {
  run run_guard 'scripts/test/affected-classes.py x' /tmp
  allowed
  sed -i 's/mode: report/mode: deny/' "$CLAUDE_SKILLS/fixture/SKILL.md"
  touch -d '+1 second' "$CLAUDE_SKILLS/fixture/SKILL.md"
  run run_guard 'scripts/test/affected-classes.py x' /tmp
  denied
}

@test "fail-open: bad input, no skills dir, a non-Bash tool" {
  run bash -c "echo 'not json' | python3 '$GUARD'"
  allowed
  run bash -c "CLAUDE_SKILLS=/nonexistent; export CLAUDE_SKILLS; jq -nc '{tool_name:\"Bash\",tool_input:{command:\"gh run watch\"}}' | python3 '$GUARD'"
  allowed
  run bash -c "jq -nc '{tool_name:\"Read\",tool_input:{file_path:\"gh run watch\"}}' | python3 '$GUARD'"
  allowed
}
