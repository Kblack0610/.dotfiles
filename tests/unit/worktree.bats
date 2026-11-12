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

  # Read at source time; lets a test match a gc line's shape.
  export PANEL_NO_COLOR=1
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
  run wt_next_slot platform "$MAIN"
  assert_success
  assert_output "1${PANEL_TAB}fresh"
}

@test "a gap in the numbering is filled, not skipped past" {
  # THREE occupied slots with a hole, not two: with two, "lowest free" and "one past the
  # highest" are the same answer and the test asserts nothing. The numbers stay small
  # because agent-panel says them out loud as a row label ("3:1").
  make_repo
  mkdir -p "$WT_ROOT/platform-agent-1" "$WT_ROOT/platform-agent-2" "$WT_ROOT/platform-agent-4"
  run wt_next_slot platform "$MAIN"
  assert_success
  assert_output "3${PANEL_TAB}fresh"
}

@test "a cut whose stamped name is taken, locally or on origin, gets a counter" {
  # Two cuts of one slot in the same second: rm -rf of a slot, then `new` at once.
  make_repo
  date() { printf '261110-120000\n'; }
  assert_equal "$(wt_branch_name "$MAIN" 1)" agent-1-261110-120000
  git -C "$MAIN" branch agent-1-261110-120000
  assert_equal "$(wt_branch_name "$MAIN" 1)" agent-1-261110-120000-2
  git -C "$MAIN" push --quiet origin main:agent-1-261110-120000-2
  git -C "$MAIN" fetch --quiet origin
  assert_equal "$(wt_branch_name "$MAIN" 1)" agent-1-261110-120000-3
}

@test "a live SESSION pins its slot even after its directory is gone" {
  # unity-core-playground-agent-4: an agent force-removed its own worktree with its session
  # still up, `new` handed slot 4 out again, and the user landed in the old session among
  # panes sitting in the deleted directory.
  make_repo
  rm -f "$NOTES_FIXTURE/tmux.no-session"
  printf 'platform-agent-1\n' > "$NOTES_FIXTURE/tmux.sessions"
  run wt_next_slot platform "$MAIN"
  assert_success
  assert_output "2${PANEL_TAB}fresh"
}

@test "a branch left by an earlier cut pins no slot, and the next cut leaves it alone" {
  # Every cut starts on a new name (wt_branch_name), so a leftover agent-N branch is never
  # reset: not one with the only copy of a commit, not one checked out elsewhere, not a merged
  # one (unity-core-playground once had three slots nobody could take again).
  make_repo
  git -C "$MAIN" branch agent-1
  git -C "$MAIN" worktree add --quiet "$SANDBOX/elsewhere" -b agent-2 origin/main
  git -C "$MAIN" branch agent-3
  git -C "$MAIN" checkout --quiet agent-3
  git -C "$MAIN" commit --quiet --allow-empty -m only-copy
  git -C "$MAIN" checkout --quiet main
  only_copy=$(git -C "$MAIN" rev-parse agent-3)
  run wt_next_slot platform "$MAIN"
  assert_success
  assert_output "1${PANEL_TAB}fresh"
  run wt_prepare "$MAIN" "$WT_ROOT/platform-agent-1" 1 fresh
  assert_success
  assert_equal "$(git -C "$MAIN" rev-parse agent-3)" "$only_copy"
  git -C "$MAIN" rev-parse --verify --quiet agent-1 >/dev/null || fail "the cut touched a leftover branch"
}

@test "each cut of a slot starts on a branch name no earlier cut used (ar-1121)" {
  # GitHub keeps a PR's head after it merges or closes, so a reused `agent-N` met a stale
  # origin/agent-N: the push was rejected and `gh pr create` opened a PR on the old head
  # (dotfiles #1546, #1579). The negative control is the stale remote head itself.
  make_repo
  git -C "$MAIN" push --quiet origin main:agent-1
  run wt_prepare "$MAIN" "$WT_ROOT/platform-agent-1" 1 fresh
  assert_success
  first=$(git -C "$WT_ROOT/platform-agent-1" branch --show-current)
  [[ "$first" =~ ^agent-1-[0-9]{6}-[0-9]{6}$ ]] || fail "unexpected branch name: $first"
  run git -C "$MAIN" ls-remote --exit-code --heads origin "$first"
  assert_failure 2 # the new name is not on origin, unlike agent-1

  wt_branch_name() { printf 'agent-1-later\n'; }
  run wt_recycle "$WT_ROOT/platform-agent-1" 1 origin/main
  assert_success
  assert_equal "$(git -C "$WT_ROOT/platform-agent-1" branch --show-current)" agent-1-later
  git -C "$MAIN" rev-parse --verify --quiet "$first" >/dev/null && fail "the merged old branch was kept"
  return 0
}

@test "an IDLE landed worktree is recycled before a higher free slot is cut" {
  # The ratchet this prevents: a session killed any way but `wt done` leaves a clean, merged
  # worktree on disk, and stepping over it every time pushed unity-core-playground to
  # agent-15 with eight of them sitting idle. Slot 1 is a plain directory (not a worktree of
  # this repo, so never touched), slot 2 is idle, slot 3 is free: 2 must win.
  make_repo
  mkdir -p "$WT_ROOT/platform-agent-1"
  git -C "$MAIN" worktree add --quiet "$WT_ROOT/platform-agent-2" -b agent-2 origin/main
  run wt_next_slot platform "$MAIN"
  assert_success
  assert_output "2${PANEL_TAB}recycle"
}

@test "an idle worktree ABOVE a free hole is recycled, not passed over for the hole" {
  # unity-core-playground 2026-10-16: slot 15 had no directory and no branch, so `new` cut a
  # full Unity checkout there while agent-20 and agent-27 sat idle. Slot 1 is a plain
  # directory, slot 2 is the hole, slot 3 is idle: 3 must win, because a fresh checkout is
  # the slow path and cold build state on top.
  make_repo
  mkdir -p "$WT_ROOT/platform-agent-1"
  git -C "$MAIN" worktree add --quiet "$WT_ROOT/platform-agent-3" -b agent-3 origin/main
  run wt_next_slot platform "$MAIN"
  assert_success
  assert_output "3${PANEL_TAB}recycle"
}

@test "a session on ANOTHER tmux server keeps its worktree from being recycled" {
  # Agents run in `lab` while you sit in `hub`. Asking only the current server saw agent-1
  # as idle while a Claude worked in it, and `new` would have switched its branch.
  make_repo
  git -C "$MAIN" worktree add --quiet "$WT_ROOT/platform-agent-1" -b agent-1 origin/main
  panel_live_servers() { printf 'lab\n'; }
  printf 'platform-agent-1\n' > "$NOTES_FIXTURE/tmux.sessions.lab"
  run wt_next_slot platform "$MAIN"
  assert_success
  assert_output "2${PANEL_TAB}fresh"
}

@test "a slot with a live session is passed over without its git work check" {
  # That check is ~1s per slot on unity-core-playground (status across a 150k-file
  # submodule) and runs before any session is on screen; with agent-1..9 live, Prefix+F
  # showed nothing for ~9s. The session lookup is 45ms and answers the same question.
  make_repo
  git -C "$MAIN" worktree add --quiet "$WT_ROOT/platform-agent-1" -b agent-1 origin/main
  panel_live_servers() { printf 'lab\n'; }
  printf 'platform-agent-1\n' > "$NOTES_FIXTURE/tmux.sessions.lab"
  wt_work_reason() { echo "$1" >>"$SANDBOX/work.log"; }
  run wt_next_slot platform "$MAIN"
  assert_success
  assert_output "2${PANEL_TAB}fresh"
  [ ! -s "$SANDBOX/work.log" ] || fail "git work check ran on a live slot: $(cat "$SANDBOX/work.log")"
}

