#!/usr/bin/env bats
# markdown.lua's on-save Focus sweep: saving a daily note still files a finished task under
# Done, but the cursor and the scroll stay where they were. It used to follow the task down
# to Done (human, 2026-11-04: "moves my cursor down there, don't want that anymore").
#
# These load the real plugin config in a headless nvim (render-markdown stubbed), open a
# daily note so the Filetype hook installs the buffer autocmds, and `:write` it.
#
# Skips where nvim is absent (the CI fast tier installs none by design); run it locally.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  command -v nvim >/dev/null || skip "nvim not installed"
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  SPEC="$REPO_ROOT/.config/nvim/lua/kennethblack/plugins/markdown.lua"
  PLUGIN="$REPO_ROOT/.config/nvim/local-plugins/notes.nvim"
  NOTE="$BATS_TEST_TMPDIR/2026-11-04.md"
  # Already in the sweep's layout, so the one thing a save changes is the finished task (row 9).
  cat > "$NOTE" <<'EOF'
# 2026-11-04

## Focus

### Urgent
- [ ] fire #c1104 #urgent

### High
- [x] finished task #c1104 #high
- [ ] next task #c1104 #high

### Low
- [ ] someday #c1104 #low

---
### Done
- [x] old done #c1104
EOF
}

# Open $NOTE with the plugin loaded, put the cursor on row $1 col $2, run the Lua in $3, then
# print "row col topline lines" and the buffer. BUF[i] is buffer row i, blanks kept (bats' own
# `lines` drops them).
save_run() {
  cat > "$BATS_TEST_TMPDIR/t.lua" <<EOF
vim.g.mapleader = " "
package.loaded["render-markdown"] = { setup = function() end }
dofile("$SPEC")[1].config()
vim.cmd("edit $NOTE")
vim.bo.filetype = "markdown"
vim.api.nvim_win_set_cursor(0, { $1, $2 })
$3
local c = vim.api.nvim_win_get_cursor(0)
io.stdout:write(table.concat({ c[1], c[2], vim.fn.winsaveview().topline, vim.api.nvim_buf_line_count(0) }, " ") .. "\n")
for _, l in ipairs(vim.api.nvim_buf_get_lines(0, 0, -1, false)) do io.stdout:write(l .. "\n") end
EOF
  nvim --headless -u NONE -i NONE --cmd "set rtp^=$PLUGIN" \
    -c "luafile $BATS_TEST_TMPDIR/t.lua" -c 'qa!' 2>&1
}

buf() { mapfile -t BUF <<<"$output"; }

@test "save files a finished task under Done and the cursor keeps its row" {
  run save_run 9 4 'vim.cmd "silent write"'
  assert_success
  buf
  assert_equal "${BUF[0]% *}" "9 4 1"
  assert_equal "${BUF[9]}" "- [ ] next task #c1104 #high"
  assert_equal "${BUF[16]}" "- [x] finished task #c1104 #high"
  assert_equal "${BUF[17]}" "- [x] old done #c1104"
  run grep -c 'finished task' "$NOTE"
  assert_output 1
}

@test "save keeps the scroll as well as the row" {
  run save_run 12 2 'vim.fn.winrestview { topline = 3, lnum = 12, col = 2 }; vim.cmd "silent write"'
  assert_success
  buf
  assert_equal "${BUF[0]% *}" "12 2 3"
}

@test "save clamps the cursor to the buffer when the sweep shortens it" {
  # three trailing blanks collapse to one, and the cursor sat on the last of them
  printf '\n\n\n' >> "$NOTE"
  run save_run 20 0 'vim.cmd "silent write"'
  assert_success
  buf
  local rows="${BUF[0]##* }"
  assert [ "$rows" -lt 20 ]
  assert_equal "${BUF[0]}" "$rows 0 1 $rows"
}

@test "the priority cycle still follows its task to the new lane" {
  # <leader>tP on "next task" (#high) raises it to #urgent, and the cursor goes with it
  run save_run 10 0 'vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<leader>tP", true, false, true), "x", false)'
  assert_success
  buf
  local row="${BUF[0]%% *}"
  assert_equal "${BUF[$row]}" "- [ ] next task #c1104 #urgent"
  assert [ "$row" -lt 10 ]
}

