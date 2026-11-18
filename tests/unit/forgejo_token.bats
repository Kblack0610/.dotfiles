#!/usr/bin/env bats
# forgejo-token: the one resolution order for the Forgejo API token (env, a worker's token file, rbw).

bats_require_minimum_version 1.5.0

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  SANDBOX="$BATS_TEST_TMPDIR"
  export HOME="$SANDBOX/home"; mkdir -p "$HOME/.config/forgejo" "$SANDBOX/bin"
  unset FORGEJO_TOKEN FORGEJO_TOKEN_FILE FORGEJO_TOKEN_ENTRY
  printf '#!/bin/sh\n[ "$1" = get ] && [ -e "%s/rbw-has-$2" ] && echo "rbw-$2"\n' "$SANDBOX" > "$SANDBOX/bin/rbw"
  chmod +x "$SANDBOX/bin/rbw"
  export FORGEJO_TOKEN_RBW="$SANDBOX/bin/rbw"
  T="$ROOT/.local/bin/forgejo-token"
}

@test "env wins over the file and rbw" {
  echo file-tok > "$HOME/.config/forgejo/token"; touch "$SANDBOX/rbw-has-forgejo_repo_admin"
  FORGEJO_TOKEN=env-tok run "$T"
  assert_success; assert_output env-tok
}

@test "a worker's token file wins over rbw, first line only" {
  printf 'file-tok\nsecond\n' > "$HOME/.config/forgejo/token"; touch "$SANDBOX/rbw-has-forgejo_repo_admin"
  run "$T"
  assert_success; assert_output file-tok
}

@test "rbw answers when there is no env and no file, and the entry is a knob" {
  touch "$SANDBOX/rbw-has-forgejo_repo_admin" "$SANDBOX/rbw-has-other"
  run "$T"; assert_success; assert_output rbw-forgejo_repo_admin
  FORGEJO_TOKEN_ENTRY=other run "$T"; assert_success; assert_output rbw-other
}

@test "an empty token file falls through to rbw" {
  : > "$HOME/.config/forgejo/token"; touch "$SANDBOX/rbw-has-forgejo_repo_admin"
  run "$T"
  assert_success; assert_output rbw-forgejo_repo_admin
}

@test "none answers: rc 1 and one line naming all three sources" {
  run --separate-stderr "$T"
  assert_failure 1
  assert_output ''
  [[ "$stderr" == *"FORGEJO_TOKEN unset"* && "$stderr" == *".config/forgejo/token missing or empty"* && "$stderr" == *"rbw forgejo_repo_admin unread"* ]] || fail "stderr: $stderr"
}
