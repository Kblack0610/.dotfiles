-- This file can be loaded by calling `lua require('plugins')` from your init.vim

-- Only required if you have packer configured as `opt`
vim.cmd [[packadd packer.nvim]]

return require('packer').startup(function(use)
    -- Packer can manage itself
    use 'wbthomason/packer.nvim'
    use "almo7aya/openingh.nvim"
    use {
        'nvim-telescope/telescope.nvim', tag = '0.1.4',
        -- or                            , branch = '0.1.x',
        requires = { { 'nvim-lua/plenary.nvim' } }
    }
    use {
        'nvim-pack/nvim-spectre',
        requires = { { 'nvim-lua/plenary.nvim' } }
    }
    use {
        "nvim-telescope/telescope-file-browser.nvim",
        requires = { "nvim-telescope/telescope.nvim", "nvim-lua/plenary.nvim" }
    }
    --THEME SHIT
    use({
        'rose-pine/neovim',
        as = 'rose-pine',
        config = function()
            require("rose-pine").setup()
            vim.cmd('colorscheme rose-pine')
        end
    })

    use('nvim-tree/nvim-web-devicons')

    -- use "folke/tokyonight.nvim"

    -- End Theme Shit

    use({
        'nvim-treesitter/nvim-treesitter',
        -- { run = ':TSUpdate' },
        requires = { { 'JoosepAlviste/nvim-ts-context-commentstring' } }
    })
    use('nvim-treesitter/playground')
    use('theprimeagen/harpoon')
    use('mbbill/undotree')
    use('tpope/vim-fugitive')
    use {
        'VonHeikemen/lsp-zero.nvim',
        branch = 'v1.x',
        requires = {
            -- LSP Support
            { 'neovim/nvim-lspconfig' },             -- Required
            { 'williamboman/mason.nvim' },           -- Optional
            { 'williamboman/mason-lspconfig.nvim' }, -- Optional

            -- Autocompletion
            { 'hrsh7th/nvim-cmp' },         -- Required
            { 'hrsh7th/cmp-nvim-lsp' },     -- Required
            { 'hrsh7th/cmp-buffer' },       -- Optional
            { 'hrsh7th/cmp-path' },         -- Optional
            { 'saadparwaiz1/cmp_luasnip' }, -- Optional
            { 'hrsh7th/cmp-nvim-lua' },     -- Optional

            -- Snippets
            { 'L3MON4D3/LuaSnip' },             -- Required
            { 'rafamadriz/friendly-snippets' }, -- Optional
        }
    }
    use {
        'numToStr/Comment.nvim',
        config = function()
            require('Comment').setup({
                pre_hook =
                    require('ts_context_commentstring.integrations.comment_nvim').create_pre_hook(),
            })
        end
    }
    use { 'nvim-telescope/telescope-fzf-native.nvim', run =
    'cmake -S. -Bbuild -DCMAKE_BUILD_TYPE=Release && cmake --build build --config Release && cmake --install build --prefix build' }
    use({
        "folke/trouble.nvim",
        config = function()
            require("trouble").setup {
                icons = false,
                -- your configuration comes here
                -- or leave it empty to use the default settings
                -- refer to the configuration section below
            }
        end
    })
    use("nvim-treesitter/nvim-treesitter-context");
    use("folke/zen-mode.nvim")
    use("github/copilot.vim")
    use("eandrju/cellular-automaton.nvim")
    use("laytan/cloak.nvim")

    use { "akinsho/toggleterm.nvim", tag = '*', config = function()
        require("toggleterm").setup()
    end }

    use("nvim-tree/nvim-tree.lua")
    use('mfussenegger/nvim-dap')
    use('ggandor/leap.nvim')

    -- use('sultanahamer/nvim-dap-reactnative')
    use('vimwiki/vimwiki')

    -- use {
    --   "rest-nvim/rest.nvim",
    --   rocks = { "lua-curl", "nvim-nio", "mimetypes", "xml2lua" },
    --   config = function()
    --     require("rest-nvim").setup()
    --   end,
    -- }
    
    -- use({
    --     "jackMort/ChatGPT.nvim",
    --     config = function()
    --         require("chatgpt").setup({
    --             -- optional configuration
    --         })
    --     end,
    --     requires = {
    --         "MunifTanjim/nui.nvim",
    --         "nvim-lua/plenary.nvim",
    --         "nvim-telescope/telescope.nvim"
    --     }
    -- })
end)
