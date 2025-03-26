-- vim.opt.guicursor = ""
--
-- vim.opt.nu = true
-- vim.opt.relativenumber = true
--
-- vim.opt.tabstop = 4
-- vim.opt.softtabstop = 4
-- vim.opt.shiftwidth = 4
-- vim.opt.expandtab = true
--
-- vim.opt.smartindent = true
--
-- vim.opt.wrap = false
--
-- vim.opt.swapfile = false
-- vim.opt.backup = false
-- vim.opt.undodir = os.getenv("HOME") .. "/.vim/undodir"
-- vim.opt.undofile = true
--
-- vim.opt.hlsearch = false
-- vim.opt.incsearch = true
--
-- vim.opt.termguicolors = true
-- vim.opt.guifont = '0xProto Nerd Font'
-- vim.opt.scrolloff = 8
-- vim.opt.signcolumn = "yes"
-- vim.opt.isfname:append("@-@")
--
-- vim.opt.updatetime = 50
--
-- vim.opt.colorcolumn = "80"
-- vim.opt.ignorecase = true
-- vim.cmd [[let &t_ut='']]
--
-- --FOLDS
-- vim.opt.foldcolumn = "0"
-- --use expr for treesitter
-- vim.opt.foldmethod = "marker"
-- vim.opt.foldmarker = "#region,#endregion"
-- vim.opt.foldexpr = "v:lua.vim.treesitter.foldexpr()"
-- function _G.MyFoldText()
--     return vim.fn.getline(vim.v.foldstart)
-- end
--
-- vim.opt.foldtext = 'v:lua.MyFoldText()'
-- vim.opt.foldlevel = 99
-- vim.opt.foldlevelstart = 1
-- vim.opt.foldnestmax = 4
--
------- need to update
vim.opt.breakindent = true -- Wrap indent to match line start
vim.opt.clipboard = "unnamedplus" -- Connection to the system clipboard
vim.opt.cmdheight = 0 -- Hide command line unless needed
vim.opt.completeopt = { "menu", "menuone", "noselect" } -- Options for insert mode completion
vim.opt.copyindent = true -- Copy the previous indentation on autoindenting
vim.opt.cursorline = true -- Highlight the text line of the cursor
vim.opt.expandtab = true -- Enable the use of space in tab
vim.opt.fileencoding = "utf-8" -- File content encoding for the buffer
vim.opt.fillchars = { eob = " " } -- Disable `~` on nonexistent lines
vim.opt.foldenable = true -- Enable fold for nvim-ufo
vim.opt.foldlevel = 99 -- Set high foldlevel for nvim-ufo
vim.opt.foldlevelstart = 99 -- Start with all code unfolded
vim.opt.foldcolumn = "0" -- Hide foldcolumn
vim.opt.history = 100 -- Number of commands to remember in a history table
vim.opt.ignorecase = true -- Case insensitive searching
vim.opt.infercase = true -- Infer cases in keyword completion
vim.opt.laststatus = 0 -- Global statusline
vim.opt.linebreak = true -- Wrap lines at 'breakat'
vim.opt.mouse = "" -- Enable mouse support
vim.opt.number = true -- Show numberline
vim.opt.preserveindent = true -- Preserve indent structure as much as possible
vim.opt.pumheight = 10 -- Height of the pop-up menu
vim.opt.relativenumber = true -- Show relative numberline
vim.opt.shiftwidth = 2 -- Number of spaces inserted for indentation
vim.opt.showmode = false -- Disable showing modes in command line
vim.opt.showtabline = 0 -- Always display tabline
vim.opt.signcolumn = "yes" -- Always show the sign column
vim.opt.statuscolumn = "%=%{v:relnum == 0 ? v:lnum : v:relnum} %s" -- custom line number and sign column arrangement
vim.opt.smartcase = true -- Case sensitive searching
vim.opt.splitbelow = true -- Splitting a new window below the current one
vim.opt.splitright = true -- Splitting a new window at the right of the current one
vim.opt.tabstop = 2 -- Number of spaces in a tab
vim.opt.termguicolors = true -- Enable 24-bit RGB color in the TUI
vim.opt.title = true -- Set terminal title to the filename and path
vim.opt.undofile = true -- Enable persistent undo
vim.opt.updatetime = 300 -- Length of time to wait before triggering the plugin
vim.opt.virtualedit = "block" -- Allow going past end of line in visual block mode
vim.opt.wrap = false -- Disable wrapping of lines longer than the width of window
vim.opt.writebackup = false -- Disable making a backup before overwriting a file
vim.opt.scrolloff = 8 -- How many lines to keep on top/bottom of screen when scrolling

-- for external editors
-- vim.opt.autoread = true

-- rewrite this
-- autocmd FocusGained * checktim
-- vim.autocommand.FocusGained {
--   callback = function()
--     vim.cmd("checktime")
--   end,
-- }
--
-- vim.autocommand.BufReadPost {
--   pattern = "*",
--   callback = function()
--     vim.cmd("checktime")
--   end,
-- }
-- vim.opt.autowrite = true
-- vim.opt.swapfile = false
-- vim.opt.backup = false
-- vim.opt.undodir = os.getenv("HOME") .. "/.vim/undodir"
-- vim.opt.undofile = true

    -- " trigger `autoread` when files changes on disk
      -- set autoread
      -- autocmd FocusGained,BufEnter,CursorHold,CursorHoldI * if mode() != 'c' | checktime | endif
    -- " notification after file change
      -- autocmd FileChangedShellPost *
        -- \ echohl WarningMsg | echo "File changed on disk. Buffer reloaded." | echohl None
-- autocmd FocusGained * checktim
