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
  # The tmux stub answers has-session with EXISTS; for a tree nobody is in, "gone" is the truth.
  : > "$NOTES_FIXTURE/tmux.no-session"
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

remove_hook() {
  bash "$REPO_ROOT/.config/shared-hooks/worktree-remove.sh" \
    <<<"$(jq -n --arg p "$1" '{worktree_path: $p}')"
}

@test "worktree-remove: an unlanded tree survives the hook, which reports the refusal" {
  # Clean, so a raw `git worktree remove` would take it; only `wt reap` sees the unpushed commit.
  git -C "$REPO" worktree add -q "$SANDBOX/slot" -b agent-1
  git -C "$SANDBOX/slot" commit -q --allow-empty -m unlanded
  run --separate-stderr remove_hook "$SANDBOX/slot"
  assert_failure
  [ -d "$SANDBOX/slot" ]
  [[ "$stderr" == *'kept slot: not merged'* ]]
}

@test "worktree-remove: a landed tree is removed with its branch, a held lock and all" {
  git -C "$REPO" worktree add -q --lock "$SANDBOX/own" -b agent-2
  run --separate-stderr remove_hook "$SANDBOX/own"
  assert_success
  [ ! -d "$SANDBOX/own" ]
  ! git -C "$REPO" rev-parse --verify --quiet agent-2 >/dev/null
}

@test "worktree-remove: a path that is already gone is a no-op" {
  run remove_hook "$SANDBOX/never-was"
  assert_success
}
