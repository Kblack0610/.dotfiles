local ensure_installed = {
  "lua_ls",
  "ts_ls",
  "jsonls",
  "bashls",
  "html",
  "cssls",
  "sqlls",
  "yamlls",
  "pyright",
  "emmet_language_server",
  "omnisharp",
}

return {
  {
    "williamboman/mason.nvim",
    opts = {},
  },
  {
    "williamboman/mason-lspconfig.nvim",
    dependencies = { "williamboman/mason.nvim" },
    opts = {
      ensure_installed = ensure_installed,
      automatic_enable = {
        exclude = { "omnisharp" }, -- handled lazily on cs filetype
      },
    },
  },
  {
    "neovim/nvim-lspconfig",
    dependencies = { "saghen/blink.cmp", "williamboman/mason-lspconfig.nvim" },
    config = function()
      vim.env.PATH = vim.fn.stdpath("data") .. "/mason/bin:" .. vim.env.PATH

      vim.o.winborder = "rounded"
      vim.diagnostic.config({ float = { border = "rounded" } })

      vim.lsp.config("*", {
        capabilities = require("blink.cmp").get_lsp_capabilities(),
      })

      vim.lsp.config("ts_ls", {
        on_attach = function(client)
          client.server_capabilities.documentFormattingProvider = false
          client.server_capabilities.documentRangeFormattingProvider = false
        end,
      })

      vim.lsp.config("emmet_language_server", {
        filetypes = { "html", "css", "scss", "javascriptreact", "typescriptreact", "javascript" },
      })

      vim.lsp.config("eslint", { settings = { format = false } })
      vim.lsp.config("biome", {})

      -- omnisharp for Unity/C# - install via setup-unity-omnisharp.sh
      vim.api.nvim_create_autocmd("FileType", {
        pattern = { "cs" },
        once = true,
        callback = function()
          vim.lsp.config("omnisharp", {
            cmd = { "/opt/omnisharp-roslyn/run", "--languageserver", "--hostPID", tostring(vim.fn.getpid()) },
            root_dir = function(bufnr, on_dir)
              local sln = vim.fs.root(bufnr, function(name) return name:match("%.sln$") end)
              local csproj = vim.fs.root(bufnr, function(name) return name:match("%.csproj$") end)
              on_dir(sln or csproj)
            end,
            use_mono = true,
            handlers = {
              ["textDocument/definition"] = require("omnisharp_extended").handler,
            },
            settings = {
              FormattingOptions = {
                EnableEditorConfigSupport = true,
                OrganizeImports = true,
              },
              MsBuild = { LoadProjectsOnDemand = true },
              RoslynExtensionsOptions = {
                EnableAnalyzersSupport = false,
                EnableImportCompletion = true,
                AnalyzeOpenDocumentsOnly = true,
                EnableDecompilationSupport = true,
              },
              Sdk = { IncludePrereleases = false },
              omnisharp = {
                useModernNet = false, -- Unity requires Mono
                analyzeOpenDocumentsOnly = true,
                enableMsBuildLoadProjectsOnDemand = true,
                projectLoadTimeout = 120,
              },
            },
          })
          vim.lsp.enable("omnisharp")
        end,
      })

      vim.api.nvim_create_autocmd("LspAttach", {
        group = vim.api.nvim_create_augroup("LspKeybindings", { clear = true }),
        callback = function(event)
          local opts = { buffer = event.buf }
          vim.keymap.set("n", "K", vim.lsp.buf.hover, opts)
          vim.keymap.set("n", "<leader>lR", vim.lsp.buf.rename, opts)
          vim.keymap.set("n", "<leader>lh", vim.lsp.buf.signature_help, opts)
          vim.keymap.set("n", "gK", vim.lsp.buf.signature_help, opts)
          vim.keymap.set({ "n", "v" }, "<leader>la", vim.lsp.buf.code_action, opts)
        end,
      })
    end,
  },
}
