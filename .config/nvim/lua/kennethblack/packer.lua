-- This file can be loaded by calling `lua require('plugins')` from your init.vim

-- Only required if you have packer configured as `opt`
vim.cmd([[packadd packer.nvim]])

return require("packer").startup(function(use)
	-- CORE ------------
	use("wbthomason/packer.nvim")
	use({
		"nvim-treesitter/nvim-treesitter",
		-- { run = ':TSUpdate' },
		requires = { { "JoosepAlviste/nvim-ts-context-commentstring" } },
	})
	use("nvim-treesitter/playground")
	use({
		"nvim-pack/nvim-spectre",
		requires = { { "nvim-lua/plenary.nvim" } },
	})
	-- telescope and file browser
	use({
		"nvim-telescope/telescope.nvim",
		tag = "0.1.4",
		-- or                            , branch = '0.1.x',
		requires = { { "nvim-lua/plenary.nvim" } },
	})
	use({
		"nvim-telescope/telescope-file-browser.nvim",
		requires = { "nvim-telescope/telescope.nvim", "nvim-lua/plenary.nvim" },
	})
	use({
		"nvim-telescope/telescope-fzf-native.nvim",
		run = "cmake -S. -Bbuild -DCMAKE_BUILD_TYPE=Release && cmake --build build --config Release && cmake --install build --prefix build",
	})
	use({
		"folke/trouble.nvim",
		config = function()
			require("trouble").setup({
				icons = false,
				-- your configuration comes here
				-- or leave it empty to use the default settings
				-- refer to the configuration section below
			})
		end,
	})

	--THEMES -------
	use("nvim-tree/nvim-web-devicons")
	use({ "ellisonleao/gruvbox.nvim" })
	-- use({
	--     'rose-pine/neovim',
	--     as = 'rose-pine',
	--     config = function()
	--         require("rose-pine").setup()
	--         vim.cmd('colorscheme rose-pine')
	--     end
	-- })
	-- use "folke/tokyonight.nvim"

	-- LSP -------------
	-- Need to deprecate lsp-zero and install requirements
	use({
		"VonHeikemen/lsp-zero.nvim",
		branch = "v4.x",
		requires = {
			-- LSP Support
			{ "neovim/nvim-lspconfig" }, -- Required

			-- Autocompletion
			{ "hrsh7th/nvim-cmp" }, -- Required
			{ "hrsh7th/cmp-nvim-lsp" }, -- Required
			{ "hrsh7th/cmp-buffer" }, -- Optional
			{ "hrsh7th/cmp-path" }, -- Optional
			{ "saadparwaiz1/cmp_luasnip" }, -- Optional
			{ "hrsh7th/cmp-nvim-lua" }, -- Optional

			-- Snippets
			{ "L3MON4D3/LuaSnip" }, -- Required
			{ "rafamadriz/friendly-snippets" }, -- Optional
		},
	})
	use({
		"williamboman/mason.nvim",
		"williamboman/mason-lspconfig.nvim",
	})
	use("Hoffs/omnisharp-extended-lsp.nvim")

	use({
		"stevearc/conform.nvim",
		config = function()
			require("conform").setup()
		end,
	})

	-- AI -------
	use({
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
				ignore_filetypes = { cpp = true },
				color = {
					-- suggestion_color = "#ffffff",
					cterm = 244,
				},
				log_level = "info", -- set to "off" to disable logging completely
				disable_inline_completion = false, -- disables inline completion for use with cmp
				disable_keymaps = false, -- disables built in keymaps for more manual control
			})
		end,
	})
	use({
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
						provider = "openai",
						name = "ChatGPT4o-mini",
						chat = true,
						command = false,
						-- string with model name or table with model name and parameters
						model = { model = "gpt-4o-mini", temperature = 1.1, top_p = 1 },
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
						provider = "openai",
						name = "CodeGPT4o-mini",
						chat = false,
						command = true,
						-- string with model name or table with model name and parameters
						model = { model = "gpt-4o-mini", temperature = 0.7, top_p = 1 },
						-- system prompt (use this to specify the persona/role of the AI)
						system_prompt = "Please return ONLY code snippets.\nSTART AND END YOUR ANSWER WITH:\n\n```",
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
	})
	-- use("github/copilot.vim")

	--- TOOLS ---------
	use("theprimeagen/harpoon")
	use("mbbill/undotree")
	use("tpope/vim-fugitive")
	use({
		"numToStr/Comment.nvim",
		config = function()
			require("Comment").setup({
				pre_hook = require("ts_context_commentstring.integrations.comment_nvim").create_pre_hook(),
			})
		end,
	})
	use("almo7aya/openingh.nvim")
	use("nvim-treesitter/nvim-treesitter-context")
	use("laytan/cloak.nvim")
	use({
		"akinsho/toggleterm.nvim",
		tag = "*",
		config = function()
			require("toggleterm").setup()
		end,
	})

	use("nvim-tree/nvim-tree.lua")
	use("mfussenegger/nvim-dap")
	use("ggandor/leap.nvim")
	-- use {
	--   "rest-nvim/rest.nvim",
	--   rocks = { "lua-curl", "nvim-nio", "mimetypes", "xml2lua" },
	--   config = function()
	--     require("rest-nvim").setup()
	--   end,
	-- }

	--- FUN -----------
	use("folke/zen-mode.nvim")
	use("eandrju/cellular-automaton.nvim")
end)
