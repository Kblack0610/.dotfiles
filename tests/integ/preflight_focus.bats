#!/usr/bin/env bats
# session-preflight.sh: the turn-1 context injection. These tests cover exactly one
# property -- that a partial deploy cannot silence the whole hook.
#
# The hooks ship via `stow --no-folding .`, one symlink per file, so a checkout can reach a
# commit that adds focus-lib.sh before stow has linked it. Under `set -e` an unguarded
# source of the missing lib exits the script before it prints anything, and the only
# symptom is an empty turn 1: no anchor, no plans, no lessons, no git context, no error
# anyone sees. That is a much worse failure than losing the Focus block, so the source is
# guarded and the Focus block is skipped when the lib did not load.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic

  # gh is the one network-reaching call in the hook. Stub it so this test is hermetic and
  # does not depend on a runner having credentials (or a repo having a remote).
  cat > "$SANDBOX/bin/gh" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
  chmod +x "$SANDBOX/bin/gh"

  # A disposable repo to be the project dir, so the git section has something to read.
  REPO="$SANDBOX/repo"
  mkdir -p "$REPO"
  git -C "$REPO" init -q .
  git -C "$REPO" config user.email t@example.com
  git -C "$REPO" config user.name tester
  echo hello > "$REPO/a.txt"
  git -C "$REPO" add -A
  git -C "$REPO" commit -qm "first commit"
  export CLAUDE_PROJECT_DIR="$REPO"

  # A deploy dir holding the hook and its required sibling, mirroring the stow layout.
  DEPLOY="$SANDBOX/shared-hooks"
  mkdir -p "$DEPLOY"
  cp "$REPO_ROOT/.config/shared-hooks/session-preflight.sh" \
     "$REPO_ROOT/.config/shared-hooks/project-name.sh" "$DEPLOY/"
}

# context -- the injected additionalContext string, or empty if the hook produced nothing.
context() {
  bash "$DEPLOY/session-preflight.sh" </dev/null 2>/dev/null \
    | jq -r '.hookSpecificOutput.additionalContext // empty' 2>/dev/null
}

@test "with focus-lib present the hook emits context including the Focus block" {
  cp "$REPO_ROOT/.config/shared-hooks/focus-lib.sh" "$DEPLOY/"
  run context
  assert_success
  assert_output --partial 'Session Preflight'
  assert_output --partial 'Recent commits'
  assert_output --partial 'Focus'
}

@test "with focus-lib missing the hook still exits 0" {
  # The regression: `set -e` plus an unguarded source made this exit 1.
  rm -f "$DEPLOY/focus-lib.sh"
  run bash "$DEPLOY/session-preflight.sh" </dev/null
  assert_success
}

@test "with focus-lib missing the rest of the context still ships" {
  # This is the whole point. Losing Focus is survivable; losing the anchor, the plans, the
  # lessons and the git context at turn 1, silently, is not.
  rm -f "$DEPLOY/focus-lib.sh"
  run context
  assert_output --partial 'Session Preflight'
  assert_output --partial 'Recent commits'
  assert_output --partial 'first commit'
}

@test "with focus-lib missing the Focus block is skipped, not half-rendered" {
  # A half-rendered block would mean the functions were called anyway and errored inline.
  rm -f "$DEPLOY/focus-lib.sh"
  run context
  refute_output --partial 'Focus (today'
  refute_output --partial 'focus_daily_note'
  refute_output --partial 'command not found'
}
