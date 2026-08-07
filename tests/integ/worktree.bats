#!/usr/bin/env bats
# worktree.sh -- the verb contract, as a subprocess. Prefix+F runs `wt new`, Prefix+X runs
# `wt done`, and the Stop hook runs `wt reap`. None of those callers can see a function, so
# what they depend on is exactly this: exit codes, rows on stdout, and which tmux commands
# get issued.
#
# The destructive verbs (reap, gc) are driven against real throwaway repos under
# $BATS_TEST_TMPDIR. Every one of them is asserted by "the directory is STILL THERE" as well
# as by the exit code -- a refusal that returns 1 and deletes anyway would pass a rc-only
# test, and that is the single failure mode that would make this tool worse than nothing.

bats_require_minimum_version 1.5.0

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic

  WT="$REPO_ROOT/.local/src/tmux/worktree.sh"
  export WT

  export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com
  export GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com

  export WT_ROOT="$SANDBOX/worktrees"
  export WT_PROJECT_MAP="$SANDBOX/no-such-map.json"
  export PANEL_NO_COLOR=1
  mkdir -p "$WT_ROOT"

  # The stub answers has-session with EXISTS by default (wind-down.sh needs that shape).
  # For a worktree nobody is sitting in, "gone" is the honest answer.
  : > "$NOTES_FIXTURE/tmux.no-session"
}

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

# add_wt <name> [branch] -- a linked worktree off origin/main
add_wt() {
  git -C "$MAIN" worktree add --quiet "$WT_ROOT/$1" -b "${2:-$1}" origin/main
}

# ── Dispatch ─────────────────────────────────────────────────────────────────

@test "an unknown verb is rejected, not quietly turned into a picker" {
  # Two panels in this repo fall through to fzf on a typo, which blocks forever headless.
  run "$WT" --frobnicate
  assert_failure
  assert_output --partial 'unknown verb'
}

@test "--help prints the header block" {
  run "$WT" --help
  assert_success
  assert_output --partial 'THE WORKTREE IS THE AGENT'
}

# ── Rows ─────────────────────────────────────────────────────────────────────

@test "--list prints one row per linked worktree, main excluded" {
  make_repo
  add_wt repo-agent-1
  add_wt repo-agent-2
  export WT_PROJECT_MAP="$SANDBOX/map.json"
  printf '{"paths":{"%s":"repo"}}\n' "$MAIN" > "$WT_PROJECT_MAP"

  run "$WT" --list
  assert_success
  assert_output --partial 'repo-agent-1'
  assert_output --partial 'repo-agent-2'
  # The main checkout is not a worktree you can land in or reap; it must never be a row.
  refute_output --partial "$MAIN	"
}

@test "--list classifies each worktree in the state column" {
  make_repo
  add_wt repo-agent-1                                 # clean, on the trunk
  add_wt repo-agent-2                                 # about to go dirty
  printf 'edit\n' > "$WT_ROOT/repo-agent-2/file.txt"
  add_wt repo-agent-3                                 # about to go unlanded
  printf 'work\n' > "$WT_ROOT/repo-agent-3/file.txt"
  git -C "$WT_ROOT/repo-agent-3" commit --quiet -am work
  export WT_PROJECT_MAP="$SANDBOX/map.json"
  printf '{"paths":{"%s":"repo"}}\n' "$MAIN" > "$WT_PROJECT_MAP"

  state() { "$WT" --list | awk -F'\t' -v n="$1" '$2==n {print $4}'; }
  assert_equal "$(state repo-agent-1)" reapable
  assert_equal "$(state repo-agent-2)" dirty
  assert_equal "$(state repo-agent-3)" unlanded
}

@test "--list is empty and succeeds when there is nothing to list" {
  run "$WT" --list
  assert_success
  assert_output ''
}

# ── new ──────────────────────────────────────────────────────────────────────

