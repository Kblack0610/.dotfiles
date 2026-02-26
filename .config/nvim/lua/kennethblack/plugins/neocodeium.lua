return {
  "monkoose/neocodeium",
  event = "VeryLazy",
  config = function()
    local neocodeium = require("neocodeium")
    neocodeium.setup({
      filetypes = {
        markdown = false,
      },
    })
    vim.keymap.set("i", "<C-l>", neocodeium.accept)
  end,
}
