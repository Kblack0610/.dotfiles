#!/usr/bin/env bats
# notes.nvim lab harpoon order: the projects index, then beta, alpha and dev sheets, then
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
    "personal	work	dev	v0	0	0	0	0	0	0	$LAB/projects/current/work/README.md" \
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

@test "empty list fills as index, beta, alpha, then dev by name; prod, draft and non-lab rows stay out" {
  run slots '{}'
  assert_success
  assert_output "$(printf '%s\n' \
    'LAB/projects/index.md' \
    'LAB/bnb/projects/current/game/README.md *' \
    'LAB/projects/current/alef/README.md *' \
    'LAB/bnb/projects/current/zeta/README.md *' \
    'LAB/projects/current/work/README.md *')"
}

@test "hand-added items stay after the auto block, in their order" {
  run slots "{ { value = '$LAB/projects/current/idea/README.md', context = {} },
               { value = '$LAB/scratch.md', context = { row = 3, col = 0 } } }"
  assert_success
  assert_line --index 5 'LAB/projects/current/idea/README.md'
  assert_line --index 6 'LAB/scratch.md'
  assert_equal "${#lines[@]}" 7
}

@test "a stale auto entry (project now prod) is dropped, a hand-added prod sheet is kept" {
  run slots "{ { value = '$LAB/bnb/projects/current/live/README.md', context = { notes_auto = true } } }"
  assert_success
  refute_output --partial 'live'
  run slots "{ { value = '$LAB/bnb/projects/current/live/README.md', context = {} } }"
  assert_line --index 5 'LAB/bnb/projects/current/live/README.md'
}

@test "a hand-added sheet that is now alpha joins the auto block once; the index and dailies are not duplicated" {
  run slots "{ { value = '$LAB/projects/current/alef/README.md', context = {} },
               { value = '$LAB/projects/index.md', context = {} },
               { value = '$LAB/daily/2026-10-26.md', context = {} } }"
  assert_success
  assert_equal "${#lines[@]}" 5
  assert_line --index 2 'LAB/projects/current/alef/README.md *'
}

# --- the hub list (hub_slots): daily, index, then today's pins; a new day starts over --------

# Print the slot values hub_slots returns for the given items, with the tmpdir shortened to T.
hub() {
  nvim --headless -u NONE -i NONE --cmd "set rtp^=$PLUGIN" \
    -c "lua local out = require('notes.harpoon').hub_slots($1, {
          daily = '$BATS_TEST_TMPDIR/daily/2026-11-09.md', index = '$LAB/projects/index.md' })
        for _, it in ipairs(out) do
          io.stdout:write((it.value:gsub(vim.pesc('$BATS_TEST_TMPDIR'), 'T')) .. '\n')
        end" \
    -c 'qa!' 2>/dev/null
}

@test "hub: an empty list becomes today's daily then the projects index" {
  run hub '{}'
  assert_success
  assert_output "$(printf '%s\n' 'T/daily/2026-11-09.md' 'T/lab/projects/index.md')"
}

@test "hub: same day, the user's pins stay after the two, the index is not duplicated" {
  run hub "{ { value = '$BATS_TEST_TMPDIR/daily/2026-11-09.md' }, { value = '$LAB/projects/index.md' },
             { value = '$BATS_TEST_TMPDIR/scratch.md' }, { value = '$LAB/projects/current/alef/README.md' } }"
  assert_success
  assert_output "$(printf '%s\n' 'T/daily/2026-11-09.md' 'T/lab/projects/index.md' \
    'T/scratch.md' 'T/lab/projects/current/alef/README.md')"
}

@test "hub: a new day (yesterday's daily in slot 1) wipes old dailies and pins back to the two" {
  local items="{ { value = '$BATS_TEST_TMPDIR/daily/2026-11-06.md' }"
  local i
  for i in $(seq 1 90); do items="$items, { value = '$BATS_TEST_TMPDIR/daily/old-$i.md' }"; done
  items="$items, { value = '$BATS_TEST_TMPDIR/scratch.md' } }"
  run hub "$items"
  assert_success
  assert_output "$(printf '%s\n' 'T/daily/2026-11-09.md' 'T/lab/projects/index.md')"
}
