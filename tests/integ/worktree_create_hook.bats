#!/usr/bin/env bats
# worktree-create.sh -- the Claude Code WorktreeCreate hook, as the harness calls it: JSON on
# stdin, and stdout read verbatim as the worktree path. A command hook must print ONLY the
# absolute path (the hookSpecificOutput JSON shape is HTTP-only); printing JSON made the harness
# take the last line `}` as the path and abort. So every case asserts stdout byte-for-byte.

bats_require_minimum_version 1.5.0

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic

  HOOK="$REPO_ROOT/.config/shared-hooks/worktree-create.sh"
  export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com
  export GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com

  REPO="$SANDBOX/myrepo"
  git init -q -b main "$REPO"
  git -C "$REPO" commit -q --allow-empty -m init
}

hook() {
  jq -n --arg cwd "$REPO" "$@" '{hook_event_name: "WorktreeCreate", cwd: $cwd} + $ARGS.named' \
    | bash "$HOOK"
}

@test "detached: stdout is exactly the absolute path, and it is a directory" {
  run --separate-stderr hook --arg name t1 --argjson detach true
  assert_success
  assert_output "$HOME/.worktrees/myrepo-t1"
  [ -d "$output" ]
  [ "$(git -C "$output" rev-parse HEAD)" = "$(git -C "$REPO" rev-parse HEAD)" ]
}

@test "new branch: created at HEAD, git chatter stays off stdout" {
  run --separate-stderr hook --arg name t2 --arg branch feat-x
  assert_success
  assert_output "$HOME/.worktrees/myrepo-t2"
  [ "$(git -C "$output" branch --show-current)" = "feat-x" ]
  [ -n "$stderr" ]
}

@test "resume: an existing worktree is handed back as the same bare path" {
  run --separate-stderr hook --arg name t3 --arg branch feat-y
  assert_success
  run --separate-stderr hook --arg name t3 --arg branch feat-y
  assert_success
  assert_output "$HOME/.worktrees/myrepo-t3"
}

@test "stdout is never JSON" {
  run --separate-stderr hook --arg name t4 --argjson detach true
  assert_success
  refute_output --partial '{'
  refute_output --partial 'hookSpecificOutput'
}

@test "worktree-remove: a slot wt holds survives the hook, which reports the refusal" {
  git -C "$REPO" worktree add -q --lock "$SANDBOX/slot" -b agent-1
  run --separate-stderr bash "$REPO_ROOT/.config/shared-hooks/worktree-remove.sh" \
    <<<"$(jq -n --arg p "$SANDBOX/slot" '{worktree_path: $p}')"
  assert_failure
  [ -d "$SANDBOX/slot" ]
}

@test "worktree-remove: a harness tree with no hold is removed" {
  git -C "$REPO" worktree add -q "$SANDBOX/own" -b own
  bash "$REPO_ROOT/.config/shared-hooks/worktree-remove.sh" \
    <<<"$(jq -n --arg p "$SANDBOX/own" '{worktree_path: $p}')"
  [ ! -d "$SANDBOX/own" ]
}