@test "a pane on ANOTHER tmux server inside a worktree keeps it from being recycled" {
  make_repo
  git -C "$MAIN" worktree add --quiet "$WT_ROOT/platform-agent-1" -b agent-1 origin/main
  panel_live_servers() { printf 'lab\n'; }
  : > "$NOTES_FIXTURE/tmux.sessions.lab"
  printf '%s\n' "$WT_ROOT/platform-agent-1" > "$NOTES_FIXTURE/tmux.panes.lab"
  run wt_next_slot platform "$MAIN"
  assert_success
  assert_output "2${PANEL_TAB}fresh"
}

@test "the current server is not asked twice when it is also in the socket list" {
  # $TMUX names the socket we are on; wt_other_servers drops it so every other server is
  # asked exactly once.
  panel_live_servers() { printf 'hub\nlab\n'; }
  TMUX=/tmp/tmux-1000/hub,1,0 run wt_other_servers
  assert_success
  assert_output 'lab'
}

@test "an idle worktree still holding WORK is stepped over, never recycled" {
  # Refusal first. Recycling switches the branch, so a dirty tree or unpushed commits would
  # be the one thing this could lose; the reap policy is what says no.
  make_repo
  git -C "$MAIN" worktree add --quiet "$WT_ROOT/platform-agent-1" -b agent-1 origin/main
  printf 'wip\n' > "$WT_ROOT/platform-agent-1/file.txt"
  git -C "$MAIN" worktree add --quiet "$WT_ROOT/platform-agent-2" -b agent-2 origin/main
  printf 'work\n' > "$WT_ROOT/platform-agent-2/file.txt"
  git -C "$WT_ROOT/platform-agent-2" commit --quiet -am work
  run wt_next_slot platform "$MAIN"
  assert_success
  assert_output "3${PANEL_TAB}fresh"
}

@test "a landed worktree with a tmux pane open inside it is not idle" {
  # No session carries its name, but a pane from another session has cd'd into a subdir --
  # an agent started elsewhere and pointed here. That is as live as its own session.
  make_repo
  git -C "$MAIN" worktree add --quiet "$WT_ROOT/platform-agent-1" -b agent-1 origin/main
  printf '%s\n' /somewhere/else "$WT_ROOT/platform-agent-1/sub" > "$NOTES_FIXTURE/tmux.panes"
  run wt_next_slot platform "$MAIN"
  assert_success
  assert_output "2${PANEL_TAB}fresh"
}

