-- BrightScript / BrighterScript: syntax highlighting + LSP (brighterscript `bsc`).
-- Local dir during development; switch to "kblack0610/brighterscript.nvim" after publish.
return {
  {
    dir = vim.fn.expand("~/dev/brighterscript.nvim"),
    name = "brighterscript.nvim",
    ft = "brightscript",
    init = function()
      -- ensure .bs also resolves to the brightscript filetype before the ft-load fires
      vim.filetype.add({ extension = { bs = "brightscript" } })
    end,
    opts = {},
  },
}
