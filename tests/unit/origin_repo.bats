#!/usr/bin/env bats
# origin-repo.sh: the one origin URL -> <owner>/<repo> parse. Before it, agent-land, fleet-sessions,
# credit-backfill, session-outcomes.sh and tmux/worktree.sh each had their own, and they disagreed
# on a trailing slash, an ssh:// URL and which host counts. Each URL form gets a case.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic
  source "$REPO_ROOT/.local/lib/origin-repo.sh"
  CLONE="$BATS_TEST_TMPDIR/clone"
  git init -q "$CLONE"
}

# repo_of <url> [host]: origin_repo on a clone whose origin is <url>.
repo_of() {
  git -C "$CLONE" remote remove origin 2>/dev/null || true
  git -C "$CLONE" remote add origin "$1"
  origin_repo "$CLONE" "${@:2}"
}

@test "every GitHub URL form gives owner/repo" {
  local url
  for url in https://github.com/o/r https://github.com/o/r.git https://github.com/o/r/ \
    https://github.com/o/r.git/ git@github.com:o/r.git git@github.com:o/r \
    ssh://git@github.com/o/r.git ssh://git@github.com:22/o/r.git; do
    run repo_of "$url"
    assert_success
    assert_output o/r
  done
}

@test "a non-GitHub host gives its owner/repo too, unless a host is asked for" {
  run repo_of https://git.example.lan/o/r.git
  assert_output o/r
  run repo_of https://git.example.lan/o/r.git github.com
  assert_failure
  assert_output ''
  # NEGATIVE CONTROL: a host only containing the name is not that host.
  run repo_of https://notgithub.com/o/r github.com
  assert_failure
}

@test "the host filter takes every URL form and ignores case" {
  run repo_of git@GitHub.com:o/r.git github.com
  assert_output o/r
  run repo_of ssh://git@github.com:22/o/r.git github.com
  assert_output o/r
  run repo_of https://github.com/o/r github.com
  assert_output o/r
  # A password may hold an @, and a path may too: neither is the host.
  run repo_of 'https://u:p@ss@github.com/o/r.git' github.com
  assert_output o/r
  run repo_of https://git.example.lan/github.com@x/r github.com
  assert_failure
}

@test "origin_off_github: a URL on another host is off GitHub; GitHub and a path origin are not" {
  local url
  for url in https://git.example.lan/o/r.git git@git.example.lan:o/r.git ssh://git@git.example.lan:2222/o/r.git file:///srv/r.git; do
    repo_of "$url" >/dev/null
    run origin_off_github "$CLONE"
    assert_success
  done
  # NEGATIVE CONTROL: GitHub in every form, and a local path (no host for gh to know), are not
  for url in https://GitHub.com/o/r git@github.com:o/r.git ssh://git@github.com:22/o/r.git /srv/r.git; do
    repo_of "$url" >/dev/null
    run origin_off_github "$CLONE"
    assert_failure
  done
}

@test "no origin, or no dir, is nothing and rc 1" {
  run origin_repo "$CLONE"
  assert_failure
  assert_output ''
  # NEGATIVE CONTROL: an empty dir must not answer for the current directory's checkout.
  git -C "$CLONE" remote add origin https://github.com/o/r
  cd "$CLONE"
  run origin_repo ''
  assert_failure
  assert_output ''
}
