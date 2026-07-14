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

      -- Task priority tags. These are plain `#hashtags` at the END of a task
      -- line, so the `notes` CLI indexes them (discoverable via `notes tags` /
      -- <leader>nt, greppable via `notes tags urgent`) and they never collide
      -- with markdown `# headings` (which are line-start only).
      --   Cycle order: (none) -> #low -> #high -> #urgent -> (none)
      --   Keymap:      <leader>tp  (sibling of <leader>t checkbox toggle)
      local PRIORITIES = { "low", "high", "urgent" }

      -- Return (base_without_tag, current_level_or_nil): strip a trailing
      -- priority tag (with any leading spaces) and trim trailing whitespace.
      local function strip_priority(line)
        for _, p in ipairs(PRIORITIES) do
          local stripped, n = line:gsub("%s*#" .. p .. "%s*$", "")
          if n > 0 then
            return (stripped:gsub("%s+$", "")), p
          end
        end
        return (line:gsub("%s+$", "")), nil
      end

      -- Next level in the cycle; nil means "back to no tag".
      local function next_priority(current)
        if current == nil then
          return "low"
        elseif current == "low" then
          return "high"
        elseif current == "high" then
          return "urgent"
        end
        return nil -- urgent -> none
      end

      -- Cycle the priority tag on a range. The next level is computed from the
      -- FIRST line and applied to every line, so a visual selection converges
      -- to a single priority.
      local function cycle_priority(line1, line2)
        local _, first = strip_priority(vim.fn.getline(line1))
        local nxt = next_priority(first)
        for lnum = line1, line2 do
          local base = strip_priority(vim.fn.getline(lnum))
          if nxt then
            local tag = "#" .. nxt
            vim.fn.setline(lnum, base == "" and tag or (base .. " " .. tag))
          else
            vim.fn.setline(lnum, base)
          end
        end
      end

      -- Overlay colors for the priority tags (matchadd draws above treesitter).
      -- `default = true` yields to any user/colorscheme override.
      vim.api.nvim_set_hl(0, "TaskPriorityUrgent", { link = "DiagnosticError", default = true })
      vim.api.nvim_set_hl(0, "TaskPriorityHigh", { link = "DiagnosticWarn", default = true })
      vim.api.nvim_set_hl(0, "TaskPriorityLow", { link = "Comment", default = true })

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

          -- Task priority cycle: current line (normal) / selection (visual).
          vim.keymap.set("n", "<leader>tp", function()
            local lnum = vim.api.nvim_win_get_cursor(0)[1]
            cycle_priority(lnum, lnum)
          end, { buffer = buf, desc = "Cycle task priority (#low/#high/#urgent)", silent = true })
          vim.keymap.set("x", "<leader>tp", function()
            vim.cmd "normal! \27"
            cycle_priority(vim.fn.line "'<", vim.fn.line "'>")
          end, { buffer = buf, desc = "Cycle task priority (#low/#high/#urgent)", silent = true })
        end,
      })

      -- Color the priority tags. matchadd is window-local, so (re)apply it once
      -- per window showing a markdown buffer; a window flag prevents duplicates.
      -- BufWinEnter fires whenever the buffer is displayed in a window (open,
      -- split), which is exactly when a fresh window needs its matches.
      vim.api.nvim_create_autocmd("BufWinEnter", {
        pattern = "*.md",
        callback = function()
          if vim.w.task_priority_matched then
            return
          end
          vim.w.task_priority_matched = true
          vim.fn.matchadd("TaskPriorityUrgent", [[#urgent\>]])
          vim.fn.matchadd("TaskPriorityHigh", [[#high\>]])
          vim.fn.matchadd("TaskPriorityLow", [[#low\>]])
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
