-- notes.find - ranked knowledge lookup over the `~/.notes` vault, wired to the `notes`
-- Rust CLI's `notes find` subcommand.
--
--   :lua require("notes.find").pick()   (bound to <leader>nk by notes.setup())
--
-- A live picker: every keystroke re-runs `notes find -- <query>`, which ranks notes across
-- knowledge/, zettels, refs, employment/ and lab/ (words in any order, typos and half-typed
-- words still match, `#tag` filters, `"a phrase"` boosts, `-word` excludes). The CLI owns
-- the ranking, so items keep its order; Enter opens the note at its best matching line.
--
-- Built on Snacks.picker with a vim.ui.input + vim.ui.select fallback, following the
-- notes conventions (see tags.lua): guard on `executable("notes")`, check v:shell_error.

local M = {}

-- How many hits the picker asks for. The CLI prints best first, so this is a page.
M.limit = 50

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

-- One `notes find` output line -> a picker item, or nil.
-- Shape: path<TAB>line<TAB>score<TAB>title<TAB>snippet
function M.parse(line)
  local file, lnum, score, title, snippet = line:match("^(.-)\t(%d+)\t([%d%.]+)\t(.-)\t(.*)$")
  if not file then
    return nil
  end
  return {
    file = file,
    pos = { tonumber(lnum), 0 },
    score_cli = tonumber(score),
    title = title,
    snippet = snippet,
    text = title .. " " .. snippet,
  }
end

function M.args(query)
  return { "find", "-n", tostring(M.limit), "--", query }
end

local function open_at(file, line)
  vim.cmd("edit " .. vim.fn.fnameescape(file))
  pcall(vim.api.nvim_win_set_cursor, 0, { tonumber(line) or 1, 0 })
end

local function have_snacks_picker()
  return _G.Snacks ~= nil and Snacks.picker ~= nil and type(Snacks.picker.pick) == "function"
end

local function format(item)
  local where = vim.fn.fnamemodify(item.file, ":~:.")
  where = where:gsub("^~/%.notes/", "")
  return {
    { item.title, "Title" },
    { "  " .. where .. ":" .. item.pos[1], "Comment" },
    { "  " .. item.snippet, "Normal" },
  }
end

local function fallback()
  vim.ui.input({ prompt = "Find knowledge: " }, function(query)
    if not query or query == "" then
      return
    end
    local items = {}
    local cmd = { "notes" }
    vim.list_extend(cmd, M.args(query))
    for _, l in ipairs(vim.fn.systemlist(cmd)) do
      items[#items + 1] = M.parse(l)
    end
    if vim.v.shell_error ~= 0 or #items == 0 then
      vim.notify("No notes match '" .. query .. "'. Try fewer words or a #tag.", vim.log.levels.INFO)
      return
    end
    vim.ui.select(items, {
      prompt = query,
      format_item = function(item)
        return ("%s  %s:%d"):format(item.title, vim.fn.fnamemodify(item.file, ":t"), item.pos[1])
      end,
    }, function(choice)
      if choice then
        open_at(choice.file, choice.pos[1])
      end
    end)
  end)
end

function M.pick(opts)
  if not notes_available() then
    return
  end
  if not have_snacks_picker() then
    return fallback()
  end
  Snacks.picker.pick(vim.tbl_deep_extend("force", {
    source = "notes_find",
    title = "Find knowledge (words, #tag, \"phrase\", -word)",
    live = true,
    supports_live = true,
    preview = "file",
    format = format,
    -- Keep the CLI's ranking: no re-sort by the fuzzy matcher.
    sort = { fields = { "idx" } },
    matcher = { sort_empty = false },
    finder = function(_, ctx)
      local query = ctx.filter.search
      if query == "" then
        return function() end
      end
      return require("snacks.picker.source.proc").proc(
        ctx:opts({
          notify = false,
          cmd = "notes",
          args = M.args(query),
          transform = function(item)
            local parsed = M.parse(item.text)
            if not parsed then
              return false
            end
            for k, v in pairs(parsed) do
              item[k] = v
            end
          end,
        }),
        ctx
      )
    end,
    confirm = function(picker, item)
      picker:close()
      if item then
        open_at(item.file, item.pos[1])
      end
    end,
  }, opts or {}))
end

return M
