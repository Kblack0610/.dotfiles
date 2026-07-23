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
      --   Keymap:      <leader>tp  (sibling of <leader>ts / <leader>tt)
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

      -- Task status = the checkbox state. `<leader>ts` cycles it:
      --   [ ] todo -> [/] in progress -> [x] done -> [ ] todo
      -- `[/]` is a SAME-DAY signal: the `notes` CLI resets it to `[ ]` on the next
      -- daily carry (stamp_line/reset_status), so only the open todo + its priority
      -- tag survive overnight. Finishing a Focus task also files it under a
      -- `--- / ### Done` block at the foot of the section (see sweep_focus below).
      -- Replaces the old obsidian.nvim :ObsidianToggleCheckbox.
      local STATUS_NEXT = { ["[ ]"] = "[/]", ["[/]"] = "[x]", ["[x]"] = "[ ]", ["[X]"] = "[ ]" }
      local STATUS_PAT = "%[[ /xX]%]"

      -- Priority lanes, most-urgent first. Mirrors the `notes` CLI (md::PRIORITIES, the
      -- shared source of truth) so the on-save sweep here and `notes focus sweep` produce
      -- identical output. Same set as the cycle keymap: low -> high -> urgent.
      local LANES = {
        { "urgent", "### Urgent" },
        { "high", "### High" },
        { "low", "### Low" },
      }

      -- Lane index for an open task by its priority tag (space-preceded #tag, word-ended),
      -- else #LANES + 1 (untagged). Most-urgent tag wins.
      local function task_lane(line)
        for i, lane in ipairs(LANES) do
          local pat = "%f[%S]#" .. lane[1] .. "%f[%W]"
          if line:match(pat) then
            return i
          end
        end
        return #LANES + 1
      end

      -- Any `### `-heading / `---` rule this sweep owns (stripped, re-emitted only where a
      -- lane is non-empty). An unrelated authored heading is preserved as content.
      local function is_scaffold(l)
        if l:match "^%-%-%-%s*$" or l:match "^###%s+Done%s*$" or l:match "^###%s+In progress%s*$" then
          return true
        end
        for _, lane in ipairs(LANES) do
          if l:lower():match("^###%s+" .. lane[1] .. "%s*$") then
            return true
          end
        end
        return false
      end

      -- Pure rebuild of the `## Focus` body, grouped by priority + status: untagged todos
      -- on top, then `### Urgent`/`### High`/`### Medium`/`### Low` (open tasks), finished
      -- (`[x]`) under `--- / ### Done`; an in-progress `[/]` keeps its mark inside its lane.
      -- The single empty `- [ ]` placeholder is kept after the untagged block. `nil` means
      -- "nothing to organize" (no priority-tagged open task, no done, no scaffold). Idempotent.
      local function rebuild_focus_body(body)
        local open, done, placeholder, had_scaffold = {}, {}, nil, false
        for _ = 1, #LANES + 1 do
          open[#open + 1] = {}
        end
        for _, l in ipairs(body) do
          if is_scaffold(l) then
            had_scaffold = true
          elseif l:match "^%s*%- %[[xX]%]" then
            done[#done + 1] = l
          elseif l:match "^%s*%- %[ %]%s*$" then
            placeholder = l
          elseif l:match "^%s*%- %[" then
            local lane = task_lane(l)
            table.insert(open[lane], l)
          elseif l:match "%S" then
            table.insert(open[#LANES + 1], l)
          end
        end
        local tagged = false
        for i = 1, #LANES do
          if #open[i] > 0 then
            tagged = true
          end
        end
        if not tagged and #done == 0 and not had_scaffold then
          return nil
        end
        local out = {}
        for _, l in ipairs(open[#LANES + 1]) do -- untagged, on top
          out[#out + 1] = l
        end
        out[#out + 1] = placeholder or "- [ ] "
        for i, lane in ipairs(LANES) do
          if #open[i] > 0 then
            out[#out + 1] = ""
            out[#out + 1] = lane[2]
            for _, l in ipairs(open[i]) do
              out[#out + 1] = l
            end
          end
        end
        if #done > 0 then
          out[#out + 1] = ""
          out[#out + 1] = "---"
          out[#out + 1] = "### Done"
          for _, l in ipairs(done) do
            out[#out + 1] = l
          end
        end
        return out
      end

      -- Pure: given all buffer lines, return (new_lines, changed). Only the `## Focus`
      -- section is rewritten; everything else is passed through untouched.
      local function sweep_focus(lines)
        local s
        for i, l in ipairs(lines) do
          if l:match "^##%s+Focus%s*$" then
            s = i
            break
          end
        end
        if not s then
          return lines, false
        end
        local e = #lines + 1
        for i = s + 1, #lines do
          if lines[i]:match "^##%s" then
            e = i
            break
          end
        end
        local body = {}
        for i = s + 1, e - 1 do
          body[#body + 1] = lines[i]
        end
        while #body > 0 and body[#body]:match "^%s*$" do
          table.remove(body)
        end
        local rebuilt = rebuild_focus_body(body)
        if not rebuilt then
          return lines, false
        end
        rebuilt[#rebuilt + 1] = "" -- one blank line before the next section / EOF
        local out = {}
        for i = 1, s do
          out[#out + 1] = lines[i]
        end
        for _, l in ipairs(rebuilt) do
          out[#out + 1] = l
        end
        for i = e, #lines do
          out[#out + 1] = lines[i]
        end
        return out, table.concat(out, "\n") ~= table.concat(lines, "\n")
      end

      -- Apply sweep_focus to the current buffer, restoring the cursor row.
      local function file_focus_done()
        local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
        local out, changed = sweep_focus(lines)
        if not changed then
          return
        end
        local cur = vim.api.nvim_win_get_cursor(0)
        vim.api.nvim_buf_set_lines(0, 0, -1, false, out)
        local row = math.min(cur[1], vim.api.nvim_buf_line_count(0))
        pcall(vim.api.nvim_win_set_cursor, 0, { row, cur[2] })
      end

      -- Cycle checkbox status on a range. The next state is computed from the FIRST
      -- line and applied to every line, so a visual selection converges to one state.
      -- After the change, finished Focus tasks are filed under the Done block.
      local function cycle_status(line1, line2)
        local first = vim.fn.getline(line1):match(STATUS_PAT)
        if not first then
          return
        end
        local nxt = STATUS_NEXT[first]
        for lnum = line1, line2 do
          local line = vim.fn.getline(lnum)
          if line:match(STATUS_PAT) then
            vim.fn.setline(lnum, (line:gsub(STATUS_PAT, nxt, 1)))
          end
        end
        file_focus_done()
      end

      -- Open a fresh `- [ ] ` task below the cursor (indentation-matched) and drop
      -- into insert mode at its end.
      local function new_task_below()
        local lnum = vim.api.nvim_win_get_cursor(0)[1]
        local indent = vim.fn.getline(lnum):match "^%s*" or ""
        vim.fn.append(lnum, indent .. "- [ ] ")
        vim.api.nvim_win_set_cursor(0, { lnum + 1, 0 })
        vim.cmd "startinsert!"
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
          -- Task ops, all under the `<leader>t` (tasks) group:
          --   ts  status cycle   [ ] -> [/] -> [x] -> [ ]
          --   tt  new task below
          --   tp  priority cycle #low -> #high -> #urgent -> (none)
          -- Current line (normal) / selection (visual).
          vim.keymap.set("n", "<leader>ts", function()
            local lnum = vim.api.nvim_win_get_cursor(0)[1]
            cycle_status(lnum, lnum)
          end, { buffer = buf, desc = "Cycle task status ([ ]/[/]/[x])", silent = true })
          vim.keymap.set("x", "<leader>ts", function()
            -- Leave visual mode so '< and '> marks are set, then cycle the range.
            vim.cmd "normal! \27"
            cycle_status(vim.fn.line "'<", vim.fn.line "'>")
          end, { buffer = buf, desc = "Cycle task status ([ ]/[/]/[x])", silent = true })

          -- New task below the cursor.
          vim.keymap.set("n", "<leader>tt", new_task_below, { buffer = buf, desc = "New task below", silent = true })

          -- Task priority cycle: current line (normal) / selection (visual). Re-sweeps
          -- so the task jumps to its new priority lane immediately, like <leader>ts does.
          vim.keymap.set("n", "<leader>tp", function()
            local lnum = vim.api.nvim_win_get_cursor(0)[1]
            cycle_priority(lnum, lnum)
            file_focus_done()
          end, { buffer = buf, desc = "Cycle task priority (#low/#high/#urgent)", silent = true })
          vim.keymap.set("x", "<leader>tp", function()
            vim.cmd "normal! \27"
            cycle_priority(vim.fn.line "'<", vim.fn.line "'>")
            file_focus_done()
          end, { buffer = buf, desc = "Cycle task priority (#low/#high/#urgent)", silent = true })

          -- Sweep `## Focus` on save too, so the note lands organized however a task
          -- was edited (typing a #tag by hand, pasting, etc.), not only via the cycles.
          -- No-op when there is no `## Focus` section or nothing changed.
          vim.api.nvim_create_autocmd("BufWritePre", {
            buffer = buf,
            callback = file_focus_done,
          })
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