@test "new cuts agent-1 off the trunk and opens a session named after the directory" {
  make_repo
  run "$WT" new -c "$MAIN"
  assert_success
  assert_output --partial 'repo-agent-1'

  [ -d "$WT_ROOT/repo-agent-1" ] || fail "the worktree directory was not created"
  assert_equal "$(git -C "$WT_ROOT/repo-agent-1" branch --show-current)" agent-1
  # The session name IS the directory basename -- that identity is what sessionizer and
  # agent-panel both parse.
  assert_called 'new-session -ds repo-agent-1'
  assert_called "-c $WT_ROOT/repo-agent-1"
}

@test "new run INSIDE a worktree cuts the next slot of the same repo" {
  # The bug this exists to prevent: resolving the repo with --show-toplevel instead of
  # --git-common-dir yields `repo-agent-1` as the repo, and the second worktree is called
  # repo-agent-1-agent-1.
  make_repo
  "$WT" new -c "$MAIN" > /dev/null
  run "$WT" new -c "$WT_ROOT/repo-agent-1"
  assert_success
  # The session name is the LAST line of stdout -- git's own "Preparing worktree" progress
  # goes to stderr, which bats' `run` merges into $output. Pin the contract, not the noise.
  assert_equal "${lines[-1]}" repo-agent-2
  [ -d "$WT_ROOT/repo-agent-2" ] || fail "second worktree not created"
  [ ! -d "$WT_ROOT/repo-agent-1-agent-1" ] || fail "resolved the repo from the worktree, not the main checkout"
}

@test "new outside any git repository fails instead of guessing" {
  mkdir -p "$SANDBOX/elsewhere"
  run "$WT" new -c "$SANDBOX/elsewhere"
  assert_failure
  assert_output --partial 'not inside a git repository'
}

# ── reap: the refusals. Each asserts the directory SURVIVES. ────────────────

@test "reap REFUSES a dirty worktree and leaves it on disk" {
  make_repo
  add_wt repo-agent-1
  printf 'edit\n' > "$WT_ROOT/repo-agent-1/file.txt"

  run "$WT" reap "$WT_ROOT/repo-agent-1"
  assert_failure
  assert_output --partial 'dirty'
  [ -d "$WT_ROOT/repo-agent-1" ] || fail "REFUSED and deleted it anyway -- the worst possible outcome"
  assert_equal "$(cat "$WT_ROOT/repo-agent-1/file.txt")" edit
}

@test "reap REFUSES a worktree with unpushed commits and leaves it on disk" {
  make_repo
  add_wt repo-agent-1
  printf 'work\n' > "$WT_ROOT/repo-agent-1/file.txt"
  git -C "$WT_ROOT/repo-agent-1" commit --quiet -am work

  run "$WT" reap "$WT_ROOT/repo-agent-1"
  assert_failure
  assert_output --partial 'unpushed'
  [ -d "$WT_ROOT/repo-agent-1" ] || fail "deleted a worktree holding the only copy of a commit"
}

@test "reap REFUSES while a tmux session for the worktree is live" {
  make_repo
  add_wt repo-agent-1
  rm -f "$NOTES_FIXTURE/tmux.no-session" # stub: has-session now reports EXISTS

  run "$WT" reap "$WT_ROOT/repo-agent-1"
  assert_failure
  assert_output --partial 'session is live'
  [ -d "$WT_ROOT/repo-agent-1" ] || fail "pulled the tree out from under a live session"
}

@test "reap REFUSES a main checkout and leaves it on disk" {
  make_repo
  run "$WT" reap "$MAIN"
  assert_failure
  assert_output --partial 'main checkout'
  [ -d "$MAIN" ] || fail "deleted a main checkout"
}

# ── reap: the pass ───────────────────────────────────────────────────────────

@test "reap removes a clean, landed worktree" {
  make_repo
  add_wt repo-agent-1
  run "$WT" reap "$WT_ROOT/repo-agent-1"
  assert_success
  assert_output --partial 'reaped repo-agent-1'
  [ ! -d "$WT_ROOT/repo-agent-1" ] || fail "reported success without removing anything"
  # and git agrees it is gone, not just the directory
  refute_line --partial "$WT_ROOT/repo-agent-1" < <(git -C "$MAIN" worktree list)
}

