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
      -- Automatically call vim.lsp.enable() for installed servers
      automatic_enable = {
        exclude = { "omnisharp" }, -- We handle omnisharp lazily
      },
    },
  },
  {
    "neovim/nvim-lspconfig",
    dependencies = { "saghen/blink.cmp", "williamboman/mason-lspconfig.nvim" },
    config = function()
      -- Add Mason bin to PATH so lspconfig can find Mason-installed servers
      local mason_bin = vim.fn.stdpath("data") .. "/mason/bin"
      vim.env.PATH = mason_bin .. ":" .. vim.env.PATH

      -- Get capabilities from blink.cmp
      local capabilities = require("blink.cmp").get_lsp_capabilities()

      -- Global capabilities for ALL servers
      vim.lsp.config("*", {
        capabilities = capabilities,
      })

      -- Global hover handler with rounded border
      -- Also suppresses "no information available" when multiple LSPs attached
      vim.lsp.handlers["textDocument/hover"] = function(_, result, ctx, config)
        if not (result and result.contents and result.contents.value ~= "") then
          return
        end
        return vim.lsp.handlers.hover(_, result, ctx, vim.tbl_extend("force", config or {}, { border = "rounded" }))
      end

      -- Global signature help with rounded border
      vim.lsp.handlers["textDocument/signatureHelp"] = vim.lsp.with(vim.lsp.handlers.signature_help, {
        border = "rounded",
      })

      -- Server-specific configs (mason-lspconfig auto-enables these)
      vim.lsp.config("ts_ls", {
        on_attach = function(client, _)
          -- Disable formatting capability for tsserver (conflicts with other formatters)
          client.server_capabilities.documentFormattingProvider = false
          client.server_capabilities.documentRangeFormattingProvider = false
        end,
      })

      vim.lsp.config("emmet_language_server", {
        filetypes = { "html", "css", "scss", "javascriptreact", "typescriptreact", "javascript" },
      })

      -- lint/formatters
      -- https://github.com/neovim/nvim-lspconfig/blob/master/doc/configs.md#eslint
      -- NOTE: need to install npm install -g vscode-langservers-extracted (eslint globally) for lsp to work
      -- eslint also needs to be installed locally in js/ts project
      vim.lsp.config("eslint", {
        settings = { format = false },
      })

      -- biome uses defaults
      vim.lsp.config("biome", {})

      -- omnisharp for Unity/C# - only setup when opening C# files
      -- Requires: OmniSharp v1.39.6 (installed via setup-unity-omnisharp.sh)
      -- Run: ~/.dotfiles/.local/src/installation_scripts/setup-unity-omnisharp.sh
      vim.api.nvim_create_autocmd("FileType", {
        pattern = { "cs" },
        once = true,
        callback = function()
          local pid = vim.fn.getpid()
          local omnisharp_bin = "/opt/omnisharp-roslyn/run"

          vim.lsp.config("omnisharp", {
            cmd = { omnisharp_bin, "--languageserver", "--hostPID", tostring(pid) },
            root_dir = function(bufnr, on_dir)
              -- Prefer .sln files, fallback to .csproj
              local sln = vim.fs.root(bufnr, function(name)
                return name:match("%.sln$")
              end)
              local csproj = vim.fs.root(bufnr, function(name)
                return name:match("%.csproj$")
              end)
              on_dir(sln or csproj)
            end,
            -- Use Mono for Unity (NOT modern .NET)
            use_mono = true,
            flags = {
              debounce_text_changes = 150,
            },
            handlers = {
              ["textDocument/hover"] = vim.lsp.with(vim.lsp.handlers.hover, { border = "rounded" }),
              ["textDocument/signatureHelp"] = vim.lsp.with(vim.lsp.handlers.signature_help, { border = "rounded" }),
              ["textDocument/definition"] = require("omnisharp_extended").handler,
            },
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
          vim.lsp.enable("omnisharp")
        end,
      })

      -- Key bindings
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
