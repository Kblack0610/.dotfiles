return {
    "Kblack0610/harpoon",
    lazy = false,
    branch = "format_path-option",
    config = function()
        local harpoon = require "harpoon"
        harpoon:setup {
            settings = {
                save_on_toggle = true, -- Save items deleted/changed on the UI when you close
            },
            format_path = function(path)
                path = path:gsub("\\", "/")
                local segments = {}
                for seg in string.gmatch(path, "[^/]+") do
                    table.insert(segments, seg)
                end
                local n = #segments
                if n >= 2 then
                    return segments[n-1] .. "/" .. segments[n]
                else
                    return segments[n]
                end
            end,
            -- need to look at new harpoon syntax
            -- display = {
            --     width = vim.api.nvim_win_get_width(0),
            -- }
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
