-- NOTE: this should only be for general mappings, try to define plugin specific mapping in the lazy setup under "keys"
-- NOTE: A LOT of mappings are in snacks.nvim

-- Leader key mapping
vim.g.mapleader = " "

-- better j and k
vim.keymap.set(
  { "n", "x" },
  "j",
  "v:count == 0 ? 'gj' : 'j'",
  { expr = true, silent = true, desc = "Move cursor down" }
)

vim.keymap.set("v", "J", ":m '>+1<CR>gv=gv", { desc = "Move selection down" })
vim.keymap.set("v", "K", ":m '<-2<CR>gv=gv", { desc = "Move selection up" })

vim.keymap.set("n", "J", "mzJ`z", { desc = "Join line (keep cursor)" })
vim.keymap.set("n", "<C-d>", "<C-d>zz", { desc = "Half-page down (center)" })
vim.keymap.set("n", "<C-u>", "<C-u>zz", { desc = "Half-page up (center)" })
vim.keymap.set("n", "n", "nzzzv", { desc = "Next search (center)" })
vim.keymap.set("n", "N", "Nzzzv", { desc = "Prev search (center)" })

-- greatest remap ever
vim.keymap.set("x", "<leader>p", [["_dP]], { desc = "Paste over (keep register)" })

-- next greatest remap ever : asbjornHaland
vim.keymap.set({"n", "v"}, "<leader>y", [["+y]], { desc = "Yank to system clipboard" })
vim.keymap.set("n", "<leader>Y", [["+Y]], { desc = "Yank line to system clipboard" })

vim.keymap.set({"n", "v"}, "<leader>d", [["_d]], { desc = "Delete to blackhole" })

-- This is going to get me cancelled
vim.keymap.set("i", "<C-c>", "<Esc>", { desc = "Escape (insert)" })

vim.keymap.set("n", "Q", "<nop>", { desc = "Disabled (ex mode)" })
vim.keymap.set("n", "<C-f>", "<cmd>silent !tmux neww tmux-sessionizer<CR>", { desc = "tmux sessionizer" })
-- <leader>f is defined in plugins/conform.lua (conform format with LSP fallback) so it
-- doesn't error on filetypes the LSP can't format (e.g. brightscript -> bsfmt).

vim.keymap.set("n", "<C-k>", "<cmd>cnext<CR>zz", { desc = "Next quickfix (center)" })
vim.keymap.set("n", "<C-j>", "<cmd>cprev<CR>zz", { desc = "Prev quickfix (center)" })
vim.keymap.set("n", "<leader>k", "<cmd>lnext<CR>zz", { desc = "Next loclist (center)" })
vim.keymap.set("n", "<leader>j", "<cmd>lprev<CR>zz", { desc = "Prev loclist (center)" })

vim.keymap.set("n", "<leader>x", "<cmd>!chmod +x %<CR>", { silent = true, desc = "Make file executable" })

vim.keymap.set("n", "<leader>vpp", "<cmd>e ~/.dotfiles/.config/nvim/lua/kennethblack/lazy.lua<CR>", { desc = "Edit lazy config" });
vim.keymap.set("n", "<leader>mr", "<cmd>CellularAutomaton make_it_rain<CR>", { desc = "Make it rain" });

-- :so USE THIS TO RESOURCE NVIM.
vim.keymap.set("n", "<leader><leader>", function()
    vim.cmd("so")
end, { desc = "Source current file" })

-- Edit and reload nvim config file quickly
vim.keymap.set("n", "<leader>se", "<cmd>tabnew ~/.dotfiles <bar> tcd %:h<cr>", {
  silent = true,
  desc = "open init.lua",
})

-- Quit all opened buffers
vim.keymap.set("n", "<leader>Q", "<cmd>qa!<cr>", { silent = true, desc = "quit nvim" })

-- Go to the beginning and end of current line in insert mode quickly
vim.keymap.set("i", "<C-A>", "<HOME>", { desc = "Line start (insert)" })
vim.keymap.set("i", "<C-E>", "<END>", { desc = "Line end (insert)" })

vim.keymap.set("n", "L", "<C-w>w", { desc = "Next window" })
vim.keymap.set("n", "H", "<C-w>W", { desc = "Prev window" })

-- NOTE: go throgh these anre remove unnecessary
--- need to look through and update

vim.keymap.set({ "n", "x" }, "k", "v:count == 0 ? 'gk' : 'k'", { expr = true, silent = true, desc = "Move cursor up" })
-- Key to clear highlight search
vim.keymap.set("n", "<leader>h", ":nohlsearch<CR>", { desc = "Clear search highlight" })
-- save and quit mappings
vim.keymap.set("n", "<leader>w", "<cmd>w<cr>", { desc = "Save" })
vim.keymap.set("n", "<leader>W", "<cmd>wa<cr>", { desc = "Save All" })
vim.keymap.set("n", "<leader>q", "<cmd>confirm q<cr>", { desc = "Quit" })
-- blackhole delete
vim.keymap.set({ "n", "v" }, "<leader>p", '"_dP', { desc = "Paste over (keep register)" })
-- Center text when moving with C-d and C-u
vim.keymap.set("n", "<C-d>", "<C-d>zz", { desc = "Half-page down (center)" })
vim.keymap.set("n", "<C-u>", "<C-u>zz", { desc = "Half-page up (center)" })
-- tmux sessionizer in nvim
vim.keymap.set("n", "<C-f>", "<cmd>silent !tmux neww ~/.config/bin/tmux-sessionizer.sh<CR>", { desc = "tmux sessionizer" })
-- copy current file name
vim.keymap.set(
  "n",
  "<leader>cf",
  '<cmd>let @+ = fnamemodify(expand("%:p"), ":.")<cr>',
  { desc = "Copy current file path" }
)
-- Show diagnostics with lsp that outputted it
-- This opens a float with diag info
vim.keymap.set("n", "<leader>ld", function()
  vim.diagnostic.open_float(nil, {
    border = "rounded",
    -- Customize how each diagnostic is formatted
    format = function(diagnostic)
      if diagnostic.source then
        return string.format("[%s] %s", diagnostic.source, diagnostic.message)
      else
        return diagnostic.message
      end
    end,
    prefix = "", -- Remove prefix aka numbered list
    header = "", -- Remove the title
  })
end, { desc = "Show diagnostics with source" })