@test "a pane in a SIBLING whose name merely extends this one does not pin it" {
  # agent-1 is a string prefix of agent-10; a prefix match would keep agent-1 busy forever
  # while agent-10 is in use.
  make_repo
  git -C "$MAIN" worktree add --quiet "$WT_ROOT/platform-agent-1" -b agent-1 origin/main
  printf '%s\n' "$WT_ROOT/platform-agent-10" > "$NOTES_FIXTURE/tmux.panes"
  run wt_next_slot platform "$MAIN"
  assert_success
  assert_output "1${PANEL_TAB}recycle"
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

# ── Submodules: a stale pointer is not work ──────────────────────────────────

# make_repo, plus a submodule `sub` whose origin has commits c1 and c2. The trunk records c1,
# then c2. agent-1 is cut at c1, initialised, then moved onto the trunk WITHOUT a submodule
# update -- exactly how a recycled unity-core-playground slot ends up: HEAD records c2, the
# checkout still sits on c1, and status reports ` M sub`.
make_drifted_submodule() {
  make_repo
  # file:// submodules are refused by default since git 2.38.1; this sandbox is all local.
  export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=protocol.file.allow GIT_CONFIG_VALUE_0=always
  SUBORIGIN="$SANDBOX/sub.git"
  git init --quiet --bare -b main "$SUBORIGIN"
  git clone --quiet "$SUBORIGIN" "$SANDBOX/subwork" 2>/dev/null
  git -C "$SANDBOX/subwork" commit --quiet --allow-empty -m c1
  C1=$(git -C "$SANDBOX/subwork" rev-parse HEAD)
  # `make_drifted_submodule lfs`: c2 also brings an LFS-tracked file, so moving onto it runs
  # the smudge filter.
  if [ "${1:-}" = lfs ]; then
    echo '*.bin filter=lfs' >"$SANDBOX/subwork/.gitattributes"
    echo payload >"$SANDBOX/subwork/a.bin"
    git -C "$SANDBOX/subwork" -c filter.lfs.clean=cat add .gitattributes a.bin
  fi
  git -C "$SANDBOX/subwork" commit --quiet --allow-empty -m c2
  C2=$(git -C "$SANDBOX/subwork" rev-parse HEAD)
  git -C "$SANDBOX/subwork" push --quiet origin main

  git -C "$MAIN" submodule add --quiet "$SUBORIGIN" sub
  git -C "$MAIN/sub" checkout --quiet "$C1"
  git -C "$MAIN" add sub
  git -C "$MAIN" commit --quiet -m 'sub at c1'
  git -C "$MAIN" push --quiet origin main

  WT="$WT_ROOT/platform-agent-1"
  git -C "$MAIN" worktree add --quiet "$WT" -b agent-1 origin/main
  git -C "$WT" submodule update --init --quiet

  git -C "$MAIN/sub" checkout --quiet "$C2"
  git -C "$MAIN" commit --quiet -am 'sub at c2'
  git -C "$MAIN" push --quiet origin main
  git -C "$WT" fetch --quiet origin
  git -C "$WT" merge --quiet --ff-only origin/main
  export SUBORIGIN C1 C2 WT
}

@test "a submodule left on an older PUSHED commit does not make a worktree dirty" {
  make_drifted_submodule
  run git -C "$WT" status --porcelain
  assert_output ' M sub' # the fixture really is in the drifted state
  run wt_reap_reason "$WT"
  assert_success
  run wt_next_slot platform "$MAIN"
  assert_output "1${PANEL_TAB}recycle"
}

@test "a submodule on an UNPUSHED commit still pins the worktree" {
  # The commit exists only in this checkout; recycling would strand it.
  make_drifted_submodule
  git -C "$WT/sub" commit --quiet --allow-empty -m local-only
  run wt_reap_reason "$WT"
  assert_failure
  assert_output 'dirty (1 uncommitted)'
  run wt_next_slot platform "$MAIN"
  assert_output "2${PANEL_TAB}fresh"
}

@test "uncommitted edits INSIDE a drifted submodule still pin the worktree" {
  make_drifted_submodule
  printf 'wip\n' > "$WT/sub/wip.txt"
  run wt_reap_reason "$WT"
  assert_failure
  assert_output 'dirty (1 uncommitted)'
}

@test "a STAGED submodule pointer is somebody's intent, not drift" {
  make_drifted_submodule
  git -C "$WT" add sub
  run wt_reap_reason "$WT"
  assert_failure
}

@test "recycling a drifted worktree brings the submodule up to the trunk" {
  make_drifted_submodule
  run wt_recycle "$WT" 1 origin/main
  assert_success
  run git -C "$WT/sub" rev-parse HEAD
  assert_output "$C2"
  run git -C "$WT" status --porcelain
  assert_output ''
}

# make_drifted_submodule, with agent-1 never initialised (a slot whose module store is empty),
# and the trunk's commit moved on so `submodule update` has to clone.
make_empty_submodule() {
  make_drifted_submodule
  git -C "$WT" submodule deinit --quiet --force sub
  rm -rf "$(git -C "$WT" rev-parse --absolute-git-dir)/modules"
  # deinit dropped the shared URL; a sibling clone having registered it is the real state.
  git -C "$MAIN" submodule init --quiet sub
}

# make_empty_submodule, whose clone cannot succeed.
make_unfillable_submodule() {
  make_empty_submodule
  git -C "$MAIN" config submodule.sub.url "$SANDBOX/gone.git"
}

@test "a recycle that leaves a submodule empty fails and names it" {
  make_unfillable_submodule
  run wt_recycle "$WT" 1 origin/main
  assert_failure
  assert_output --partial 'has empty submodules: sub'
}

@test "a submodule cloned without its pinned commit counts as empty" {
  # The clone lands, so <sub>/.git exists, but the commit is not in it and nothing is checked out.
  make_empty_submodule
  git -C "$MAIN/sub" commit --quiet --allow-empty -m c3
  git -C "$MAIN" commit --quiet -am 'sub at c3'
  git -C "$MAIN" push --quiet origin main
  rm -f "$MAIN/sub/.git"
  run wt_recycle "$WT" 1 origin/main
  assert_failure
  assert_output --partial 'has empty submodules: sub'
}

@test "a submodule name with a space is read whole" {
  make_repo
  git -C "$MAIN" config -f .gitmodules 'submodule.my lib.path' 'ext/my lib'
  run wt_submodule_list "$MAIN"
  assert_output "my lib${PANEL_TAB}ext/my lib"
}

@test "wt_prepare stops on an empty submodule, so no session starts" {
  make_unfillable_submodule
  run wt_prepare "$MAIN" "$WT" 1 recycle
  assert_failure
  refute_output --partial 'reusing idle'
}

@test "a submodule that clones cleanly on recycle is filled and passes" {
  make_empty_submodule
  run wt_recycle "$WT" 1 origin/main
  assert_success
  run git -C "$WT/sub" rev-parse HEAD
  assert_output "$C2"
}

@test "a failed update on an already-filled submodule still only warns" {
  # Behind is usable; only empty stops the start. C3 was never pushed, and the main checkout's
  # copy that wt_recycle would borrow it from is gone, so `update` cannot get it.
  make_drifted_submodule
  git -C "$WT" submodule update --quiet
  git -C "$MAIN/sub" commit --quiet --allow-empty -m c3
  git -C "$MAIN" commit --quiet -am 'sub at c3'
  git -C "$MAIN" push --quiet origin main
  rm -f "$MAIN/sub/.git"
  run wt_recycle "$WT" 1 origin/main
  assert_success
  assert_output --partial 'are not at origin/main'
}

@test "a module store path in the shared URL is restored from .gitmodules" {
  # 2026-11-08: the URL named agent-55's own store, and every clone in the repo failed on it.
  make_empty_submodule
  git -C "$MAIN" config submodule.sub.url "$MAIN/.git/worktrees/platform-agent-55/modules/sub"
  run wt_recycle "$WT" 1 origin/main
  assert_success
  assert_output --partial 'restoring the one in .gitmodules'
  run git -C "$MAIN" config --get submodule.sub.url
  assert_output "$SUBORIGIN"
  run git -C "$WT/sub" rev-parse HEAD
  assert_output "$C2"
}

@test "a fresh worktree also gets the shared URL restored" {
  make_drifted_submodule
  git -C "$MAIN" config submodule.sub.url "$MAIN/.git/modules/sub"
  SLOT="$WT_ROOT/platform-agent-2"
  run wt_prepare "$MAIN" "$SLOT" 2 fresh
  assert_success
  run git -C "$MAIN" config --get submodule.sub.url
  assert_output "$SUBORIGIN"
}

@test "a local mirror URL that is not a module store is left alone" {
  make_drifted_submodule
  git -C "$MAIN" config submodule.sub.url "$SANDBOX/mirror.git"
  run wt_heal_submodule_urls "$WT"
  assert_success
  assert_output ''
  run git -C "$MAIN" config --get submodule.sub.url
  assert_output "$SANDBOX/mirror.git"
}

@test "recycling takes a submodule's new commit from the main checkout, not the network" {
  # The main fetch already brought it into the main checkout's copy; each worktree has its
  # own submodule store, and fetching it again was ~1s of ssh to github per recycle. C3
  # exists only upstream and in $MAIN/sub, and upstream then goes away: only a local fetch
  # can reach it.
  make_drifted_submodule
  git -C "$WT" submodule update --quiet
  git -C "$SANDBOX/subwork" commit --quiet --allow-empty -m c3
  C3=$(git -C "$SANDBOX/subwork" rev-parse HEAD)
  git -C "$SANDBOX/subwork" push --quiet origin main
  git -C "$MAIN/sub" fetch --quiet origin
  git -C "$MAIN/sub" checkout --quiet "$C3"
  git -C "$MAIN" commit --quiet -am 'sub at c3'
  git -C "$MAIN" push --quiet origin main
  git -C "$MAIN" fetch --quiet origin
  mv "$SUBORIGIN" "$SUBORIGIN.offline"
  run wt_recycle "$WT" 1 origin/main
  assert_success
  run git -C "$WT/sub" rev-parse HEAD
  assert_output "$C3"
  run git -C "$WT" status --porcelain
  assert_output ''
  # Borrowed is not pushed: this store never saw C3 on a remote, and must not claim it did.
  run wt_submodule_pushed "$WT/sub"
  assert_failure
}

@test "a submodule commit already fetched but on no ref is still borrowed from main" {
  # `update` treats a commit no ref reaches as missing and goes to the network for it, so
  # "the object exists" is not enough to skip the local fetch. Same fixture as above, but C3
  # is first fetched into FETCH_HEAD only.
  make_drifted_submodule
  git -C "$WT" submodule update --quiet
  git -C "$SANDBOX/subwork" commit --quiet --allow-empty -m c3
  C3=$(git -C "$SANDBOX/subwork" rev-parse HEAD)
  git -C "$SANDBOX/subwork" push --quiet origin main
  git -C "$MAIN/sub" fetch --quiet origin
  git -C "$MAIN/sub" checkout --quiet "$C3"
  git -C "$MAIN" commit --quiet -am 'sub at c3'
  git -C "$MAIN" push --quiet origin main
  git -C "$MAIN" fetch --quiet origin
  git -C "$WT/sub" fetch --quiet "$MAIN/sub" "$C3" # FETCH_HEAD, no ref
  mv "$SUBORIGIN" "$SUBORIGIN.offline"
  run wt_recycle "$WT" 1 origin/main
  assert_success
  run git -C "$WT/sub" rev-parse HEAD
  assert_output "$C3"
}

@test "recycling never smudges LFS through the worktree's own submodule store" {
  # A smudge here is a download into a per-worktree store (4.2 GB on unity-core-playground).
  # Stub git-lfs and record what the smudge filter would have been asked to do.
  make_drifted_submodule lfs
  mkdir -p "$SANDBOX/bin"
  # Real git-lfs reads GIT_LFS_SKIP_SMUDGE itself (git still calls the filter), so the stub
  # logs a smudge only when it would have fetched.
  cat >"$SANDBOX/bin/git-lfs" <<EOF
#!/bin/sh
case "\$1" in
smudge) [ "\$GIT_LFS_SKIP_SMUDGE" = 1 ] || echo smudge >>"$SANDBOX/lfs.log"; cat ;;
*) echo "\$*" >>"$SANDBOX/lfs.log" ;;
esac
exit 0
EOF
  chmod +x "$SANDBOX/bin/git-lfs"
  export PATH="$SANDBOX/bin:$PATH"
  export GIT_CONFIG_COUNT=3 GIT_CONFIG_KEY_1=filter.lfs.smudge GIT_CONFIG_VALUE_1='git-lfs smudge -- %f' \
    GIT_CONFIG_KEY_2=filter.lfs.clean GIT_CONFIG_VALUE_2=cat
  touch "$SANDBOX/lfs.log"
  run wt_recycle "$WT" 1 origin/main
  assert_success
  run grep -c '^smudge' "$SANDBOX/lfs.log"
  assert_output 0
  run grep -c '^checkout' "$SANDBOX/lfs.log"
  assert_output 1
  # Only what c1 -> c2 changed, never a bare whole-tree scan (20s+ on asset-library).
  run grep '^checkout' "$SANDBOX/lfs.log"
  assert_output 'checkout -- .gitattributes a.bin'
}

