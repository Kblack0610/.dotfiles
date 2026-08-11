#!/usr/bin/env bats
# worktree.sh -- the functions, sourced. `wt` cuts a worktree per piece of work and reaps it
# when the work has landed, so the two questions worth pinning here are:
#
#   1. what does a worktree get CALLED (the basename is the identity three other surfaces
#      parse: sessionizer's session name, agent-panel's project_from_path and short_target)
#   2. when is one SAFE TO DELETE
#
# The second is the whole reason this panel exists rather than a two-line alias. Cheap
# creation without a reaper is how ~/dev/bnb/platform reached 35 worktrees; a reaper that
# cannot refuse is worse than none at all, because it deletes work. So every eligibility
# test here is written as a REFUSAL first -- the passing case is the easy half.
#
# git is a subprocess but it is not the subject: these are sourced functions driven against
# a real throwaway repo under $BATS_TEST_TMPDIR. No daemon, no server, host-safe.

bats_require_minimum_version 1.5.0

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic

  # No global git config exists under the sandbox HOME, so identity comes from the env.
  export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com
  export GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com

  export WT_ROOT="$SANDBOX/worktrees"
  export WT_PROJECT_MAP="$SANDBOX/no-such-map.json" # discovery off unless a test wants it
  mkdir -p "$WT_ROOT"

  # The stub's has-session reports EXISTS by default (wind-down needs that); for a freshly
  # cut worktree the honest answer is "gone", so flip it. One test flips it back, which is
  # how the live-session refusal gets covered.
  : > "$NOTES_FIXTURE/tmux.no-session"

  # shellcheck source=/dev/null
  source "$REPO_ROOT/.local/src/tmux/worktree.sh"
}

# A repo with a real origin, so `origin/main`, upstreams and push all behave normally.
make_repo() {
  ORIGIN="$SANDBOX/origin.git"
  MAIN="$SANDBOX/repo"
  git init --quiet --bare -b main "$ORIGIN"
  git init --quiet -b main "$MAIN"
  printf 'seed\n' > "$MAIN/file.txt"
  git -C "$MAIN" add file.txt
  git -C "$MAIN" commit --quiet -m seed
  git -C "$MAIN" remote add origin "$ORIGIN"
  git -C "$MAIN" push --quiet -u origin main
  export ORIGIN MAIN
}

# ── Naming: the basename IS the identity ─────────────────────────────────────

@test "a leading dot is stripped, so ~/.dotfiles yields dotfiles-agent-N" {
  # Not cosmetic. agent-panel's project_from_path folds `.dotfiles` to `dotfiles` and
  # short_target strips a leading dot before reading the agent number; naming the directory
  # `.dotfiles-agent-1` would make the panel's two halves disagree about the same row.
  run wt_repo_name /home/someone/.dotfiles
  assert_success
  assert_output 'dotfiles'
}

@test "an interior dot is folded to an underscore" {
  # tmux reads `.` as the window separator inside a target: `-t my.project` addresses window
  # "project" of session "my". panel-lib.sh:panel_session_name is where the rule lives.
  run wt_repo_name /home/someone/my.dotted.project
  assert_success
  assert_output 'my_dotted_project'
}

@test "an ordinary repo name passes through untouched" {
  run wt_repo_name /home/someone/dev/platform
  assert_success
  assert_output 'platform'
}

# ── Slot allocation ──────────────────────────────────────────────────────────

@test "the first worktree of a repo is agent-1" {
  make_repo
  run wt_next_n platform "$MAIN"
  assert_success
  assert_output '1'
}

@test "a gap in the numbering is filled, not skipped past" {
  # THREE occupied slots with a hole, not two: with two, "lowest free" and "one past the
  # highest" are the same answer and the test asserts nothing. The numbers stay small
  # because agent-panel says them out loud as a row label ("3:1").
  make_repo
  mkdir -p "$WT_ROOT/platform-agent-1" "$WT_ROOT/platform-agent-2" "$WT_ROOT/platform-agent-4"
  run wt_next_n platform "$MAIN"
  assert_success
  assert_output '3'
}

@test "a slot whose DIRECTORY is free but whose BRANCH still exists is skipped" {
  # The failure this prevents: a refused reap leaves branch agent-3 behind after its
  # directory is gone, and `git worktree add -b agent-3` then fails outright. Checking only
  # the directory would hand out a slot that cannot be created.
  make_repo
  mkdir -p "$WT_ROOT/platform-agent-1" "$WT_ROOT/platform-agent-2" "$WT_ROOT/platform-agent-4"
  git -C "$MAIN" branch agent-3
  run wt_next_n platform "$MAIN"
  assert_success
  assert_output '5'
}

# ── Eligibility: the refusals ────────────────────────────────────────────────

