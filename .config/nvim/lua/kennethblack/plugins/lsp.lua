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
    opts = {
      ensure_installed = ensure_installed,
    },
  },
  {
    "neovim/nvim-lspconfig",
    -- Remove if you want to go back to nvim-cmp
    dependencies = { "saghen/blink.cmp" },
    config = function()
      local lspconfig = require "lspconfig"
      -- If you want to go back to nvim-cmp
      --   local capabilities = require("cmp_nvim_lsp").default_capabilities()
      local capabilities = require("blink.cmp").get_lsp_capabilities()
      require("lspconfig.ui.windows").default_options.border = "rounded"

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
      local rounded_border_handlers = {
        ["textDocument/hover"] = vim.lsp.with(vim.lsp.handlers.hover, { border = "rounded" }),
        ["textDocument/signatureHelp"] = vim.lsp.with(vim.lsp.handlers.signature_help, { border = "rounded" }),
      }
      local pid = vim.fn.getpid()
      local omnisharp_bin = "/opt/omnisharp-roslyn/run"
      for _, value in ipairs(ensure_installed) do
        if value == "ts_ls" then
          lspconfig[value].setup {
            capabilities = capabilities,
            on_attach = function(client, _)
              -- Disable formatting capability for tsserver
              -- This conflicts with other formatters
              client.server_capabilities.documentFormattingProvider = false
              client.server_capabilities.documentRangeFormattingProvider = false
            end,
          }
        elseif value == "emmet_language_server" then
          lspconfig[value].setup {
            capabilities = capabilities,
            filetypes = { "html", "css", "scss", "javascriptreact", "typescriptreact", "javascript" },
          }
        elseif value == "omnisharp" then
          lspconfig[value].setup {
            capabilities = capabilities,
            root_dir = function(fname)
              local lspconfig = require("lspconfig")
              local primary = lspconfig.util.root_pattern("*.sln")(fname)
              local fallback = lspconfig.util.root_pattern("*.csproj")(fname)
              return primary or fallback
            end,
            analyze_open_documents_only = true,
            organize_imports_on_format = true,
            flags = {
              debounce_text_changes = 150,
            },
            cmd = { omnisharp_bin, "--languageserver", "--hostPID", tostring(pid) },
            -- --cmd = { "dotnet", "/path/to/omnisharp/OmniSharp.dll" },
            handlers = vim.tbl_extend("force", rounded_border_handlers, {
              ["textDocument/definition"] = require("omnisharp_extended").handler,
            }),
            settings = {
              FormattingOptions = {
                -- Enables support for reading code style, naming convention and analyzer
                -- settings from .editorconfig.
                EnableEditorConfigSupport = true,
                -- Specifies whether 'using' directives should be grouped and sorted during
                -- document formatting.
                OrganizeImports = nil,
              },
              MsBuild = {
                -- If true, MSBuild project system will only load projects for files that
                -- were opened in the editor. This setting is useful for big C# codebases
                -- and allows for faster initialization of code navigation features only
                -- for projects that are relevant to code that is being edited. With this
                -- setting enabled OmniSharp may load fewer projects and may thus display
                -- incomplete reference lists for symbols.
                LoadProjectsOnDemand = nil,
              },
              RoslynExtensionsOptions = {
                -- Enables support for roslyn analyzers, code fixes and rulesets.
                EnableAnalyzersSupport = nil,
                -- Enables support for showing unimported types and unimported extension
                -- methods in completion lists. When committed, the appropriate using
                -- directive will be added at the top of the current file. This option can
                -- have a negative impact on initial completion responsiveness,
                -- particularly for the first few completion sessions after opening a
                -- solution.
                EnableImportCompletion = nil,
                -- Only run analyzers against open files when 'enableRoslynAnalyzers' is
                -- true
                AnalyzeOpenDocumentsOnly = nil,
              },
              Sdk = {
                -- Specifies whether to include preview versions of the .NET SDK when
                -- determining which version to use for project loading.
                IncludePrereleases = true,
              },
              -- omnisharp = {
              --   analyzeOpenDocumentsOnly = true,
              --   enableAsyncCompletion = false,
              --   enableMsBuildLoadProjectsOnDemand = false,
              --   projectLoadTimeout = 300,
              --   useModernNet = true,
              --   enableRoslynAnalyzers = false,
              -- },
            },
          }
        else
          lspconfig[value].setup {
            capabilities = capabilities,

          }
        end
      end

      -- lint/formatters
      -- https://github.com/neovim/nvim-lspconfig/blob/master/doc/configs.md#eslint
      -- NOTE: need to install npm install -g vscode-langservers-extracted (eslint globally) for lsp to work
      -- eslint also needs to be installed locally in js/ts project
      -- this is ONLY for eslint projects
      lspconfig.eslint.setup {
        settings = {
          format = false,
        },
      }
      lspconfig.biome.setup {}

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
