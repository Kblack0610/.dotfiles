#!/usr/bin/env bats
# notes.nvim lab harpoon order: the projects index, then beta sheets, then alpha sheets, then
# whatever the user added. Drives notes.harpoon.lab_slots in a real headless nvim against
# fixture `notes projects --stats` rows; harpoon itself is not needed.
#
# Skips where nvim is absent (the CI fast tier installs none by design); run it locally.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  command -v nvim >/dev/null || skip "nvim not installed"
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  PLUGIN="$REPO_ROOT/.config/nvim/local-plugins/notes.nvim"
  LAB="$BATS_TEST_TMPDIR/lab"
  STATS="$BATS_TEST_TMPDIR/stats.tsv"
  # profile name stage version open urgent high low planned agent sheet
  printf '%s\n' \
    "bnb	zeta	alpha	v0	0	0	0	0	0	0	$LAB/bnb/projects/current/zeta/README.md" \
    "bnb	game	beta	v1	0	0	0	0	0	0	$LAB/bnb/projects/current/game/README.md" \
    "bnb	live	prod	v2	0	0	0	0	0	0	$LAB/bnb/projects/current/live/README.md" \
    "personal	alef	alpha	v0	0	0	0	0	0	0	$LAB/projects/current/alef/README.md" \
    "personal	idea	draft	v0	0	0	0	0	0	0	$LAB/projects/current/idea/README.md" \
    "work	client	beta	v0	0	0	0	0	0	0	$BATS_TEST_TMPDIR/employment/client/README.md" \
    > "$STATS"
}

# Print the slot values lab_slots returns for the given current items (a Lua table literal),
# one per line, with the lab root shortened to `LAB` and an `*` on auto entries.
slots() {
  nvim --headless -u NONE -i NONE --cmd "set rtp^=$PLUGIN" \
    -c "lua local out = require('notes.harpoon').lab_slots($1, vim.fn.readfile('$STATS'), {
          index = '$LAB/projects/index.md', lab_root = '$LAB', daily_dir = '$LAB/daily/' })
        for _, it in ipairs(out) do
          local v = it.value:gsub(vim.pesc('$LAB'), 'LAB')
          io.stdout:write(v .. ((it.context or {}).notes_auto and ' *' or '') .. '\n')
        end" \
    -c 'qa!' 2>/dev/null
}

@test "empty list fills as index, beta, then alpha by name; prod, draft and non-lab rows stay out" {
  run slots '{}'
  assert_success
  assert_output "$(printf '%s\n' \
    'LAB/projects/index.md' \
    'LAB/bnb/projects/current/game/README.md *' \
    'LAB/projects/current/alef/README.md *' \
    'LAB/bnb/projects/current/zeta/README.md *')"
}

@test "hand-added items stay after the auto block, in their order" {
  run slots "{ { value = '$LAB/projects/current/idea/README.md', context = {} },
               { value = '$LAB/scratch.md', context = { row = 3, col = 0 } } }"
  assert_success
  assert_line --index 4 'LAB/projects/current/idea/README.md'
  assert_line --index 5 'LAB/scratch.md'
  assert_equal "${#lines[@]}" 6
}

@test "a stale auto entry (project now prod) is dropped, a hand-added prod sheet is kept" {
  run slots "{ { value = '$LAB/bnb/projects/current/live/README.md', context = { notes_auto = true } } }"
  assert_success
  refute_output --partial 'live'
  run slots "{ { value = '$LAB/bnb/projects/current/live/README.md', context = {} } }"
  assert_line --index 4 'LAB/bnb/projects/current/live/README.md'
}

@test "a hand-added sheet that is now alpha joins the auto block once; the index and dailies are not duplicated" {
  run slots "{ { value = '$LAB/projects/current/alef/README.md', context = {} },
               { value = '$LAB/projects/index.md', context = {} },
               { value = '$LAB/daily/2026-10-26.md', context = {} } }"
  assert_success
  assert_equal "${#lines[@]}" 4
  assert_line --index 2 'LAB/projects/current/alef/README.md *'
}