# ── gc ───────────────────────────────────────────────────────────────────────

@test "gc reaps the eligible and NAMES the ones it kept, with the reason" {
  make_repo
  add_wt repo-agent-1                                  # reapable
  add_wt repo-agent-2                                  # dirty
  printf 'edit\n' > "$WT_ROOT/repo-agent-2/file.txt"

  run "$WT" gc
  assert_success
  assert_output --partial 'reaped'
  assert_output --partial 'repo-agent-1'
  # A silent skip is the failure mode: a sweep that quietly leaves things behind reads as
  # "everything was clean".
  assert_output --partial 'kept'
  assert_output --partial 'dirty'
  [ ! -d "$WT_ROOT/repo-agent-1" ] || fail "eligible worktree survived gc"
  [ -d "$WT_ROOT/repo-agent-2" ] || fail "gc deleted a dirty worktree"
}

@test "gc --dry-run removes NOTHING" {
  make_repo
  add_wt repo-agent-1
  run "$WT" gc --dry-run
  assert_success
  assert_output --partial 'would reap'
  assert_output --partial 'nothing removed'
  [ -d "$WT_ROOT/repo-agent-1" ] || fail "a dry run deleted a worktree"
}

@test "gc over an empty list says so rather than reporting a clean sweep" {
  # Every tooling failure in this tree has been a silent success: a gate that ran over zero
  # inputs and said "done". An empty candidate list is a RESULT and has to be spoken aloud.
  run "$WT" gc
  assert_success
  assert_output --partial 'no worktrees to consider'
}

@test "gc scoped to a repo covers worktrees that live OUTSIDE \$WT_ROOT" {
  # ~/dev/bnb/platform has 35 sibling worktrees that predate this tool and none of them are
  # under ~/.worktrees. `gc <repo>` is the verb that can see them at all.
  make_repo
  git -C "$MAIN" worktree add --quiet "$SANDBOX/sibling-wt" -b sibling origin/main
  run "$WT" gc "$MAIN" --dry-run
  assert_success
  assert_output --partial 'sibling-wt'
  [ -d "$SANDBOX/sibling-wt" ] || fail "a dry run deleted a worktree"
}

# ── done: the one-shot teardown ──────────────────────────────────────────────
#
# `done` exists because you CANNOT do this by hand from inside the session: `tmux
# kill-session` takes your shell with it, so a chained `wt reap` never runs. So the two
# things worth pinning are that the refusal happens BEFORE anything is killed (afterwards
# there is no terminal to print it to), and that the kill and the reap go to the tmux server
# in that order.

@test "done REFUSES a dirty worktree and kills NOTHING" {
  # The critical one. A refusal that arrives after the session is dead is not a refusal --
  # the terminal that would have shown it is gone, and so is the worktree.
  make_repo
  add_wt repo-agent-1
  printf 'edit\n' > "$WT_ROOT/repo-agent-1/file.txt"
  # TMUX set, so `done` takes the DEFERRED path -- the one where the check has to happen
  # up front. Without this the test passes through the direct-reap fallback, which re-checks
  # anyway, and asserts nothing about the pre-kill guard.
  export TMUX=fake

  run "$WT" done "$WT_ROOT/repo-agent-1"
  assert_failure
  assert_output --partial 'dirty'
  [ -d "$WT_ROOT/repo-agent-1" ] || fail "refused and deleted it anyway"
  assert_not_called 'kill-session'
  assert_not_called 'run-shell'
}

@test "done REFUSES a worktree with unpushed commits and kills NOTHING" {
  make_repo
  add_wt repo-agent-1
  printf 'work\n' > "$WT_ROOT/repo-agent-1/file.txt"
  git -C "$WT_ROOT/repo-agent-1" commit --quiet -am work
  export TMUX=fake

  run "$WT" done "$WT_ROOT/repo-agent-1"
  assert_failure
  assert_output --partial 'unpushed'
  assert_not_called 'kill-session'
}

