#!/usr/bin/env bats
# stop-session-changes.py -- the paths this session changed, judged from its session-start snapshot.
#
# The Stop gate picks its shell tests from this list. A checkout or reset that moves HEAD back (a canary start,
# a bisect, a reset to an older commit) rewrites files the session never edited. Before the fix each
# of them counted as the session's, and one harness path in the list picked every test file.
#
# git is a subprocess, not the subject: a throwaway repo under $BATS_TEST_TMPDIR, with a remote
# only in the test that needs one.

bats_require_minimum_version 1.5.0

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic

  # No global git config exists under the sandbox HOME, so identity comes from the env.
  export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com
  export GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com
  export XDG_CACHE_HOME="$BATS_TEST_TMPDIR/cache"

  CLASSIFIER="$BATS_TEST_DIRNAME/../../.config/shared-hooks/stop-session-changes.py"
  REPO="$BATS_TEST_TMPDIR/repo"
  git init -q -b main "$REPO"
  printf '1\n' >"$REPO/a.txt"
  printf '1\n' >"$REPO/b.txt"
  git -C "$REPO" add -A
  git -C "$REPO" commit -qm one
  printf '2\n' >"$REPO/a.txt"
  git -C "$REPO" commit -qam two
}

# The session-start snapshot, then the classifier's answer for the session so far.
snapshot() { python3 "$CLASSIFIER" start "$REPO" session-1; }
changed() { python3 "$CLASSIFIER" changed "$REPO" session-1; }

@test "a checkout that moves HEAD backward is not a session change" {
  snapshot
  git -C "$REPO" checkout -q HEAD~1
  run changed
  assert_success
  assert_output ""
}

@test "an edit made after such a checkout still counts" {
  snapshot
  git -C "$REPO" checkout -q HEAD~1
  printf '3\n' >"$REPO/b.txt"
  run changed
  assert_success
  assert_output "b.txt"
}

@test "a commit the session makes counts" {
  snapshot
  printf '3\n' >"$REPO/a.txt"
  git -C "$REPO" commit -qam three
  run changed
  assert_success
  assert_output "a.txt"
}

@test "dirty work that predates the session stays out of the list across a checkout" {
  printf 'wip\n' >"$REPO/b.txt"
  snapshot
  git -C "$REPO" checkout -q HEAD~1
  run changed
  assert_success
  assert_output ""
}

@test "a file reverted to HEAD without a HEAD move still counts" {
  printf 'wip\n' >"$REPO/b.txt"
  snapshot
  git -C "$REPO" checkout -q -- b.txt
  run changed
  assert_success
  assert_output "b.txt"
}

@test "a fast-forward to the default branch is upstream's, not the session's" {
  git init -q --bare "$BATS_TEST_TMPDIR/origin.git"
  git -C "$REPO" remote add origin "$BATS_TEST_TMPDIR/origin.git"
  git -C "$REPO" push -q origin main
  git -C "$REPO" reset -q --hard HEAD~1
  git -C "$REPO" fetch -q origin
  snapshot
  git -C "$REPO" merge -q --ff-only origin/main
  run changed
  assert_success
  assert_output ""
}

@test "a switch to history with no commit in common counts only the dirty paths" {
  snapshot
  tree=$(git -C "$REPO" mktree </dev/null)
  orphan=$(git -C "$REPO" commit-tree "$tree" -m orphan)
  git -C "$REPO" checkout -q "$orphan"
  run changed
  assert_success
  assert_output ""
}
