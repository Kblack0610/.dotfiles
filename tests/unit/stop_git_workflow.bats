#!/usr/bin/env bats
# stop-checks.d/10-git-workflow.sh: unpushed commits block a Stop, except while this
# session's own background run is still going. A live run is a process holding the run's
# output file open (<tmp>/claude-<uid>/<cwd>/<session>/tasks/<id>.output); the tests hold
# one open from the test process itself, so nothing sleeps and nothing is left running.

bats_require_minimum_version 1.5.0

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic

  CHECK="$REPO_ROOT/.claude/hooks/stop-checks.d/10-git-workflow.sh"
  # No network: the open-PR lookup finds nothing.
  printf '#!/bin/sh\nexit 1\n' > "$SANDBOX/bin/gh"
  chmod +x "$SANDBOX/bin/gh"

  git init -q --bare "$SANDBOX/origin.git"
  REPO="$SANDBOX/repo"
  git clone -q "$SANDBOX/origin.git" "$REPO" 2>/dev/null
  git -C "$REPO" config user.email t@example.com
  git -C "$REPO" config user.name tester
  git -C "$REPO" checkout -q -b main
  echo one > "$REPO/a.txt"
  git -C "$REPO" add a.txt
  git -C "$REPO" commit -qm one
  git -C "$REPO" push -q -u origin main 2>/dev/null
  git -C "$REPO" checkout -q -b feat/x
  git -C "$REPO" push -q -u origin feat/x 2>/dev/null
  echo two >> "$REPO/a.txt"
  git -C "$REPO" commit -qam two         # one commit the remote does not have

  TASKS="$SANDBOX/claude-1000/-repo"
}

# hold <session> -- this test process holds a background run's output file open.
hold() {
  mkdir -p "$TASKS/$1/tasks"
  exec 9>"$TASKS/$1/tasks/bq1.output"
}

teardown() { exec 9>&- 2>/dev/null || true; }

check() { cd "$REPO" && STOP_SESSION_ID="${1:-}" run --separate-stderr bash "$CHECK"; }

@test "unpushed commits block with no background run" {
  check s1
  assert_failure 2
  [[ "$stderr" == *"FAILED: Branch 'feat/x' has 1 unpushed commit(s)"* ]]
}

@test "unpushed commits only warn while this session's background run is live" {
  hold s1
  check s1
  assert_failure 1
  [[ "$stderr" == *"a background run of this session is still going"* ]]
  [[ "$stderr" != *FAILED* ]]
}

@test "another session's live run does not excuse this one" {
  hold s2
  check s1
  assert_failure 2
}

@test "a closed output file is a finished run" {
  hold s1
  exec 9>&-
  check s1
  assert_failure 2
}

@test "with no session id it blocks as before" {
  hold s1
  check ''
  assert_failure 2
}

@test "a pushed branch passes" {
  git -C "$REPO" push -q 2>/dev/null
  check s1
  assert_success
}
