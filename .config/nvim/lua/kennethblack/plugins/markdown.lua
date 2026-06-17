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
