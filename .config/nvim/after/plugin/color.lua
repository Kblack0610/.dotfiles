function ColorMyPencils(color)
	color = color or "tokyonight"
    --color = color or "rose-pine"

	vim.cmd.colorscheme(color)
 
	vim.api.nvim_set_hl(0, "Normal", {bg="none"})
	vim.api.nvim_set_hl(0, "NormalFloat", {bg="none"})

    --need to figure out what's wrong with this for transparency, it's working well enough now though
    --vim.cmd('set t_Co=256')
    --vim.cmd('syntax on')
    --vim.cmd('filetype plugin indent on')
    --vim.cmd('colorscheme rose-pine')
    --vim.cmd('highlight nonText ctermbg=NONE')
    --vim.cmd('highlight Normal ctermbg=NONE')
end

ColorMyPencils()
