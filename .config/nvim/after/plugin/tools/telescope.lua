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
        -- TODO Make work/unity/other configs at root level
        -- for unity
        -- file_ignore_patterns = { "QFSW", "Sirenix", "AstarPathfindingProject", "MonKey Commander", "PrettyHierarchy",
        --     "Art", "%.shader", "%.wav", "%.fbx", "%.obj",
        --     "%.exr", "%.ttf", "%.otf", "%.mat", "%.asmdef", "%.asmref", "%.overrideController", "node_modules",
        --     "%.prefab",
        --     "%.png", "%.tsm", "%.tmx", "%.gif", "%.PNG", "%.meta", "%.asset", "%.controller", "%.anim", "%.unity" },
        --
        -- WORK
        file_ignore_patterns = { "android", "jest", "apps" },




        -- when you needs tests
        -- file_ignore_patterns = {"%.snap", "%.meta"},
        -- other stuff
        -- file_ignore_patterns = {"%.snap","%.meta", '__tests__'},
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



-- SET DIFFERENT TOGGLE FOR GREP
vim.keymap.set('n', '<leader>pf', "<cmd>Telescope find_files prompt_prefix=🔍<CR>")
vim.keymap.set('n', '<leader>pF',
    "<cmd>Telescope find_files find_command=rg,--ignore,--hidden,--files prompt_prefix=🔍<CR>")
vim.keymap.set("n", "<leader>ps", "<cmd>Telescope find_files search_dirs=%:p:h select_buffer=true<CR>");

vim.keymap.set('n', '<C-p>', builtin.git_files, {})

vim.keymap.set("n", "<leader>pd", "<cmd>Telescope live_grep search_dirs=%:p:h prompt_prefix=🔍<CR>");
vim.keymap.set("n", "<leader>pg", "<cmd>Telescope live_grep prompt_prefix=🔍<CR>");
vim.keymap.set("n", "<leader>pG",
    "<cmd>Telescope live_grep find_command=rg,--ignore,--hidden,--files prompt_prefix=🔍<CR>");

vim.keymap.set('n', '<leader>pw', builtin.grep_string, {})
vim.keymap.set('n', '<leader>pb', builtin.buffers, {})

-- different toggle for grep
-- vim.keymap.set('n', '<leader>ps', function()
--     builtin.grep_string({ search = vim.fn.input("Grep > ") })
-- end)
