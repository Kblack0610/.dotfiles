-- Native Windows nvim is for quick edits on the VDI; real dev happens in WSL.
-- Skip Mason auto-install there to avoid blocking startup on slow corp networks.
local is_windows_native = vim.fn.has("win32") == 1 and vim.fn.has("wsl") == 0

local ensure_installed = is_windows_native and {} or {
  "lua_ls",
  "ts_ls",
  "jsonls",
  "bashls",
  "html",
  "cssls",
  "sqlls",
  "yamlls",
  "pyright",
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

      -- :Lsp* commands. nvim-lspconfig 3.x bails on registering these because of an
      -- upstream check (`exists(':lsp') == 2`) that mis-fires on nvim 0.12.
      local cmd = vim.api.nvim_create_user_command
      cmd("LspInfo", "checkhealth vim.lsp", { desc = "Show LSP status" })
      cmd("LspLog", function()
        vim.cmd("tabnew " .. vim.lsp.get_log_path())
      end, { desc = "Open LSP log" })
      cmd("LspRestart", function(info)
        local names = #info.fargs > 0 and info.fargs or vim.tbl_map(function(c) return c.name end, vim.lsp.get_clients())
        for _, name in ipairs(names) do
          for _, c in ipairs(vim.lsp.get_clients({ name = name })) do
            vim.lsp.stop_client(c.id, true)
          end
          vim.defer_fn(function() vim.lsp.enable(name) end, 200)
        end
      end, { nargs = "*", desc = "Restart LSP client(s)" })

      vim.keymap.set("n", "<leader>li", function()
        local clients = vim.lsp.get_clients({ bufnr = 0 })
        if #clients == 0 then
          vim.notify("LSP: no clients attached to buffer " .. vim.api.nvim_buf_get_name(0), vim.log.levels.WARN)
          return
        end
        for _, c in ipairs(clients) do
          vim.notify(("LSP: %s  root=%s  id=%d"):format(c.name, c.config.root_dir or "?", c.id), vim.log.levels.INFO)
        end
      end, { desc = "LSP: list attached clients" })
    end,
  },
}
