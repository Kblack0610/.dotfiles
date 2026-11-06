#!/usr/bin/env bats
# notes.nvim `notes.tag_source`: the dropdown of known tags on `#`. These run the real module in
# a headless nvim with a stub `notes` on PATH; the menu itself needs a real editor.
#
# Skips where nvim is absent (the CI fast tier installs none by design); run it locally.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  command -v nvim >/dev/null || skip "nvim not installed"
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  PLUGIN="$REPO_ROOT/.config/nvim/local-plugins/notes.nvim"
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  cat > "$BATS_TEST_TMPDIR/bin/notes" <<'STUB'
#!/bin/sh
case "$3" in
  task)  printf 'high\t40\nsize/s\t9\nsize/m\t7\nv0.5.0\t2\n' ;;
  topic) printf 'software\t77\nai\t5\n' ;;
  *) exit 2 ;;
esac
STUB
  chmod +x "$BATS_TEST_TMPDIR/bin/notes"
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
}

# Run a Lua chunk with notes.nvim on the runtimepath; it prints with io.stdout:write.
lua_run() {
  printf '%s\n' "$1" > "$BATS_TEST_TMPDIR/t.lua"
  nvim --headless -u NONE -i NONE --cmd "set rtp^=$PLUGIN" \
    -c "luafile $BATS_TEST_TMPDIR/t.lua" -c 'qa!' 2>&1
}

# The labels the source offers for the buffer `lines`, cursor at the end of the last one.
LABELS='
local src = require("notes.tag_source").new()
local function labels(lines)
  vim.api.nvim_buf_set_lines(0, 0, -1, false, lines)
  local line = lines[#lines]
  local got
  src:get_completions({ bufnr = 0, line = line, cursor = { #lines, #line } }, function(r) got = r end)
  vim.wait(2000, function() return got ~= nil end, 5)
  local out = {}
  for _, i in ipairs(got.items) do out[#out + 1] = i.label end
  return table.concat(out, " ")
end
'

@test "a task row offers task tags first, in the CLI's order, then topics" {
  run lua_run "$LABELS"'io.stdout:write(labels({ "- [ ] ship it #" }))'
  assert_output '#high #size/s #size/m #v0.5.0 #software #ai'
}

@test "prose offers topics only" {
  run lua_run "$LABELS"'io.stdout:write(labels({ "some thought about #" }))'
  assert_output '#software #ai'
}

@test "frontmatter tags offer topics with no hash, and only inside the fence" {
  run lua_run "$LABELS"'
io.stdout:write(labels({ "---", "tags: [" }), "|", labels({ "---", "a: b", "---", "tags: [" }))'
  assert_output 'software ai|'
}

@test "a closed frontmatter tag list offers nothing past its bracket" {
  run lua_run '
local s = require("notes.tag_source")
io.stdout:write(tostring(s.context("tags: [a, so", true) ~= nil), " ",
  tostring(s.context("tags: [a] so", true) ~= nil))'
  assert_output 'true false'
}

@test "past a slash only the tags under it remain, filtered on the part after it" {
  run lua_run '
local s = require("notes.tag_source")
local ctx = s.context("- [ ] x #size/", false)
local out = s.items(ctx, { { tag = "high", count = 1 }, { tag = "size/s", count = 2 } }, 3, 14)
io.stdout:write(#out, " ", out[1].filterText, " ", out[1].textEdit.newText, " ",
  out[1].textEdit.range.start.character, "-", out[1].textEdit.range["end"].character)'
  assert_output '1 s #size/s 8-14'
}

@test "what is not a tag offers nothing: headings, glued hashes, code spans, numbers" {
  run lua_run "$LABELS"'
for _, l in ipairs({ "## Fo", "#", "  #", "##", "a#b", "see `#x", "issue #12", "[#", "plain words" }) do
  io.stdout:write("[", labels({ l }), "]")
end'
  assert_output '[][][][][][][][][]'
}

@test "a closed code span does not hide the tag after it" {
  run lua_run "$LABELS"'io.stdout:write(labels({ "use `x` here #" }))'
  assert_output '#software #ai'
}

@test "a CLI too old for --kind offers nothing and raises no error" {
  printf '#!/bin/sh\necho "unexpected argument --kind" >&2\nexit 2\n' > "$BATS_TEST_TMPDIR/bin/notes"
  run lua_run "$LABELS"'io.stdout:write("[", labels({ "- [ ] x #" }), "]")'
  assert_output '[]'
}

@test "enabled only in markdown under ~/.notes" {
  run lua_run '
local s = require("notes.tag_source").new()
local function on(name, ft)
  vim.cmd("enew!")
  vim.api.nvim_buf_set_name(0, vim.fn.expand(name))
  vim.bo.filetype = ft
  return tostring(s:enabled())
end
io.stdout:write(on("~/.notes/a.md", "markdown"), " ", on("~/.notes-other/b.md", "markdown"), " ",
  on("~/.notes/c.lua", "lua"))'
  assert_output 'true false false'
}

# marksman indexes the whole vault and can sit on a request for seconds. blink waits for every
# sync provider, so a sync lsp froze the menu on an older token and `#size/m` accepted as `#size/s`.
@test "the lsp provider never holds up the menu in the vault, and stays sync elsewhere" {
  run lua_run '
local spec = dofile("'"$REPO_ROOT"'/.config/nvim/lua/kennethblack/plugins/blink.lua")
local async = spec[1].opts.sources.providers.lsp.async
local function on(name, ft)
  vim.cmd("enew!")
  vim.api.nvim_buf_set_name(0, vim.fn.expand(name))
  vim.bo.filetype = ft
  return tostring(async())
end
io.stdout:write(on("~/.notes/a.md", "markdown"), " ", on("/tmp/repo/README.md", "markdown"), " ",
  on("~/.notes/c.lua", "lua"))'
  assert_output 'true false false'
}
