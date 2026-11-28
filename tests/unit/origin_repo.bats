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

@test "origin_host: every URL form gives its host, lower-cased; a path origin gives none" {
  local url
  for url in https://Git.Example.lan/o/r.git git@git.example.lan:o/r.git ssh://git@git.example.lan:2222/o/r.git \
    'https://u:p@ss@git.example.lan/o/r.git'; do
    repo_of "$url" >/dev/null
    run origin_host "$CLONE"
    assert_output git.example.lan
  done
  repo_of /srv/r.git >/dev/null
  run origin_host "$CLONE"
  assert_success
  assert_output ''
  # NEGATIVE CONTROL: no origin is rc 1, not an empty host
  git -C "$CLONE" remote remove origin
  run origin_host "$CLONE"
  assert_failure
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

@test "github_over_https sends a GitHub ssh origin over HTTPS and keeps env config already set" {
  git -C "$CLONE" remote add origin git@github.com:o/r.git
  # NEGATIVE CONTROL: without it the origin stays on ssh.
  run git -C "$CLONE" remote get-url origin
  assert_output git@github.com:o/r.git
  export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=user.name GIT_CONFIG_VALUE_0=kept
  github_over_https
  run git -C "$CLONE" remote get-url origin
  assert_output https://github.com/o/r.git
  local url
  for url in ssh://git@github.com/o/r.git ssh://git@github.com:22/o/r.git; do
    git -C "$CLONE" remote set-url origin "$url"
    run git -C "$CLONE" remote get-url origin
    assert_output https://github.com/o/r.git
  done
  run git -C "$CLONE" config user.name
  assert_output kept
  # Another host is left alone.
  git -C "$CLONE" remote set-url origin git@git.example.lan:o/r.git
  run git -C "$CLONE" remote get-url origin
  assert_output git@git.example.lan:o/r.git
}

@test "store_name: a GitHub host (or none) gives owner/repo, any other host host/owner/repo, lower-cased" {
  local h
  for h in github.com GitHub.com ssh.github.com github.com-work ''; do
    run store_name "$h" o/r
    assert_output o/r
  done
  run store_name Git.Example.LAN o/r
  assert_output git.example.lan/o/r
}

@test "origin_store_name: the store key of a checkout's origin; rc 1 with none" {
  run origin_store_name "$CLONE"
  assert_failure 1
  git -C "$CLONE" remote add origin git@github.com:o/r.git
  run origin_store_name "$CLONE"
  assert_output o/r
  git -C "$CLONE" remote set-url origin https://git.example.lan/o/r.git
  run origin_store_name "$CLONE"
  assert_output git.example.lan/o/r
}

@test "pr_store: the store's rows on 0, 3 for a repo it does not list, 1 for any other failure" {
  source "$REPO_ROOT/.local/lib/main-state.sh"
  ss_stub
  ss_answer prs.out '[{"number":1}]'
  run pr_store o/r --state open --checks
  assert_success
  assert_output '[{"number":1}]'
  run calls
  assert_output 'schedules-sync prs o/r --state open --checks'
  ss_answer prs.rc 3
  run pr_store o/r
  assert_failure 3
  assert_output ''
  ss_answer prs.rc 2
  run pr_store o/r
  assert_failure 1
}

# checkout_fixture: $CLONE with one commit, a linked worktree $LINKED of it, a submodule $SUP/sub (its
# own worktree $SUBWT), and a bare repo $BARE. file:// submodules are refused by default since git 2.38.1.
checkout_fixture() {
  local g=(git -c user.email=t@t -c user.name=t -c protocol.file.allow=always)
  "${g[@]}" -C "$CLONE" commit -q --allow-empty -m init
  LINKED="$BATS_TEST_TMPDIR/linked"
  git -C "$CLONE" worktree add -q "$LINKED" -b linked
  SUP="$BATS_TEST_TMPDIR/sup"
  git init -q "$SUP"
  "${g[@]}" -C "$SUP" commit -q --allow-empty -m init
  "${g[@]}" -C "$SUP" submodule -q add "$CLONE" sub 2>/dev/null
  SUBWT="$BATS_TEST_TMPDIR/subwt"
  git -C "$SUP/sub" worktree add -q "$SUBWT" -b x
  BARE="$BATS_TEST_TMPDIR/bare.git"
  git init -q --bare "$BARE"
}

@test "main_checkout: the main checkout from itself, a linked worktree, and a subdirectory (ar-3541)" {
  checkout_fixture
  mkdir "$CLONE/d"
  for d in "$CLONE" "$CLONE/d" "$LINKED"; do
    run main_checkout "$d"
    assert_success
    assert_output "$CLONE"
  done
}

@test "main_checkout: a submodule, and its linked worktree, resolve to the submodule's checkout (ar-255)" {
  checkout_fixture
  run main_checkout "$SUP/sub"
  assert_success
  assert_output "$SUP/sub"
  run main_checkout "$SUBWT"
  assert_success
  assert_output "$SUP/sub"
  # A deinitialised submodule keeps core.worktree, so its checkout must still exist.
  rm -rf "$SUP/sub"
  run main_checkout "$SUBWT"
  assert_failure
}

@test "main_checkout: a bare repo, a directory outside any repo and no directory are nothing" {
  checkout_fixture
  mkdir "$BATS_TEST_TMPDIR/plain"
  for d in "$BARE" "$BATS_TEST_TMPDIR/plain" "$BATS_TEST_TMPDIR/missing"; do
    run main_checkout "$d"
    assert_failure
    assert_output ''
  done
}

@test "is_linked_checkout: only a linked worktree, a submodule's included; no main checkout, bare repo or plain directory" {
  checkout_fixture
  mkdir "$BATS_TEST_TMPDIR/plain" "$CLONE/d"
  run is_linked_checkout "$LINKED"
  assert_success
  run is_linked_checkout "$SUBWT"
  assert_success
  # NEGATIVE CONTROL: the main checkout and its subdirectory, a submodule's own checkout, a bare
  # repo and a directory outside any repo are all rc 1.
  for d in "$CLONE" "$CLONE/d" "$SUP/sub" "$BARE" "$BATS_TEST_TMPDIR/plain" "$BATS_TEST_TMPDIR/missing"; do
    run is_linked_checkout "$d"
    assert_failure
  done
}

@test "forge_repo_name reads the main checkout's name from a linked worktree" {
  checkout_fixture
  run forge_repo_name "$LINKED"
  assert_output clone
}
