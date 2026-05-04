local augroup = vim.api.nvim_create_augroup
local autocmd = vim.api.nvim_create_autocmd

-- Open neotree when running nvim . or opening dir
autocmd("BufEnter", {
  desc = "Open Neo-Tree on startup with directory",
  group = augroup("neotree_start", { clear = true }),
  callback = function()
    if package.loaded["neo-tree"] then
      vim.api.nvim_del_augroup_by_name "neotree_start"
    else
      local stats = vim.uv.fs_stat(vim.api.nvim_buf_get_name(0))
      if stats and stats.type == "directory" then
        vim.api.nvim_del_augroup_by_name "neotree_start"
        require "neo-tree"
      end
    end
  end,
})

autocmd("TermClose", {
  pattern = "*lazygit*",
  desc = "Refresh Neo-Tree when closing lazygit",
  group = augroup("neotree_refresh", { clear = true }),
  callback = function()
    local manager_avail, manager = pcall(require, "neo-tree.sources.manager")
    if manager_avail then
      for _, source in ipairs { "filesystem", "git_status", "document_symbols" } do
        local module = "neo-tree.sources." .. source
        if package.loaded[module] then manager.refresh(require(module).name) end
      end
    end
  end,
})

-- Make sure any changes are reflected
autocmd({ "FocusGained", "TermClose", "TermLeave" }, {
  desc = "Check if buffers changed on editor focus",
  group = augroup("checktime", { clear = true }),
  command = "checktime",
})

autocmd("BufWinEnter", {
  desc = "Make q close help, man, quickfix, dap floats",
  group = augroup("q_close_windows", { clear = true }),
  callback = function(args)
    local buftype = vim.api.nvim_get_option_value("buftype", { buf = args.buf })
    if vim.tbl_contains({ "help", "nofile", "quickfix" }, buftype) and vim.fn.maparg("q", "n") == "" then
      vim.keymap.set("n", "q", "<cmd>close<cr>", {
        desc = "Close window",
        buffer = args.buf,
        silent = true,
        nowait = true,
      })
    end
  end,
})

-- IMPORTANT: Soft wrap for human-readable filetypes
autocmd("FileType", {
  desc = "Enable soft wrap for prose filetypes",
  group = augroup("prose_wrap", { clear = true }),
  pattern = { "markdown", "text", "gitcommit", "html", "latex", "tex", "rst", "asciidoc", "json", "jsonc" },
  callback = function()
    vim.opt_local.wrap = true
    vim.opt_local.spell = true
  end,
})

-- Quick highlight visual on yank
autocmd("TextYankPost", {
  desc = "Highlight yanked text",
  group = augroup("highlightyank", { clear = true }),
  pattern = "*",
  callback = function() vim.highlight.on_yank() end,
})

local statuscolumn_group = augroup("disablestatusline", { clear = true })
-- Autocommand to disable statuscolumn in specific filetypes
autocmd("FileType", {
  desc = "Hide statusline",
  group = statuscolumn_group,
  pattern = { "help", "man", "qf", "lazy", "aerial", "dapui_.", "NvimTree" },
  callback = function() vim.opt_local.statuscolumn = "" end,
})

-- Alternative method for Neo-tree windows since above didnt work for neotree
autocmd("BufEnter", {
  desc = "Hide statusline",
  group = statuscolumn_group,
  callback = function()
    local types = { "neo-tree" }
    for _, type in ipairs(types) do
      if vim.bo.filetype == type then vim.opt_local.statuscolumn = "" end
    end
  end,
})

-- ============================================
-- Daily Journal Harpoon Integration
-- Pins today's daily note when in ~/.notes
-- Creates journal with template and carry-over section
-- ============================================
local journal_harpoon_group = augroup("journal_harpoon", { clear = true })

local function is_in_notes_dir()
  local cwd = vim.fn.getcwd()
  local notes_dir = vim.fn.expand("~/.notes")
  return cwd:find(notes_dir, 1, true) == 1
end

local function get_journal_path(date_str)
  return vim.fn.expand("~/.notes/journal/daily/" .. date_str .. ".md")
end

local function get_today_journal()
  return get_journal_path(os.date("%Y-%m-%d"))
end

local function get_today_refs_dir()
  return vim.fn.expand("~/.notes/journal/refs/" .. os.date("%Y-%m-%d"))
end

local function file_exists(path)
  local stat = vim.uv.fs_stat(path)
  return stat ~= nil
end

local function read_file(path)
  local file = io.open(path, "r")
  if not file then return nil end
  local content = file:read("*all")
  file:close()
  return content
