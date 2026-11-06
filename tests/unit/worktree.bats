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
  run wt_next_slot platform "$MAIN" origin/main
  assert_success
  assert_output "1${PANEL_TAB}fresh"
}

@test "a gap in the numbering is filled, not skipped past" {
  # THREE occupied slots with a hole, not two: with two, "lowest free" and "one past the
  # highest" are the same answer and the test asserts nothing. The numbers stay small
  # because agent-panel says them out loud as a row label ("3:1").
  make_repo
  mkdir -p "$WT_ROOT/platform-agent-1" "$WT_ROOT/platform-agent-2" "$WT_ROOT/platform-agent-4"
  run wt_next_slot platform "$MAIN" origin/main
  assert_success
  assert_output "3${PANEL_TAB}fresh"
}

@test "a slot whose DIRECTORY is free but whose UNMERGED branch still exists is skipped" {
  # A refused reap leaves branch agent-3 behind after its directory is gone. If it carries a
  # commit the trunk does not have, it may be the only copy -- `new` resetting it with -B
  # would throw that away.
  make_repo
  mkdir -p "$WT_ROOT/platform-agent-1" "$WT_ROOT/platform-agent-2" "$WT_ROOT/platform-agent-4"
  git -C "$MAIN" branch agent-3
  git -C "$MAIN" checkout --quiet agent-3
  git -C "$MAIN" commit --quiet --allow-empty -m only-copy
  git -C "$MAIN" checkout --quiet main
  run wt_next_slot platform "$MAIN" origin/main
  assert_success
  assert_output "5${PANEL_TAB}fresh"
}

@test "a live SESSION pins its slot even after its directory is gone" {
  # unity-core-playground-agent-4: an agent force-removed its own worktree with its session
  # still up, `new` handed slot 4 out again, and the user landed in the old session among
  # panes sitting in the deleted directory.
  make_repo
  rm -f "$NOTES_FIXTURE/tmux.no-session"
  printf 'platform-agent-1\n' > "$NOTES_FIXTURE/tmux.sessions"
  run wt_next_slot platform "$MAIN" origin/main
  assert_success
  assert_output "2${PANEL_TAB}fresh"
}

@test "a leftover branch already MERGED into the trunk does not pin its slot" {
  # unity-core-playground had agent-1..3 branches with no directories, all merged: three
  # slots nobody could ever take again.
  make_repo
  git -C "$MAIN" branch agent-1
  run wt_next_slot platform "$MAIN" origin/main
  assert_success
  assert_output "1${PANEL_TAB}fresh"
}

@test "a merged branch CHECKED OUT in some other worktree still pins its slot" {
  # -B cannot reset a branch another worktree has checked out; handing out the slot would
  # just make `worktree add` fail.
  make_repo
  git -C "$MAIN" worktree add --quiet "$SANDBOX/elsewhere" -b agent-1 origin/main
  run wt_next_slot platform "$MAIN" origin/main
  assert_success
  assert_output "2${PANEL_TAB}fresh"
}

@test "an IDLE landed worktree is recycled before a higher free slot is cut" {
  # The ratchet this prevents: a session killed any way but `wt done` leaves a clean, merged
  # worktree on disk, and stepping over it every time pushed unity-core-playground to
  # agent-15 with eight of them sitting idle. Slot 1 is a plain directory (not a worktree of
  # this repo, so never touched), slot 2 is idle, slot 3 is free: 2 must win.
  make_repo
  mkdir -p "$WT_ROOT/platform-agent-1"
  git -C "$MAIN" worktree add --quiet "$WT_ROOT/platform-agent-2" -b agent-2 origin/main
  run wt_next_slot platform "$MAIN" origin/main
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
  run wt_next_slot platform "$MAIN" origin/main
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
  run wt_next_slot platform "$MAIN" origin/main
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
  run wt_next_slot platform "$MAIN" origin/main
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
  run wt_next_slot platform "$MAIN" origin/main
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
  run wt_next_slot platform "$MAIN" origin/main
  assert_success
  assert_output "3${PANEL_TAB}fresh"
}

@test "a landed worktree with a tmux pane open inside it is not idle" {
  # No session carries its name, but a pane from another session has cd'd into a subdir --
  # an agent started elsewhere and pointed here. That is as live as its own session.
  make_repo
  git -C "$MAIN" worktree add --quiet "$WT_ROOT/platform-agent-1" -b agent-1 origin/main
  printf '%s\n' /somewhere/else "$WT_ROOT/platform-agent-1/sub" > "$NOTES_FIXTURE/tmux.panes"
  run wt_next_slot platform "$MAIN" origin/main
  assert_success
  assert_output "2${PANEL_TAB}fresh"
}

@test "a pane in a SIBLING whose name merely extends this one does not pin it" {
  # agent-1 is a string prefix of agent-10; a prefix match would keep agent-1 busy forever
  # while agent-10 is in use.
  make_repo
  git -C "$MAIN" worktree add --quiet "$WT_ROOT/platform-agent-1" -b agent-1 origin/main
  printf '%s\n' "$WT_ROOT/platform-agent-10" > "$NOTES_FIXTURE/tmux.panes"
  run wt_next_slot platform "$MAIN" origin/main
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
  run wt_next_slot platform "$MAIN" origin/main
  assert_output "1${PANEL_TAB}recycle"
}

@test "a submodule on an UNPUSHED commit still pins the worktree" {
  # The commit exists only in this checkout; recycling would strand it.
  make_drifted_submodule
  git -C "$WT/sub" commit --quiet --allow-empty -m local-only
  run wt_reap_reason "$WT"
  assert_failure
  assert_output 'dirty (1 uncommitted)'
  run wt_next_slot platform "$MAIN" origin/main
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
  assert_output --partial 'repo-agent-1 (orphan daemon 500)'
  assert_output --partial '1 of 1 reapable'
  [ ! -d "$T" ]
  assert_equal "$(cat "$SANDBOX/kill.log")" '-TERM 500'
}

@test "gc -n names the orphan daemon and signals nothing" {
  orphan_tree
  run cmd_gc -n
  assert_success
  assert_output --partial 'repo-agent-1 (orphan daemon 500)'
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

@test "a dirty tree held only by an orphan reads stranded and the orphan lives" {
  orphan_tree
  echo edit > "$T/wip"
  run cmd_gc
  assert_output --partial 'stranded, nobody in it'
  [ -d "$T" ]
  [ ! -e "$SANDBOX/kill.log" ]
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

@test "a git-less dir holding anything but Unity caches is kept" {
  # A source tree whose .git went missing may be the only copy of its work.
  mkdir -p "$WT_ROOT/repo-agent-4/Library" "$WT_ROOT/repo-agent-4/apps"
  run wt_reap_reason "$WT_ROOT/repo-agent-4"
  assert_failure
  assert_output 'no git, and it holds more than Unity caches'
  mkdir -p "$WT_ROOT/repo-agent-5/.claude"
  run wt_reap_reason "$WT_ROOT/repo-agent-5"
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
