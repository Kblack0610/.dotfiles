#!/usr/bin/env bats
# dotfiles-drift -- is what is MERGED actually what is RUNNING?
#
# This is the detector the rest of the deploy story leans on: the `deploy-drift`
# sentinel watch runs `dotfiles-drift --quiet` every 6h and is the only thing
# that reports "merged is not deployed". Until now it had no tests at all, which
# is a poor property for the one check nobody else double-checks.
#
# The tests are written around the MIRROR class, because that is the one that
# actually cost six weeks: the private overlay's watch-companion-loop had been
# merged since June while a stale gitignored physical copy in the PUBLIC tree was
# what stow linked and what the daemon executed.
#
# The load-bearing case is `duplicate that still MATCHES`. Before 2026-08-09 the
# check only fired once the two copies DIFFERED, which is one commit too late:
# a byte-identical copy is not convergence, it is drift that has not happened
# yet, and nothing runs between "copy made" and "private repo moves on" to
# notice. Every MIRROR incident on record began life as a matching copy.
#
# Everything here is throwaway git repos under $BATS_TEST_TMPDIR. No daemon, no
# server, no network, host-safe.

bats_require_minimum_version 1.5.0

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic

  # No global git config under the sandbox HOME (same reason as worktree.bats).
  export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com
  export GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com

  DRIFT="$REPO_ROOT/.local/bin/dotfiles-drift"

  PUB="$SANDBOX/pub"
  PRIV="$SANDBOX/priv"
  make_repo "$PUB"
  make_repo "$PRIV"

  # The subject reads both roots from the environment, which is the whole reason
  # this is testable without touching the real ~/.dotfiles.
  export DOTFILES="$PUB" DOTFILES_PRIVATE="$PRIV"
  export DRIFT PUB PRIV
}

# A repo with a real origin so origin/main resolves and `rev-list HEAD..origin/main`
# behaves. Bare + clone rather than a fake ref, so BEHIND is exercised for real.
make_repo() {
  local work="$1" origin="$1.git"
  git init --quiet --bare -b main "$origin"
  git init --quiet -b main "$work"
  printf 'seed\n' > "$work/seed.txt"
  git -C "$work" add seed.txt
  git -C "$work" commit --quiet -m seed
  git -C "$work" remote add origin "$origin"
  git -C "$work" push --quiet -u origin main
}

# Track a deploy-path file in the PRIVATE repo -- the shape check_mirror scans for.
priv_tracks() {
  local rel="$1" body="$2"
  mkdir -p "$PRIV/$(dirname "$rel")"
  printf '%s\n' "$body" > "$PRIV/$rel"
  git -C "$PRIV" add "$rel"
  git -C "$PRIV" commit --quiet -m "add $rel"
  git -C "$PRIV" push --quiet origin main
}

# The deployed state in the PUBLIC tree: the wrong shape (a copy) and the right
# one (a link to the owning repo). These are the two states the whole MIRROR
# class is about, so they get a name each.
pub_copy() {
  local rel="$1" body="$2"
  mkdir -p "$PUB/$(dirname "$rel")"
  printf '%s\n' "$body" > "$PUB/$rel"
}
pub_link() {
  local rel="$1"
  mkdir -p "$PUB/$(dirname "$rel")"
  ln -sfn "$PRIV/$rel" "$PUB/$rel"
}

# Satisfy the LINK check so a test can assert on MIRROR alone. check_links wants
# every tracked .local/{bin,lib} path to resolve under $HOME.
link_into_home() {
  local rel="$1"
  mkdir -p "$HOME/$(dirname "$rel")"
  ln -sfn "$PUB/$rel" "$HOME/$rel"
}

# ---------------------------------------------------------------- clean state

@test "a symlink at the public path is CORRECT and reports no drift" {
  priv_tracks .local/bin/runner 'v2'
  pub_link .local/bin/runner
  link_into_home .local/bin/runner

  run "$DRIFT"
  assert_success
  assert_output --partial 'clean'
  refute_output --partial 'MIRROR'
}

# NEGATIVE CONTROL for the test above: same tree, same paths, the ONLY difference
# is copy-vs-link. If this did not fire, the "clean" assertion would be vacuous --
# it would be passing because the scanner saw nothing, not because the state is
# right. That failure mode (a gate reporting success on an empty input list) has
# bitten this repo before, so the pair is asserted together.
@test "...and the same tree with a COPY instead of a link does fire" {
  priv_tracks .local/bin/runner 'v2'
  pub_copy .local/bin/runner 'v2'
  link_into_home .local/bin/runner

  run "$DRIFT"
  assert_failure
  assert_output --partial 'MIRROR'
  assert_output --partial '.local/bin/runner'
}

