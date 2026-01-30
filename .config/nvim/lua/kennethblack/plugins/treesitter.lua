return {
  "nvim-treesitter/nvim-treesitter",
  build = ":TSUpdate",
  config = function()
    local configs = require("nvim-treesitter.configs")
    configs.setup({
       -- ensure_installed = {"tsx", "graphql", "javascript", "typescript", "c_sharp", "lua", "vim", "python", "html"},
       ensure_installed = {
        "c_sharp",
        "lua",
        "javascript",
        "typescript",
        "json",
        "yaml",
        "dockerfile",
        "bash",
        "html",
        "css",
        "scss",
        "sql",
        "go",
        "markdown",
        "graphql",
        "proto",
        "angular",
        "toml",
        "tsx"
      },
      ignore_install = {},
      auto_install = false,
      sync_install = false,
      highlight = { enable = true },
      indent = { enable = true },
    })
  end,
}

