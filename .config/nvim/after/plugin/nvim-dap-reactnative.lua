
local dap = require('dap')
--
-- -- using modules
-- M.config = {
-- 	adapters = {
-- 		type = "executable",
-- 		command = "node",
-- 		args = { dbg_path .. "vscode-node-debug2/out/src/nodeDebug.js" },
-- 	},
-- 	configurations = {
-- 		{
-- 			type = "node2",
-- 			request = "attach",
-- 			program = "${file}",
-- 			cwd = fn.getcwd(),
-- 			sourceMaps = true,
-- 			protocol = "inspector",
-- 			console = "integratedTerminal",
-- 			port = 35000
-- 		},
-- 	},
-- }
--
-- -- OR
-- -- directly - typescript react example
--
dap.adapters.node2 = {
	type = "executable",
	command = "node",
	args = { os.getenv("HOME") .. "/vscode-node-debug2/out/src/nodeDebug.js" },
}


dap.configurations.typescriptreact = {
	{
		name = "React native",
		type = "node2",
		request = "attach",
		program = "${file}",
		cwd = vim.fn.getcwd(),
		sourceMaps = true,
		protocol = "inspector",
		console = "integratedTerminal",
		port = 35000,
	},
}
