-- Automatically generated packer.nvim plugin loader code

if vim.api.nvim_call_function('has', {'nvim-0.5'}) ~= 1 then
  vim.api.nvim_command('echohl WarningMsg | echom "Invalid Neovim version for packer.nvim! | echohl None"')
  return
end

vim.api.nvim_command('packadd packer.nvim')

local no_errors, error_msg = pcall(function()

_G._packer = _G._packer or {}
_G._packer.inside_compile = true

local time
local profile_info
local should_profile = false
if should_profile then
  local hrtime = vim.loop.hrtime
  profile_info = {}
  time = function(chunk, start)
    if start then
      profile_info[chunk] = hrtime()
    else
      profile_info[chunk] = (hrtime() - profile_info[chunk]) / 1e6
    end
  end
else
  time = function(chunk, start) end
end

local function save_profiles(threshold)
  local sorted_times = {}
  for chunk_name, time_taken in pairs(profile_info) do
    sorted_times[#sorted_times + 1] = {chunk_name, time_taken}
  end
  table.sort(sorted_times, function(a, b) return a[2] > b[2] end)
  local results = {}
  for i, elem in ipairs(sorted_times) do
    if not threshold or threshold and elem[2] > threshold then
      results[i] = elem[1] .. ' took ' .. elem[2] .. 'ms'
    end
  end
  if threshold then
    table.insert(results, '(Only showing plugins that took longer than ' .. threshold .. ' ms ' .. 'to load)')
  end

  _G._packer.profile_output = results
end

time([[Luarocks path setup]], true)
local package_path_str = "/home/kblack0610/.cache/nvim/packer_hererocks/2.1.1713484068/share/lua/5.1/?.lua;/home/kblack0610/.cache/nvim/packer_hererocks/2.1.1713484068/share/lua/5.1/?/init.lua;/home/kblack0610/.cache/nvim/packer_hererocks/2.1.1713484068/lib/luarocks/rocks-5.1/?.lua;/home/kblack0610/.cache/nvim/packer_hererocks/2.1.1713484068/lib/luarocks/rocks-5.1/?/init.lua"
local install_cpath_pattern = "/home/kblack0610/.cache/nvim/packer_hererocks/2.1.1713484068/lib/lua/5.1/?.so"
if not string.find(package.path, package_path_str, 1, true) then
  package.path = package.path .. ';' .. package_path_str
end

if not string.find(package.cpath, install_cpath_pattern, 1, true) then
  package.cpath = package.cpath .. ';' .. install_cpath_pattern
end

time([[Luarocks path setup]], false)
time([[try_loadstring definition]], true)
local function try_loadstring(s, component, name)
  local success, result = pcall(loadstring(s), name, _G.packer_plugins[name])
  if not success then
    vim.schedule(function()
      vim.api.nvim_notify('packer.nvim: Error running ' .. component .. ' for ' .. name .. ': ' .. result, vim.log.levels.ERROR, {})
    end)
  end
  return result
end

time([[try_loadstring definition]], false)
time([[Defining packer_plugins]], true)
_G.packer_plugins = {
  ["Comment.nvim"] = {
    config = { "\27LJ\2\nª\1\0\0\6\0\a\0\r6\0\0\0'\2\1\0B\0\2\0029\0\2\0005\2\5\0006\3\0\0'\5\3\0B\3\2\0029\3\4\3B\3\1\2=\3\6\2B\0\2\1K\0\1\0\rpre_hook\1\0\1\rpre_hook\0\20create_pre_hook7ts_context_commentstring.integrations.comment_nvim\nsetup\fComment\frequire\0" },
    loaded = true,
    path = "/home/kblack0610/.local/share/nvim/site/pack/packer/start/Comment.nvim",
    url = "https://github.com/numToStr/Comment.nvim"
  },
  LuaSnip = {
    loaded = true,
    path = "/home/kblack0610/.local/share/nvim/site/pack/packer/start/LuaSnip",
    url = "https://github.com/L3MON4D3/LuaSnip"
  },
  ["cellular-automaton.nvim"] = {
    loaded = true,
    path = "/home/kblack0610/.local/share/nvim/site/pack/packer/start/cellular-automaton.nvim",
    url = "https://github.com/eandrju/cellular-automaton.nvim"
  },
  ["cloak.nvim"] = {
    loaded = true,
    path = "/home/kblack0610/.local/share/nvim/site/pack/packer/start/cloak.nvim",
    url = "https://github.com/laytan/cloak.nvim"
  },
  ["cmp-buffer"] = {
    loaded = true,
    path = "/home/kblack0610/.local/share/nvim/site/pack/packer/start/cmp-buffer",
    url = "https://github.com/hrsh7th/cmp-buffer"
  },
  ["cmp-nvim-lsp"] = {
    loaded = true,
    path = "/home/kblack0610/.local/share/nvim/site/pack/packer/start/cmp-nvim-lsp",
    url = "https://github.com/hrsh7th/cmp-nvim-lsp"
  },
  ["cmp-nvim-lua"] = {
    loaded = true,
    path = "/home/kblack0610/.local/share/nvim/site/pack/packer/start/cmp-nvim-lua",
    url = "https://github.com/hrsh7th/cmp-nvim-lua"
  },
  ["cmp-path"] = {
    loaded = true,
    path = "/home/kblack0610/.local/share/nvim/site/pack/packer/start/cmp-path",
    url = "https://github.com/hrsh7th/cmp-path"
  },
  cmp_luasnip = {
    loaded = true,
    path = "/home/kblack0610/.local/share/nvim/site/pack/packer/start/cmp_luasnip",
    url = "https://github.com/saadparwaiz1/cmp_luasnip"
  },
  ["codeium.nvim"] = {
    config = { "\27LJ\2\n9\0\0\3\0\3\0\a6\0\0\0'\2\1\0B\0\2\0029\0\2\0004\2\0\0B\0\2\1K\0\1\0\nsetup\fcodeium\frequire\0" },
    loaded = true,
    path = "/home/kblack0610/.local/share/nvim/site/pack/packer/start/codeium.nvim",
    url = "https://github.com/Exafunction/codeium.nvim"
  },
  ["conform.nvim"] = {
    config = { "\27LJ\2\n5\0\0\3\0\3\0\0066\0\0\0'\2\1\0B\0\2\0029\0\2\0B\0\1\1K\0\1\0\nsetup\fconform\frequire\0" },
    loaded = true,
    path = "/home/kblack0610/.local/share/nvim/site/pack/packer/start/conform.nvim",
    url = "https://github.com/stevearc/conform.nvim"
  },
  ["friendly-snippets"] = {
    loaded = true,
    path = "/home/kblack0610/.local/share/nvim/site/pack/packer/start/friendly-snippets",
    url = "https://github.com/rafamadriz/friendly-snippets"
  },
  ["gp.nvim"] = {
    config = { "\27LJ\2\nµ\16\0\0\6\0)\0r5\0\3\0006\1\0\0009\1\1\1'\3\2\0B\1\2\2=\1\4\0005\1\a\0005\2\5\0006\3\0\0009\3\1\3'\5\2\0B\3\2\2=\3\6\2=\2\b\0015\2\t\0006\3\0\0009\3\1\3'\5\n\0B\3\2\2=\3\6\2=\2\v\1=\1\f\0004\1\v\0005\2\r\0>\2\1\0015\2\14\0005\3\15\0=\3\16\0026\3\17\0'\5\18\0B\3\2\0029\3\19\3=\3\20\2>\2\2\0015\2\21\0005\3\22\0=\3\16\0026\3\17\0'\5\18\0B\3\2\0029\3\19\3=\3\20\2>\2\3\0015\2\23\0005\3\24\0=\3\16\0026\3\17\0'\5\18\0B\3\2\0029\3\19\3=\3\20\2>\2\4\0015\2\25\0005\3\26\0=\3\16\0026\3\17\0'\5\18\0B\3\2\0029\3\19\3=\3\20\2>\2\5\0015\2\27\0005\3\28\0=\3\16\0026\3\17\0'\5\18\0B\3\2\0029\3\29\3=\3\20\2>\2\6\0015\2\30\0005\3\31\0=\3\16\0026\3\17\0'\5\18\0B\3\2\0029\3\29\3=\3\20\2>\2\a\0015\2 \0005\3!\0=\3\16\0026\3\17\0'\5\18\0B\3\2\0029\3\29\3=\3\20\2>\2\b\0015\2\"\0005\3#\0=\3\16\0026\3\17\0'\5\18\0B\3\2\0029\3\29\3=\3\20\2>\2\t\0015\2$\0005\3%\0=\3\16\0026\3\17\0'\5\18\0B\3\2\0029\3\29\3=\3\20\2>\2\n\1=\1&\0006\1\17\0'\3'\0B\1\2\0029\1(\1\18\3\0\0B\1\2\1K\0\1\0\nsetup\agp\vagents\1\0\4\ntop_p\3\1\16temperature\4š³æÌ\t™³æþ\3\nmin_p\4š³æÌ\t™³¦ý\3\nmodel\rllama3.1\1\0\6\tname\26CodeOllamaLlama3.1-8B\18system_prompt\0\fcommand\2\nmodel\0\tchat\2\rprovider\vollama\1\0\3\ntop_p\3\1\16temperature\4š³æÌ\t™³¦ÿ\3\nmodel\28claude-3-haiku-20240307\1\0\6\tname\23CodeClaude-3-Haiku\18system_prompt\0\fcommand\2\nmodel\0\tchat\2\rprovider\14anthropic\1\0\3\ntop_p\3\1\16temperature\4š³æÌ\t™³¦ÿ\3\nmodel\31claude-3-5-sonnet-20240620\1\0\6\tname\26CodeClaude-3-5-Sonnet\18system_prompt\0\fcommand\2\nmodel\0\tchat\2\rprovider\14anthropic\1\0\4\ntop_p\3\1\16temperature\4š³æÌ\t™³¦ÿ\3\6n\3\1\nmodel\vgpt-4o\1\0\6\tname\16CodeCopilot\18system_prompt\0\fcommand\2\nmodel\0\tchat\1\rprovider\fcopilot\23code_system_prompt\1\0\3\ntop_p\3\1\16temperature\4š³æÌ\t™³¦ÿ\3\nmodel\vgpt-4o\1\0\6\tname\14CodeGPT4o\18system_prompt\0\fcommand\2\nmodel\0\tchat\1\rprovider\vopenai\1\0\3\ntop_p\3\1\16temperature\4š³æÌ\t™³¦ÿ\3\nmodel\28claude-3-haiku-20240307\1\0\6\tname\23ChatClaude-3-Haiku\18system_prompt\0\fcommand\1\nmodel\0\tchat\2\rprovider\14anthropic\1\0\3\ntop_p\3\1\16temperature\4š³æÌ\t™³¦ÿ\3\nmodel\31claude-3-5-sonnet-20240620\1\0\6\tname\26ChatClaude-3-5-Sonnet\18system_prompt\0\fcommand\1\nmodel\0\tchat\2\rprovider\14anthropic\1\0\3\ntop_p\3\1\16temperature\4š³æÌ\t™³Æÿ\3\nmodel\vgpt-4o\1\0\6\tname\16ChatCopilot\18system_prompt\0\fcommand\1\nmodel\0\tchat\2\rprovider\fcopilot\18system_prompt\23chat_system_prompt\16gp.defaults\frequire\nmodel\1\0\3\ntop_p\3\1\16temperature\4š³æÌ\t™³Æÿ\3\nmodel\vgpt-4o\1\0\5\tchat\2\fcommand\1\nmodel\0\tname\14ChatGPT4o\18system_prompt\0\1\0\2\tname\25ExampleDisabledAgent\fdisable\2\14providers\14anthropic\22ANTHROPIC_API_KEY\1\0\3\rendpoint*https://api.anthropic.com/v1/messages\fdisable\1\vsecret\0\vopenai\1\0\2\14anthropic\0\vopenai\0\vsecret\1\0\3\rendpoint/https://api.openai.com/v1/chat/completions\fdisable\1\vsecret\0\19openai_api_key\1\0\3\14providers\0\19openai_api_key\0\vagents\0\19OPENAI_API_KEY\vgetenv\aos\0" },
    loaded = true,
    path = "/home/kblack0610/.local/share/nvim/site/pack/packer/start/gp.nvim",
    url = "https://github.com/robitx/gp.nvim"
  },
  ["gruvbox.nvim"] = {
    loaded = true,
    path = "/home/kblack0610/.local/share/nvim/site/pack/packer/start/gruvbox.nvim",
    url = "https://github.com/ellisonleao/gruvbox.nvim"
  },
  harpoon = {
    loaded = true,
    path = "/home/kblack0610/.local/share/nvim/site/pack/packer/start/harpoon",
    url = "https://github.com/theprimeagen/harpoon"
  },
  ["leap.nvim"] = {
    loaded = true,
    path = "/home/kblack0610/.local/share/nvim/site/pack/packer/start/leap.nvim",
    url = "https://github.com/ggandor/leap.nvim"
  },
  ["mason-lspconfig.nvim"] = {
    loaded = true,
    path = "/home/kblack0610/.local/share/nvim/site/pack/packer/start/mason-lspconfig.nvim",
    url = "https://github.com/williamboman/mason-lspconfig.nvim"
  },
  ["mason.nvim"] = {
    loaded = true,
    path = "/home/kblack0610/.local/share/nvim/site/pack/packer/start/mason.nvim",
    url = "https://github.com/williamboman/mason.nvim"
  },
  ["nvim-cmp"] = {
    loaded = true,
    path = "/home/kblack0610/.local/share/nvim/site/pack/packer/start/nvim-cmp",
    url = "https://github.com/hrsh7th/nvim-cmp"
  },
  ["nvim-dap"] = {
    loaded = true,
    path = "/home/kblack0610/.local/share/nvim/site/pack/packer/start/nvim-dap",
    url = "https://github.com/mfussenegger/nvim-dap"
  },
  ["nvim-lspconfig"] = {
    loaded = true,
    path = "/home/kblack0610/.local/share/nvim/site/pack/packer/start/nvim-lspconfig",
    url = "https://github.com/neovim/nvim-lspconfig"
  },
  ["nvim-spectre"] = {
    loaded = true,
    path = "/home/kblack0610/.local/share/nvim/site/pack/packer/start/nvim-spectre",
    url = "https://github.com/nvim-pack/nvim-spectre"
  },
  ["nvim-treesitter"] = {
    loaded = true,
    path = "/home/kblack0610/.local/share/nvim/site/pack/packer/start/nvim-treesitter",
    url = "https://github.com/nvim-treesitter/nvim-treesitter"
  },
  ["nvim-treesitter-context"] = {
    loaded = true,
    path = "/home/kblack0610/.local/share/nvim/site/pack/packer/start/nvim-treesitter-context",
    url = "https://github.com/nvim-treesitter/nvim-treesitter-context"
  },
  ["nvim-ts-context-commentstring"] = {
    loaded = true,
    path = "/home/kblack0610/.local/share/nvim/site/pack/packer/start/nvim-ts-context-commentstring",
    url = "https://github.com/JoosepAlviste/nvim-ts-context-commentstring"
  },
  ["nvim-web-devicons"] = {
    loaded = true,
    path = "/home/kblack0610/.local/share/nvim/site/pack/packer/start/nvim-web-devicons",
    url = "https://github.com/nvim-tree/nvim-web-devicons"
  },
  ["omnisharp-extended-lsp.nvim"] = {
    loaded = true,
    path = "/home/kblack0610/.local/share/nvim/site/pack/packer/start/omnisharp-extended-lsp.nvim",
    url = "https://github.com/Hoffs/omnisharp-extended-lsp.nvim"
  },
  ["openingh.nvim"] = {
    loaded = true,
    path = "/home/kblack0610/.local/share/nvim/site/pack/packer/start/openingh.nvim",
    url = "https://github.com/almo7aya/openingh.nvim"
  },
  ["packer.nvim"] = {
    loaded = true,
    path = "/home/kblack0610/.local/share/nvim/site/pack/packer/start/packer.nvim",
    url = "https://github.com/wbthomason/packer.nvim"
  },
  playground = {
    loaded = true,
    path = "/home/kblack0610/.local/share/nvim/site/pack/packer/start/playground",
    url = "https://github.com/nvim-treesitter/playground"
  },
  ["plenary.nvim"] = {
    loaded = true,
    path = "/home/kblack0610/.local/share/nvim/site/pack/packer/start/plenary.nvim",
    url = "https://github.com/nvim-lua/plenary.nvim"
  },
  ["supermaven-nvim"] = {
    config = { "\27LJ\2\nÊ\2\0\0\4\0\n\0\r6\0\0\0'\2\1\0B\0\2\0029\0\2\0005\2\3\0005\3\4\0=\3\5\0025\3\6\0=\3\a\0025\3\b\0=\3\t\2B\0\2\1K\0\1\0\ncolor\1\0\1\ncterm\3ô\1\21ignore_filetypes\1\0\2\amd\2\bcpp\2\fkeymaps\1\0\3\16accept_word\n<C-j>\22accept_suggestion\n<Tab>\21clear_suggestion\n<C-]>\1\0\a\15identifier\15supermaven\ncolor\0\fkeymaps\0\21ignore_filetypes\0\20disable_keymaps\1\30disable_inline_completion\1\14log_level\tinfo\nsetup\20supermaven-nvim\frequire\0" },
    loaded = true,
    path = "/home/kblack0610/.local/share/nvim/site/pack/packer/start/supermaven-nvim",
    url = "https://github.com/supermaven-inc/supermaven-nvim"
  },
  ["telescope-file-browser.nvim"] = {
    loaded = true,
    path = "/home/kblack0610/.local/share/nvim/site/pack/packer/start/telescope-file-browser.nvim",
    url = "https://github.com/nvim-telescope/telescope-file-browser.nvim"
  },
  ["telescope-fzf-native.nvim"] = {
    loaded = true,
    path = "/home/kblack0610/.local/share/nvim/site/pack/packer/start/telescope-fzf-native.nvim",
    url = "https://github.com/nvim-telescope/telescope-fzf-native.nvim"
  },
  ["telescope.nvim"] = {
    loaded = true,
    path = "/home/kblack0610/.local/share/nvim/site/pack/packer/start/telescope.nvim",
    url = "https://github.com/nvim-telescope/telescope.nvim"
  },
  ["toggleterm.nvim"] = {
    config = { "\27LJ\2\n8\0\0\3\0\3\0\0066\0\0\0'\2\1\0B\0\2\0029\0\2\0B\0\1\1K\0\1\0\nsetup\15toggleterm\frequire\0" },
    loaded = true,
    path = "/home/kblack0610/.local/share/nvim/site/pack/packer/start/toggleterm.nvim",
    url = "https://github.com/akinsho/toggleterm.nvim"
  },
  ["trouble.nvim"] = {
    config = { "\27LJ\2\nC\0\0\3\0\4\0\a6\0\0\0'\2\1\0B\0\2\0029\0\2\0005\2\3\0B\0\2\1K\0\1\0\1\0\1\nicons\1\nsetup\ftrouble\frequire\0" },
    loaded = true,
    path = "/home/kblack0610/.local/share/nvim/site/pack/packer/start/trouble.nvim",
    url = "https://github.com/folke/trouble.nvim"
  },
  undotree = {
    loaded = true,
    path = "/home/kblack0610/.local/share/nvim/site/pack/packer/start/undotree",
    url = "https://github.com/mbbill/undotree"
  },
  ["vim-fugitive"] = {
    loaded = true,
    path = "/home/kblack0610/.local/share/nvim/site/pack/packer/start/vim-fugitive",
    url = "https://github.com/tpope/vim-fugitive"
  },
  ["zen-mode.nvim"] = {
    loaded = true,
    path = "/home/kblack0610/.local/share/nvim/site/pack/packer/start/zen-mode.nvim",
    url = "https://github.com/folke/zen-mode.nvim"
  }
}

time([[Defining packer_plugins]], false)
-- Config for: toggleterm.nvim
time([[Config for toggleterm.nvim]], true)
try_loadstring("\27LJ\2\n8\0\0\3\0\3\0\0066\0\0\0'\2\1\0B\0\2\0029\0\2\0B\0\1\1K\0\1\0\nsetup\15toggleterm\frequire\0", "config", "toggleterm.nvim")
time([[Config for toggleterm.nvim]], false)
-- Config for: Comment.nvim
time([[Config for Comment.nvim]], true)
try_loadstring("\27LJ\2\nª\1\0\0\6\0\a\0\r6\0\0\0'\2\1\0B\0\2\0029\0\2\0005\2\5\0006\3\0\0'\5\3\0B\3\2\0029\3\4\3B\3\1\2=\3\6\2B\0\2\1K\0\1\0\rpre_hook\1\0\1\rpre_hook\0\20create_pre_hook7ts_context_commentstring.integrations.comment_nvim\nsetup\fComment\frequire\0", "config", "Comment.nvim")
time([[Config for Comment.nvim]], false)
-- Config for: supermaven-nvim
time([[Config for supermaven-nvim]], true)
try_loadstring("\27LJ\2\nÊ\2\0\0\4\0\n\0\r6\0\0\0'\2\1\0B\0\2\0029\0\2\0005\2\3\0005\3\4\0=\3\5\0025\3\6\0=\3\a\0025\3\b\0=\3\t\2B\0\2\1K\0\1\0\ncolor\1\0\1\ncterm\3ô\1\21ignore_filetypes\1\0\2\amd\2\bcpp\2\fkeymaps\1\0\3\16accept_word\n<C-j>\22accept_suggestion\n<Tab>\21clear_suggestion\n<C-]>\1\0\a\15identifier\15supermaven\ncolor\0\fkeymaps\0\21ignore_filetypes\0\20disable_keymaps\1\30disable_inline_completion\1\14log_level\tinfo\nsetup\20supermaven-nvim\frequire\0", "config", "supermaven-nvim")
time([[Config for supermaven-nvim]], false)
-- Config for: trouble.nvim
time([[Config for trouble.nvim]], true)
try_loadstring("\27LJ\2\nC\0\0\3\0\4\0\a6\0\0\0'\2\1\0B\0\2\0029\0\2\0005\2\3\0B\0\2\1K\0\1\0\1\0\1\nicons\1\nsetup\ftrouble\frequire\0", "config", "trouble.nvim")
time([[Config for trouble.nvim]], false)
-- Config for: conform.nvim
time([[Config for conform.nvim]], true)
try_loadstring("\27LJ\2\n5\0\0\3\0\3\0\0066\0\0\0'\2\1\0B\0\2\0029\0\2\0B\0\1\1K\0\1\0\nsetup\fconform\frequire\0", "config", "conform.nvim")
time([[Config for conform.nvim]], false)
-- Config for: gp.nvim
time([[Config for gp.nvim]], true)
try_loadstring("\27LJ\2\nµ\16\0\0\6\0)\0r5\0\3\0006\1\0\0009\1\1\1'\3\2\0B\1\2\2=\1\4\0005\1\a\0005\2\5\0006\3\0\0009\3\1\3'\5\2\0B\3\2\2=\3\6\2=\2\b\0015\2\t\0006\3\0\0009\3\1\3'\5\n\0B\3\2\2=\3\6\2=\2\v\1=\1\f\0004\1\v\0005\2\r\0>\2\1\0015\2\14\0005\3\15\0=\3\16\0026\3\17\0'\5\18\0B\3\2\0029\3\19\3=\3\20\2>\2\2\0015\2\21\0005\3\22\0=\3\16\0026\3\17\0'\5\18\0B\3\2\0029\3\19\3=\3\20\2>\2\3\0015\2\23\0005\3\24\0=\3\16\0026\3\17\0'\5\18\0B\3\2\0029\3\19\3=\3\20\2>\2\4\0015\2\25\0005\3\26\0=\3\16\0026\3\17\0'\5\18\0B\3\2\0029\3\19\3=\3\20\2>\2\5\0015\2\27\0005\3\28\0=\3\16\0026\3\17\0'\5\18\0B\3\2\0029\3\29\3=\3\20\2>\2\6\0015\2\30\0005\3\31\0=\3\16\0026\3\17\0'\5\18\0B\3\2\0029\3\29\3=\3\20\2>\2\a\0015\2 \0005\3!\0=\3\16\0026\3\17\0'\5\18\0B\3\2\0029\3\29\3=\3\20\2>\2\b\0015\2\"\0005\3#\0=\3\16\0026\3\17\0'\5\18\0B\3\2\0029\3\29\3=\3\20\2>\2\t\0015\2$\0005\3%\0=\3\16\0026\3\17\0'\5\18\0B\3\2\0029\3\29\3=\3\20\2>\2\n\1=\1&\0006\1\17\0'\3'\0B\1\2\0029\1(\1\18\3\0\0B\1\2\1K\0\1\0\nsetup\agp\vagents\1\0\4\ntop_p\3\1\16temperature\4š³æÌ\t™³æþ\3\nmin_p\4š³æÌ\t™³¦ý\3\nmodel\rllama3.1\1\0\6\tname\26CodeOllamaLlama3.1-8B\18system_prompt\0\fcommand\2\nmodel\0\tchat\2\rprovider\vollama\1\0\3\ntop_p\3\1\16temperature\4š³æÌ\t™³¦ÿ\3\nmodel\28claude-3-haiku-20240307\1\0\6\tname\23CodeClaude-3-Haiku\18system_prompt\0\fcommand\2\nmodel\0\tchat\2\rprovider\14anthropic\1\0\3\ntop_p\3\1\16temperature\4š³æÌ\t™³¦ÿ\3\nmodel\31claude-3-5-sonnet-20240620\1\0\6\tname\26CodeClaude-3-5-Sonnet\18system_prompt\0\fcommand\2\nmodel\0\tchat\2\rprovider\14anthropic\1\0\4\ntop_p\3\1\16temperature\4š³æÌ\t™³¦ÿ\3\6n\3\1\nmodel\vgpt-4o\1\0\6\tname\16CodeCopilot\18system_prompt\0\fcommand\2\nmodel\0\tchat\1\rprovider\fcopilot\23code_system_prompt\1\0\3\ntop_p\3\1\16temperature\4š³æÌ\t™³¦ÿ\3\nmodel\vgpt-4o\1\0\6\tname\14CodeGPT4o\18system_prompt\0\fcommand\2\nmodel\0\tchat\1\rprovider\vopenai\1\0\3\ntop_p\3\1\16temperature\4š³æÌ\t™³¦ÿ\3\nmodel\28claude-3-haiku-20240307\1\0\6\tname\23ChatClaude-3-Haiku\18system_prompt\0\fcommand\1\nmodel\0\tchat\2\rprovider\14anthropic\1\0\3\ntop_p\3\1\16temperature\4š³æÌ\t™³¦ÿ\3\nmodel\31claude-3-5-sonnet-20240620\1\0\6\tname\26ChatClaude-3-5-Sonnet\18system_prompt\0\fcommand\1\nmodel\0\tchat\2\rprovider\14anthropic\1\0\3\ntop_p\3\1\16temperature\4š³æÌ\t™³Æÿ\3\nmodel\vgpt-4o\1\0\6\tname\16ChatCopilot\18system_prompt\0\fcommand\1\nmodel\0\tchat\2\rprovider\fcopilot\18system_prompt\23chat_system_prompt\16gp.defaults\frequire\nmodel\1\0\3\ntop_p\3\1\16temperature\4š³æÌ\t™³Æÿ\3\nmodel\vgpt-4o\1\0\5\tchat\2\fcommand\1\nmodel\0\tname\14ChatGPT4o\18system_prompt\0\1\0\2\tname\25ExampleDisabledAgent\fdisable\2\14providers\14anthropic\22ANTHROPIC_API_KEY\1\0\3\rendpoint*https://api.anthropic.com/v1/messages\fdisable\1\vsecret\0\vopenai\1\0\2\14anthropic\0\vopenai\0\vsecret\1\0\3\rendpoint/https://api.openai.com/v1/chat/completions\fdisable\1\vsecret\0\19openai_api_key\1\0\3\14providers\0\19openai_api_key\0\vagents\0\19OPENAI_API_KEY\vgetenv\aos\0", "config", "gp.nvim")
time([[Config for gp.nvim]], false)
-- Config for: codeium.nvim
time([[Config for codeium.nvim]], true)
try_loadstring("\27LJ\2\n9\0\0\3\0\3\0\a6\0\0\0'\2\1\0B\0\2\0029\0\2\0004\2\0\0B\0\2\1K\0\1\0\nsetup\fcodeium\frequire\0", "config", "codeium.nvim")
time([[Config for codeium.nvim]], false)

_G._packer.inside_compile = false
if _G._packer.needs_bufread == true then
  vim.cmd("doautocmd BufRead")
end
_G._packer.needs_bufread = false

if should_profile then save_profiles() end

end)

if not no_errors then
  error_msg = error_msg:gsub('"', '\\"')
  vim.api.nvim_command('echohl ErrorMsg | echom "Error in packer_compiled: '..error_msg..'" | echom "Please check your config for correctness" | echohl None')
end