@test "recycling skips lfs checkout in a submodule that did not move" {
  # On unity-core-playground that scan is 28k LFS files in asset-library, 20s+ of a recycle,
  # and it bought nothing when the pointer had not changed.
  make_drifted_submodule lfs
  git -C "$WT" submodule update --quiet # already at the trunk's C2: nothing will move
  mkdir -p "$SANDBOX/bin"
  cat >"$SANDBOX/bin/git-lfs" <<EOF
#!/bin/sh
case "\$1" in
smudge | clean) cat ;;
*) echo "\$1" >>"$SANDBOX/lfs.log" ;;
esac
exit 0
EOF
  chmod +x "$SANDBOX/bin/git-lfs"
  export PATH="$SANDBOX/bin:$PATH"
  touch "$SANDBOX/lfs.log"
  run wt_recycle "$WT" 1 origin/main
  assert_success
  run git -C "$WT/sub" rev-parse HEAD
  assert_output "$C2"
  run grep -c '^checkout' "$SANDBOX/lfs.log"
  assert_output 0
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

@test "inside a submodule the main repo is the submodule's checkout" {
  # Its --git-common-dir is <super>/.git/modules/sub, not */.git: this read as a bare repo
  # and `wt new` died with "not inside a git repository" (ar-255).
  make_drifted_submodule
  run wt_main_repo "$MAIN/sub"
  assert_success
  assert_output "$MAIN/sub"
  git -C "$MAIN/sub" worktree add --quiet "$WT_ROOT/sub-agent-1" -b agent-1
  run wt_main_repo "$WT_ROOT/sub-agent-1"
  assert_success
  assert_output "$MAIN/sub"
  # A superproject worktree's submodule keeps its store under .git/worktrees/<n>/modules.
  run wt_main_repo "$WT/sub"
  assert_success
  assert_output "$WT/sub"
}

@test "a deinitialised submodule resolves to nothing, not a missing checkout" {
  make_drifted_submodule
  git -C "$MAIN/sub" worktree add --quiet "$WT_ROOT/sub-agent-1" -b agent-1
  rm -rf "$MAIN/sub"
  run wt_main_repo "$WT_ROOT/sub-agent-1"
  assert_failure
}

@test "a submodule's main checkout is never listed as one of its worktrees" {
  # git names a submodule's main worktree by its .git/modules dir, which matched no path.
  make_drifted_submodule
  git -C "$MAIN/sub" worktree add --quiet "$WT_ROOT/sub-agent-1" -b agent-1
  run wt_worktrees_of "$MAIN/sub"
  assert_success
  assert_output "$WT_ROOT/sub-agent-1	agent-1"
}

