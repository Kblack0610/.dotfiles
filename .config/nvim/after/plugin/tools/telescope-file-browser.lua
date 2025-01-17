-- You don't need to set any of these options.
-- IMPORTANT!: this is only a showcase of how you can set default options!
require("telescope").setup {
    extensions = {
        file_browser = {
            theme = "ivy",
            -- theme = "dropdown",
            -- theme = "center",
            -- disables netrw and use telescope-file-browser in its place
            initial_mode = "normal",
            hijack_netrw = true,
            mappings = {
                ["i"] = {
                    -- your custom insert mode mappings
                },
                ["n"] = {
                    -- your custom normal mode mappings
                },
            },
            -- defaults = {
            --     theme = "center",
            --     sorting_strategy = "ascending",
            --     layout_config = {
            --         horizontal = {
            --             prompt_position = "top",
            --             preview_width = 0.3,
            --         },
            --     },
            -- },
        },
    },
}
-- To get telescope-file-browser loaded and working with telescope,
-- you need to call load_extension, somewhere after setup function:
require("telescope").load_extension "file_browser"

vim.keymap.set("n", "<space>pa", ":Telescope file_browser<CR>")

-- open file_browser with the path of the current buffer
-- TODO Fix icons
vim.keymap.set("n", "<space>pv", ":Telescope file_browser path=%:p:h<CR>")

-- -- Alternatively, using lua API
-- vim.keymap.set("n", "<space>fb", function()
-- 	require("telescope").extensions.file_browser.file_browser()
-- end)
