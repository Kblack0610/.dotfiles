-- Markdown: in-editor rendering + live browser preview.
-- See ~/.dotfiles/.local/bin/md-export for file export (pandoc HTML/PDF)
-- and the `marp-slide` skill / `marp` CLI for slide decks.
return {
  -- 1) In-editor rendering (headers, tables, code blocks) ---------------------
  {
    "MeanderingProgrammer/render-markdown.nvim",
    ft = { "markdown" }, -- only load when opening a markdown file
    config = function()
      require("render-markdown").setup {
        file_types = { "markdown" },
        render_modes = { "n", "v", "V", "i", "c" }, -- render markdown in all modes
        code = {
          sign = false,
          style = "normal",
          width = "block",
        },
      }

      -- Toggle markdown task checkboxes: `- [ ]` <-> `- [x]`.
      -- Operates on the current line (normal) or every line in the visual
      -- selection (visual). Replaces the old obsidian.nvim :ObsidianToggleCheckbox.
      local function toggle_checkbox(line1, line2)
        for lnum = line1, line2 do
          local line = vim.fn.getline(lnum)
          local toggled
          if line:match "%[ %]" then
            toggled = line:gsub("%[ %]", "[x]", 1)
          elseif line:match "%[[xX]%]" then
            toggled = line:gsub("%[[xX]%]", "[ ]", 1)
          end
          if toggled then
            vim.fn.setline(lnum, toggled)
          end
        end
      end
      -- Only allow keybindings in markdown files
      vim.api.nvim_create_autocmd("Filetype", {
        pattern = "markdown",
        callback = function()
          local buf = vim.api.nvim_get_current_buf()
          vim.api.nvim_buf_set_keymap(
            buf,
            "n",
            "<leader>mt",
            "<CMD>RenderMarkdown toggle<CR>",
            { desc = "Markdown toggle", silent = true }
          )
          vim.api.nvim_buf_set_keymap(
            buf,
            "n",
            "<leader>me",
            "<CMD>RenderMarkdown enable<CR>",
            { desc = "Markdown enable", silent = true }
          )
          vim.api.nvim_buf_set_keymap(
            buf,
            "n",
            "<leader>md",
            "<CMD>RenderMarkdown disable<CR>",
            { desc = "Markdown disable", silent = true }
          )
          -- Task checkbox toggle: current line (normal) / selection (visual).
          vim.keymap.set("n", "<leader>t", function()
            local lnum = vim.api.nvim_win_get_cursor(0)[1]
            toggle_checkbox(lnum, lnum)
          end, { buffer = buf, desc = "Toggle task checkbox", silent = true })
          vim.keymap.set("x", "<leader>t", function()
            -- Leave visual mode so '< and '> marks are set, then toggle the range.
            vim.cmd "normal! \27"
            toggle_checkbox(vim.fn.line "'<", vim.fn.line "'>")
          end, { buffer = buf, desc = "Toggle task checkbox(es)", silent = true })
        end,
      })
    end,
  },

  -- 2) Live browser preview (scroll-synced) — best for client screen-share ----
  {
    "iamcco/markdown-preview.nvim",
    ft = { "markdown" },
    build = function()
      vim.fn["mkdp#util#install"]() -- uses yarn/node
    end,
    keys = {
      { "<leader>mp", "<cmd>MarkdownPreviewToggle<cr>", desc = "Markdown preview (browser)", ft = "markdown" },
    },
    init = function()
      vim.g.mkdp_auto_close = 1
      vim.g.mkdp_theme = "dark" -- match tokyonight
      -- vim.g.mkdp_browser = "..."  -- optional: pin a presentation browser/profile
    end,
  },
}
