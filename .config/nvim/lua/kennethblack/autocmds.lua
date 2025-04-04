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
