-- notes_tags.lua — a tag finder for the `~/.notes` vault, wired to the `notes`
-- Rust CLI's `notes tags` subcommand.
--
--   :lua require("kennethblack.notes_tags").pick()   (bound to <leader>nt)
--
-- Two stages (mirrors the `notes-tags` fzf window):
--   1. pick a #tag from `notes tags`        ("<tag>\t<count>")
--   2. pick a matching note line from        ("<path>\t<line>\t<text>")
--      `notes tags <tag>`, previewed in-editor, then opened at that line.
--
-- Built on Snacks.picker (the only picker installed) with a vim.ui.select
-- fallback, and following the notes conventions in autocmds.lua: guard on
-- `executable("notes")`, shell out with vim.fn.system*, check v:shell_error,
-- notify on failure.

local M = {}

-- True if the `notes` CLI is on PATH; otherwise notify once and return false.
local function notes_available()
  if vim.fn.executable("notes") == 1 then
    return true
  end
  vim.notify(
    "`notes` CLI not found on PATH (build ~/.dotfiles/.local/src/notes-cli)",
    vim.log.levels.ERROR
  )
  return false
end

-- Run `notes tags <args...>` and return stdout as a list of non-empty lines.
-- Notifies + returns {} on failure.
local function run_tags(args)
  local cmd = { "notes", "tags" }
  vim.list_extend(cmd, args or {})
  local out = vim.fn.systemlist(cmd)
  if vim.v.shell_error ~= 0 then
    vim.notify(
      "notes " .. table.concat({ "tags", unpack(args or {}) }, " ") .. " failed:\n"
        .. table.concat(out, "\n"),
      vim.log.levels.ERROR
    )
    return {}
  end
  return vim.tbl_filter(function(l)
    return l ~= nil and l ~= ""
  end, out)
end

-- Open a note file at a 1-based line.
local function open_at(file, line)
  vim.cmd("edit " .. vim.fn.fnameescape(file))
  pcall(vim.api.nvim_win_set_cursor, 0, { tonumber(line) or 1, 0 })
end

local function have_snacks_picker()
  return _G.Snacks ~= nil and Snacks.picker ~= nil and type(Snacks.picker.pick) == "function"
end

-- ── Stage 2: the matching lines for a single tag ────────────────
function M.pick_hits(tag)
  local items = {}
  for _, l in ipairs(run_tags({ tag })) do
    local file, line, text = l:match("^(.-)\t(%d+)\t(.*)$")
    if file then
      items[#items + 1] = { file = file, pos = { tonumber(line), 0 }, text = text }
    end
  end

  if #items == 0 then
    vim.notify("No notes tagged #" .. tag, vim.log.levels.INFO)
    return
  end

  if have_snacks_picker() then
    Snacks.picker.pick({
      source = "notes_tag_hits",
      title = "#" .. tag,
      items = items,
      preview = "file",
      format = function(item)
        local base = vim.fn.fnamemodify(item.file, ":t")
        return {
          { base, "Directory" },
          { ":" .. item.pos[1] .. "  ", "LineNr" },
          { item.text, "Normal" },
        }
      end,
      confirm = function(picker, item)
        picker:close()
        if item then
          open_at(item.file, item.pos[1])
        end
      end,
    })
    return
  end

  -- Fallback: vim.ui.select
  vim.ui.select(items, {
    prompt = "#" .. tag,
    format_item = function(item)
      return ("%s:%d  %s"):format(vim.fn.fnamemodify(item.file, ":t"), item.pos[1], item.text)
    end,
  }, function(choice)
    if choice then
      open_at(choice.file, choice.pos[1])
    end
  end)
end

-- ── Stage 1: the list of tags ───────────────────────────────────
function M.pick()
  if not notes_available() then
    return
  end

  local items = {}
  for _, l in ipairs(run_tags({})) do
    local tag, count = l:match("^(.-)\t(%d+)$")
    if tag then
      items[#items + 1] = { text = tag, tag = tag, count = tonumber(count) }
    end
  end

  if #items == 0 then
    vim.notify(
      "No tags found. Add an inline #hashtag or a frontmatter 'tags:' entry to a note.",
      vim.log.levels.INFO
    )
    return
  end

  if have_snacks_picker() then
    Snacks.picker.pick({
      source = "notes_tags",
      title = "Tags",
      items = items,
      preview = "none",
      format = function(item)
        return {
          { "#" .. item.tag, "Identifier" },
          { "  (" .. item.count .. ")", "Comment" },
        }
      end,
      confirm = function(picker, item)
        picker:close()
        if item then
          -- defer so the first picker fully closes before the second opens
          vim.schedule(function()
            M.pick_hits(item.tag)
          end)
        end
      end,
    })
    return
  end

  -- Fallback: vim.ui.select
  vim.ui.select(items, {
    prompt = "Tags",
    format_item = function(item)
      return ("#%s  (%d)"):format(item.tag, item.count)
    end,
  }, function(choice)
    if choice then
      M.pick_hits(choice.tag)
    end
  end)
end

return M