@test "a bare repo still resolves to nothing" {
  git init --quiet --bare "$SANDBOX/bare.git"
  run wt_main_repo "$SANDBOX/bare.git"
  assert_failure
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

@test "git config wt.trunk overrides origin/HEAD" {
  make_repo
  git -C "$MAIN" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
  git -C "$MAIN" config wt.trunk develop
  run wt_default_branch "$MAIN"
  assert_success
  assert_output 'develop'
}

# ── Squash merges, editors, submodule worktrees, and reaping with submodules ─

# A worktree with one local commit and no upstream, its origin renamed to a GitHub URL so
# wt_pr_merged_at_head asks the gh stub. Pushes are done before the rename.
make_squash_candidate() {
  make_repo
  git -C "$MAIN" worktree add --quiet --no-track "$WT_ROOT/repo-agent-1" -b feat/x origin/main
  printf 'work\n' > "$WT_ROOT/repo-agent-1/file.txt"
  git -C "$WT_ROOT/repo-agent-1" commit --quiet -am work
  git -C "$MAIN" remote set-url origin https://github.com/me/repo.git
  HEAD_OID=$(git -C "$WT_ROOT/repo-agent-1" rev-parse HEAD)
  export HEAD_OID
}

@test "a squash-merged branch whose PR head is this HEAD is reapable" {
  make_squash_candidate
  printf '[{"headRefName":"feat/x","headRefOid":"%s","state":"MERGED"}]\n' "$HEAD_OID" > "$GH_FIXTURE/prs.me-repo"
  run wt_reap_reason "$WT_ROOT/repo-agent-1"
  assert_success
  assert_output ''
}

@test "a commit made AFTER the merged PR's head still pins the worktree" {
  make_squash_candidate
  printf '[{"headRefName":"feat/x","headRefOid":"%s","state":"MERGED"}]\n' "$HEAD_OID" > "$GH_FIXTURE/prs.me-repo"
  printf 'more\n' > "$WT_ROOT/repo-agent-1/file.txt"
  git -C "$WT_ROOT/repo-agent-1" commit --quiet -am more
  run wt_reap_reason "$WT_ROOT/repo-agent-1"
  assert_failure
  assert_output --partial 'not merged'
}

@test "no merged PR for the branch pins the worktree" {
  make_squash_candidate
  run wt_reap_reason "$WT_ROOT/repo-agent-1"
  assert_failure
  assert_output --partial 'not merged'
}

@test "a Unity editor with the worktree open pins it" {
  make_repo
  git -C "$MAIN" worktree add --quiet "$WT_ROOT/repo-agent-1" -b agent-1 origin/main
  printf '#!/bin/sh\necho "Unity /opt/Unity/Editor/Unity -projectPath %s -logFile x"\n' "$WT_ROOT/repo-agent-1" > "$SANDBOX/bin/ps"
  chmod +x "$SANDBOX/bin/ps"
  run wt_reap_reason "$WT_ROOT/repo-agent-1"
  assert_failure
  assert_output 'a Unity editor has it open'
}

@test "a running process inside the worktree pins it" {
  make_repo
  git -C "$MAIN" worktree add --quiet "$WT_ROOT/repo-agent-1" -b agent-1 origin/main
  export WT_PROC_ROOT="$SANDBOX/proc"
  mkdir -p "$WT_PROC_ROOT/100" "$WT_PROC_ROOT/200" "$WT_PROC_ROOT/300"
  ln -s "$SANDBOX" "$WT_PROC_ROOT/100/cwd"
  ln -s "$WT_ROOT/repo-agent-10" "$WT_PROC_ROOT/200/cwd"
  run wt_reap_reason "$WT_ROOT/repo-agent-1"
  assert_success

  ln -s "$WT_ROOT/repo-agent-1/Assets/Tests" "$WT_PROC_ROOT/300/cwd"
  run wt_reap_reason "$WT_ROOT/repo-agent-1"
  assert_failure
  assert_output 'a running process is inside it'
}

# -- an orphan daemon does not hold a tree --

# fake_proc <pid> <cwd> <exe> <ppid> -- one process in a fake /proc. The parent gets a comm of
# systemd when <ppid> is 1030, the user manager's shape, and bash otherwise.
fake_proc() {
  export WT_PROC_ROOT="$SANDBOX/proc"
  mkdir -p "$WT_PROC_ROOT/$1" "$WT_PROC_ROOT/$4"
  ln -s "$2" "$WT_PROC_ROOT/$1/cwd"
  ln -s "$3" "$WT_PROC_ROOT/$1/exe"
  printf 'Name:\tx\nPPid:\t%s\n' "$4" > "$WT_PROC_ROOT/$1/status"
  if [ "$4" = 1030 ]; then echo systemd; else echo bash; fi > "$WT_PROC_ROOT/$4/comm"
}

# orphan_tree -- repo-agent-1, landed and clean, with a daemon in Library/ under the user manager
orphan_tree() {
  make_unity_tree
  T="$WT_ROOT/repo-agent-1"
  mkdir -p "$T/Library/mcp-server"
  fake_proc 500 "$T/Library/mcp-server" "$T/Library/mcp-server/server" 1030
  # Stubbed, so no test here signals a real pid. The fake process exits on TERM unless told not to.
  kill() {
    printf '%s\n' "$*" >> "$SANDBOX/kill.log"
    [ -e "$SANDBOX/kill.ignored" ] || rm -rf "$WT_PROC_ROOT/500"
  }
  waitpid() { :; }
}

@test "gc ends an orphan daemon and reaps the tree it pinned" {
  orphan_tree
  run cmd_gc
  assert_success
  assert_line --regexp '^reaped +repo-agent-1 +landed +\(orphan daemon 500\)$'
  assert_output --partial '1 of 1 reapable'
  [ ! -d "$T" ]
  assert_equal "$(cat "$SANDBOX/kill.log")" '-TERM 500'
}

@test "gc -n names the orphan daemon and signals nothing" {
  orphan_tree
  run cmd_gc -n
  assert_success
  assert_line --regexp '^would reap +repo-agent-1 +landed +\(orphan daemon 500\)$'
  [ -d "$T" ]
  [ ! -e "$SANDBOX/kill.log" ]
}

@test "an orphan whose parent is init does not pin the tree" {
  orphan_tree
  printf 'PPid:\t1\n' > "$WT_PROC_ROOT/500/status"
  run wt_reap_reason "$T"
  assert_success
}

@test "a daemon that outlives SIGTERM keeps its tree" {
  orphan_tree
  touch "$SANDBOX/kill.ignored"
  run cmd_reap "$T"
  assert_failure
  assert_output --partial 'an orphan daemon outlived SIGTERM'
  [ -d "$T" ]
}

@test "gc counts a tree whose daemon will not exit as kept, naming the pid" {
  orphan_tree
  touch "$SANDBOX/kill.ignored"
  run cmd_gc
  assert_success
  assert_output --partial '0 of 1 reapable, 1 kept'
  # Still the state it was judged in; the reason says why the reap refused.
  assert_line --regexp '^kept +repo-agent-1 +landed +.*an orphan daemon outlived SIGTERM \(orphan daemon 500\)$'
  [ -d "$T" ]
}

@test "a path with glob characters matches itself and no other tree" {
  fake_proc 600 "$SANDBOX/a[1]/x" /bin/true 2000
  fake_proc 601 "$SANDBOX/a1/x" /bin/true 2000
  run wt_pids_inside "$SANDBOX/a[1]"
  assert_output 600
}

@test "an idle slot is not recycled over a daemon that will not exit" {
  orphan_tree
  touch "$SANDBOX/kill.ignored"
  run wt_recycle "$T" 1 origin/main
  assert_failure
}

@test "recycling a slot ends its orphan daemon" {
  orphan_tree
  wt_recycle "$T" 1 origin/main
  assert_equal "$(cat "$SANDBOX/kill.log")" '-TERM 500'
}

@test "a daemon with an open editor is left alone" {
  # The daemon's parent is systemd even while its editor runs, so the editor check is what
  # protects it.
  orphan_tree
  wt_editor_open() { [ "$1" = "$T" ]; }
  run cmd_gc
  assert_output --partial 'a Unity editor has it open'
  [ -d "$T" ]
  [ ! -e "$SANDBOX/kill.log" ]
}

@test "a Library binary with a live parent still pins the tree" {
  make_unity_tree
  T="$WT_ROOT/repo-agent-1"
  fake_proc 500 "$T/Library" "$T/Library/server" 400
  run wt_reap_reason "$T"
  assert_failure
  assert_output 'a running process is inside it'
}

@test "a detached server outside Library/ still pins the tree" {
  # Left running from a build directory: someone's, so unattended gc does not signal it.
  make_unity_tree
  T="$WT_ROOT/repo-agent-1"
  fake_proc 500 "$T" "$T/target/server" 1030
  run wt_reap_reason "$T"
  assert_failure
  assert_output 'a running process is inside it'
}

@test "an orphan beside a real process does not free the tree" {
  orphan_tree
  fake_proc 600 "$T" /usr/bin/make 400
  run cmd_gc
  assert_output --partial 'a running process is inside it'
  [ -d "$T" ]
  [ ! -e "$SANDBOX/kill.log" ]
}

@test "a dirty tree held only by an orphan reads held and the orphan lives" {
  orphan_tree
  echo edit > "$T/wip"
  run cmd_gc
  assert_line --regexp '^kept +repo-agent-1 +held +dirty'
  [ -d "$T" ]
  [ ! -e "$SANDBOX/kill.log" ]
}

# -- orphans: the sweep over every Unity project --

# orphan_project -- a Unity project outside $WT_ROOT (a main checkout or clone), whose editor
# is gone and whose MCP server is left under the user manager.
orphan_project() {
  orphan_tree
  P="$SANDBOX/dev/game"
  mkdir -p "$P/ProjectSettings" "$P/Library/mcp-server/linux-x64"
  rm -rf "$WT_PROC_ROOT/500"
  fake_proc 500 "$P" "$P/Library/mcp-server/linux-x64/gamedev-mcp-server" 1030
}

@test "orphans ends a server whose editor is gone, outside the worktrees too" {
  orphan_project
  run cmd_orphans
  assert_success
  assert_output "ended 500  $P"
  assert_equal "$(cat "$SANDBOX/kill.log")" '-TERM 500'
}

@test "orphans -n names the server and signals nothing" {
  orphan_project
  run cmd_orphans -n
  assert_success
  assert_output "would end 500  $P"
  [ ! -e "$SANDBOX/kill.log" ]
}

@test "orphans leaves a server alone while its editor is open" {
  orphan_project
  wt_editor_open() { [ "$1" = "$P" ]; }
  run cmd_orphans
  assert_success
  assert_output --partial 'no orphan daemons'
  [ ! -e "$SANDBOX/kill.log" ]
}

@test "orphans leaves a Library binary outside a Unity project alone" {
  orphan_project
  rm -r "$P/ProjectSettings"
  run cmd_orphans
  assert_success
  assert_output --partial 'no orphan daemons'
  [ ! -e "$SANDBOX/kill.log" ]
}

@test "orphans fails, naming why, when a server outlives SIGTERM" {
  orphan_project
  touch "$SANDBOX/kill.ignored"
  run cmd_orphans
  assert_failure
  assert_output "failed 500  $P: outlived SIGTERM"
}

@test "orphans counts an editor whose cwd is the project as open, however its path was spelled" {
  orphan_project
  fake_proc 700 "$P" /opt/Unity/Editor/Unity 400
  echo Unity > "$WT_PROC_ROOT/700/comm"
  run cmd_orphans
  assert_success
  assert_output --partial 'no orphan daemons'
  [ ! -e "$SANDBOX/kill.log" ]
}

@test "orphans finds a project that sits under a dir named Library" {
  orphan_project
  Q="$SANDBOX/Library/game"
  mkdir -p "$Q/ProjectSettings"
  rm -rf "$WT_PROC_ROOT/500"
  fake_proc 500 "$Q" "$Q/Library/mcp-server/linux-x64/gamedev-mcp-server" 1030
  run cmd_orphans -n
  assert_output "would end 500  $Q"
}

# -- done: kill, then reap, on the server --

# done_from_inside <tree> -- `wt done` the way an agent runs it: from a shell in its own tree,
# inside tmux, with the tree's session live. Then run what it queued, as the server would,
# after the caller has gone. Real /proc: the job and the reap it starts are real processes.
done_from_inside() {
  printf '%s\n' "$(basename "$1")" >> "$NOTES_FIXTURE/tmux.sessions"
  rm -f "$NOTES_FIXTURE/tmux.no-session"
  (cd "$1" && TMUX="$SANDBOX/tmp/tmux-0/default,1,0" cmd_done)
  local cwd cmd
  while IFS=$'\t' read -r cwd cmd; do
    (cd "$cwd" && sh -c "$cmd") || : # a kept tree is a failing job, as on the server
  done < "$NOTES_FIXTURE/tmux.jobs"
}

@test "done reaps its tree once the session it killed is gone" {
  # Every done since #652 was kept "a running process is inside it": the job ran in the
  # caller's cwd, so the reap counted itself. done.log:386 on, 68 of 69 lines.
  make_repo
  git -C "$MAIN" worktree add --quiet "$WT_ROOT/repo-agent-1" -b agent-1 origin/main
  done_from_inside "$WT_ROOT/repo-agent-1"
  run cat "$HOME/.agent/wt/done.log"
  assert_output --partial 'reaped repo-agent-1'
  [ ! -d "$WT_ROOT/repo-agent-1" ]
}

@test "done keeps its tree while another session has a pane in it" {
  # A peer session in the same slot outlives the kill, which is by name.
  make_repo
  git -C "$MAIN" worktree add --quiet "$WT_ROOT/repo-agent-1" -b agent-1 origin/main
  printf 'peer\n' > "$NOTES_FIXTURE/tmux.sessions"
  printf '%s\n' "$WT_ROOT/repo-agent-1" > "$NOTES_FIXTURE/tmux.panes"
  done_from_inside "$WT_ROOT/repo-agent-1"
  run cat "$HOME/.agent/wt/done.log"
  assert_output --partial 'kept repo-agent-1: a tmux pane is open inside it'
  [ -d "$WT_ROOT/repo-agent-1" ]
}

@test "an editor on ANOTHER project does not pin the worktree" {
  make_repo
  git -C "$MAIN" worktree add --quiet "$WT_ROOT/repo-agent-1" -b agent-1 origin/main
  printf '#!/bin/sh\necho "unityhub-unity-editor-6000 x -projectpath %s"\n' "$WT_ROOT/repo-agent-10" > "$SANDBOX/bin/ps"
  chmod +x "$SANDBOX/bin/ps"
  run wt_reap_reason "$WT_ROOT/repo-agent-1"
  assert_success
}

@test "a worktree of its own submodule pins the worktree" {
  # That worktree's git dir lives in this one's .git/modules; removing this one orphans it.
  make_drifted_submodule
  git -C "$WT/sub" worktree add --quiet "$SANDBOX/sub-wt" -b side
  run wt_reap_reason "$WT"
  assert_failure
  assert_output --partial 'a submodule worktree lives off it'
}

@test "a pushed submodule worktree whose dir is gone does not pin the worktree" {
  # git marks it prunable; nothing is left but its HEAD, and that is on origin (ar-232).
  make_drifted_submodule
  git -C "$WT/sub" worktree add --quiet "$SANDBOX/sub-wt" -b side
  rm -rf "$SANDBOX/sub-wt"
  run wt_submodule_worktrees "$WT"
  assert_failure
  run wt_reap_reason "$WT"
  assert_success
}

@test "an unpushed submodule worktree whose dir is gone still pins the worktree" {
  # Its commit lives only in this tree's .git/modules, so removing the tree loses it.
  make_drifted_submodule
  git -C "$WT/sub" worktree add --quiet "$SANDBOX/sub-wt" -b side
  git -C "$SANDBOX/sub-wt" commit --quiet --allow-empty -m local
  rm -rf "$SANDBOX/sub-wt"
  run wt_reap_reason "$WT"
  assert_failure
  assert_output --partial "a submodule worktree lives off it: $SANDBOX/sub-wt (its dir is gone"
}

@test "gc judges a submodule's worktree before the tree its git dir lives in" {
  # Reaping it first frees the superproject tree in the same pass.
  mkdir -p "$WT_ROOT/aa-super" "$WT_ROOT/zz-sub"
  printf 'gitdir: %s/.git/worktrees/x/modules/sub/worktrees/zz-sub\n' "$SANDBOX" > "$WT_ROOT/zz-sub/.git"
  printf 'apps\n' > "$WT_ROOT/aa-super/keep.txt"
  run cmd_gc -n
  assert_line --index 0 --partial 'zz-sub'
  assert_line --index 1 --partial 'aa-super'
}

@test "gc judges a dot-prefixed worktree" {
  make_repo
  git -C "$MAIN" worktree add --quiet "$WT_ROOT/.repo-agent-1" -b dotted
  run cmd_gc -n
  assert_success
  assert_output --partial '.repo-agent-1'
  assert_output --partial '1 of 1 reapable'
}

@test "gc keeps a dot-prefixed worktree whose session is live under the dotless name" {
  # panel_session_name strips the leading dot, so the session is repo-agent-1, not .repo-agent-1.
  make_repo
  git -C "$MAIN" worktree add --quiet "$WT_ROOT/.repo-agent-1" -b dotted
  wt_session_exists() { [ "$1" = repo-agent-1 ]; }
  run cmd_gc
  assert_output --partial 'its tmux session is live'
  [ -d "$WT_ROOT/.repo-agent-1" ]
}

@test "gc leaves a dot dir that is no worktree alone, even one holding only caches" {
  # .preview and .xdg-agent18 are tools' dirs; a cache-only one would read as a reapable husk.
  mkdir -p "$WT_ROOT/.preview/Library" "$WT_ROOT/.xdg-agent18/Logs"
  run cmd_gc
  assert_output --partial 'no worktrees to consider'
  [ -d "$WT_ROOT/.preview/Library" ]
  [ -d "$WT_ROOT/.xdg-agent18/Logs" ]
  # Nor one holding a clone: its .git is a directory, a main checkout, not a worktree.
  mkdir -p "$WT_ROOT/.clone/.git"
  run cmd_gc
  assert_output --partial 'no worktrees to consider'
}

# ── gc state words: README "Worktree states" ─────────────────────────────────

@test "gc classifies dirty and unpushed trees as held, a symlink as not-a-worktree, and ignores a loose file" {
  # The negative control: nothing here is reapable, so a real (not dry) pass must remove none.
  make_repo
  git -C "$MAIN" worktree add --quiet "$WT_ROOT/repo-agent-1" -b dirty
  printf 'edit\n' > "$WT_ROOT/repo-agent-1/file.txt"
  git -C "$MAIN" worktree add --quiet "$WT_ROOT/repo-agent-2" -b unpushed
  git -C "$WT_ROOT/repo-agent-2" commit --quiet --allow-empty -m local
  ln -s "$MAIN" "$WT_ROOT/repo"
  printf 'notes\n' > "$WT_ROOT/loose.txt"
  run cmd_gc --tsv
  assert_success
  assert_line --regexp $'^held\tkept\trepo-agent-1\t[^\t]+\tdirty'
  assert_line --regexp $'^held\tkept\trepo-agent-2\t[^\t]+\tnot merged'
  assert_line --regexp $'^not-a-worktree\tskipped\trepo\t[^\t]+\ta symlink to '
  refute_output --partial 'loose.txt'
  assert_equal "${#lines[@]}" 3
  [ -d "$WT_ROOT/repo-agent-1" ] && [ -d "$WT_ROOT/repo-agent-2" ] && [ -L "$WT_ROOT/repo" ] && [ -f "$WT_ROOT/loose.txt" ]
  [ -f "$MAIN/file.txt" ]
}

@test "gc never judges a tree through a symlink, even one pointing at a reapable worktree" {
  make_repo
  git -C "$MAIN" worktree add --quiet "$SANDBOX/elsewhere" -b landed
  ln -s "$SANDBOX/elsewhere" "$WT_ROOT/repo-agent-3"
  run cmd_gc
  assert_line --regexp '^skipped +repo-agent-3 +not-a-worktree'
  assert_output --partial '0 of 1 reapable, 0 kept, 1 skipped;'
  [ -d "$SANDBOX/elsewhere" ]
}

@test "gc calls a tree someone is in claimed, and a cache-only husk husk" {
  make_repo
  git -C "$MAIN" worktree add --quiet "$WT_ROOT/repo-agent-1" -b live
  mkdir -p "$WT_ROOT/repo-agent-2/Library"
  wt_session_exists() { [ "$1" = repo-agent-1 ]; }
  run cmd_gc -n --tsv
  assert_success
  assert_line --regexp $'^claimed\tkept\trepo-agent-1\t[^\t]+\tits tmux session is live$'
  assert_line --regexp $'^husk\twould reap\trepo-agent-2\t[^\t]+\t$'
}

@test "gc a main checkout and an unresolvable .git are not-a-worktree, not held" {
  mkdir -p "$WT_ROOT/clone/.git" "$WT_ROOT/broken"
  git init --quiet "$WT_ROOT/clone"
  printf 'gitdir: %s/no/such/dir\n' "$SANDBOX" > "$WT_ROOT/broken/.git"
  run cmd_gc -n
  assert_success
  assert_line --regexp '^skipped +broken +not-a-worktree'
  assert_line --regexp '^skipped +clone +not-a-worktree +a main checkout'
  assert_output --partial 'held 0, not-a-worktree 2'
}

@test "gc --tsv over nothing keeps stdout empty" {
  run --separate-stderr cmd_gc --tsv
  assert_success
  assert_output ''
}

@test "the README states table names exactly the words gc prints" {
  local readme="$REPO_ROOT/.local/src/tmux/README.md" doc code
  doc=$(awk '/^\*\*Worktree states\.\*\*/ {on = 1; next} on && /^\| `/ {print} on && /^$/ && seen {exit} on && /^\|/ {seen = 1}' "$readme" |
    sed -E 's/^\| `([^`]+)`.*/\1/' | sort)
  code=$(printf '%s\n' $WT_GC_STATES | sort)
  [ -n "$doc" ] || fail "no states table under **Worktree states.** in the README"
  assert_equal "$doc" "$code"
}

@test "reap removes a clean worktree that has an initialised submodule" {
  # Plain `git worktree remove` refuses every such tree, clean or not.
  make_drifted_submodule
  run cmd_reap "$WT"
  assert_success
  [ ! -d "$WT" ]
}

@test "reap keeps a worktree with edits inside its submodule" {
  make_drifted_submodule
  printf 'wip\n' > "$WT/sub/wip.txt"
  run cmd_reap "$WT"
  assert_failure
  [ -f "$WT/sub/wip.txt" ]
}

# -- the hold: a slot cut by `new` is git-locked until `reap` frees it --

held_slot() {
  make_repo
  SLOT="$WT_ROOT/repo-agent-1"
  wt_prepare "$MAIN" "$SLOT" 1 fresh 2>/dev/null
}

@test "a raw git worktree remove cannot take a slot, forced or not" {
  held_slot
  run git -C "$MAIN" worktree remove "$SLOT"
  assert_failure
  assert_output --partial 'wt reap'
  run git -C "$MAIN" worktree remove --force "$SLOT"
  assert_failure
  run git -C "$MAIN" worktree move "$SLOT" "$SANDBOX/moved"
  assert_failure
  [ -f "$SLOT/file.txt" ]
}

@test "a recycled slot is held, whether or not it was before" {
  held_slot
  run wt_prepare "$MAIN" "$SLOT" 1 recycle
  assert_success
  refute_output --partial 'could not lock'
  git -C "$MAIN" worktree unlock "$SLOT"
  wt_prepare "$MAIN" "$SLOT" 1 recycle 2>/dev/null
  run git -C "$MAIN" worktree remove "$SLOT"
  assert_failure
  assert_output --partial 'wt reap'
}

@test "reap frees a held slot, and takes its branch" {
  held_slot
  run cmd_reap "$SLOT"
  assert_success
  assert_output --regexp 'reaped repo-agent-1 \(branch agent-1-[0-9-]+ deleted\)'
  [ ! -d "$SLOT" ]
}

@test "reap frees a held slot with a submodule through the forced path" {
  make_drifted_submodule
  wt_hold "$WT"
  run cmd_reap "$WT"
  assert_success
  [ ! -d "$WT" ]
}

@test "a reap refused for a live session leaves the hold on" {
  held_slot
  rm "$NOTES_FIXTURE/tmux.no-session"
  run cmd_reap "$SLOT"
  assert_failure
  assert_output --partial 'its tmux session is live'
  run git -C "$MAIN" worktree remove "$SLOT"
  assert_failure
  assert_output --partial 'wt reap'
}

@test "a reap git refuses after the policy passed puts the hold back" {
  # git's own dirty check is the second door, for a tree that changed since the policy looked.
  held_slot
  printf 'late\n' > "$SLOT/late.txt"
  wt_reap_reason() { return 0; }
  run cmd_reap "$SLOT"
  assert_failure
  assert_output --partial 'git worktree remove refused'
  [ -f "$SLOT/late.txt" ]
  run git -C "$MAIN" worktree remove --force "$SLOT"
  assert_failure
  assert_output --partial 'wt reap'
}

@test "a hold that outlived its directory frees the slot for the next new" {
  held_slot
  rm -rf "$SLOT"
  run wt_next_slot repo "$MAIN"
  assert_success
  assert_output "1${PANEL_TAB}fresh"
  run wt_prepare "$MAIN" "$SLOT" 1 fresh
  assert_success
  [ -f "$SLOT/file.txt" ]
}

@test "a live session keeps the hold on a slot whose directory is gone" {
  held_slot
  rm -rf "$SLOT"
  rm "$NOTES_FIXTURE/tmux.no-session"
  run wt_next_slot repo "$MAIN"
  git -C "$MAIN" worktree list --porcelain | grep -q '^locked'
}

# -- husks: a dir with no .git left behind after its worktree went --

@test "a husk holding only Unity caches is reaped" {
  mkdir -p "$WT_ROOT/repo-agent-4/Library/mcp-server/linux-x64" "$WT_ROOT/repo-agent-4/Logs"
  run wt_reap_reason "$WT_ROOT/repo-agent-4"
  assert_success
  run cmd_reap "$WT_ROOT/repo-agent-4"
  assert_success
  assert_output --partial 'reaped repo-agent-4 (no git'
  [ ! -e "$WT_ROOT/repo-agent-4" ]
}

@test "a husk holding only files tools rewrote is reaped" {
  # Seen live 2026-11-07: Claude Code's local settings, Unity's package manifest and lock,
  # and a pnpm install, each alone in a dir whose worktree had gone.
  local h="$WT_ROOT/repo-agent-4"
  mkdir -p "$h/.claude" "$h/Packages" "$h/node_modules/.pnpm/x" "$h/Library"
  touch "$h/.claude/settings.local.json" "$h/Packages/manifest.json" "$h/Packages/packages-lock.json" \
    "$h/pnpm-lock.yaml" "$h/node_modules/.pnpm/x/index.js"
  run wt_reap_reason "$h"
  assert_success
}

@test "a git-less dir holding anything but tool caches is kept" {
  # A source tree whose .git went missing may be the only copy of its work.
  mkdir -p "$WT_ROOT/repo-agent-4/Library" "$WT_ROOT/repo-agent-4/apps"
  touch "$WT_ROOT/repo-agent-4/apps/main.ts"
  run wt_reap_reason "$WT_ROOT/repo-agent-4"
  assert_failure
  assert_output 'no git, and it holds more than tool caches'
  # The named files pass only at their own path: an embedded package or a skill is work.
  mkdir -p "$WT_ROOT/repo-agent-5/.claude/skills" "$WT_ROOT/repo-agent-6/Packages/com.x"
  touch "$WT_ROOT/repo-agent-5/.claude/skills/SKILL.md" "$WT_ROOT/repo-agent-6/Packages/com.x/manifest.json"
  run wt_reap_reason "$WT_ROOT/repo-agent-5"
  assert_failure
  run wt_reap_reason "$WT_ROOT/repo-agent-6"
  assert_failure
  mkdir -p "$WT_ROOT/repo-agent-8" && ln -s /nowhere "$WT_ROOT/repo-agent-8/link"
  run wt_reap_reason "$WT_ROOT/repo-agent-8"
  assert_failure
  # An empty skeleton is kept too: only the named files' own dirs are walked.
  mkdir -p "$WT_ROOT/repo-agent-9/Library" "$WT_ROOT/repo-agent-9/Assets/Scenes"
  run wt_reap_reason "$WT_ROOT/repo-agent-9"
  assert_failure
}

@test "a husk with a process inside it is kept" {
  mkdir -p "$WT_ROOT/repo-agent-4/Logs"
  export WT_PROC_ROOT="$SANDBOX/proc"
  mkdir -p "$WT_PROC_ROOT/100"
  ln -s "$WT_ROOT/repo-agent-4/Logs" "$WT_PROC_ROOT/100/cwd"
  run cmd_reap "$WT_ROOT/repo-agent-4"
  assert_failure
  [ -d "$WT_ROOT/repo-agent-4/Logs" ]
}

# -- reap --after-kill: the deferred reap of done and wind-down --

# a landed worktree whose Library/ is ignored, as in a Unity repo
make_unity_tree() {
  make_repo
  printf 'Library/\n' > "$MAIN/.gitignore"
  git -C "$MAIN" add .gitignore
  git -C "$MAIN" commit --quiet -m ignore
  git -C "$MAIN" push --quiet origin main
  git -C "$MAIN" worktree add --quiet "$WT_ROOT/repo-agent-1" -b agent-1 origin/main
}

@test "reap --after-kill ends a server whose binary lives in the tree, then reaps" {
  # Unity's gamedev-mcp-server runs from Library/ and is reparented to systemd: nothing else
  # ever ends it, and its cwd pinned the tree for good.
  command -v waitpid >/dev/null || skip 'needs util-linux waitpid'
  make_unity_tree
  mkdir -p "$WT_ROOT/repo-agent-1/Library/mcp-server"
  cp "$(command -v sleep)" "$WT_ROOT/repo-agent-1/Library/mcp-server/server"
  (cd "$WT_ROOT/repo-agent-1/Library/mcp-server" && exec ./server 300) &
  local pid=$!
  run cmd_reap --after-kill "$WT_ROOT/repo-agent-1"
  assert_success
  assert_output --partial 'reaped repo-agent-1'
  [ ! -d "$WT_ROOT/repo-agent-1" ]
  ! kill -0 "$pid" 2>/dev/null || [ "$(ps -o stat= -p "$pid")" = Z ]
}

@test "reap --after-kill never kills a process that only works inside the tree" {
  # A gate or a build is somebody's work; it is waited on, never killed.
  command -v waitpid >/dev/null || skip 'needs util-linux waitpid'
  make_unity_tree
  (cd "$WT_ROOT/repo-agent-1" && exec sleep 300) &
  local pid=$!
  WT_SETTLE_SECS=1 run cmd_reap --after-kill "$WT_ROOT/repo-agent-1"
  assert_failure
  assert_output --partial 'a running process is inside it'
  kill -0 "$pid"
  kill "$pid"
}

@test "reap --after-kill does nothing to a tree whose session is still live" {
  make_unity_tree
  rm -f "$NOTES_FIXTURE/tmux.no-session"
  printf 'repo-agent-1\n' >> "$NOTES_FIXTURE/tmux.sessions"
  mkdir -p "$WT_ROOT/repo-agent-1/Library/mcp-server"
  cp "$(command -v sleep)" "$WT_ROOT/repo-agent-1/Library/mcp-server/server"
  (cd "$WT_ROOT/repo-agent-1/Library/mcp-server" && exec ./server 300) &
  local pid=$!
  run cmd_reap --after-kill "$WT_ROOT/repo-agent-1"
  assert_failure
  assert_output --partial 'its tmux session is live'
  kill -0 "$pid"
  kill "$pid"
}
