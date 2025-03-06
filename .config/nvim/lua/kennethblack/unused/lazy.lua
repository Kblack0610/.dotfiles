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

        --See context
        { "nvim-treesitter/nvim-treesitter-context" },

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

        "tpope/vim-fugitive",
        "almo7aya/openingh.nvim",
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
