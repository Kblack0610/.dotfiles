local builtin = require('telescope.builtin')
local actions = require "telescope.actions"
local utils = require("telescope.utils")

require('telescope').setup {
    pickers = {
        buffers = {
            mappings = {
                i = {
                    ["<c-b>"] = actions.delete_buffer + actions.move_to_top,
                }
            }
        }
    },
    defaults = {
        -- for unity
        -- file_ignore_patterns = { "QFSW", "Sirenix", "AstarPathfindingProject", "MonKey Commander", "PrettyHierarchy", "Art", "%.shader", "%.wav", "%.fbx", "%.obj",
        --     "%.exr", "%.ttf", "%.otf", "%.mat", "%.asmdef", "%.asmref", "%.overrideController", "node_modules", "%.prefab",
            -- "%.png", "%.tsm", "%.tmx", "%.gif", "%.PNG", "%.meta", "%.asset", "%.controller", "%.anim", "%.unity" },
            --
        -- when you needs tests
        -- file_ignore_patterns = {"%.snap", "%.meta"},
        -- other stuff
        file_ignore_patterns = {"%.snap","%.meta", '__tests__'},
        -- find_command = { "fd", "-t=f", "-a" },
        -- path_display = { "absolute" },
        wrap_results = true
    },
    extensions = {
        fzf = {
            fuzzy = true, -- false will only do exact matching
            -- override_generic_sorter = true, -- override the generic sorter
            -- override_file_sorter = true, -- override the file sorter
            -- case_mode = "smart_case", -- or "ignore_case" or "respect_case"
            -- the default case_mode is "smart_case"
        }
    }
}


-- vim.keymap.set('n', '<leader>pd', builtin.find_files, {cwd = utils.buffer_dir()})

vim.keymap.set('n', '<leader>pf', builtin.find_files, {})

--require('telescope').load_extension('fzf')
-- vim.keymap.set('n', '<leader>pf', builtin.find_files, {})
-- vim.keymap.set('n', '<leader>pc', builtin.find_files, {default_text = " ", search_dirs = { "/tmp" }})
-- lua require('telescope.builtin').live_grep({default_text = " ", search_dirs = { "/tmp" }})  
vim.keymap.set('n', '<C-p>', builtin.git_files, {})
vim.keymap.set('n', '<leader>ps', function()
    builtin.grep_string({ search = vim.fn.input("Grep > ") })
end)
--
-- vim.keymap.set('n', '<leader>pd', function()
--     builtin.live_grep({ searchdirs = './account' })
-- end)

-- vim.keymap.set("n", "<leader>pd", "<cmd>Telescope live_grep search_dirs=./account/<CR>");

vim.keymap.set('n', '<leader>pg', builtin.live_grep, {})
vim.keymap.set('n', '<leader>pw', builtin.grep_string, {})
vim.keymap.set('n', '<leader>pb', builtin.buffers, {})