@test "done schedules the kill and THEN the reap, backgrounded on the server" {
  # Order is the whole mechanism: the reap re-runs the full policy, including the
  # live-session rule, which only passes once the kill has landed.
  make_repo
  add_wt repo-agent-1
  export TMUX=fake

  run "$WT" done "$WT_ROOT/repo-agent-1"
  assert_success
  run grep 'run-shell' "$NOTES_FIXTURE/calls.log"
  assert_success
  assert_output --partial 'run-shell -b'
  assert_output --partial "kill-session -t '=repo-agent-1'"
  assert_output --partial 'reap'

  local chain="$output"
  case "${chain%%kill-session*}" in
  *reap*) fail "the reap is scheduled BEFORE the kill -- it would refuse every time" ;;
  esac
}

@test "done from a SUBDIRECTORY still targets the worktree root" {
  # The keybinding passes #{pane_current_path}, which is wherever you cd'd to. From
  # <worktree>/tests, a naive basename gives "tests": the kill misses and the remove errors.
  make_repo
  add_wt repo-agent-1
  mkdir -p "$WT_ROOT/repo-agent-1/tests"
  export TMUX=fake

  run "$WT" done "$WT_ROOT/repo-agent-1/tests"
  assert_success
  run grep 'run-shell' "$NOTES_FIXTURE/calls.log"
  assert_output --partial "kill-session -t '=repo-agent-1'"
  refute_output --partial "'=tests'"
}

@test "done takes a bare worktree NAME, not just a path" {
  make_repo
  add_wt repo-agent-1
  export TMUX=fake
  run "$WT" done repo-agent-1
  assert_success
  run grep 'run-shell' "$NOTES_FIXTURE/calls.log"
  assert_output --partial "kill-session -t '=repo-agent-1'"
}

@test "done outside tmux with no session reaps directly instead of deferring" {
  make_repo
  add_wt repo-agent-1
  run "$WT" done "$WT_ROOT/repo-agent-1"
  assert_success
  assert_output --partial 'reaped repo-agent-1'
  [ ! -d "$WT_ROOT/repo-agent-1" ] || fail "nothing was actually removed"
}

# ── reap takes the branch with it ────────────────────────────────────────────

@test "reap deletes the branch it just freed, so the slot is reusable" {
  # Without this the numbers ratchet forever: wt_next_n counts an existing `agent-N` branch
  # as an occupied slot, so four reaped worktrees pushed the next one to agent-5 with
  # nothing on disk.
  make_repo
  add_wt repo-agent-1 agent-1
  run "$WT" reap "$WT_ROOT/repo-agent-1"
  assert_success
  assert_output --partial 'branch agent-1 deleted'
  run git -C "$MAIN" show-ref --verify --quiet refs/heads/agent-1
  assert_failure
  # and the slot is genuinely free again
  run "$WT" new -c "$MAIN"
  assert_success
  assert_equal "${lines[-1]}" repo-agent-1
}

@test "reap KEEPS a branch git will not safely delete, and says so" {
  # `-d`, never `-D`. git's safe-delete is a second, independent check on the same question
  # reap already asked -- if the two ever disagree, the branch survives.
  make_repo
  # --no-track, so the branch has no upstream to vouch for it. Its commit then goes straight
  # onto origin/main, which is what makes the two checks genuinely disagree: reap sees HEAD
  # as an ancestor of origin/main and proceeds, while `git branch -d` sees a branch merged
  # into neither the LOCAL HEAD (still behind) nor any upstream, and declines.
  git -C "$MAIN" worktree add --quiet --no-track -b agent-1 "$WT_ROOT/repo-agent-1" origin/main
  printf 'work\n' > "$WT_ROOT/repo-agent-1/file.txt"
  git -C "$WT_ROOT/repo-agent-1" commit --quiet -am work
  git -C "$WT_ROOT/repo-agent-1" push --quiet origin HEAD:main
  git -C "$MAIN" fetch --quiet origin

  run "$WT" reap "$WT_ROOT/repo-agent-1"
  assert_success
  assert_output --partial 'branch agent-1 kept'
  [ ! -d "$WT_ROOT/repo-agent-1" ] || fail "the worktree should still have been removed"
}
