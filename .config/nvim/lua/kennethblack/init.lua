-- Set up lazy.nvim
local lazypath = vim.fn.stdpath "data" .. "/lazy/lazy.nvim"
if not vim.loop.fs_stat(lazypath) then
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
require("lazy").setup "kennethblack.plugins"

-- colorscheme
vim.cmd.colorscheme "tokyonight"

-- line number color custom
-- vim.cmd [[
--   highlight CursorLineNr guifg=#c0c4d8 gui=bold
-- ]]
--
-- do later
-- 
-- -- Load plugins, lazy will do this automagically if string is in lua/{your dir here}. I use 'plugins'
-- require("lazy").setup({"kennethblack.plugins", "kennethblack.local_plugins" }, 
--   {
--   -- Lazy Configuration Options
--   dev = {
--     -- path = "~/projects", -- 1. CHANGE THIS to where you keep your local repos
--     
--     -- 2. AUTOMATION: 
--     -- If is_dev_mode is true, any plugin string matching these 
--     -- patterns will automatically switch to local source.
--     patterns = is_dev_mode and { "plugins", "local_plugins" } or {},
--     
--     fallback = true, -- If local copy is missing, download from GitHub anyway
--   },
-- })
