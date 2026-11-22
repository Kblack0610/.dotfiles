-- The theme: kennethblack/theme.lua, theme-switch's gitignored render (colorscheme, lualine
-- branch, NeoTreeModified). Where it has not run (a fresh clone, the phone, Windows), say so once
-- and leave each colour unset, so nvim falls back to its own defaults instead of failing to load.
local ok, theme = pcall(require, "kennethblack.theme")
if not ok then
  vim.schedule(function()
    vim.notify("kennethblack/theme.lua is missing: run theme-switch <theme> --only nvim", vim.log.levels.WARN)
  end)
  theme = {}
end
return theme
