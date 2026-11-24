#!/usr/bin/env bats
# The knowledge finder: notes.nvim `notes.find` (<leader>nk) and the fzf popup
# `.local/src/tmux/notes-find.sh` (tmux Prefix+k), both over a stub `notes find`. The ranking
# itself is tested in notes-cli (`cargo test find::`); these check that each surface keeps the
# CLI's order, parses its rows and opens at the hit's line.
#
# The nvim cases skip where nvim is absent; the test image pins it (tests/Dockerfile, NVIM_VERSION).

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  PLUGIN="$REPO_ROOT/.config/nvim/local-plugins/notes.nvim"
  FIND_SH="$REPO_ROOT/.local/src/tmux/notes-find.sh"
  mkdir -p "$BATS_TEST_TMPDIR/bin" "$BATS_TEST_TMPDIR/vault"
  printf 'l1\nl2\nl3\nl4\nl5\nl6\nl7\nsso with oidc here\nl9\n' > "$BATS_TEST_TMPDIR/vault/sso.md"
  # Records its argv, then prints two hits, best first, in the CLI's tab shape.
  cat > "$BATS_TEST_TMPDIR/bin/notes" <<STUB
#!/bin/sh
printf '%s\n' "\$*" > "$BATS_TEST_TMPDIR/argv"
printf '$BATS_TEST_TMPDIR/vault/sso.md\t8\t9.50\tSSO notes\tsso with oidc here\n'
printf '$BATS_TEST_TMPDIR/vault/other.md\t1\t2.00\tOther\tauth in passing\n'
STUB
  chmod +x "$BATS_TEST_TMPDIR/bin/notes"
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
}

# Called first in each nvim test: a skip inside `run lua_run` would only end the subshell.
need_nvim() { command -v nvim >/dev/null || skip "nvim not installed"; }

lua_run() {
  printf '%s\n' "$1" > "$BATS_TEST_TMPDIR/t.lua"
  nvim --headless -u NONE -i NONE --cmd "set rtp^=$PLUGIN" \
    -c "luafile $BATS_TEST_TMPDIR/t.lua" -c 'qa!' 2>&1
}

@test "a CLI row parses into file, line, title and snippet; a malformed row is dropped" {
  need_nvim
  run lua_run '
local f = require("notes.find")
local i = f.parse("/v/a.md\t12\t3.25\tA title\tthe snippet")
io.stdout:write(i.file, "|", i.pos[1], "|", i.title, "|", i.snippet, "|", tostring(f.parse("junk")))'
  assert_output '/v/a.md|12|A title|the snippet|nil'
}

@test "the query goes to the CLI after --, so a leading -word is not read as a flag" {
  need_nvim
  run lua_run '
local f = require("notes.find")
io.stdout:write(table.concat(f.args("-draft ai oauth"), " "))'
  assert_output 'find -n 50 -- -draft ai oauth'
}

@test "the fallback picker lists hits in the CLI's order and opens the first at its line" {
  need_nvim
  run lua_run '
vim.ui.input = function(_, cb) cb("ai oauth") end
local shown
vim.ui.select = function(items, _, cb)
  local t = {}
  for _, i in ipairs(items) do t[#t + 1] = i.title end
  shown = table.concat(t, ",")
  cb(items[1])
end
require("notes.find").pick()
io.stdout:write(shown, "|", vim.fn.expand("%:t"), ":", vim.api.nvim_win_get_cursor(0)[1])'
  assert_output 'SSO notes,Other|sso.md:8'
}

@test "a popup hit is one row: path and line hidden, then its title and folder, no snippet" {
  NOTES_FIND_VAULT="$BATS_TEST_TMPDIR/" run "$FIND_SH" --rows "ai oauth"
  assert_success
  assert_line --index 0 --partial "$BATS_TEST_TMPDIR/vault/sso.md"$'\t8\t'
  assert_line --index 0 --regexp $'\t[^\t]*SSO notes[^\t]* [^\t]*vault[^\t]*$'
  assert_line --index 1 --partial 'Other'
  refute_output --partial 'sso with oidc here'
  [ "$(awk -F'\t' '{print NF}' <<<"$output" | sort -u)" = 3 ]
  run cat "$BATS_TEST_TMPDIR/argv"
  assert_output 'find -n 50 -- ai oauth'
}

@test "an empty or blank popup query runs nothing and prints nothing" {
  run "$FIND_SH" --rows "   "
  assert_success
  assert_output ''
  [ ! -e "$BATS_TEST_TMPDIR/argv" ]
}

@test "the preview is the whole note, opened with the hit line a third of the way down" {
  PATH="$BATS_TEST_TMPDIR/bin:/usr/bin:/bin" run "$FIND_SH" --preview "$BATS_TEST_TMPDIR/vault/sso.md" 8
  assert_success
  assert_output --partial 'sso with oidc here'
  assert_line --index 0 --partial 'l1'
  run "$REPO_ROOT/.local/src/tmux/panel-layout.sh" args notes-find side
  assert_success
  assert_line --index 0 --regexp '^--preview-window=right,.*,wrap-word,\+\{2\}/3$'
}
