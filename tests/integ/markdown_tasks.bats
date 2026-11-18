#!/usr/bin/env bats
# The markdown task keys: <leader>tt converts a line (or a visual range) to a task and
# lands the cursor where its text goes; <leader>ts cycles the checkbox, <leader>tS resets it
# to todo. `o` stays stock vim: no markdown map may take it.
# Runs the real plugin config in a headless nvim with render-markdown stubbed.
#
# Skips where nvim is absent (the CI fast tier installs none by design); run it locally.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  command -v nvim >/dev/null || skip "nvim not installed"
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  SPEC="$REPO_ROOT/.config/nvim/lua/kennethblack/plugins/markdown.lua"
  PLUGIN="$REPO_ROOT/.config/nvim/local-plugins/notes.nvim"
  NOTE="$BATS_TEST_TMPDIR/note.md"
}

# Write lines to the note, run the Lua in $1 with the keymaps loaded, then print the
# buffer joined by " / " and the cursor as "row,col mode".
run_keys() {
  local lua="$1"
  shift
  printf '%s\n' "$@" > "$NOTE"
  nvim --headless -u NONE -i NONE --cmd "set rtp^=$PLUGIN" \
    -c "lua package.loaded['render-markdown'] = { setup = function() end }; vim.g.mapleader = ' '; dofile('$SPEC')[1].config()" \
    -c "edit $NOTE" -c 'set ft=markdown' \
    -c "lua $lua" \
    -c "lua local c = vim.api.nvim_win_get_cursor(0); io.stdout:write(table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), ' / ') .. ' | ' .. c[1] .. ',' .. c[2] .. ' ' .. vim.fn.mode() .. '\n')" \
    -c 'qa!' 2>/dev/null
}

# <leader>$2 on line $1, normal mode (tt leaves insert pending, as the mapping does).
key() { echo "vim.api.nvim_win_set_cursor(0, {$1, 0}); vim.fn.maparg(' $2', 'n', false, true).callback()"; }
tt() { key "$1" tt; }
# Visual <leader>$3 over lines $1..$2.
vkey() { echo "vim.fn.setpos(\"'<\", {0, $1, 1, 0}); vim.fn.setpos(\"'>\", {0, $2, 1, 0}); vim.fn.maparg(' $3', 'x', false, true).callback()"; }

@test "tt on prose converts it and lands at the end of the text" {
  run run_keys "$(tt 1)" '  buy milk'
  assert_output '  - [ ] buy milk | 1,16 n'
}

@test "tt on a blank line makes an empty task" {
  run run_keys "$(tt 1)" ''
  assert_output '- [ ]  | 1,6 n'
}

@test "tt keeps a checklist box from another bullet" {
  run run_keys "$(tt 1)" '* [x] done'
  assert_output '- [x] done | 1,10 n'
}

@test "tt on a task opens an indented subtask" {
  run run_keys "$(tt 1)" '- [ ] parent' 'next'
  assert_output '- [ ] parent /   - [ ]  / next | 2,8 n'
}

@test "tt on a heading opens a task below it instead of converting it" {
  run run_keys "$(tt 1)" '### High'
  assert_output '### High / - [ ]  | 2,6 n'
}

@test "visual tt converts prose and bullets, leaves headings, rules and tasks" {
  run run_keys "$(vkey 1 6 tt)" \
    '## Focus' 'one' '' '- [/] two' '* three' '---'
  assert_output '## Focus / - [ ] one /  / - [/] two / - [ ] three / --- | 1,0 n'
}

@test "ts cycles todo to in progress" {
  run run_keys "$(key 1 ts)" '- [ ] a'
  assert_output '- [/] a | 1,0 n'
}

@test "tS resets a done or in-progress task to todo" {
  run run_keys "$(key 1 tS); $(key 2 tS); $(key 3 tS)" '- [x] a' '- [/] b' '- [ ] c'
  assert_output '- [ ] a / - [ ] b / - [ ] c | 3,0 n'
}

@test "tS on a non-task line changes nothing" {
  run run_keys "$(key 1 tS)" 'prose'
  assert_output 'prose | 1,0 n'
}

@test "visual tS resets every task in a selection that starts on a heading" {
  run run_keys "$(vkey 1 3 tS)" '### Done' '- [x] a' '- [/] b'
  assert_output '### Done / - [ ] a / - [ ] b | 1,0 n'
}

@test "visual ts converges the selection to the first task's next state" {
  run run_keys "$(vkey 1 2 ts)" '- [/] a' '- [ ] b'
  assert_output '- [x] a / - [x] b | 1,0 n'
}

@test "o is stock vim o, on a task line too" {
  run run_keys "vim.api.nvim_win_set_cursor(0, {1, 0}); vim.api.nvim_feedkeys('ofoo\27', 'xt', false)" '- [ ] a' 'b'
  assert_output '- [ ] a / foo / b | 2,2 n'
}

@test "the config maps none of o, O or Enter in a markdown buffer" {
  run run_keys "for _, k in ipairs { 'o', 'O', '<CR>' } do vim.fn.setline(1, vim.fn.getline(1) .. '[' .. k .. '=' .. vim.fn.maparg(k, 'n') .. ']') end" ''
  assert_output '[o=][O=][<CR>=] | 1,0 n'
}
