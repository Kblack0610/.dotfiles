local function find_upward(filenames, bufnr)
  local dir = vim.fs.dirname(vim.api.nvim_buf_get_name(bufnr or 0))
  if dir == "" or dir == nil then dir = vim.fn.getcwd() end
  return vim.fs.find(filenames, { upward = true, path = dir })[1]
end

local function js_formatter(bufnr)
  if find_upward({ ".oxfmtrc.json", "oxfmt.json", "node_modules/.bin/oxfmt" }, bufnr) then
    return { "oxfmt" }
  end
  if find_upward({
    ".prettierrc", ".prettierrc.json", ".prettierrc.js", ".prettierrc.cjs",
    ".prettierrc.mjs", ".prettierrc.yaml", ".prettierrc.yml", ".prettierrc.toml",
    "prettier.config.js", "prettier.config.cjs", "prettier.config.mjs",
  }, bufnr) then
    return { "prettierd" }
  end
  if find_upward({ "biome.json", "biome.jsonc" }, bufnr) then
    return { "biome" }
  end
  if find_upward({
    ".eslintrc", ".eslintrc.json", ".eslintrc.js", ".eslintrc.cjs",
    ".eslintrc.yml", ".eslintrc.yaml",
    "eslint.config.js", "eslint.config.cjs", "eslint.config.mjs", "eslint.config.ts",
  }, bufnr) then
    return { "eslint_d" }
  end
  return {}
end

return {
  "stevearc/conform.nvim",
  event = { "BufWritePre" },
  cmd = { "ConformInfo" },
  keys = {
    {
      "<leader>lf",
      function() require("conform").format({ async = true, lsp_fallback = true }) end,
      mode = "",
      desc = "Format buffer",
    },
  },
  ---@module "conform"
  ---@type conform.setupOpts
  opts = {
    formatters_by_ft = {
      javascript = js_formatter,
      typescript = js_formatter,
      javascriptreact = js_formatter,
      typescriptreact = js_formatter,
      json = { "prettierd" },
      jsonc = { "prettierd" },
      svelte = { "prettierd" },
      css = { "prettierd" },
      scss = { "prettierd" },
      html = { "prettierd" },
      yaml = { "prettierd" },
      markdown = { "prettierd" },
      graphql = { "prettierd" },
      lua = { "stylua" },
      python = { "isort", "black" },
      go = { "gofmt" },
      cs = { "csharpier" },
    },
    formatters = {
      oxfmt = {
        command = function(_, ctx)
          local local_bin = vim.fs.find("node_modules/.bin/oxfmt", {
            upward = true,
            path = ctx.dirname,
            type = "file",
          })[1]
          return local_bin or "oxfmt"
        end,
        args = { "--stdin-filepath", "$FILENAME" },
        stdin = true,
      },
    },
    default_format_opts = {
      lsp_format = "fallback",
    },
  },
}
