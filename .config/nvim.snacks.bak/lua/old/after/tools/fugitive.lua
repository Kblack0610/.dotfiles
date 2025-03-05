vim.keymap.set("n", "<leader>gs", vim.cmd.Git);
vim.keymap.set("n", "<leader>gg", "<cmd>Git blame<cr>",
  {silent = true, noremap = true}
)
