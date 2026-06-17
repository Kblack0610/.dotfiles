-- BrightScript / BrighterScript: syntax highlighting + LSP (brighterscript `bsc`).
-- Remote plugin. `dev = true` uses ~/dev/brighterscript.nvim when that checkout exists
-- (live development); otherwise lazy clones the published repo (dev.fallback in init.lua).
return {
  {
    "Kblack0610/brighterscript.nvim",
    dev = true,
    ft = "brightscript",
    init = function()
      -- ensure .bs also resolves to the brightscript filetype before the ft-load fires
      vim.filetype.add({ extension = { bs = "brightscript" } })
    end,
    opts = {},
  },
}
