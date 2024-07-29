local on_attach = function(_, bufnr)
	local opts = { noremap = true, silent = true, buffer = bufnr }
	vim.keymap.set("n", "<leader>bo", "<cmd>lua vim.lsp.buf.document_symbol()<CR>", opts)
	vim.keymap.set("n", "gd", "<Cmd>lua vim.lsp.buf.definition()<CR>", opts)
	vim.keymap.set("n", "gD", "<Cmd>lua vim.lsp.buf.declaration()<CR>", opts)
	vim.keymap.set("n", "K", "<Cmd>lua vim.lsp.buf.hover()<CR>", opts)
	vim.keymap.set("n", "gi", "<cmd>lua vim.lsp.buf.implementation()<CR>", opts)
	vim.keymap.set("n", "<C-k>", "<cmd>lua vim.lsp.buf.signature_help()<CR>", opts)
	vim.keymap.set("n", "<leader>wa", "<cmd>lua vim.lsp.buf.add_workspace_folder()<CR>", opts)
	vim.keymap.set("n", "<leader>wr", "<cmd>lua vim.lsp.buf.remove_workspace_folder()<CR>", opts)
	vim.keymap.set("n", "<leader>wl", "<cmd>lua print(vim.inspect(vim.lsp.buf.list_workspace_folders()))<CR>", opts)
	vim.keymap.set("n", "<leader>D", "<cmd>lua vim.lsp.buf.type_definition()<CR>", opts)
	vim.keymap.set("n", "<leader>rn", "<cmd>lua vim.lsp.buf.rename()<CR>", opts)
	vim.keymap.set("n", "<leader>ca", "<cmd>lua vim.lsp.buf.code_action()<CR>", opts)
	vim.keymap.set("n", "gr", "<cmd>lua vim.lsp.buf.references()<CR>", opts)
	vim.keymap.set("n", "<leader>e", "<cmd>lua vim.diagnostic.open_float()<CR>", opts)
	vim.keymap.set("n", "[d", "<cmd>lua vim.diagnostic.goto_prev()<CR>", opts)
	vim.keymap.set("n", "]d", "<cmd>lua vim.diagnostic.goto_next()<CR>", opts)
	vim.keymap.set("n", "<leader>dl", "<cmd>lua vim.lsp.diagnostic.setloclist()<CR>", opts)
end

local rounded_border_handlers = {
	["textDocument/hover"] = vim.lsp.with(vim.lsp.handlers.hover, { border = "rounded" }),
	["textDocument/signatureHelp"] = vim.lsp.with(vim.lsp.handlers.signature_help, { border = "rounded" }),
}

require'cmp'.setup {
  sources = {
    { name = 'nvim_lsp' }
  }
}
local capabilities = vim.lsp.protocol.make_client_capabilities()
capabilities = require("cmp_nvim_lsp").default_capabilities(capabilities)

local conform = require("conform")

conform.setup({
	formatters_by_ft = {
		cs = { "csharpier" },
		css = { "prettier" },
		go = { "gofmt" },
		html = { "prettier" },
		javascript = { "prettier" },
		lua = { "stylua" },
		zig = { "zigfmt" },
		rust = { "rustfmt" },
		python = { "black" },
	},
})
vim.keymap.set({ "n", "v" }, "<leader>f", function()
	conform.format({
		lsp_fallback = true,
		async = false,
	})
end)

//TODO REMOVE ABOVE THIS, JUST USE LSPCONFIG FOR OMNISHARP PATH USE LSP ZERO FOR REST.
require("mason").setup()
require("mason-lspconfig").setup({
	ensure_installed = {
		"lua_ls",
        "tsserver",   
		-- "gopls",
		"omnisharp",
		-- "zls",
	},
})

