return {
    "ThePrimeagen/harpoon",
    lazy = false,
    branch = "harpoon2",
    config = function()
        local harpoon = require "harpoon"
        harpoon:setup {
            settings = {
                save_on_toggle = true, -- Save items deleted/changed on the UI when you close
            },
            default = {
                select = function(list_item, list, options)
                    if list_item == nil then
                        return
                    end
                    local bufnr = vim.fn.bufnr(list_item.value)
                    local set_position = false
                    if bufnr == -1 then
                        set_position = true
                        bufnr = vim.fn.bufadd(list_item.value)
                    end
                    vim.api.nvim_set_current_buf(bufnr)
                    vim.bo[bufnr].buflisted = true
                    if set_position and list_item.context and list_item.context.row and list_item.context.col then
                        vim.api.nvim_win_set_cursor(0, { list_item.context.row, list_item.context.col })
                    end
                end,
            },
        }

        local harpoon_extensions = require("harpoon.extensions")
        harpoon:extend(harpoon_extensions.builtins.highlight_current_file())
        vim.keymap.set("n", "<leader>a", function() harpoon:list():add() end)
        vim.keymap.set(
            "n",
            "<C-e>",
            function()
                harpoon.ui:toggle_quick_menu(harpoon:list(), {
                    border = "rounded",
                    title_pos = "center",
                    ui_width_ratio = 0.4,
                })
            end
        )
        -- Kitty hack, these are bound to alt, but kitty is binding ctrl + KEY to send this as well
        -- see kitty.conf
        vim.keymap.set("n", "<C-h>", function() harpoon:list():select(1) end)
        vim.keymap.set("n", "<C-j>", function() harpoon:list():select(2) end)
        vim.keymap.set("n", "<C-k>", function() harpoon:list():select(3) end)
        vim.keymap.set("n", "<C-l>", function() harpoon:list():select(4) end)
        vim.keymap.set("n", "<C-n>", function() harpoon:list():select(5) end)
        vim.keymap.set("n", "<C-m>", function() harpoon:list():select(6) end)
    end,
    dependencies = { "nvim-lua/plenary.nvim" },

}