# ---------------------------------------------------------------- MIRROR

@test "MIRROR: a deployed copy that DIFFERS from the tracked source is reported" {
  priv_tracks .local/bin/runner 'v2-merged'
  pub_copy .local/bin/runner 'v1-stale'     # the six-week outage, in miniature
  link_into_home .local/bin/runner

  run "$DRIFT"
  assert_failure
  assert_output --partial 'MIRROR'
  assert_output --partial 'differs from tracked source'
}

# THE REGRESSION TEST for 2026-08-09. This case was SILENT before: the old check
# ran a diff and only spoke when it failed, so a duplicate whose content still
# matched passed as converged. It is not converged -- it is one private commit
# away from the test above, with nothing in between to report it.
@test "MIRROR: a duplicate that still MATCHES is drift-in-waiting and is reported" {
  priv_tracks .local/bin/runner 'identical'
  pub_copy .local/bin/runner 'identical'    # byte-for-byte the tracked content
  link_into_home .local/bin/runner

  run "$DRIFT"
  assert_failure
  assert_output --partial 'MIRROR'
  assert_output --partial 'drifts on the next private commit'
}

# ...and the state it warns about really is one commit away. This asserts the
# WHY rather than the message: make the private repo move, re-run, and the same
# untouched public file is now the acute "differs" case.
@test "MIRROR: the matching duplicate becomes a real difference on the next private commit" {
  priv_tracks .local/bin/runner 'identical'
  pub_copy .local/bin/runner 'identical'
  link_into_home .local/bin/runner

  run "$DRIFT"
  assert_output --partial 'drifts on the next private commit'

  priv_tracks .local/bin/runner 'moved-on'           # nobody touched the public copy

  run "$DRIFT"
  assert_failure
  assert_output --partial 'differs from tracked source'
}

@test "MIRROR: a git-side symlink (mode 120000) is not a mirror" {
  mkdir -p "$PRIV/.local/bin"
  ln -sfn /some/where "$PRIV/.local/bin/runner"
  git -C "$PRIV" add .local/bin/runner
  git -C "$PRIV" commit --quiet -m 'add link'
  git -C "$PRIV" push --quiet origin main
  pub_copy .local/bin/runner 'anything'
  link_into_home .local/bin/runner

  run "$DRIFT"
  refute_output --partial 'MIRROR'
}

# ---------------------------------------------------------------- BEHIND

@test "BEHIND: a checkout below origin/main is reported" {
  printf 'later\n' > "$PUB/seed.txt"
  git -C "$PUB" commit --quiet -am later
  git -C "$PUB" push --quiet origin main
  git -C "$PUB" reset --hard --quiet HEAD~1        # fetched, merged, not checked out

  run "$DRIFT"
  assert_failure
  assert_output --partial 'BEHIND'
  assert_output --partial '1 commit(s)'
}

# ---------------------------------------------------------------- modes

@test "--quiet prints nothing and exits 1 on drift" {
  priv_tracks .local/bin/runner 'v2'
  pub_copy .local/bin/runner 'v1'
  link_into_home .local/bin/runner

  run "$DRIFT" --quiet
  assert_failure
  assert_output ''
}

@test "--quiet exits 0 when clean, so the watch does not page on a healthy box" {
  priv_tracks .local/bin/runner 'v2'
  pub_link .local/bin/runner
  link_into_home .local/bin/runner

  run "$DRIFT" --quiet
  assert_success
  assert_output ''
}

@test "--json emits a parseable object whose count matches the findings" {
  priv_tracks .local/bin/runner 'v2'
  pub_copy .local/bin/runner 'v1'
  link_into_home .local/bin/runner

  run "$DRIFT" --json
  assert_failure
  # Parse it rather than grepping: the point of --json is that a consumer can.
  run bash -c "'$DRIFT' --json | jq -e '.drift >= 1 and (.findings|length) == .drift and (.findings[0].type|type) == \"string\"'"
  assert_success
}

# ---------------------------------------------------------------- remedy text

# The remedy is part of the contract. It used to say "refresh the deployed copy"
# with a `git show > file` one-liner -- which fixes the symptom and re-creates the
# duplicate, so the same finding returns on the next private commit. That advice
# is what kept this drift alive, so the test pins that it is gone.
@test "the MIRROR remedy tells you to LINK, and never to copy the file back" {
  priv_tracks .local/bin/runner 'v2'
  pub_copy .local/bin/runner 'v1'
  link_into_home .local/bin/runner

  run "$DRIFT"
  assert_output --partial 'ln -sfn'
  refute_output --partial 'show origin/main:<path> > '
}
