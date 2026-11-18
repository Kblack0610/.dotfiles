#!/usr/bin/env bats
# .githooks/post-merge restarts noctalia.service when a merge in the stowed checkout changed the
# Noctalia plugins: Noctalia's hot reload misses a file git replaced, so without the restart a
# pulled chip.luau never loads. Each test merges in a throwaway repo with a stub systemctl.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic
  export FX="$BATS_TEST_TMPDIR"
  printf '#!/usr/bin/env bash\necho "systemctl $*" >> "$FX/calls.log"\n[ "${NOCTALIA_ACTIVE:-1}" = 1 ] || [ "$2" != is-active ]\n' > "$SANDBOX/bin/systemctl"
  chmod +x "$SANDBOX/bin/systemctl"
  REPO="$SANDBOX/repo"
  git init -q -b main "$REPO"
  git -C "$REPO" config user.email t@t && git -C "$REPO" config user.name t
  git -C "$REPO" config core.hooksPath "$REPO_ROOT/.githooks"
  mkdir -p "$REPO/.local/share/noctalia/plugins/dotfiles-chips" "$REPO/docs"
  echo one > "$REPO/.local/share/noctalia/plugins/dotfiles-chips/chip.luau"
  echo one > "$REPO/docs/desk.md"
  git -C "$REPO" add -A && git -C "$REPO" commit -qm base
  export DOTFILES_ROOT="$REPO"
}

# merge_change <path>: change <path> on a branch, then fast-forward main onto it in $REPO.
merge_change() {
  git -C "$REPO" checkout -q -b change
  echo two > "$REPO/$1"
  git -C "$REPO" commit -qam change
  git -C "$REPO" checkout -q main
  : > "$FX/calls.log"
  (cd "$REPO" && git merge -q --ff-only change)
}

restarts() { grep -c 'restart noctalia.service' "$FX/calls.log" || true; }

@test "a merge that changes a plugin restarts noctalia" {
  run merge_change .local/share/noctalia/plugins/dotfiles-chips/chip.luau
  assert_success
  assert_output --partial 'restarting noctalia.service'
  [ "$(restarts)" = 1 ]
}

@test "a merge that leaves the plugins alone restarts nothing" {
  run merge_change docs/desk.md
  assert_success
  [ "$(restarts)" = 0 ]
}

@test "a stopped noctalia is not started by a merge" {
  export NOCTALIA_ACTIVE=0
  run merge_change .local/share/noctalia/plugins/dotfiles-chips/chip.luau
  assert_success
  [ "$(restarts)" = 0 ]
}

@test "a merge outside the stowed checkout restarts nothing" {
  export DOTFILES_ROOT="$SANDBOX/elsewhere"
  mkdir -p "$DOTFILES_ROOT"
  run merge_change .local/share/noctalia/plugins/dotfiles-chips/chip.luau
  assert_success
  [ "$(restarts)" = 0 ]
}
