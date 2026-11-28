#!/usr/bin/env bats
# .githooks/post-merge restarts noctalia.service when a merge in the stowed checkout changed the
# Noctalia plugins: Noctalia's hot reload misses a file git replaced, so without the restart a
# pulled chip.luau never loads. It also reloads systemd --user when a merge changed a user unit and
# re-renders a missing generated theme file, and a merge anywhere else does none of these. Each test merges in a throwaway repo with a stub systemctl.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic
  export FX="$BATS_TEST_TMPDIR"
  printf '#!/usr/bin/env bash\necho "systemctl $*" >> "$FX/calls.log"\n{ [ "${NOCTALIA_ACTIVE:-1}" = 1 ] || [ "$2" != is-active ]; } && { [ "${RELOAD_FAILS:-0}" = 0 ] || [ "$2" != daemon-reload ]; }\n' > "$SANDBOX/bin/systemctl"
  chmod +x "$SANDBOX/bin/systemctl"
  REPO="$SANDBOX/repo"
  git init -q -b main "$REPO"
  git -C "$REPO" config user.email t@t && git -C "$REPO" config user.name t
  git -C "$REPO" config core.hooksPath "$REPO_ROOT/.githooks"
  mkdir -p "$REPO/.local/share/noctalia/plugins/dotfiles-chips" "$REPO/docs" "$REPO/.config/systemd/user"
  echo one > "$REPO/.local/share/noctalia/plugins/dotfiles-chips/chip.luau"
  echo one > "$REPO/.config/systemd/user/demo.service"
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

reloads() { grep -c 'systemctl --user daemon-reload' "$FX/calls.log" || true; }

@test "a merge that changes a user unit reloads systemd --user" {
  run merge_change .config/systemd/user/demo.service
  assert_success
  assert_output --partial 'reloading systemd --user'
  [ "$(reloads)" = 1 ]
}

@test "a merge that leaves the user units alone reloads nothing" {
  run merge_change docs/desk.md
  assert_success
  [ "$(reloads)" = 0 ]
}

@test "a merge outside the stowed checkout reloads nothing" {
  export DOTFILES_ROOT="$SANDBOX/elsewhere"
  mkdir -p "$DOTFILES_ROOT"
  run merge_change .config/systemd/user/demo.service
  assert_success
  [ "$(reloads)" = 0 ]
}

@test "a failed daemon-reload says so and does not fail the merge" {
  export RELOAD_FAILS=1
  run merge_change .config/systemd/user/demo.service
  assert_success
  assert_output --partial 'daemon-reload failed; run it by hand'
}

# theme_switch_stub <root>: a theme-switch under <root> that logs its call instead of rendering.
theme_switch_stub() {
  mkdir -p "$1/.local/src/theme"
  printf '#!/usr/bin/env bash\necho "theme-switch $*" >> "$FX/calls.log"\n' > "$1/.local/src/theme/theme-switch"
  chmod +x "$1/.local/src/theme/theme-switch"
}

@test "a merge in the stowed checkout re-renders a missing generated theme file" {
  theme_switch_stub "$REPO"
  run merge_change docs/desk.md
  assert_success
  assert_output --partial 're-rendering'
  run grep -c '^theme-switch batman --only .*hyprland' "$FX/calls.log"
  assert_output 1
}

# A worktree merge ran the main checkout's theme-switch, which reloads the live Hyprland, on every
# merge while main lacked a new render (ar-3266). The merge runs in a linked worktree of the stowed
# repo, which has the theme-switch and is missing every render.
@test "a merge in a worktree of the stowed checkout renders no theme and restarts nothing" {
  theme_switch_stub "$REPO"
  local wt="$SANDBOX/wt"
  git -C "$REPO" worktree add -q -b wt-base "$wt"
  git -C "$wt" checkout -q -b wt-change
  echo two > "$wt/.local/share/noctalia/plugins/dotfiles-chips/chip.luau"
  git -C "$wt" commit -qam change
  git -C "$wt" checkout -q wt-base
  : > "$FX/calls.log"
  run bash -c 'cd "$1" && git merge -q --ff-only wt-change' _ "$wt"
  assert_success
  refute_output --partial 're-rendering'
  run grep -cE '^theme-switch|restart noctalia' "$FX/calls.log"
  assert_output 0
}
