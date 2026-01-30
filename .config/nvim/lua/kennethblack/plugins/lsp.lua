local ensure_installed = {
  "lua_ls",
  "ts_ls",
  "jsonls",
  "bashls",
  "html",
  "cssls",
  "sqlls",
  -- "gopls",
  "yamlls",
  "pyright",
  "emmet_language_server",
  --csharp
  -- "csharpier",
  "omnisharp",
  --ruby
  -- "ruby_lsp",
  -- "rubocop",
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
    },
  },
  {
    "neovim/nvim-lspconfig",
    dependencies = { "saghen/blink.cmp", "williamboman/mason-lspconfig.nvim" },
    config = function()
      -- Get capabilities from blink.cmp
      local capabilities = require("blink.cmp").get_lsp_capabilities()

      -- Set border for shift+k
      -- also ignore "no information found" when multiple lsps attached and trying hover
      vim.lsp.handlers["textDocument/hover"] = function(_, result, ctx, config)
        if not (result and result.contents and result.contents.value ~= "") then
          return -- Suppress "no information available" notifications
        end
        -- merge config table if it exists
        return vim.lsp.handlers.hover(_, result, ctx, vim.tbl_extend("force", config or {}, { border = "rounded" }))
      end
      -- Set border for signature help <leader>lh
      vim.lsp.handlers["textDocument/signatureHelp"] = vim.lsp.with(vim.lsp.handlers.signature_help, {
        border = "rounded",
      })

      -- Border setup for omnisharp
      local rounded_border_handlers = {
        ["textDocument/hover"] = vim.lsp.with(vim.lsp.handlers.hover, { border = "rounded" }),
        ["textDocument/signatureHelp"] = vim.lsp.with(vim.lsp.handlers.signature_help, { border = "rounded" }),
      }

      local pid = vim.fn.getpid()
      local omnisharp_bin = "/opt/omnisharp-roslyn/run"

      -- Use mason-lspconfig's automatic setup (modern pattern)
      require("mason-lspconfig").setup_handlers({
        -- Default handler for all servers
        function(server_name)
          require("lspconfig")[server_name].setup({
            capabilities = capabilities,
          })
        end,

        -- Custom handler for ts_ls
        ["ts_ls"] = function()
          require("lspconfig").ts_ls.setup({
            capabilities = capabilities,
            on_attach = function(client, _)
              -- Disable formatting capability for tsserver
              -- This conflicts with other formatters
              client.server_capabilities.documentFormattingProvider = false
              client.server_capabilities.documentRangeFormattingProvider = false
            end,
          })
        end,

        -- Custom handler for emmet_language_server
        ["emmet_language_server"] = function()
          require("lspconfig").emmet_language_server.setup({
            capabilities = capabilities,
            filetypes = { "html", "css", "scss", "javascriptreact", "typescriptreact", "javascript" },
          })
        end,

        -- Custom handler for omnisharp
        ["omnisharp"] = function()
          -- Unity-compatible OmniSharp setup
          -- Requires: OmniSharp v1.39.6 (installed via setup-unity-omnisharp.sh)
          -- Run: ~/.dotfiles/.local/src/installation_scripts/setup-unity-omnisharp.sh
          require("lspconfig").omnisharp.setup({
            capabilities = capabilities,
            root_dir = function(fname)
              local util = require("lspconfig.util")
              -- Prefer .sln files, fallback to .csproj
              local primary = util.root_pattern("*.sln")(fname)
              local fallback = util.root_pattern("*.csproj")(fname)
              return primary or fallback
            end,
            -- Use Mono for Unity (NOT modern .NET)
            use_mono = true,
            flags = {
              debounce_text_changes = 150,
            },
            cmd = { omnisharp_bin, "--languageserver", "--hostPID", tostring(pid) },
            handlers = vim.tbl_extend("force", rounded_border_handlers, {
              ["textDocument/definition"] = require("omnisharp_extended").handler,
            }),
            settings = {
              FormattingOptions = {
                EnableEditorConfigSupport = true,
                OrganizeImports = true,
              },
              MsBuild = {
                -- Load projects on demand for faster startup
                LoadProjectsOnDemand = true,
              },
              RoslynExtensionsOptions = {
                -- Disable heavy analyzers for better performance with Unity
                EnableAnalyzersSupport = false,
                EnableImportCompletion = true,
                AnalyzeOpenDocumentsOnly = true,
                EnableDecompilationSupport = true,
              },
              Sdk = {
                IncludePrereleases = false,
              },
              omnisharp = {
                -- CRITICAL: Use Mono, not modern .NET (Unity requirement)
                useModernNet = false,
                analyzeOpenDocumentsOnly = true,
                enableMsBuildLoadProjectsOnDemand = true,
                projectLoadTimeout = 120,
              },
            },
          })
        end,
      })

      -- lint/formatters
      -- https://github.com/neovim/nvim-lspconfig/blob/master/doc/configs.md#eslint
      -- NOTE: need to install npm install -g vscode-langservers-extracted (eslint globally) for lsp to work
      -- eslint also needs to be installed locally in js/ts project
      -- this is ONLY for eslint projects
      require("lspconfig").eslint.setup({
        settings = {
          format = false,
        },
      })
      require("lspconfig").biome.setup({})

      -- key bindings
      vim.api.nvim_create_autocmd("LspAttach", {
        group = vim.api.nvim_create_augroup("LspKeybindings", { clear = true }),
        callback = function(event)
          local opts = { buffer = event.buf }
          vim.keymap.set("n", "K", vim.lsp.buf.hover, opts)

          -- vim.keymap.set("n", "gi", vim.lsp.buf.implementation, opts)
          vim.keymap.set("n", "<leader>lR", vim.lsp.buf.rename, opts)
          vim.keymap.set("n", "<leader>lh", vim.lsp.buf.signature_help, opts)
          vim.keymap.set("n", "gK", vim.lsp.buf.signature_help, opts)
          vim.keymap.set({ "n", "v" }, "<leader>la", vim.lsp.buf.code_action, opts)
          -- using conform now
          -- vim.keymap.set("n", "<leader>lf", function() vim.lsp.buf.format { async = true } end, opts)
          --
        end,
      })
    end,
  },
}

-- https://github.com/omnisharp/omnisharp-roslyn
-- OmniSharp server based on Roslyn workspaces
--
-- `omnisharp-roslyn` can be installed by downloading and extracting a release from [here](https://github.com/OmniSharp/omnisharp-roslyn/releases).
-- OmniSharp can also be built from source by following the instructions [here](https://github.com/omnisharp/omnisharp-roslyn#downloading-omnisharp).
--
-- OmniSharp requires the [dotnet-sdk](https://dotnet.microsoft.com/download) to be installed.
--
-- **By default, omnisharp-roslyn doesn't have a `cmd` set.** This is because nvim-lspconfig does not make assumptions about your path. You must add the following to your init.vim or init.lua to set `cmd` to the absolute path ($HOME and ~ are not expanded) of the unzipped run script or binary.
--
-- For `go_to_definition` to work fully, extended `textDocument/definition` handler is needed, for example see [omnisharp-extended-lsp.nvim](https://github.com/Hoffs/omnisharp-extended-lsp.nvim)
