return {
  "nvim-treesitter/nvim-treesitter",
  branch = "main",
  build = ":TSUpdate",
  lazy = false,
  config = function()
    local parsers = {
      "angular", "bash", "c_sharp", "css", "dockerfile", "go", "graphql",
      "html", "javascript", "json", "lua", "markdown", "markdown_inline",
      "proto", "regex", "scss", "sql", "toml", "tsx", "typescript", "vim",
      "vimdoc", "yaml",
    }
    require("nvim-treesitter").install(parsers)

    vim.api.nvim_create_autocmd("FileType", {
      group = vim.api.nvim_create_augroup("TSHighlight", { clear = true }),
      callback = function(args)
        local lang = vim.treesitter.language.get_lang(vim.bo[args.buf].filetype)
        if lang and pcall(vim.treesitter.start, args.buf, lang) then
          vim.bo[args.buf].indentexpr = "v:lua.require'nvim-treesitter'.indentexpr()"
        end
      end,
    })
  end,
}