# The same input and expected text as the golden in focus_sweep.rs, so the two sweeps cannot
# drift. The save also stamps the tasks it finds, which the Rust sweep leaves to the rollover.
@test "a save files every line of Focus into a lane, as the Rust sweep does" {
  printf '%s' $'## Focus\n- [ ] plain top\n- [ ] task #high\n- bare bullet\n    its note\nplain line\n### Urgent\n- [ ] dropped\ntyped here\n- [ ] \n\n## Notes\nafter\n' > "$NOTE"
  run save_run 1 0 'vim.cmd "silent write"'
  assert_success
  run sed 's/ #c1104//' "$NOTE"
  assert_output "$(printf '%s' $'## Focus\n\n### Urgent\n- [ ] dropped #urgent\n- [ ] typed here #urgent\n\n### High\n- [ ] task #high\n\n### Low\n- [ ] plain top #low\n- [ ] bare bullet #low\n    its note\n- [ ] plain line #low\n\n---\n### Done\n\n## Notes\nafter\n')"
}

@test "a note with an empty Focus opens on the bare lanes" {
  printf '## Focus\n- [ ] \n\n## Notes\n' > "$NOTE"
  run save_run 1 0 'vim.cmd "silent write"'
  assert_success
  run cat "$NOTE"
  assert_output "$(printf '## Focus\n\n### Urgent\n\n### High\n\n### Low\n\n---\n### Done\n\n## Notes\n')"
}

@test "a save stops at the rollup, whose rows are mirrored and not this note's" {
  printf '%s' $'## Focus\nloose\n<!-- rollup:start -->\n### bnb\n- [ ] row\nraw text\n\n## Refs\n' > "$NOTE"
  run save_run 1 0 'vim.cmd "silent write"'
  assert_success
  # No sed over the whole note: the mirrored row must come back without this note's created tag.
  run sed '/rollup:start/,$!s/ #c1104//' "$NOTE"
  assert_output "$(printf '%s' $'## Focus\n\n### Urgent\n\n### High\n\n### Low\n- [ ] loose #low\n\n---\n### Done\n\n<!-- rollup:start -->\n### bnb\n- [ ] row\nraw text\n\n## Refs\n')"
}

# Same input and expected text as focus_sweep.rs golden_tag_grammar_matches_the_nvim_buffer_sweep.
# md::tag_span reads `#high-priority` as one tag that is no priority; a `%f[%W]` match read it
# as `#high`, filed the row by it and cut `#high` out of the tag, leaving `-priority` behind.
@test "a save reads a priority tag by the CLI's tag grammar" {
  printf '%s' $'## Focus\n- [ ] a #high-priority #low\n- [ ] b #size/m #high-priority\n- [ ] c foo#urgent\n- [ ] d `#urgent` #HIGH.\n\n## Notes\n' > "$NOTE"
  run save_run 1 0 'vim.cmd "silent write"'
  assert_success
  run sed 's/ #c1104//' "$NOTE"
  assert_output "$(printf '%s' $'## Focus\n\n### Urgent\n\n### High\n- [ ] d `#urgent` #HIGH.\n\n### Low\n- [ ] a #high-priority #low\n- [ ] b #size/m #high-priority #low\n- [ ] c foo#urgent #low\n\n---\n### Done\n\n## Notes\n')"
}

@test "the priority cycle leaves a longer tag that starts with a level alone" {
  printf '%s' $'## Focus\n\n### Urgent\n\n### High\n- [ ] row #size/m #high-priority #c1104 #high\n\n### Low\n\n---\n### Done\n' > "$NOTE"
  run save_run 6 0 'vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<leader>tP", true, false, true), "x", false)'
  assert_success
  buf
  local row="${BUF[0]%% *}"
  assert_equal "${BUF[$row]}" "- [ ] row #size/m #high-priority #c1104 #urgent"
}

@test "a doc that is no daily note keeps the prose under its Focus heading" {
  NOTE="$BATS_TEST_TMPDIR/plan.md"
  printf '## Focus\nThis quarter is about reliability.\n- one theme\n' > "$NOTE"
  run save_run 1 0 'vim.cmd "silent write"'
  assert_success
  run cat "$NOTE"
  assert_output "$(printf '## Focus\nThis quarter is about reliability.\n- one theme\n')"
}