require("mason-lspconfig").setup_handlers({
	function(server_name)
		require("lspconfig")[server_name].setup({
			on_attach = on_attach,
			capabilities = capabilities,
			handlers = rounded_border_handlers,
		})
	end,
	["omnisharp"] = function()
		require("lspconfig")["omnisharp"].setup({
			on_attach = on_attach,
			capabilities = capabilities,
			root_dir = function(fname)
				local lspconfig = require("lspconfig")
				local primary = lspconfig.util.root_pattern("*.sln")(fname)
				local fallback = lspconfig.util.root_pattern("*.csproj")(fname)
				return primary or fallback
			end,
			analyze_open_documents_only = true,
			organize_imports_on_format = true,
			handlers = vim.tbl_extend("force", rounded_border_handlers, {
				["textDocument/definition"] = require("omnisharp_extended").handler,
			}),
		})
	end,
	-- ["gopls"] = function()
	-- 	require("lspconfig")["gopls"].setup({
	-- 		on_attach = on_attach,
	-- 		capabilities = capabilities,
	-- 		handlers = rounded_border_handlers,
	-- 		settings = {
	-- 			gopls = {
	-- 				analyses = {
	-- 					unusedparams = true,
	-- 				},
	-- 				staticcheck = true,
	-- 				templateExtensions = { "gohtml" },
	-- 			},
	-- 		},
	-- 	})
	-- end,
	["lua_ls"] = function()
		local lua_runtime_path = vim.split(package.path, ";")
		table.insert(lua_runtime_path, "lua/?.lua")
		table.insert(lua_runtime_path, "lua/?/init.lua")

		require("lspconfig")["lua_ls"].setup({
			on_attach = on_attach,
			capabilities = capabilities,

			handlers = rounded_border_handlers,
			settings = {
				Lua = {
					runtime = {
						version = "LuaJIT",
						path = lua_runtime_path,
					},
					diagnostics = {
						globals = { "vim" },

					},
					workspace = {
						library = vim.api.nvim_get_runtime_file("", true),
						checkThirdParty = false,
					},
					telemetry = {
						enable = false,
					},
				},
			},
		})
	end,
})

-- Use an on_attach function to only map the following keys
-- after the language server attaches to the current buffer
local on_attach = function(client, bufnr)
  local function buf_set_keymap(...) vim.api.nvim_buf_set_keymap(bufnr, ...) end
  local function buf_set_option(...) vim.api.nvim_buf_set_option(bufnr, ...) end

  -- Omnicompletion
  buf_set_option('omnifunc', 'v:lua.vim.lsp.omnifunc')

  local opts = { noremap=true, silent=true }
  buf_set_keymap('n', 'gD', '<cmd>lua vim.lsp.buf.declaration()<CR>', opts)
  buf_set_keymap('n', 'gd', '<cmd>lua vim.lsp.buf.definition()<CR>', opts)
  buf_set_keymap('n', 'gi', '<cmd>lua vim.lsp.buf.implementation()<CR>', opts)
  buf_set_keymap('n', 'K', '<cmd>lua vim.lsp.buf.hover()<CR>', opts)
  buf_set_keymap('n', '<C-k>', '<cmd>lua vim.lsp.buf.signature_help()<CR>', opts)
  buf_set_keymap('n', '[d', '<cmd>lua vim.diagnostic.goto_prev()<CR>', opts)
  buf_set_keymap('n', ']d', '<cmd>lua vim.diagnostic.goto_next()<CR>', opts)
  buf_set_keymap('n', 'gR', '<cmd>lua vim.lsp.buf.references()<CR>', opts)
end

-- Omnisharp/C#/Unity
local pid = vim.fn.getpid()
local omnisharp_bin = "/opt/omnisharp-roslyn/run"
require'lspconfig'.omnisharp.setup{
    on_attach = on_attach,
    flags = {
      debounce_text_changes = 150,
    },
    cmd = { omnisharp_bin, "--languageserver" , "--hostPID", tostring(pid) };
}
local cmp = require('cmp')

cmp.setup({
  sources = {
    {name = 'nvim_lsp'},
  },
  snippet = {
    expand = function(args)
      require('luasnip').lsp_expand(args.body)
    end,
  },
  mapping = cmp.mapping.preset.insert({}),
})

local lsp_zero = require('lsp-zero')

local lsp_attach = function(client, bufnr)
  -- see :help lsp-zero-keybindings
  -- to learn the available actions
  lsp_zero.default_keymaps({buffer = bufnr})
end

lsp_zero.extend_lspconfig({
  capabilities = require('cmp_nvim_lsp').default_capabilities(),
  lsp_attach = lsp_attach,
  float_border = 'rounded',
  sign_text = true,
})

