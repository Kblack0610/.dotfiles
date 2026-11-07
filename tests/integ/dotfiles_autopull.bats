#!/usr/bin/env bats
# dotfiles-autopull: the stowed checkouts (~/.dotfiles, ~/.dotfiles-private) follow their upstream,
# fast-forward only. Each checkout is a clone of a fixture bare origin under the sandbox $HOME; a
# second clone stands in for a merged PR. No live checkout is touched.

bats_require_minimum_version 1.5.0

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic
  PULL="$REPO_ROOT/.local/bin/dotfiles-autopull"
  export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
  unset DOTFILES_DIR DOTFILES_PRIVATE DOTFILES_AUTOPULL_INTERVAL
  PUB="$HOME/.dotfiles" PRIV="$HOME/.dotfiles-private"
  pair pub "$PUB"
  pair priv "$PRIV"
}

# pair <name> <checkout> -> a bare origin, the checkout cloned from it, and $SANDBOX/<name>-up, a
# second clone that pushes the "merged" commits
pair() {
  git init -q --bare -b main "$SANDBOX/$1.git"
  git clone -q "$SANDBOX/$1.git" "$SANDBOX/$1-up" 2>/dev/null
  printf 'v1\n' >"$SANDBOX/$1-up/f"
  git -C "$SANDBOX/$1-up" add f && git -C "$SANDBOX/$1-up" commit -qm v1 && git -C "$SANDBOX/$1-up" push -q origin HEAD:main
  git clone -q "$SANDBOX/$1.git" "$2"
}

# merge <name> <content> -> origin's main gets a commit that sets f to <content>
merge() {
  printf '%s\n' "$2" >"$SANDBOX/$1-up/f"
  git -C "$SANDBOX/$1-up" commit -qam "$2" && git -C "$SANDBOX/$1-up" push -q origin HEAD:main
}

head_of() { git -C "$1" rev-parse HEAD; }

@test "--now from a worktree of the public repo fast-forwards ~/.dotfiles, and only it" {
  git -C "$PUB" worktree add -q "$SANDBOX/pub-wt" -b feat
  merge pub v2
  merge priv v2
  priv_before=$(head_of "$PRIV")
  run "$PULL" --now "$SANDBOX/pub-wt"
  assert_success
  assert_output --regexp '^~/\.dotfiles: fast-forwarded main [0-9a-f]{8}\.\.[0-9a-f]{8}$'
  assert_equal "$(cat "$PUB/f")" v2
  assert_equal "$(head_of "$PRIV")" "$priv_before"
  run cat "$XDG_CACHE_HOME/dotfiles-autopull/autopull.log"
  assert_output --partial '~/.dotfiles: fast-forwarded main'
}

@test "--now from the private repo fast-forwards ~/.dotfiles-private" {
  merge priv v2
  run "$PULL" --now "$PRIV"
  assert_success
  assert_output --regexp '^~/\.dotfiles-private: fast-forwarded main '
  assert_equal "$(cat "$PRIV/f")" v2
}

@test "negative control: a dirty file the merge would overwrite stays put, and the line names it" {
  merge pub v2
  printf 'local edit\n' >"$PUB/f"
  before=$(head_of "$PUB")
  run "$PULL" --now "$PUB"
  assert_success
  assert_output --regexp '^~/\.dotfiles: not fast-forwarded, main stays at [0-9a-f]{8}: local changes to f$'
  assert_equal "$(head_of "$PUB")" "$before"
  assert_equal "$(cat "$PUB/f")" 'local edit'
  run cat "$XDG_CACHE_HOME/dotfiles-autopull/autopull.log"
  assert_output --partial 'local changes to f'
}

@test "a dirty file the merge does not touch does not block it, and keeps its edit" {
  printf 'g1\n' >"$SANDBOX/pub-up/g"
  git -C "$SANDBOX/pub-up" add g && git -C "$SANDBOX/pub-up" commit -qm g && git -C "$SANDBOX/pub-up" push -q origin HEAD:main
  git -C "$PUB" pull -q
  merge pub v2
  printf 'mine\n' >"$PUB/g"
  run "$PULL" --now "$PUB"
  assert_output --partial 'fast-forwarded main'
  assert_equal "$(cat "$PUB/f")" v2
  assert_equal "$(cat "$PUB/g")" mine
}

@test "local commits its upstream lacks: left alone and said" {
  merge pub v2
  printf 'h\n' >"$PUB/h" && git -C "$PUB" add h && git -C "$PUB" commit -qm local
  before=$(head_of "$PUB")
  run "$PULL" --now "$PUB"
  assert_output '~/.dotfiles: not fast-forwarded, main has local commits its upstream lacks'
  assert_equal "$(head_of "$PUB")" "$before"
}

@test "already current: says so" {
  run "$PULL" --now "$PUB"
  assert_output --regexp '^~/\.dotfiles: main already current at [0-9a-f]{8}$'
}

@test "--now for a repo that is not a stowed checkout prints nothing and moves nothing" {
  merge pub v2
  git init -q "$SANDBOX/other"
  run "$PULL" --now "$SANDBOX/other"
  assert_success
  assert_output ''
  assert_equal "$(cat "$PUB/f")" v1
  run "$PULL" --now "$SANDBOX/not-a-dir"
  assert_success
  assert_output ''
}

@test "the shell pass moves both checkouts, then holds off until the interval passes" {
  merge pub v2
  merge priv v2
  run "$PULL"
  assert_success
  assert_output ''
  assert_equal "$(cat "$PUB/f")" v2
  assert_equal "$(cat "$PRIV/f")" v2
  merge priv v3
  run "$PULL"
  assert_equal "$(cat "$PRIV/f")" v2
  DOTFILES_AUTOPULL_INTERVAL=0 run "$PULL"
  assert_equal "$(cat "$PRIV/f")" v3
}

@test "the shell pass with no private checkout still moves the public one" {
  rm -rf "$PRIV"
  merge pub v2
  run "$PULL"
  assert_success
  assert_equal "$(cat "$PUB/f")" v2
}
