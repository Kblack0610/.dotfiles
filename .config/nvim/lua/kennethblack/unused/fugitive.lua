return {
    "tpope/vim-fugitive",
    opts = {
        vim.keymap.set("n", "<leader>gB", "<cmd>Git blame<cr>",
            { silent = true, noremap = true }
        )
    }
}
