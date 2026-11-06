-- notes.tag_source: a blink.cmp source that opens a dropdown of known tags when you type `#` in
-- a note, fed by `notes tags --kind`. Registered in plugins/blink.lua.
--
--   a task row      `#` offers task tags, then topics
--   anywhere else   `#` offers topics
--   `tags: [` in frontmatter offers topics, written without the `#`
--
-- The CLI owns which tags exist and what kind each is; this only decides what the cursor is on.
-- A hit runs the CLI each time, so there is no cache to go stale; a failed run offers nothing.

local M = {}

local NONE = { items = {}, is_incomplete_forward = false, is_incomplete_backward = false }
local KEYWORD_KIND = 14 -- LSP CompletionItemKind.Keyword

-- What the text before the cursor is typing, or nil when it is not a tag. The rules mirror
-- md::for_each_tag: a `#` glued to a word or inside a code span is no tag, and a tag starts with
-- a letter. A `#` alone at the start of a line is a heading on its way, so it offers nothing.
-- Returns { kinds, start (0-based byte col the edit replaces from), prefix, sigil }.
function M.context(before, in_frontmatter)
  if in_frontmatter and before:match("^tags:%s*%[[^%]]*$") then
    local word = before:match("[%w_%-/]*$")
    return { kinds = { "topic" }, start = #before - #word, prefix = word, sigil = "" }
  end
  local token = before:match("[%w_%-/%.]*$")
  local hash = #before - #token
  if hash == 0 or before:sub(hash, hash) ~= "#" then
    return nil
  end
  local head = before:sub(1, hash - 1)
  if head:match("^%s*$") or head:match("[%w_/%.%[#]$") then
    return nil
  end
  if token ~= "" and not token:match("^%a") then
    return nil
  end
  if select(2, head:gsub("`", "")) % 2 == 1 then
    return nil
  end
  local row = before:match("^%s*%- %[") ~= nil
  return {
    kinds = row and { "task", "topic" } or { "topic" },
    start = hash - 1,
    prefix = token,
    sigil = "#",
  }
end

-- `tags` ({ { tag, count }, ... }, best first) as completion items at `ctx`. blink's keyword stops
-- at `/` and `.`, so past one of those it filters on the part after it and the tag must match
-- what came before, while the edit still replaces the whole `#token`.
function M.items(ctx, tags, line, col)
  local typed = ctx.prefix:match("^.*[/%.]") or ""
  local items = {}
  for _, t in ipairs(tags) do
    if t.tag:sub(1, #typed) == typed then
      local text = ctx.sigil .. t.tag
      items[#items + 1] = {
        label = text,
        filterText = t.tag:sub(#typed + 1),
        sortText = ("%05d"):format(#items),
        kind = KEYWORD_KIND,
        labelDetails = { description = tostring(t.count) },
        textEdit = {
          newText = text,
          range = {
            start = { line = line, character = ctx.start },
            ["end"] = { line = line, character = col },
          },
        },
      }
    end
  end
  return items
end

-- Whether 1-based `row` of `bufnr` sits inside the frontmatter fence that opens the file.
local function in_frontmatter(bufnr, row)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, row, false)
  if lines[1] ~= "---" then
    return false
  end
  for i = 2, #lines - 1 do
    if lines[i] == "---" then
      return false
    end
  end
  return row > 1
end

-- `notes tags --kind <k>` for all of `kinds` at once, then on_done(tags) in `kinds` order. Async,
-- so the list never blocks typing; a kind that fails adds nothing.
local function fetch(kinds, on_done)
  local lists, left = {}, #kinds
  local function finish(i, list)
    lists[i], left = list, left - 1
    if left == 0 then
      local tags = {}
      for k = 1, #kinds do
        vim.list_extend(tags, lists[k])
      end
      on_done(tags)
    end
  end
  for i, kind in ipairs(kinds) do
    local ok = pcall(vim.system, { "notes", "tags", "--kind", kind }, { text = true }, function(res)
      local list = {}
      for l in (res.code == 0 and res.stdout or ""):gmatch("[^\n]+") do
        local tag, count = l:match("^(.-)\t(%d+)$")
        if tag then
          list[#list + 1] = { tag = tag, count = tonumber(count) }
        end
      end
      finish(i, list)
    end)
    if not ok then
      finish(i, {})
    end
  end
end

function M.new()
  return setmetatable({}, { __index = M })
end

function M:enabled()
  local notes_dir = vim.fn.expand("~/.notes") .. "/"
  return vim.bo.filetype == "markdown"
    and vim.api.nvim_buf_get_name(0):sub(1, #notes_dir) == notes_dir
end

function M:get_trigger_characters()
  return { "#", "/", ".", "[" }
end

function M:get_completions(context, callback)
  local row, col = context.cursor[1], context.cursor[2]
  local before = context.line:sub(1, col)
  local ctx = M.context(before, before:match("^tags:") ~= nil and in_frontmatter(context.bufnr, row))
  if not ctx then
    return callback(NONE)
  end
  callback = vim.schedule_wrap(callback)
  fetch(ctx.kinds, function(tags)
    callback({
      items = M.items(ctx, tags, row - 1, col),
      is_incomplete_forward = false,
      is_incomplete_backward = false,
    })
  end)
end

return M
