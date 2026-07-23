-- notes.projects — a project finder for the `~/.notes` vault, wired to the
-- `notes` Rust CLI's `notes projects` subcommand. These are the same indexed
-- projects that populate the daily note's `## Current Projects` block.
--
--   :lua require("notes.projects").pick()   (bound to <leader>np by notes.setup())
--
-- Two stages (mirrors the `notes-projects` fzf window):
--   1. pick a project from `notes projects`   ("<name>\t<summary>\t<status>"),
--      previewed as its summary.md, then
--   2. pick a file inside it from              ("<path>\t<label>")
--      `notes projects <name>`, previewed in-editor, then opened.
--
-- Stage 2 remaps <Esc> (and <C-o>) to step BACK to the project list instead of
-- quitting — so the drill-down is reversible. (<Esc> on the project list still
-- closes, i.e. Esc → projects → Esc → quit.)
--
-- Built on Snacks.picker (the only picker installed) with a vim.ui.select
-- fallback, following the notes conventions: guard on `executable("notes")`,
-- shell out with vim.fn.system*, check v:shell_error, notify on failure.

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

-- Run `notes projects <args...>` and return stdout as a list of non-empty lines.
-- Notifies + returns {} on failure.
local function run_projects(args)
  local cmd = { "notes", "projects" }
  vim.list_extend(cmd, args or {})
  local out = vim.fn.systemlist(cmd)
  if vim.v.shell_error ~= 0 then
    vim.notify(
      "notes " .. table.concat({ "projects", unpack(args or {}) }, " ") .. " failed:\n"
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

-- ── Stage 2: the note files inside a single project ─────────────
function M.pick_files(name)
  local items = {}
  for _, l in ipairs(run_projects({ name })) do
    local file, label = l:match("^(.-)\t(.*)$")
    if file then
      items[#items + 1] = { file = file, text = label, label = label }
    end
  end

  if #items == 0 then
    vim.notify("No files for project " .. name, vim.log.levels.INFO)
    return
  end

  if have_snacks_picker() then
    Snacks.picker.pick({
      source = "notes_project_files",
      title = name,
      items = items,
      preview = "file",
      format = function(item)
        return {
          { item.label, "Directory" },
          { "  " .. vim.fn.fnamemodify(item.file, ":t"), "Comment" },
        }
      end,
      -- <Esc>/<C-o> step back to the project list instead of closing the finder.
      actions = {
        notes_projects_back = function(picker)
          picker:close()
          vim.schedule(function()
            M.pick()
          end)
        end,
      },
      win = {
        input = {
          keys = {
            ["<Esc>"] = { "notes_projects_back", mode = { "n", "i" } },
            ["<C-o>"] = { "notes_projects_back", mode = { "n", "i" } },
          },
        },
        list = {
          keys = {
            ["<Esc>"] = "notes_projects_back",
            ["<C-o>"] = "notes_projects_back",
          },
        },
      },
      confirm = function(picker, item)
        picker:close()
        if item then
          open_at(item.file, 1)
        end
      end,
    })
    return
  end

  -- Fallback: vim.ui.select
  vim.ui.select(items, {
    prompt = name,
    format_item = function(item)
      return ("%s  (%s)"):format(item.label, vim.fn.fnamemodify(item.file, ":t"))
    end,
  }, function(choice)
    if choice then
      open_at(choice.file, 1)
    end
  end)
end

-- ── Stage 1: the list of projects ───────────────────────────────
function M.pick()
  if not notes_available() then
    return
  end

  local items = {}
  for _, l in ipairs(run_projects({})) do
    local name, summary, status, version = l:match("^(.-)\t(.-)\t(.-)\t(.*)$")
    if name then
      items[#items + 1] =
        { text = name, name = name, file = summary, status = status, version = version }
    end
  end

  if #items == 0 then
    vim.notify(
      "No indexed projects. Add one under lab/projects/current/<name>/summary.md",
      vim.log.levels.INFO
    )
    return
  end

  if have_snacks_picker() then
    Snacks.picker.pick({
      source = "notes_projects",
      title = "Projects",
      items = items,
      -- preview the project's summary.md as you scroll
      preview = "file",
      format = function(item)
        local row = { { item.name, "Identifier" } }
        if item.version and item.version ~= "" then
          row[#row + 1] = { "  " .. item.version, "Special" }
        end
        if item.status and item.status ~= "" then
          row[#row + 1] = { "  " .. item.status, "Comment" }
        end
        return row
      end,
      confirm = function(picker, item)
        picker:close()
        if item then
          -- defer so the first picker fully closes before the second opens
          vim.schedule(function()
            M.pick_files(item.name)
          end)
        end
      end,
    })
    return
  end

  -- Fallback: vim.ui.select
  vim.ui.select(items, {
    prompt = "Projects",
    format_item = function(item)
      if item.status and item.status ~= "" then
        return ("%s  %s"):format(item.name, item.status)
      end
      return item.name
    end,
  }, function(choice)
    if choice then
      M.pick_files(choice.name)
    end
  end)
end

return M
