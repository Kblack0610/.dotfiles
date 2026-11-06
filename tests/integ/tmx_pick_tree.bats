#!/usr/bin/env bats
# `tmx pick` (Prefix+H): the collapsible tree over `tmx rows`.
#
# integ tier: tree-rows and tree-enter read a rows file and an open list, so a fixture rows
# file drives them with no tmux server. The rows themselves are pinned by the ui tier
# (servers_isolation.bats); this pins what the tree does with them.

bats_require_minimum_version 1.5.0

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic

  TMX="$REPO_ROOT/.local/src/tmux/servers.sh"
  export TMX_PICK_DIR="$SANDBOX/pick"
  mkdir -p "$TMX_PICK_DIR"
  : > "$TMX_PICK_DIR/open"
  # The shape _all_rows emits: stranded block first, then each world and its sessions.
  printf '%s\n' \
    $'\t\t\tSTRANDED  1  no agent, no manifest' \
    $'hub\tloose\t\t  hub  loose  stranded' \
    $'hub\t\t\thub  2 sessions' \
    $'hub\tdaily\t\t  daily  nvim' \
    $'hub\tdotfiles\t\t  dotfiles  2 win' \
    $'hub\tdotfiles\t1\t       1* main' \
    $'lab\t\t\tlab  1 session' \
    $'lab\tdotfiles-agent-3\t\t  dotfiles-agent-3  WORKING' \
    $'work\t\t\twork  not running' > "$TMX_PICK_DIR/rows"
}

shown() { "$TMX" tree-rows "$@" | cut -f4; }

@test "it opens collapsed: one row per world, the stranded block as one row after them" {
  run shown
  assert_success
  assert_line --index 0 '+ hub  2 sessions'
  assert_line --index 1 '+ lab  1 session'
  assert_line --index 2 '  work  not running'
  assert_line --index 3 '+ STRANDED  1  no agent, no manifest'
  refute_output --partial 'daily'
  refute_output --partial 'loose'
}

@test "Enter on a world opens it: its sessions and windows, and no other world's" {
  run "$TMX" tree-enter hub
  assert_output --partial 'reload:'
  run shown
  assert_line --index 0 '- hub  2 sessions'
  assert_output --partial 'daily  nvim'
  assert_output --partial '1* main'
  refute_output --partial 'dotfiles-agent-3'
}

@test "Enter on an open world closes it again" {
  "$TMX" tree-enter lab >/dev/null
  "$TMX" tree-enter lab >/dev/null
  run shown
  refute_output --partial 'dotfiles-agent-3'
  assert_line --index 1 '+ lab  1 session'
}

@test "Enter on a session, a window or a world that is down goes there" {
  # Negative control for the toggle: a row with no key never reloads.
  run "$TMX" tree-enter ''
  assert_output 'accept'
  run bash -c "'$TMX' tree-rows | awk -F'\t' '\$1==\"work\" {print \$5}'"
  assert_output ''
}

@test "STRANDED opens like a world" {
  "$TMX" tree-enter STRANDED >/dev/null
  run shown
  assert_output --partial '- STRANDED'
  assert_output --partial 'loose  stranded'
}

@test "a search shows every row, open or not" {
  run shown 'agent'
  assert_output --partial 'dotfiles-agent-3'
  assert_output --partial 'daily  nvim'
  assert_output --partial 'loose  stranded'
}

@test "a picked row keeps its target in the first three fields" {
  "$TMX" tree-enter hub >/dev/null
  run bash -c "'$TMX' tree-rows | awk -F'\t' '\$4 ~ /1\\* main/ {print \$1\"/\"\$2\"/\"\$3}'"
  assert_output 'hub/dotfiles/1'
}