-- These are just examples. Replace them with the language
-- servers you have installed in your system
-- require('lspconfig').tsserver.setup({})
-- require('lspconfig').lua_ls.setup({})
-- require('lspconfig').omnisharp.setup({})
-- -- SETUP
--
-- local lsp = require('lsp-zero').preset({
--     name = 'minimal',
--     signs = true,
--     set_lsp_keymaps = true,
--     manage_nvim_cmp = true,
--     suggest_lsp_servers = false,
--     -- sign_icons = {
--     --     error = 'E',
--     --     warn = 'W',
--     --     hint = 'H',
--     --     info = 'I'
--     -- },
--     -- severity_sort = false,
--     -- suggest_lsp_servers = false,
--     -- update_in_insert = false,
--     underline = false,
-- })
--
-- --todo might remove
-- vim.lsp.handlers["textDocument/publishDiagnostics"] =
--     vim.lsp.with(vim.lsp.diagnostic.on_publish_diagnostics, {
--         -- Disable underline, it's very annoying
--         underline = true,
--         -- Enable virtual text, override spacing to 4
--         virtual_text = true,
--         signs = true,
--         update_in_insert = true 
--     })
--     
-- lsp.nvim_workspace()
--
-- -- SPECIFIC LANGUAGE SERVER CONFIGURATIONS
-- -- todo Fix Undefined global 'vim'
-- lsp.ensure_installed({ 'tsserver' })
--
-- lsp.configure('lua-language-server', {
--     settings = {
--         Lua = {
--             diagnostics = {
--                 globals = { 'vim' }
--             }
--         }
--     }
-- })
--
--
-- lsp.configure('omnisharp-mono', {
--   on_attach = function(client, bufnr)
--     print('hello omnisharp mono')
--   end,
--
-- })
--
-- require'lspconfig'.tsserver.setup{}
--
-- -- POSSIBLY BULLSHIT
-- local cmp = require('cmp')
-- local cmp_select = { behavior = cmp.SelectBehavior.Select }
-- local cmp_mappings = lsp.defaults.cmp_mappings({
--     ['<C-p>'] = cmp.mapping.select_prev_item(cmp_select),
--     ['<C-n>'] = cmp.mapping.select_next_item(cmp_select),
--     ['<C-y>'] = cmp.mapping.confirm({ select = true }),
--     ["<C-Space>"] = cmp.mapping.complete(),
-- })
-- local cmp_select_opts = {behavior = cmp.SelectBehavior.Select}
--
-- cmp.setup({
--   sources = {
--     {name = 'nvim_lsp'},
--   },
--   mapping = {
--     ['<C-y>'] = cmp.mapping.confirm({select = true}),
--     ['<C-e>'] = cmp.mapping.abort(),
--     ['<C-u>'] = cmp.mapping.scroll_docs(-4),
--     ['<C-d>'] = cmp.mapping.scroll_docs(4),
--     ['<Up>'] = cmp.mapping.select_prev_item(cmp_select_opts),
--     ['<Down>'] = cmp.mapping.select_next_item(cmp_select_opts),
--     ['<C-p>'] = cmp.mapping(function()
--       if cmp.visible() then
--         cmp.select_prev_item(cmp_select_opts)
--       else
--         cmp.complete()
--       end
--     end),
--     ['<C-n>'] = cmp.mapping(function()
--       if cmp.visible() then
--         cmp.select_next_item(cmp_select_opts)
--       else
--         cmp.complete()
--       end
--     end),
--   },
--   snippet = {
--     expand = function(args)
--       require('luasnip').lsp_expand(args.body)
--     end,
--   },
--   window = {
--     documentation = {
--       max_height = 15,
--       max_width = 60,
--     }
--   },
--   formatting = {
--     fields = {'abbr', 'menu', 'kind'},
--     format = function(entry, item)
--       local short_name = {
--         nvim_lsp = 'LSP',
--         nvim_lua = 'nvim'
--       }
--
--       local menu_name = short_name[entry.source.name] or entry.source.name
--
--       item.menu = string.format('[%s]', menu_name)
--       return item
--     end,
--   },
-- })
-- cmp_mappings['<Tab>'] = nil
-- cmp_mappings['<S-Tab>'] = nil
--
--
-- lsp.setup_nvim_cmp({
--     mapping = cmp_mappings
-- })
--
-- lsp.on_attach(function(client, bufnr)
--     local opts = { buffer = bufnr, remap = false }
--     lsp_status.on_attach(client)
--     local bufopts = { noremap=true, silent=true, buffer=bufnr }
--     -- vim.keymap.set('n', 'gd', function() vim.lsp.buf.definition{on_list=on_list} end, bufopts)
--     vim.keymap.set('n', 'gd', function() vim.lsp.buf.definition() end, bufopts)
--     vim.keymap.set("n", "gD", function() vim.lsp.buf.declaration() end, opts)
--     vim.keymap.set("n", "K", function() vim.lsp.buf.hover() end, opts)
--
--     vim.keymap.set("n", "[d", function() vim.diagnostic.goto_next() end, opts)
--     vim.keymap.set("n", "]d", function() vim.diagnostic.goto_prev() end, opts)
--
--     -- !!!!!!!!!!!!! NOTE: OPEN FLOAT IS default "gl" on lsp-zero!"
--     
--     -- vim.keymap.set("n", "<leader>xt", function() vim.diagnostic.open_float({scope="line"}) end, opts)
--     --vim.keymap.set("n", "<leader>vx", function() vim.lsp.diagnostic.show_line_diagnostics() end, opts)
--     --
--     -- possibly bs commands
--     -- vim.keymap.set("n", "<leader>vca", function() vim.lsp.buf.code_action() end, opts)
--     -- vim.keymap.set("n", "<leader>vrr", function() vim.lsp.buf.references() end, opts)
--     -- vim.keymap.set("n", "<leader>vrn", function() vim.lsp.buf.rename() end, opts)
--     --vim.set("n", "<leader>vws", function() vim.lsp.buf.workspace_symbol() end, opts)
--     --vim.keymap.set("i", "<C-h>", function() vim.lsp.buf.signature_help() end, opts)
--     
--     -- for unity, TODO might remove?
--     -- if client.name == "omnisharp" then
--     --     client.server_capabilities.semanticTokensProvider = {
--     --         full = vim.empty_dict(),
--     --         legend = {
--     --             tokenModifiers = { "static_symbol" },
--     --             tokenTypes = {
--     --                 "comment",
--     --                 "excluded_code",
--     --                 "identifier",
--     --                 "keyword",
--     --                 "keyword_control",
--     --                 "number",
--     --                 "operator",
--     --                 "operator_overloaded",
--     --                 "preprocessor_keyword",
--     --                 "string",
--     --                 "whitespace",
--     --                 "text",
--     --                 "static_symbol",
--     --                 "preprocessor_text",
--     --                 "punctuation",
--     --                 "string_verbatim",
--     --                 "string_escape_character",
--     --                 "class_name",
--     --                 "delegate_name",
--     --                 "enum_name",
--     --                 "interface_name",
--     --                 "module_name",
--     --                 "struct_name",
--     --                 "type_parameter_name",
--     --                 "field_name",
--     --                 "enum_member_name",
--     --                 "constant_name",
--     --                 "local_name",
--     --                 "parameter_name",
--     --                 "method_name",
--     --                 "extension_method_name",
--     --                 "property_name",
--     --                 "event_name",
--     --                 "namespace_name",
--     --                 "label_name",
--     --                 "xml_doc_comment_attribute_name",
--     --                 "xml_doc_comment_attribute_quotes",
--     --                 "xml_doc_comment_attribute_value",
--     --                 "xml_doc_comment_cdata_section",
--     --                 "xml_doc_comment_comment",
--     --                 "xml_doc_comment_delimiter",
--     --                 "xml_doc_comment_entity_reference",
--     --                 "xml_doc_comment_name",
--     --                 "xml_doc_comment_processing_instruction",
--     --                 "xml_doc_comment_text",
--     --                 "xml_literal_attribute_name",
--     --                 "xml_literal_attribute_quotes",
--     --                 "xml_literal_attribute_value",
--     --                 "xml_literal_cdata_section",
--     --                 "xml_literal_comment",
--     --                 "xml_literal_delimiter",
--     --                 "xml_literal_embedded_expression",
--     --                 "xml_literal_entity_reference",
--     --                 "xml_literal_name",
--     --                 "xml_literal_processing_instruction",
--     --                 "xml_literal_text",
--     --                 "regex_comment",
--     --                 "regex_character_class",
--     --                 "regex_anchor",
--     --                 "regex_quantifier",
--     --                 "regex_grouping",
--     --                 "regex_alternation",
--     --                 "regex_text",
--     --                 "regex_self_escaped_character",
--     --                 "regex_other_escape",
--     --             },
--     --         },
--     --         range = true,
--     --     }
--     -- end
--     client.server_capabilities.semanticTokensProvider.legend = {
--         tokenModifiers = { "static" },
--         tokenTypes = { "comment", "excluded", "identifier", "keyword", "keyword", "number", "operator", "operator", "preprocessor", "string", "whitespace", "text", "static", "preprocessor", "punctuation", "string", "string", "class", "delegate", "enum", "interface", "module", "struct", "typeParameter", "field", "enumMember", "constant", "local", "parameter", "method", "method", "property", "event", "namespace", "label", "xml", "xml", "xml", "xml", "xml", "xml", "xml", "xml", "xml", "xml", "xml", "xml", "xml", "xml", "xml", "xml", "xml", "xml", "xml", "xml", "xml", "regexp", "regexp", "regexp", "regexp", "regexp", "regexp", "regexp", "regexp", "regexp" }
--     }
-- end)
--
-- lsp.setup()
--
--
--
--
--
