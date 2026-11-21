#!/usr/bin/env bats
# session-preflight.sh: a session started while gh is signed out on this host is told at turn 1
# that only the human signs it back in, so it does not rebuild the login itself (ar-2876).

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic

  gh_script 'exit 1'
  unset GH_TOKEN GITHUB_TOKEN GH_CONFIG_DIR XDG_CONFIG_HOME

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
}

context() {
  bash "$DEPLOY/session-preflight.sh" </dev/null 2>/dev/null \
    | jq -r '.hookSpecificOutput.additionalContext // empty' 2>/dev/null
}

@test "no github.com login in hosts.yml: turn 1 says gh is signed out and only the human redoes it" {
  mkdir -p "$HOME/.config/gh"
  run context
  assert_success
  assert_output --partial 'gh is signed out on'
  assert_output --partial 'Only the human signs it back in'
  assert_output --partial '/gh:auth'
}

@test "a github.com login, or a GH_TOKEN, prints nothing about it" {
  mkdir -p "$HOME/.config/gh"
  printf 'github.com:\n    user: someone\n' > "$HOME/.config/gh/hosts.yml"
  run context
  assert_success
  assert_output --partial 'Session Preflight'
  refute_output --partial 'signed out'
  rm "$HOME/.config/gh/hosts.yml"
  GH_TOKEN=x run context
  refute_output --partial 'signed out'
}

@test "a host where gh was never set up (no config dir) prints nothing about it" {
  rm -rf "$HOME/.config/gh"
  run context
  assert_success
  refute_output --partial 'signed out'
}
