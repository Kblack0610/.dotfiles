#!/usr/bin/env bats
# notes.nvim `notes.datetag`: a task typed by hand into a daily note's `## Focus` is dated
# on save with `#cMMDD`, and the cockpit reads its age back from that tag.
#
# The CLI stamps every task it writes, but a task typed in the editor used to stay bare
# until the next carry, which then dated it the previous day. These run the real module
# in a headless nvim; the save hook in markdown.lua is a thin caller of stamp_focus.
#
# Skips where nvim is absent (the CI fast tier installs none by design); run it locally.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  command -v nvim >/dev/null || skip "nvim not installed"
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  PLUGIN="$REPO_ROOT/.config/nvim/local-plugins/notes.nvim"
}

# Run a Lua chunk with notes.nvim on the runtimepath; it prints with io.stdout:write.
lua_run() {
  printf '%s\n' "$1" > "$BATS_TEST_TMPDIR/t.lua"
  nvim --headless -u NONE -i NONE --cmd "set rtp^=$PLUGIN" \
    -c "luafile $BATS_TEST_TMPDIR/t.lua" -c 'qa!' 2>&1
}

@test "stamp_focus dates bare open Focus tasks and nothing else" {
  run lua_run '
local dt = require("notes.datetag")
local lines = {
  "# 2026-10-26",
  "## Focus",
  "- [ ] submit app #urgent",
  "- [/] wire it up",
  "- [ ] already #c1022 #high",
  "- [ ] legacy (3d) <!-- since:2026-10-23 -->",
  "- [ ] ",
  "- [x] finished thing",
  "  - [ ] nested step <!-- cu:abc -->",
  "---",
  "Backlogs: [[x]]",
  "## Notes",
  "- [ ] not in focus",
}
local out, changed = dt.stamp_focus(lines, dt.note_date("/v/journal/daily/2026-10-26.md"))
for _, l in ipairs(out) do io.stdout:write(l .. "\n") end
io.stdout:write("changed=" .. table.concat(changed, ",") .. "\n")'
  assert_success
  assert_line --index 2 "- [ ] submit app #c1026 #urgent"
  assert_line --index 3 "- [/] wire it up #c1026"
  assert_line --index 4 "- [ ] already #c1022 #high"
  assert_line --index 5 "- [ ] legacy (3d) <!-- since:2026-10-23 -->"
  assert_line --index 6 "- [ ] "
  assert_line --index 7 "- [x] finished thing"
  assert_line --index 8 "  - [ ] nested step #c1026 <!-- cu:abc -->"
  assert_line --index 12 "- [ ] not in focus"
  assert_line "changed=3,4,9"
}

@test "note_date reads only a daily note's own file name" {
  run lua_run '
local dt = require("notes.datetag")
for _, p in ipairs { "/v/daily/2026-10-26.md", "/v/sessions/2026-10-26-wind-down.md", "/v/2026-10-26/notes.md" } do
  local d = dt.note_date(p)
  io.stdout:write((d and string.format("%d-%d-%d", d.year, d.month, d.day) or "nil") .. "\n")
end'
  assert_success
  assert_output $'2026-10-26\nnil\nnil'
}

@test "age reads month-day across a year end, the long form, and the legacy comment" {
  run lua_run '
local dt = require("notes.datetag")
local function show(text, y, m, d) io.stdout:write(tostring(dt.age(text, { year = y, month = m, day = d })) .. "\n") end
show("- [ ] x #c1022 #high", 2026, 10, 26)
show("- [ ] x #c1230", 2027, 1, 5)
show("- [ ] x (9d) #c261017", 2026, 10, 26)
show("- [ ] x (3d) <!-- since:2026-10-23 -->", 2026, 10, 26)
show("- [ ] x #cat", 2026, 10, 26)'
  assert_success
  assert_output $'4\n6\n9\n3\nnil'
}
