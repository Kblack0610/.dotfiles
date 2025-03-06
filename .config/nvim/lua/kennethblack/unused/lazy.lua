-- Bootstrap lazy.nvim
local lazypath = vim.fn.stdpath("data") .. "/lazy/lazy.nvim"

if not (vim.uv or vim.loop).fs_stat(lazypath) then
    local lazyrepo = "https://github.com/folke/lazy.nvim.git"
    local out = vim.fn.system({ "git", "clone", "--filter=blob:none", "--branch=stable", lazyrepo, lazypath })
    if vim.v.shell_error ~= 0 then
        vim.api.nvim_echo({
            { "Failed to clone lazy.nvim:\n", "ErrorMsg" },
            { out,                            "WarningMsg" },
            { "\nPress any key to exit..." },
        }, true, {})
        vim.fn.getchar()
        os.exit(1)
    end
end
vim.opt.rtp:prepend(lazypath)

-- Make sure to setup `mapleader` and `maplocalleader` before
-- loading lazy.nvim so that mappings are correct.
-- This is also a good place to setup other settings (vim.opt)
vim.g.mapleader = " "
vim.g.maplocalleader = "\\"

-- Setup lazy.nvim
require("lazy").setup({
    spec = {
        -- Language Support --------------------------------------------------------------------------------------
        {
            "nvim-treesitter/nvim-treesitter",
            dependencies = { "JoosepAlviste/nvim-ts-context-commentstring" },
        },
        { "nvim-treesitter/playground" },
        -- LSP --------------------------------------------------------------------------------------
        --Language Server Package Manager
        {
            "williamboman/mason.nvim",
            "williamboman/mason-lspconfig.nvim",
        },
        { "neovim/nvim-lspconfig" }, -- Required

        -- Autocompletion
        { "hrsh7th/nvim-cmp" },         -- Required
        { "hrsh7th/cmp-nvim-lsp" },     -- Required
        { "hrsh7th/cmp-buffer" },       -- Optional
        { "hrsh7th/cmp-path" },         -- Optional
        { "saadparwaiz1/cmp_luasnip" }, -- Optional
        { "hrsh7th/cmp-nvim-lua" },     -- Optional

        --See context
        { "nvim-treesitter/nvim-treesitter-context" },
        -- Snippets
        { "L3MON4D3/LuaSnip" },             -- Required
        { "rafamadriz/friendly-snippets" }, -- Optional

        --Debugger
        { "mfussenegger/nvim-dap" },

        --Language Specific Packages
        { "Hoffs/omnisharp-extended-lsp.nvim" },
        {
            'nvim-telescope/telescope.nvim',
            tag = '0.1.8',
            dependencies = { 'nvim-lua/plenary.nvim' }
        },
        --Formatter
        {
            "stevearc/conform.nvim",
            config = function()
                require("conform").setup()
            end,
        },
        --Pretty LSP Diagnostics
        {
            "folke/trouble.nvim",
            config = function()
                require("trouble").setup({
                    icons = false,
                    -- your configuration comes here
                    -- or leave it empty to use the default settings
                    -- refer to the configuration section below
                })
            end,
        },
        -- AI --------------------------------------------------------------------------------------
        -- Code Completion ------
        -- Github Copilot
        -- use("github/copilot.vim")

        --Codeium
        {
            "Exafunction/codeium.nvim",
            requires = {
                "nvim-lua/plenary.nvim",
                "hrsh7th/nvim-cmp",
            },
            config = function()
                require("codeium").setup({
                })
            end
        },

        -- Supermaven
        {
            "supermaven-inc/supermaven-nvim",
            config = function()
                require("supermaven-nvim").setup({
                    -- your configuration goes here
                    identifier = "supermaven",
                    -- the default is to use the current buffer's filetype
                    keymaps = {
                        accept_suggestion = "<Tab>",
                        clear_suggestion = "<C-]>",
                        accept_word = "<C-j>",
                    },
                    ignore_filetypes = { cpp = true, md = true },
                    color = {
                        -- suggestion_color = "#ffffff",
                        cterm = 244,
                    },
                    log_level = "info",                -- set to "off" to disable logging completely
                    disable_inline_completion = false, -- disables inline completion for use with cmp
                    disable_keymaps = false,           -- disables built in keymaps for more manual control
                })
            end,
        },

        --Chat/Commands
        {
            "robitx/gp.nvim",
            config = function()
                local conf = { -- For customization, refer to Install > Configuration in the Documentation/Readme
                    openai_api_key = os.getenv("OPENAI_API_KEY"),
                    providers = {
                        openai = {
                            disable = false,
                            endpoint = "https://api.openai.com/v1/chat/completions",
                            secret = os.getenv("OPENAI_API_KEY"),
                        },
                        anthropic = {
                            disable = false,
                            endpoint = "https://api.anthropic.com/v1/messages",
                            secret = os.getenv("ANTHROPIC_API_KEY"),
                        },
                    },
                    agents = {
                        {
                            name = "ExampleDisabledAgent",
                            disable = true,
                        },
                        {
                            name = "ChatGPT4o",
                            chat = true,
                            command = false,
                            -- string with model name or table with model name and parameters
                            model = { model = "gpt-4o", temperature = 1.1, top_p = 1 },
                            -- system prompt (use this to specify the persona/role of the AI)
                            system_prompt = require("gp.defaults").chat_system_prompt,
                        },
                        {
                            provider = "copilot",
                            name = "ChatCopilot",
                            chat = true,
                            command = false,
                            -- string with model name or table with model name and parameters
                            model = { model = "gpt-4o", temperature = 1.1, top_p = 1 },
                            -- system prompt (use this to specify the persona/role of the AI)
                            system_prompt = require("gp.defaults").chat_system_prompt,
                        },
                        --
                        -- {
                        -- 	provider = "pplx",
                        -- 	name = "ChatPerplexityLlama3.1-8B",
                        -- 	chat = true,
                        -- 	command = false,
                        -- 	-- string with model name or table with model name and parameters
                        -- 	model = { model = "llama-3.1-sonar-small-128k-chat", temperature = 1.1, top_p = 1 },
                        -- 	-- system prompt (use this to specify the persona/role of the AI)
                        -- 	system_prompt = require("gp.defaults").chat_system_prompt,
                        -- },
                        {
                            provider = "anthropic",
                            name = "ChatClaude-3-5-Sonnet",
                            chat = true,
                            command = false,
                            -- string with model name or table with model name and parameters
                            model = { model = "claude-3-5-sonnet-20240620", temperature = 0.8, top_p = 1 },
                            -- system prompt (use this to specify the persona/role of the AI)
                            system_prompt = require("gp.defaults").chat_system_prompt,
                        },
                        {
                            provider = "anthropic",
                            name = "ChatClaude-3-Haiku",
                            chat = true,
                            command = false,
                            -- string with model name or table with model name and parameters
                            model = { model = "claude-3-haiku-20240307", temperature = 0.8, top_p = 1 },
                            -- system prompt (use this to specify the persona/role of the AI)
                            system_prompt = require("gp.defaults").chat_system_prompt,
                        },
                        {
                            provider = "openai",
                            name = "CodeGPT4o",
                            chat = false,
                            command = true,
                            -- string with model name or table with model name and parameters
                            model = { model = "gpt-4o", temperature = 0.8, top_p = 1 },
                            -- system prompt (use this to specify the persona/role of the AI)
                            system_prompt = require("gp.defaults").code_system_prompt,
                        },
                        {
                            provider = "copilot",
                            name = "CodeCopilot",
                            chat = false,
                            command = true,
                            -- string with model name or table with model name and parameters
                            model = { model = "gpt-4o", temperature = 0.8, top_p = 1, n = 1 },
                            -- system prompt (use this to specify the persona/role of the AI)
                            system_prompt = require("gp.defaults").code_system_prompt,
                        },
                        -- {
                        -- 	provider = "googleai",
                        -- 	name = "CodeGemini",
                        -- 	chat = false,
                        -- 	command = true,
                        -- 	-- string with model name or table with model name and parameters
                        -- 	model = { model = "gemini-pro", temperature = 0.8, top_p = 1 },
                        -- 	system_prompt = require("gp.defaults").code_system_prompt,
                        -- },
                        -- {
                        -- 	provider = "pplx",
                        -- 	name = "CodePerplexityLlama3.1-8B",
                        -- 	chat = false,
                        -- 	command = true,
                        -- 	-- string with model name or table with model name and parameters
                        -- 	model = { model = "llama-3.1-sonar-small-128k-chat", temperature = 0.8, top_p = 1 },
                        -- 	system_prompt = require("gp.defaults").code_system_prompt,
                        -- },
                        {
                            provider = "anthropic",
                            name = "CodeClaude-3-5-Sonnet",
                            chat = true,
                            command = true,
                            -- string with model name or table with model name and parameters
                            model = { model = "claude-3-5-sonnet-20240620", temperature = 0.8, top_p = 1 },
                            system_prompt = require("gp.defaults").code_system_prompt,
                        },
                        {
                            provider = "anthropic",
                            name = "CodeClaude-3-Haiku",
                            chat = true,
                            command = true,
                            -- string with model name or table with model name and parameters
                            model = { model = "claude-3-haiku-20240307", temperature = 0.8, top_p = 1 },
                            system_prompt = require("gp.defaults").code_system_prompt,
                        },
                        {
                            provider = "ollama",
                            name = "CodeOllamaLlama3.1-8B",
                            chat = true,
                            command = true,
                            -- string with model name or table with model name and parameters
                            model = {
                                model = "llama3.1",
                                temperature = 0.4,
                                top_p = 1,
                                min_p = 0.05,
                            },
                            -- system prompt (use this to specify the persona/role of the AI)
                            system_prompt = require("gp.defaults").code_system_prompt,
                        },
                    },
                }
                require("gp").setup(conf)

                -- Setup shortcuts here (see Usage > Shortcuts in the Documentation/Readme)
            end,
        },

        --- TOOLS --------------------------------------------------------------------------------------
        {
            "folke/snacks.nvim",
            priority = 1000,
            lazy = false,
            ---@type snacks.Config
            opts = {
                -- your configuration comes here
                -- or leave it empty to use the default settings
                -- refer to the configuration section below
                -- bigfile = { enabled = true },
                -- dashboard = { enabled = true },
                explorer = { enabled = true },
                -- indent = { enabled = true },
                -- input = { enabled = true },
                -- picker = { enabled = true },
                -- notifier = { enabled = true },
                -- quickfile = { enabled = true },
                -- scope = { enabled = true },
                -- scroll = { enabled = true },
                -- statuscolumn = { enabled = true },
                -- words = { enabled = true },
            },
        },
        -- Telescope and File Browser
        {
            "nvim-telescope/telescope.nvim",
            version = "0.1.4",
            dependencies = { "nvim-lua/plenary.nvim" },
        },
        {
            "nvim-telescope/telescope-file-browser.nvim",
            dependencies = { "nvim-telescope/telescope.nvim", "nvim-lua/plenary.nvim" },
        },
        {
            "nvim-telescope/telescope-fzf-native.nvim",
            build =
            "cmake -S. -Bbuild -DCMAKE_BUILD_TYPE=Release && cmake --build build --config Release && cmake --install build --prefix build",
        },
        {
            "nvim-pack/nvim-spectre",
            dependencies = { "nvim-lua/plenary.nvim" },
        },
        "theprimeagen/harpoon",
        "mbbill/undotree",
        {
            "numToStr/Comment.nvim",
            config = function()
                require("Comment").setup({
                    pre_hook = require("ts_context_commentstring.integrations.comment_nvim").create_pre_hook(),
                })
            end,
        },
        "tpope/vim-fugitive",
        "almo7aya/openingh.nvim",
        "laytan/cloak.nvim",

        --Floating terminal, good for panels like Lazygit
        {
            "akinsho/toggleterm.nvim",
            config = function()
                require("toggleterm").setup()
            end,
        },
        --Quick file navigation
        "ggandor/leap.nvim",
        --THEMES --------------------------------------------------------------------------------------
        { "nvim-tree/nvim-web-devicons" },
        { "ellisonleao/gruvbox.nvim" }

    },
    -- Configure any other settings here. See the documentation for more details.
    -- colorscheme that will be used when installing plugins.
    -- install = { colorscheme = { "habamax" } },
    -- automatically check for plugin updates
    checker = { enabled = true },
})
