-- Set up lazy.nvim
local lazypath = vim.fn.stdpath "data" .. "/lazy/lazy.nvim"
if not vim.uv.fs_stat(lazypath) then
  vim.fn.system {
    "git",
    "clone",
    "--filter=blob:none",
    "https://github.com/folke/lazy.nvim.git",
    "--branch=stable", -- latest stable release
    lazypath,
  }
end
vim.opt.rtp:prepend(lazypath)

-- Load other lua files
require "kennethblack.set"
require "kennethblack.map"
require "kennethblack.autocmds"

-- Load plugins, lazy will do this automagically if string is in lua/{your dir here}. I use 'plugins'
require("lazy").setup("kennethblack.plugins", {
  ui = {
    size = { width = 0.9, height = 0.9 },  -- larger window for errors
    wrap = true,  -- wrap long lines so nothing is cut off
    border = "rounded",
  },
})

-- colorscheme
vim.cmd.colorscheme "tokyonight"
