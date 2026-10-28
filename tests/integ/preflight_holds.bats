#!/usr/bin/env bats
# session-preflight.sh: a session started while a fleet hold is set must see it at turn 1,
# because the coordinator's messages only reached the sessions running at the time.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic

  printf '#!/usr/bin/env bash\nexit 1\n' > "$SANDBOX/bin/gh"
  chmod +x "$SANDBOX/bin/gh"

  REPO="$SANDBOX/repo"
  mkdir -p "$REPO"
  git -C "$REPO" init -q .
  git -C "$REPO" config user.email t@example.com
  git -C "$REPO" config user.name tester
  echo hello > "$REPO/a.txt"
  git -C "$REPO" add -A
  git -C "$REPO" commit -qm "first commit"
  export CLAUDE_PROJECT_DIR="$REPO"

  DEPLOY="$SANDBOX/shared-hooks"
  mkdir -p "$DEPLOY"
  cp "$REPO_ROOT/.config/shared-hooks/session-preflight.sh" \
     "$REPO_ROOT/.config/shared-hooks/project-name.sh" "$DEPLOY/"

  export AGENT_HOLD_DIR="$HOME/.agent/holds"
}

context() {
  bash "$DEPLOY/session-preflight.sh" </dev/null 2>/dev/null \
    | jq -r '.hookSpecificOutput.additionalContext // empty' 2>/dev/null
}

@test "an active hold is printed with who set it and why" {
  "$REPO_ROOT/.local/bin/agent-hold" set unity-tests --by cap-concurrent "96 C, 16 editors"
  run context
  assert_success
  assert_output --partial 'Active holds'
  assert_output --partial 'unity-tests since'
  assert_output --partial 'by cap-concurrent: 96 C, 16 editors'
}

@test "no hold, no block" {
  run context
  assert_success
  assert_output --partial 'Session Preflight'
  refute_output --partial 'Active holds'
}

@test "a released hold disappears" {
  "$REPO_ROOT/.local/bin/agent-hold" set unity-tests --by c "hot"
  "$REPO_ROOT/.local/bin/agent-hold" release unity-tests
  run context
  refute_output --partial 'Active holds'
}