@test "a MAIN checkout is never reapable" {
  # The worst thing this tool could do. --git-dir == --git-common-dir only in a main
  # checkout, which is the one structural fact that distinguishes it.
  make_repo
  run wt_reap_reason "$MAIN"
  assert_failure
  assert_output --partial 'a main checkout'
}

@test "a dirty worktree is refused, and the reason counts the files" {
  make_repo
  git -C "$MAIN" worktree add --quiet "$WT_ROOT/repo-agent-1" -b agent-1 origin/main
  printf 'edit\n' > "$WT_ROOT/repo-agent-1/file.txt"
  run wt_reap_reason "$WT_ROOT/repo-agent-1"
  assert_failure
  assert_output --partial 'dirty (1 uncommitted)'
}

@test "an UNTRACKED file counts as dirty" {
  # `status --porcelain` includes untracked, and that is the behaviour wanted: an untracked
  # file is the one kind of work that exists nowhere else at all.
  make_repo
  git -C "$MAIN" worktree add --quiet "$WT_ROOT/repo-agent-1" -b agent-1 origin/main
  printf 'notes\n' > "$WT_ROOT/repo-agent-1/scratch.md"
  run wt_reap_reason "$WT_ROOT/repo-agent-1"
  assert_failure
  assert_output --partial 'dirty'
}

@test "a clean worktree with UNPUSHED commits is refused" {
  # Clean is not the same as safe. This is the commit that exists on exactly one disk.
  make_repo
  git -C "$MAIN" worktree add --quiet "$WT_ROOT/repo-agent-1" -b agent-1 origin/main
  printf 'work\n' > "$WT_ROOT/repo-agent-1/file.txt"
  git -C "$WT_ROOT/repo-agent-1" commit --quiet -am work
  run wt_reap_reason "$WT_ROOT/repo-agent-1"
  assert_failure
  assert_output --partial 'unpushed commits'
}

@test "a live tmux session pins the worktree even when the work has landed" {
  # "Clean and pushed" is a SNAPSHOT, not a promise: an agent working detached in this
  # worktree is clean-and-pushed for a moment after every push, and a gc landing in that
  # window would delete the tree out from under it mid-turn.
  make_repo
  git -C "$MAIN" worktree add --quiet "$WT_ROOT/repo-agent-1" -b agent-1 origin/main
  rm -f "$NOTES_FIXTURE/tmux.no-session" # stub: has-session now reports EXISTS
  run wt_reap_reason "$WT_ROOT/repo-agent-1"
  assert_failure
  assert_output --partial 'session is live'
}

# ── Eligibility: the passes ──────────────────────────────────────────────────

@test "a clean worktree sitting on the trunk is reapable" {
  make_repo
  git -C "$MAIN" worktree add --quiet "$WT_ROOT/repo-agent-1" -b agent-1 origin/main
  run wt_reap_reason "$WT_ROOT/repo-agent-1"
  assert_success
  assert_output ''
}

@test "a clean worktree whose commits are all PUSHED is reapable" {
  # Pushed counts as landed. Requiring a local merge would keep every open-PR worktree
  # alive for days after its work was done, which is the sprawl this tool exists to stop --
  # and the branch is on the remote, so nothing is lost.
  make_repo
  git -C "$MAIN" worktree add --quiet "$WT_ROOT/repo-agent-1" -b agent-1 origin/main
  printf 'work\n' > "$WT_ROOT/repo-agent-1/file.txt"
  git -C "$WT_ROOT/repo-agent-1" commit --quiet -am work
  git -C "$WT_ROOT/repo-agent-1" push --quiet -u origin agent-1
  run wt_reap_reason "$WT_ROOT/repo-agent-1"
  assert_success
  assert_output ''
}

# ── Repo resolution ──────────────────────────────────────────────────────────

@test "the main repo resolves identically from inside a linked worktree" {
  # `wt new` run inside dotfiles-agent-1 must cut dotfiles-agent-2, not
  # dotfiles-agent-1-agent-1. --git-common-dir is what makes the answer position-independent.
  make_repo
  git -C "$MAIN" worktree add --quiet "$WT_ROOT/repo-agent-1" -b agent-1 origin/main
  run wt_main_repo "$WT_ROOT/repo-agent-1"
  assert_success
  assert_output "$MAIN"
}

@test "a directory outside any repo resolves to nothing" {
  mkdir -p "$SANDBOX/not-a-repo"
  run wt_main_repo "$SANDBOX/not-a-repo"
  assert_failure
}

@test "the default branch comes from origin/HEAD when it is set" {
  make_repo
  git -C "$MAIN" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
  run wt_default_branch "$MAIN"
  assert_success
  assert_output 'main'
}
