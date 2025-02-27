require("kennethblack.remap")
require("kennethblack.set")
require("kennethblack.lazy_init")

-- colorscheme
vim.cmd.colorscheme "gruvbox"

-- line number color custom
vim.cmd [[
  highlight CursorLineNr guifg=#c0c4d8 gui=bold
]]

