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
      --   Levels:  #low  #high  #urgent
      --   Keymaps: <leader>tP raise / <leader>tp lower (cycle, cursor follows the task)
      --            ring: none -> low -> high -> urgent -> none
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

      -- Set the priority tag on a range to `level` ("urgent"/"high"/"low"), or clear it
      -- when `level` is nil. Non-task lines are left alone.
      local function set_priority(line1, line2, level)
        for lnum = line1, line2 do
          local raw = vim.fn.getline(lnum)
          if raw:match "^%s*%- %[" then
            local base = strip_priority(raw)
            if level then
              local tag = "#" .. level
              vim.fn.setline(lnum, base == "" and tag or (base .. " " .. tag))
            else
              vim.fn.setline(lnum, base)
            end
          end
        end
      end

      -- Ring of priority levels, least -> most urgent; `false` stands in for "no tag".
      -- `step_priority` walks one slot in `dir` (+1 raise toward urgent, -1 lower), wrapping
      -- through the no-tag slot, and returns the next level (nil = clear the tag).
      local PRIORITY_RING = { false, "low", "high", "urgent" }
      local function step_priority(current, dir)
        local idx = 1
        for i, lvl in ipairs(PRIORITY_RING) do
          if lvl == (current or false) then
            idx = i
            break
          end
        end
        local nxt = PRIORITY_RING[((idx - 1 + dir) % #PRIORITY_RING) + 1]
        return nxt or nil
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

      -- Which LANES index this scaffold line opens, or nil if it's a non-lane scaffold
      -- (`---`, `### Done`, `### In progress`) that closes the priority region.
      local function scaffold_lane(l)
        for i, lane in ipairs(LANES) do
          if l:lower():match("^###%s+" .. lane[1] .. "%s*$") then
            return i
          end
        end
        return nil
      end

      -- Pure rebuild of the `## Focus` body, grouped by priority + status: untagged todos
      -- on top, then `### Urgent`/`### High`/`### Low` (open tasks), finished (`[x]`) under
      -- `--- / ### Done`; an in-progress `[/]` keeps its mark inside its lane. Once the
      -- section is active, ALL lane headers + Done are emitted even when empty, so the
      -- columns stay put as stable drop targets. A task's #tag is the source of truth, but an
      -- untagged task sitting under a lane header inherits that lane's tag (drop-to-tag) when
      -- `inherit` is set. Inherit is ON for the on-save sweep (you dragged a task into a
      -- column) and OFF for the interactive cursor-follow cycle (so clearing a tag actually
      -- clears it instead of the task re-inheriting the lane it still sits under). The single
      -- empty `- [ ]` placeholder is kept after the untagged block. `nil` means "nothing to
      -- organize" (no priority-tagged open task, no done, no scaffold). Idempotent.
      local function rebuild_focus_body(body, inherit)
        local open, done, placeholder, had_scaffold = {}, {}, nil, false
        for _ = 1, #LANES + 1 do
          open[#open + 1] = {}
        end
        local cur_lane = nil -- LANES index of the header we're under, else nil
        for _, l in ipairs(body) do
          if is_scaffold(l) then
            had_scaffold = true
            cur_lane = scaffold_lane(l)
          elseif l:match "^%s*%- %[[xX]%]" then
            done[#done + 1] = l
          elseif l:match "^%s*%- %[ %]%s*$" then
            placeholder = l
          elseif l:match "^%s*%- %[" then
            local _, lvl = strip_priority(l)
            if lvl then
              table.insert(open[task_lane(l)], l) -- tag is the source of truth
            elseif inherit and cur_lane then
              local base = strip_priority(l) -- untagged under a lane -> inherit its tag
              table.insert(open[cur_lane], base .. " #" .. LANES[cur_lane][1])
            else
              table.insert(open[#LANES + 1], l) -- untagged (or no inherit) -> top bucket
            end
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
        for i, lane in ipairs(LANES) do -- every lane header, even when empty (drop targets)
          out[#out + 1] = ""
          out[#out + 1] = lane[2]
          for _, l in ipairs(open[i]) do
            out[#out + 1] = l
          end
        end
        out[#out + 1] = "" -- Done placeholder is always present too
        out[#out + 1] = "---"
        out[#out + 1] = "### Done"
        for _, l in ipairs(done) do
          out[#out + 1] = l
        end
        return out
      end

      -- Pure: given all buffer lines, return (new_lines, changed). Only the `## Focus`
      -- section is rewritten; everything else is passed through untouched. `inherit` gates
      -- drop-to-tag (see rebuild_focus_body): ON for the save sweep, OFF for the live cycle.
      local function sweep_focus(lines, inherit)
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
        local rebuilt = rebuild_focus_body(body, inherit)
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

      -- Apply the on-save sweep to the current buffer (inherit ON: a task dragged into a
      -- column gets that column's tag), restoring the cursor row.
      local function file_focus_done()
        local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
        local out, changed = sweep_focus(lines, true)
        if not changed then
          return
        end
        local cur = vim.api.nvim_win_get_cursor(0)
        vim.api.nvim_buf_set_lines(0, 0, -1, false, out)
        local row = math.min(cur[1], vim.api.nvim_buf_line_count(0))
        pcall(vim.api.nvim_win_set_cursor, 0, { row, cur[2] })
      end

      -- Sweep, then put the cursor on wherever the line currently at `track_lnum` ended up
      -- (matched by exact text), so a direct priority set lands the cursor on the task it
      -- just moved instead of leaving it on the old row. Falls back to a row-clamp when the
      -- line can't be found (e.g. it was the placeholder). No-op when the sweep changes nothing.
      local function sweep_and_follow(track_lnum)
        local target = vim.fn.getline(track_lnum)
        local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
        local out, changed = sweep_focus(lines, false) -- live cycle: tag-driven, no drop-to-tag
        if not changed then
          return
        end
        local col = vim.api.nvim_win_get_cursor(0)[2]
        vim.api.nvim_buf_set_lines(0, 0, -1, false, out)
        local row
        for i, l in ipairs(out) do
          if l == target then
            row = i
            break
          end
        end
        row = row or math.min(track_lnum, vim.api.nvim_buf_line_count(0))
        pcall(vim.api.nvim_win_set_cursor, 0, { row, col })
      end

      -- Cycle the priority tag on a range by `dir` (+1 raise / -1 lower). The next level is
      -- computed from the FIRST line so a selection converges, then the note re-sweeps and the
      -- cursor follows the task to its new lane.
      local function cycle_priority(line1, line2, dir)
        local _, first = strip_priority(vim.fn.getline(line1))
        set_priority(line1, line2, step_priority(first, dir))
        sweep_and_follow(line1)
      end

      -- Cycle checkbox status on a range. The next state is computed from the FIRST
      -- line and applied to every line, so a visual selection converges to one state.
      -- The edit is applied in place; the Focus sweep (regroup into lanes / Done)
      -- runs on save, so tasks don't jump around under the cursor as you cycle.
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
          --   ts  status cycle    [ ] -> [/] -> [x] -> [ ]
          --   tt  new task below
          --   tP  raise priority  none -> low -> high -> urgent -> none
          --   tp  lower priority  (the same ring, the other way)
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

          -- Task priority cycle: tP raises toward urgent, tp lowers, through the ring
          -- none -> low -> high -> urgent -> none. Each press re-sweeps and follows the task
          -- to its new lane so the cursor rides along. Current line (normal) / selection (visual).
          for _, m in ipairs { { "P", 1, "Raise task priority" }, { "p", -1, "Lower task priority" } } do
            local key, dir, desc = m[1], m[2], m[3]
            vim.keymap.set("n", "<leader>t" .. key, function()
              local lnum = vim.api.nvim_win_get_cursor(0)[1]
              cycle_priority(lnum, lnum, dir)
            end, { buffer = buf, desc = desc, silent = true })
            vim.keymap.set("x", "<leader>t" .. key, function()
              vim.cmd "normal! \27"
              cycle_priority(vim.fn.line "'<", vim.fn.line "'>", dir)
            end, { buffer = buf, desc = desc, silent = true })
          end

          -- Sweep `## Focus` on save too, so the note lands organized however a task
          -- was edited (typing a #tag by hand, pasting, etc.), not only via the cycles.
          -- No-op when there is no `## Focus` section or nothing changed.
          vim.api.nvim_create_autocmd("BufWritePre", {
            buffer = buf,
            callback = file_focus_done,
          })

          -- After save, push ClickUp status edits up: a `[/]`/`[x]` on a cu-linked Focus
          -- item flows to ClickUp (the write-back half of the bridge). Fires only for a
          -- daily note (`YYYY-MM-DD.md`); async via jobstart so the save never blocks; and
          -- inherently a no-op when the profile has no `clickup_list`, the cache is empty,
          -- or nothing changed (`notes clickup push` decides — this just triggers it).
          vim.api.nvim_create_autocmd("BufWritePost", {
            buffer = buf,
            callback = function(args)
              local base = vim.fn.fnamemodify(args.file, ":t")
              if base:match "^%d%d%d%d%-%d%d%-%d%d%.md$" and vim.fn.executable "notes" == 1 then
                vim.fn.jobstart { "notes", "clickup", "push" }
              end
            end,
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