end

local function write_file(path, content)
  local file = io.open(path, "w")
  if not file then return false end
  file:write(content)
  file:close()
  return true
end

local function create_daily_journal()
  local journal_path = get_today_journal()
  if file_exists(journal_path) then return end
  vim.fn.system("journal-create")
end

local function ensure_today_refs_dir()
  local refs_dir = get_today_refs_dir()
  if file_exists(refs_dir) then return end
  vim.fn.mkdir(refs_dir, "p")
end

local function get_today_refs_anchor()
  return get_today_refs_dir() .. "/_index.md"
end

local function ensure_today_refs_anchor()
  ensure_today_refs_dir()

  local anchor = get_today_refs_anchor()
  if file_exists(anchor) then return anchor end

  local lines = {
    "---",
    "id: \"" .. os.date("%Y-%m-%d") .. "-refs\"",
    "tags: [refs]",
    "---",
    "",
    "# Refs " .. os.date("%Y-%m-%d"),
    "",
  }

  write_file(anchor, table.concat(lines, "\n"))
  return anchor
end

local function sync_notes_harpoon_slots()
  if not is_in_notes_dir() then return end

  vim.defer_fn(function()
    create_daily_journal()
    ensure_today_refs_dir()

    local ok, harpoon = pcall(require, "harpoon")
    if not ok then return end

    local journal_path = get_today_journal()
    local list = harpoon:list()
    local items = list.items
    for i = #items, 1, -1 do
      local value = items[i].value
      if value == journal_path then
        table.remove(items, i)
      end
    end

    table.insert(items, 1, { value = journal_path, context = {} })
  end, 100)
end

autocmd("DirChanged", {
  desc = "Sync notes harpoon slots in notes directory",
  group = journal_harpoon_group,
  callback = sync_notes_harpoon_slots,
})

autocmd("VimEnter", {
  desc = "Sync notes harpoon slots if starting in notes",
  group = journal_harpoon_group,
  callback = sync_notes_harpoon_slots,
})

function _G.open_today_refs_in_neotree()
  local anchor = ensure_today_refs_anchor()
  vim.api.nvim_command(
    "Neotree show current reveal_force_cwd reveal_file=" .. vim.fn.fnameescape(anchor)
  )
end

local function get_projects_dir()
  return vim.fn.expand("~/.notes/dev/projects")
end

local function get_projects_anchor()
  return get_projects_dir() .. "/_index.md"
end

local function ensure_projects_anchor()
  local projects_dir = get_projects_dir()
  if not file_exists(projects_dir) then
    vim.fn.mkdir(projects_dir, "p")
  end

  local anchor = get_projects_anchor()
  if file_exists(anchor) then return anchor end

  local lines = {
    "---",
    "id: \"dev-projects\"",
    "tags: [projects]",
    "---",
    "",
    "# Projects",
    "",
  }

  write_file(anchor, table.concat(lines, "\n"))
  return anchor
end

function _G.open_dev_projects_in_neotree()
  local anchor = ensure_projects_anchor()
  vim.api.nvim_command(
    "Neotree show current reveal_force_cwd reveal_file=" .. vim.fn.fnameescape(anchor)
  )
end

-- ============================================
-- Link current buffer to daily note
-- Adds a [[wiki link]] to today's journal and jumps there
-- ============================================
local function link_to_daily()
  local current_file = vim.fn.expand("%:p")
  local notes_dir = vim.fn.expand("~/.notes")

  -- Create relative link if in notes dir, otherwise use filename
  local link_text
  if current_file:find(notes_dir, 1, true) then
    link_text = current_file:sub(#notes_dir + 2):gsub("%.md$", "")
  else
    link_text = vim.fn.expand("%:t:r") -- filename without extension
  end

  -- Ensure journal exists
  create_daily_journal()

  local journal_path = get_today_journal()
  local content = read_file(journal_path) or ""

  -- Append link under ## Notes section
  local link_line = "- [[" .. link_text .. "]]"
  local new_content = content:gsub("(## Notes\n)", "%1" .. link_line .. "\n")

  write_file(journal_path, new_content)

  -- Jump to daily via harpoon slot 1
  local ok, harpoon = pcall(require, "harpoon")
  if ok then
    harpoon:list():select(1)
  else
    vim.cmd("edit " .. journal_path)
  end

  vim.notify("Linked: " .. link_text, vim.log.levels.INFO)
end

vim.keymap.set("n", "<leader>nl", link_to_daily, { desc = "Link to daily note" })
