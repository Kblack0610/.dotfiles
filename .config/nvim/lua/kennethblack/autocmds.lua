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

-- Kill OmniSharp server when leaving C# files or exiting Neovim
local omnisharp_group = augroup("omnisharp_autoclose", { clear = true })

-- Function to check if there are any C# buffers open
local function has_csharp_buffers()
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_buf_is_loaded(buf) then
      local ft = vim.api.nvim_buf_get_option(buf, "filetype")
      if ft == "cs" then
        return true
      end
    end
  end
  return false
end

-- Function to kill OmniSharp server process
local function kill_omnisharp()
  vim.fn.system("pkill -f 'omnisharp-roslyn'")
  print("OmniSharp server terminated")
end

-- Check when leaving a C# buffer if we should kill the server
autocmd("BufLeave", {
  desc = "Check if we should kill OmniSharp server when leaving C# buffer",
  group = omnisharp_group,
  pattern = "*.cs",
  callback = function()
    -- Schedule the check to run after leaving the buffer
    vim.defer_fn(function()
      if not has_csharp_buffers() then
        kill_omnisharp()
      end
    end, 100)
  end,
})

-- Kill OmniSharp when exiting Neovim
autocmd("VimLeave", {
  desc = "Kill OmniSharp server when exiting Neovim",
  group = omnisharp_group,
  callback = kill_omnisharp,
})

-- ============================================
-- Daily Journal Harpoon Integration
-- Pins today's daily note and refs folder when in ~/.notes
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

local function get_projects_dir()
  return vim.fn.expand("~/.notes/dev/projects")
end

local function get_most_recent_journal()
  local daily_dir = vim.fn.expand("~/.notes/journal/daily/")
  local today = os.date("%Y-%m-%d")
  local files = vim.fn.glob(daily_dir .. "*.md", false, true)
  table.sort(files)
  -- Find most recent that isn't today
  for i = #files, 1, -1 do
    if not files[i]:find(today, 1, true) then
      return files[i]
    end
  end
  return nil
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

local function extract_carryover(content)
  if not content then return {} end
  local lines = {}
  local in_carryover = false
  for line in content:gmatch("[^\n]*") do
    if line:match("^## Carry Over") then
      in_carryover = true
    elseif in_carryover and line:match("^## ") then
      break
    elseif in_carryover and line ~= "" then
      table.insert(lines, line)
    end
  end
  return lines
end

local function create_daily_journal()
  local today = os.date("%Y-%m-%d")
  local journal_path = get_today_journal()

  -- Don't recreate if exists
  if file_exists(journal_path) then return end

  -- Get carry over content from most recent previous note
  local prev_journal = get_most_recent_journal()
  local prev_content = prev_journal and read_file(prev_journal) or nil
  local carryover = extract_carryover(prev_content)

  -- Build clean template
  local lines = {
    "---",
    "date: " .. today,
    "tags: [daily]",
    "---",
    "",
    "# " .. today,
    "",
    "## Focus",
    "- [ ] ",
    "",
    "## Notes",
    "",
    "## Carry Over",
  }

  -- Add yesterday's carry over items
  if #carryover > 0 then
    for _, line in ipairs(carryover) do
      table.insert(lines, line)
    end
  end
  table.insert(lines, "")

  write_file(journal_path, table.concat(lines, "\n"))
end

local function ensure_today_refs_dir()
  local refs_dir = get_today_refs_dir()
  if file_exists(refs_dir) then return end
  vim.fn.mkdir(refs_dir, "p")
end

local function is_daily_journal(path)
  return path:match("/%.notes/journal/daily/%d%d%d%d%-%d%d%-%d%d%.md$") ~= nil
end

local function sync_notes_harpoon_slots()
  if not is_in_notes_dir() then return end

  vim.defer_fn(function()
    create_daily_journal()
    ensure_today_refs_dir()

    local ok, harpoon = pcall(require, "harpoon")
    if not ok then return end

    local journal_path = get_today_journal()
    local refs_dir = get_today_refs_dir()
    local projects_dir = get_projects_dir()
    local list = harpoon:list()
    local items = list.items
    for i = #items, 1, -1 do
      local value = items[i].value
      if value == journal_path or value == refs_dir or value == projects_dir or is_daily_journal(value) then
        table.remove(items, i)
      end
    end

    table.insert(items, 1, { value = journal_path })
    table.insert(items, 2, { value = refs_dir })
    table.insert(items, 3, { value = projects_dir })
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
