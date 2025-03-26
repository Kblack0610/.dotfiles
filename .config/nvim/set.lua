-- Trigger autoread when files change on disk
vim.opt.autoread = true

-- Create an autocommand group for file change detection
local augroup = vim.api.nvim_create_augroup("AutoReloadGroup", { clear = true })

-- Check for file changes when gaining focus, entering buffer, or after idle time
vim.api.nvim_create_autocmd({"FocusGained", "BufEnter", "CursorHold", "CursorHoldI"}, {
  group = augroup,
  callback = function()
    if vim.fn.mode() ~= "c" then
      vim.cmd("checktime")
    end
  end,
  desc = "Check for file changes when returning to Neovim or after idle"
})

-- Display notification after file changes
vim.api.nvim_create_autocmd("FileChangedShellPost", {
  group = augroup,
  callback = function()
    vim.api.nvim_echo({{
      "File changed on disk. Buffer reloaded.",
      "WarningMsg"
    }}, true, {})
  end,
  desc = "Show notification when file is changed outside Neovim"
})
