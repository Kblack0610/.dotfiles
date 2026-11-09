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
