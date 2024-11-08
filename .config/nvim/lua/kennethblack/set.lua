vim.opt.guicursor = ""

vim.opt.nu = true
vim.opt.relativenumber = true

vim.opt.tabstop = 4
vim.opt.softtabstop = 4
vim.opt.shiftwidth = 4
vim.opt.expandtab = true

vim.opt.smartindent = true

vim.opt.wrap = false

vim.opt.swapfile = false
vim.opt.backup = false
vim.opt.undodir = os.getenv("HOME") .. "/.vim/undodir"
vim.opt.undofile = true

vim.opt.hlsearch = false
vim.opt.incsearch = true

vim.opt.termguicolors = true
vim.opt.guifont = '0xProto Nerd Font'
vim.opt.scrolloff = 8
vim.opt.signcolumn = "yes"
vim.opt.isfname:append("@-@")

vim.opt.updatetime = 50

vim.opt.colorcolumn = "80"
vim.opt.ignorecase = true
vim.cmd [[let &t_ut='']]

--FOLDS
vim.opt.foldcolumn = "0"
--use expr for treesitter
vim.opt.foldmethod = "marker"
vim.opt.foldmarker = "#region,#endregion"
vim.opt.foldexpr = "v:lua.vim.treesitter.foldexpr()"
function _G.MyFoldText()
    return vim.fn.getline(vim.v.foldstart)
end

vim.opt.foldtext = 'v:lua.MyFoldText()'
vim.opt.foldlevel = 99
vim.opt.foldlevelstart = 1
vim.opt.foldnestmax = 4
