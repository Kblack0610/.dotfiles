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
-- require'nvim-treesitter.configs'.setup {
--   -- A list of parser names, or "all" (the four listed parsers should always be installed)
--   ensure_installed = {"tsx", "graphql", "javascript", "typescript", "c_sharp", "lua", "vim", "python", "html"},
--
--   -- Install parsers synchronously (only applied to `ensure_installed`)
--   sync_install = false,
--
--   -- Automatically install missing parsers when entering buffer
--   -- Recommendation: set to false if you don't have `tree-sitter` CLI installed locally
--   auto_install = true,
--
--   highlight = {
--     enable = true,
--
--     -- Setting this to true will run `:h syntax` and tree-sitter at the same time.
--     -- Set this to `true` if you depend on 'syntax' being enabled (like for indentation).
--     -- Using this option may slow down your editor, and you may see some duplicate highlights.
--     -- Instead of true it can also be a list of languages
--     additional_vim_regex_highlighting = false,
--   },
--
--  --  context_commentstring = {
--  --    enable = true,
--  --    config = {
--  --       javascript = {
--  --          __default = '// %s',
--  --          jsx_element = '{/* %s */}',
--  --          jsx_fragment = '{/* %s */}',
--  --          jsx_attribute = '// %s',
--  --          comment = '// %s',
--  --       },
--  --       typescript = { __default = '// %s', __multiline = '/* %s */' },
--  --   },
--  -- }
-- }
--
-- require('ts_context_commentstring').setup{ }
--
-- vim.g.skip_ts_context_commentstring_module = true

