#!/usr/bin/env bats
# .githooks/post-commit runs the live AI config sync only for a commit in the main checkout.
# A worktree commit once rewrote ~/.codex, ~/.gemini and ~/.config/opencode from unmerged
# sources. HOME is a sandbox and the sync is a stub, so nothing live is touched.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  hook="$REPO_ROOT/.githooks/post-commit"

  export HOME="$BATS_TEST_TMPDIR/home" GIT_CONFIG_NOSYSTEM=1
  unset DOTFILES_ROOT
  mkdir -p "$HOME"
  git config --global user.name test
  git config --global user.email test@example.invalid
  git config --global init.defaultBranch main

  main="$HOME/.dotfiles"
  sync_path=".config/codex/sync-ai-global-config.sh"
  marker="$BATS_TEST_TMPDIR/synced"
  git init -q "$main"
  mkdir -p "$main/.config/codex" "$BATS_TEST_TMPDIR/hooks"
  printf 'echo "$PWD" >>"%s"\n' "$marker" >"$main/$sync_path"
  git -C "$main" add "$sync_path"
  git -C "$main" commit -q -m base
  cp "$hook" "$BATS_TEST_TMPDIR/hooks/post-commit"
  git -C "$main" config core.hooksPath "$BATS_TEST_TMPDIR/hooks"
}

# touch_sync <checkout>: commit a change to the sync script there.
touch_sync() {
  echo "# changed" >>"$1/$sync_path"
  git -C "$1" add "$sync_path"
  git -C "$1" commit -q -m change
}

@test "a commit in the main checkout that changes the sync script runs the sync" {
  touch_sync "$main"
  [ -f "$marker" ]
}

@test "the same commit in a linked worktree does not run the sync" {
  git -C "$main" worktree add -q -b wt "$BATS_TEST_TMPDIR/wt"
  touch_sync "$BATS_TEST_TMPDIR/wt"
  [ ! -f "$marker" ]
}

@test "a DOTFILES_ROOT pointed at the worktree does not bring the sync back" {
  git -C "$main" worktree add -q -b wt "$BATS_TEST_TMPDIR/wt"
  DOTFILES_ROOT="$BATS_TEST_TMPDIR/wt" touch_sync "$BATS_TEST_TMPDIR/wt"
  [ ! -f "$marker" ]
}

@test "a main checkout reached through a symlinked HOME still runs the sync" {
  ln -s "$HOME" "$BATS_TEST_TMPDIR/link"
  HOME="$BATS_TEST_TMPDIR/link" touch_sync "$main"
  [ -f "$marker" ]
}

@test "a commit that leaves the sync script alone does not run the sync" {
  echo x >"$main/other"
  git -C "$main" add other
  git -C "$main" commit -q -m other
  [ ! -f "$marker" ]
}
