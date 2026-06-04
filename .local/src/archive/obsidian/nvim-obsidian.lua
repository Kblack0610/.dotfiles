return {
  "epwalsh/obsidian.nvim",
  version = "*",
  lazy = true,
  ft = "markdown",
  dependencies = { "nvim-lua/plenary.nvim" },
  opts = {
    workspaces = {
      { name = "notes", path = "~/.notes" },
    },
    daily_notes = {
      folder = "journal/daily",
      date_format = "%Y-%m-%d",
    },
    completion = {
      nvim_cmp = false, -- using blink.cmp
      min_chars = 2,
    },
    mappings = {
      ["gf"] = {
        action = function()
          return require("obsidian").util.gf_passthrough()
        end,
        opts = { noremap = false, expr = true, buffer = true },
      },
      ["<CR>"] = {
        action = function()
          return require("obsidian").util.smart_action()
        end,
        opts = { buffer = true, expr = true },
      },
      ["<leader>ch"] = {
        action = function()
          return require("obsidian").util.toggle_checkbox()
        end,
        opts = { buffer = true },
      },
      -- Quick binary toggle ([ ] ↔ [x])
      ["<leader>ct"] = {
        action = function()
          local line = vim.api.nvim_get_current_line()
          local new_line
          if line:match("%- %[ %]") then
            new_line = line:gsub("%- %[ %]", "- [x]", 1)
          elseif line:match("%- %[x%]") then
            new_line = line:gsub("%- %[x%]", "- [ ]", 1)
          else
            return
          end
          vim.api.nvim_set_current_line(new_line)
        end,
        opts = { buffer = true, desc = "Quick toggle checkbox" },
      },
      -- Quick create task
      ["<leader>ta"] = {
        action = function()
          vim.api.nvim_put({ "- [ ] " }, "l", true, true)
          vim.cmd("startinsert!")
        end,
        opts = { buffer = true, desc = "Add new task" },
      },
    },
    ui = { enable = false }, -- using render-markdown.nvim instead
  },
}
