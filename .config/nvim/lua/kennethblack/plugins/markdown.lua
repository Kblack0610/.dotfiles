-- Markdown: in-editor rendering + live browser preview.
-- See ~/.dotfiles/.local/bin/md-export for file export (pandoc HTML/PDF)
-- and the `marp-slide` skill / `marp` CLI for slide decks.
return {
  -- 1) In-editor rendering (headers, tables, code blocks) ---------------------
  {
    "MeanderingProgrammer/render-markdown.nvim",
    ft = { "markdown" }, -- only load when opening a markdown file
    config = function()
      -- Headings. A terminal grid has exactly one cell size, so no plugin can render a
      -- taller `#` -- "size" has to be faked with weight instead: a full-width tinted bar
      -- per level, a distinct accent color, and a thick border above/below H1/H2 so the
      -- top-level sections read as slabs. For real font sizes use <leader>mo (export to
      -- browser) or <leader>mp (live preview).
      local HEADING_FG = { "#7aa2f7", "#bb9af7", "#7dcfff", "#9ece6a", "#e0af68", "#f7768e" }
      -- Bar opacity falls off with depth, so H1 is loudest and H6 is barely a tint.
      local HEADING_ALPHA = { 0.32, 0.26, 0.21, 0.17, 0.13, 0.10 }
      -- tokyonight is configured `transparent = true`, so Normal has no bg to blend
      -- against -- pin the palette's night bg explicitly.
      local HEADING_BASE = "#1a1b26"

      -- Blend `hex` toward `base` (alpha 1.0 = pure `hex`), returning "#rrggbb".
      local function blend(hex, base, alpha)
        local function chan(s, i)
          return tonumber(s:sub(i, i + 1), 16)
        end
        local out = "#"
        for i = 2, 6, 2 do
          out = out .. string.format("%02x", math.floor(chan(hex, i) * alpha + chan(base, i) * (1 - alpha) + 0.5))
        end
        return out
      end

      -- render-markdown declares its own RenderMarkdown* groups with `default = true`,
      -- linked to Diff*/Visual -- which tokyonight renders almost invisibly, hence
      -- "headings look like nothing happened". A plain nvim_set_hl outranks a default
      -- link. Re-run on ColorScheme, which clears explicitly-set groups.
      local function set_heading_colors()
        for i, fg in ipairs(HEADING_FG) do
          vim.api.nvim_set_hl(0, "RenderMarkdownH" .. i, { fg = fg, bold = true })
          vim.api.nvim_set_hl(0, "RenderMarkdownH" .. i .. "Bg", { bg = blend(fg, HEADING_BASE, HEADING_ALPHA[i]) })
          -- The heading TEXT is treesitter's group, not the plugin's; match it so the
          -- level is legible from the words, not only from the bar behind them.
          vim.api.nvim_set_hl(0, "@markup.heading." .. i .. ".markdown", { fg = fg, bold = true })
        end
      end
      set_heading_colors()
      vim.api.nvim_create_autocmd("ColorScheme", {
        group = vim.api.nvim_create_augroup("MarkdownHeadingColors", {}),
        callback = set_heading_colors,
      })

      require("render-markdown").setup {
        file_types = { "markdown" },
        render_modes = { "n", "v", "V", "i", "c" }, -- render markdown in all modes
        heading = {
          sign = false, -- the bar carries the level; no need for a gutter glyph too
          width = "full", -- bar spans the window, not just the heading text
          left_pad = 1,
          right_pad = 1,
          border = { true, false, false, false, false, false }, -- slab rules on H1 only
        },
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

      -- Return (base_without_tag, current_level_or_nil): strip the priority tag wherever it
      -- sits and trim trailing whitespace.
      --
      -- Deliberately NOT anchored to end-of-line. It used to be, which was fine while a
      -- priority tag was always last; a wave tag now follows it (`#high #v0.0.2`), and an
      -- anchored match reads such a task as untagged, so `<leader>tP` would restart the ring
      -- from nothing every time. Mirrors md::split_priority, which never anchored.
      local function strip_priority(line)
        for _, p in ipairs(PRIORITIES) do
          local stripped, n = line:gsub("%s*#" .. p .. "%f[%W]", "")
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

      -- Append `tag` to a task line, BEFORE any trailing `<!-- ... -->` marker. Mirrors
      -- md::add_tag in the notes CLI, and the position is not cosmetic: the display path
      -- truncates at the first `<!--` and only then strips tags, so a tag written past the
      -- marker survives as raw text onto board rows and cockpit lines. No-op when the line
      -- already carries the tag, so a re-sweep cannot double it.
      local function add_tag(line, tag)
        for w in line:gmatch "%S+" do
          if w == tag then
            return line
          end
        end
        local head, marker = line:match "^(.-)%s*(<!%-%-.*%-%->)%s*$"
        if head then
          return head .. " " .. tag .. " " .. marker
        end
        return (line:gsub("%s+$", "")) .. " " .. tag
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
      local function rebuild_focus_body(body, inherit, lanes, force)
        lanes = lanes or LANES
        local open, done, placeholder, had_scaffold = {}, {}, nil, false
        for _ = 1, #lanes + 1 do
          open[#open + 1] = {}
        end
        local cur_lane = nil -- LANES index of the header we're under, else nil
        -- Which bucket the last top-level line went to, so its indented children follow it.
        -- `last` is a LANES index, or 0 meaning the done bucket.
        local last = nil
        for _, l in ipairs(body) do
          if is_scaffold(l) then
            had_scaffold = true
            cur_lane = scaffold_lane(l)
            last = nil
          elseif l:match "^%s" and l:match "%S" and last then
            -- An indented line belongs to the task above it: a wrapped continuation, or a
            -- subtask. Bucketing it alone would tear it off its parent and float it to the
            -- top of the list.
            if last == 0 then
              done[#done + 1] = l
            else
              table.insert(open[last], l)
            end
          elseif l:match "^%s*%- %[[xX]%]" then
            done[#done + 1] = l
            last = 0
          elseif l:match "^%s*%- %[ %]%s*$" then
            placeholder = l
            last = nil
          elseif l:match "^%s*%- %[" then
            local _, lvl = strip_priority(l)
            if lvl then
              local i = task_lane(l)
              table.insert(open[i], l) -- tag is the source of truth
              last = i
            elseif inherit and cur_lane then
              -- untagged under a lane -> inherit its tag
              table.insert(open[cur_lane], add_tag(l, "#" .. lanes[cur_lane][1]))
              last = cur_lane
            else
              table.insert(open[#lanes + 1], l) -- untagged (or no inherit) -> top bucket
              last = #lanes + 1
            end
          elseif l:match "%S" then
            table.insert(open[#lanes + 1], l)
            last = #lanes + 1
          end
        end
        local tagged = false
        for i = 1, #lanes do
          if #open[i] > 0 then
            tagged = true
          end
        end
        if not force and not tagged and #done == 0 and not had_scaffold then
          return nil
        end
        local out = {}
        for _, l in ipairs(open[#lanes + 1]) do -- untagged, on top
          out[#out + 1] = l
        end
        out[#out + 1] = placeholder or "- [ ] "
        for i, lane in ipairs(lanes) do -- every lane header, even when empty (drop targets)
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

      -- ---- waves -------------------------------------------------------------------
      -- A project sheet groups tasks into `## Wave: vX.Y.Z` sections the same way the daily
      -- note groups them into priority lanes, and by the same rule: the `#vX.Y.Z` tag on the
      -- line is the source of truth, the heading is swept output. Mirrors project_sweep.rs;
      -- a golden test in the Rust crate pins the two to the same bytes.
      local WAVE_PAT = "#v%d+%.%d+%.%d+"

      local function parse_ver(s)
        local a, b, c = tostring(s):match "^v(%d+)%.(%d+)%.(%d+)$"
        if not a then
          return nil
        end
        return { tonumber(a), tonumber(b), tonumber(c) }
      end

      local function ver_str(v)
        return string.format("v%d.%d.%d", v[1], v[2], v[3])
      end

      -- -1 / 0 / 1, so waves sort the way versions order rather than the way strings do.
      local function ver_cmp(x, y)
        for i = 1, 3 do
          if x[i] ~= y[i] then
            return x[i] < y[i] and -1 or 1
          end
        end
        return 0
      end

      local function wave_of(line)
        local t = line:match("(" .. WAVE_PAT .. ")")
        return t and parse_ver(t:sub(2)) or nil
      end

      local function strip_wave(line)
        return (line:gsub("%s?" .. WAVE_PAT, ""):gsub("%s+$", ""))
      end

      -- Canonical tag order: text, priority, wave, then the marker. Mirrors md::normalize_tags.
      -- Two paths add tags at different points, so without one order the same task is spelled
      -- two ways and the editor and the CLI stop producing the same bytes.
      local function normalize_tags(line)
        if not line:match "^%s*%- %[" then
          return line
        end
        local wave = line:match("(" .. WAVE_PAT .. ")")
        -- No tags to reorder: return the line untouched rather than round-tripping it through
        -- the strippers, which would also eat the `- [ ] ` placeholder's trailing space.
        if not wave and not select(2, strip_priority(line)) then
          return line
        end
        local base, prio = strip_priority(strip_wave(line))
        if prio then
          base = add_tag(base, "#" .. prio)
        end
        if wave then
          base = add_tag(base, wave)
        end
        return base
      end

      -- The current wave: the version the sheet's own `Version:` line declares. Position
      -- cannot define it in a sweep that reorders sections, so the declaration does.
      local function sheet_version(lines)
        for _, l in ipairs(lines) do
          local v = l:match "^Version:%s+(v%d+%.%d+%.%d+)%s*$"
          if v then
            return parse_ver(v)
          end
        end
        return nil
      end

      -- Pure: given all buffer lines, return (new_lines, changed). Rewrites only the `## Wave`
      -- roadmap. Refuses a sheet with no `Version:` and one whose wave heading names no
      -- version (a legacy `## Wave 1 - verify`), rather than renumbering what it cannot name.
      local function sweep_waves(lines, inherit)
        local cur = sheet_version(lines)
        if not cur then
          return lines, false
        end
        -- the roadmap: the first `## Wave` heading through the last consecutive one
        local heads = {}
        for i, l in ipairs(lines) do
          if l:match "^##%s+Wave" then
            heads[#heads + 1] = i
          elseif #heads > 0 and l:match "^##%s" then
            break
          end
        end
        if #heads == 0 then
          return lines, false
        end
        local secs = {}
        for n, i in ipairs(heads) do
          local v = parse_ver(lines[i]:match "(v%d+%.%d+%.%d+)" or "")
          if not v then
            return lines, false -- an unnamed wave is not safe to reorder
          end
          local stop = #lines + 1
          for j = i + 1, #lines do
            if lines[j]:match "^##%s" then
              stop = j
              break
            end
          end
          secs[n] = { ver = v, from = i, to = (heads[n + 1] or stop) }
        end
        local roadmap_from, roadmap_to = heads[1], secs[#secs].to

        -- bucket every task by its tag, else the section it sits in
        local order, buckets = {}, {}
        local function bucket(v)
          local k = ver_str(v)
          if not buckets[k] then
            buckets[k] = {}
            order[#order + 1] = v
          end
          return buckets[k]
        end
        bucket(cur)
        for _, sec in ipairs(secs) do
          bucket(sec.ver)
        end
        for _, sec in ipairs(secs) do
          for j = sec.from + 1, sec.to - 1 do
            local l = lines[j]
            -- blanks and the generated `- [ ] ` placeholder are scaffold, not content
            if l:match "%S" and not l:match "^%s*%- %[ %]%s*$" then
              local want = wave_of(l) or sec.ver
              if ver_cmp(want, cur) < 0 then
                want = cur -- never earlier than the wave in flight
              end
              local line = l
              if l:match "^%s*%- %[" then
                local is_cur = ver_cmp(want, cur) == 0
                line = strip_wave(l)
                if not is_cur and select(2, strip_priority(line)) == "urgent" then
                  line = add_tag((strip_priority(line)), "#high")
                end
                line = add_tag(line, "#" .. ver_str(want))
              end
              table.insert(bucket(want), line)
            end
          end
        end

        -- current wave first, then the roadmap ascending. A plain version sort would put a
        -- wave numbered below the current one ABOVE it, and every reader takes the first
        -- section as the current wave.
        local rest = {}
        for _, v in ipairs(order) do
          if ver_cmp(v, cur) ~= 0 then
            rest[#rest + 1] = v
          end
        end
        table.sort(rest, function(a, b)
          return ver_cmp(a, b) < 0
        end)
        table.insert(rest, 1, cur)

        local out = {}
        for i = 1, roadmap_from - 1 do
          out[#out + 1] = lines[i]
        end
        for n, v in ipairs(rest) do
          if n > 1 then
            out[#out + 1] = ""
          end
          local is_cur = ver_cmp(v, cur) == 0
          out[#out + 1] = "## Wave: " .. ver_str(v) .. (is_cur and " (current)" or " (planned)")
          local lanes = LANES
          if not is_cur then -- a planned wave has no legal Urgent lane, so it renders none
            lanes = { LANES[2], LANES[3] }
          end
          for _, l in ipairs(rebuild_focus_body(buckets[ver_str(v)], inherit, lanes, true)) do
            out[#out + 1] = normalize_tags(l)
          end
        end
        -- One blank line between the roadmap and whatever follows it. At EOF there is
        -- nothing to separate, and a trailing blank would be a line the CLI does not write.
        if roadmap_to <= #lines then
          out[#out + 1] = ""
          for i = roadmap_to, #lines do
            out[#out + 1] = lines[i]
          end
        end
        while #out > 1 and out[#out] == "" and out[#out - 1] == "" do
          table.remove(out)
        end
        return out, table.concat(out, "\n") ~= table.concat(lines, "\n")
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
      -- A buffer is a project SHEET when it declares a `Version:` and holds a `## Wave`;
      -- anything else with a `## Focus` is a daily note. One dispatcher so the keymaps and
      -- the save hook cannot disagree about which sweep a buffer gets.
      local function sweep_buffer(lines, inherit)
        for _, l in ipairs(lines) do
          if l:match "^##%s+Wave" then
            return sweep_waves(lines, inherit)
          end
        end
        return sweep_focus(lines, inherit)
      end

      local function file_focus_done()
        local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
        local out, changed = sweep_buffer(lines, true)
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
        local out, changed = sweep_buffer(lines, false) -- live cycle: tag-driven, no drop-to-tag
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

      -- Step a task one wave in `dir` (-1 sooner, +1 later), then re-sweep and follow it.
      --
      -- A ladder, not a ring, unlike the priority cycle: sooner CLAMPS at the current wave
      -- (a wave before the one in flight is what every reader takes as current), later MINTS
      -- the next patch past the end of the roadmap. Mirrors project_sweep::step_wave.
      local function cycle_wave(line1, line2, dir)
        local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
        local cur = sheet_version(lines)
        if not cur then
          return
        end
        local ladder = {}
        for _, l in ipairs(lines) do
          local v = l:match "^##%s+Wave:%s+(v%d+%.%d+%.%d+)"
          if v then
            ladder[#ladder + 1] = parse_ver(v)
          end
        end
        local at = wave_of(vim.fn.getline(line1)) or cur
        local to
        if dir < 0 then
          if ver_cmp(at, cur) <= 0 then
            vim.notify("already in " .. ver_str(cur) .. " - nothing sooner", vim.log.levels.WARN)
            return
          end
          for _, v in ipairs(ladder) do
            if ver_cmp(v, at) < 0 and ver_cmp(v, cur) >= 0 and (not to or ver_cmp(v, to) > 0) then
              to = v
            end
          end
          to = to or cur
        else
          for _, v in ipairs(ladder) do
            if ver_cmp(v, at) > 0 and (not to or ver_cmp(v, to) < 0) then
              to = v
            end
          end
          if not to then
            local top = at
            for _, v in ipairs(ladder) do
              if ver_cmp(v, top) > 0 then
                top = v
              end
            end
            to = { top[1], top[2], top[3] + 1 }
          end
        end
        local is_cur = ver_cmp(to, cur) == 0
        for lnum = line1, line2 do
          local raw = vim.fn.getline(lnum)
          if raw:match "^%s*%- %[" then
            local line = strip_wave(raw)
            if not is_cur and select(2, strip_priority(line)) == "urgent" then
              line = add_tag((strip_priority(line)), "#high")
            end
            vim.fn.setline(lnum, normalize_tags(add_tag(line, "#" .. ver_str(to))))
          end
        end
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

      -- Smart task line, for turning bullets/prose into tasks on the fly. If the
      -- current line is NOT a task yet (plain text, a `-`/`*`/`+` bullet, or blank),
      -- convert it in place into `- [ ] <text>`. If it's ALREADY a task, leave it
      -- alone and open an indented subtask beneath it instead, so repeated presses
      -- build a task/subtask tree rather than a flat list of siblings.
      local function smart_task()
        local lnum = vim.api.nvim_win_get_cursor(0)[1]
        local line = vim.fn.getline(lnum)
        local indent, rest = line:match "^(%s*)(.-)%s*$"

        if rest:match("^%- " .. STATUS_PAT) then
          vim.fn.append(lnum, indent .. "  - [ ] ")
          vim.api.nvim_win_set_cursor(0, { lnum + 1, 0 })
          vim.cmd "startinsert!"
        else
          local text = rest:gsub("^[-*+]%s*", "")
          vim.fn.setline(lnum, indent .. "- [ ] " .. text)
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
          -- Export the current note to standalone, themed HTML and open it in the
          -- browser. Unlike <leader>mp this needs no node server and produces a file
          -- you can email; unlike the in-editor render it has real heading sizes.
          -- Output goes to a tempfile so exports never land next to the note.
          vim.keymap.set("n", "<leader>mo", function()
            local src = vim.api.nvim_buf_get_name(0)
            if src == "" then
              return vim.notify("markdown: buffer has no file to export", vim.log.levels.ERROR)
            end
            for cmd, hint in pairs { ["md-export"] = "~/.dotfiles/.local/bin", pandoc = "pacman -S pandoc-cli" } do
              if vim.fn.executable(cmd) == 0 then
                return vim.notify(("markdown: %s not found (%s)"):format(cmd, hint), vim.log.levels.ERROR)
              end
            end
            vim.cmd "silent write"
            local out = vim.fn.tempname() .. ".html"
            vim.system({ "md-export", "html", src, out }, { text = true }, function(res)
              vim.schedule(function()
                if res.code ~= 0 then
                  vim.notify("md-export failed: " .. (res.stderr or ""), vim.log.levels.ERROR)
                else
                  vim.ui.open(out)
                end
              end)
            end)
          end, { buffer = buf, desc = "Markdown export -> browser", silent = true })
          -- Task ops, all under the `<leader>t` (tasks) group:
          --   ts  status cycle    [ ] -> [/] -> [x] -> [ ]
          --   tt  convert line to task, or add an indented subtask if already one
          --   tP  raise priority  none -> low -> high -> urgent -> none
          --   tp  lower priority  (the same ring, the other way)
          --   tW  push one wave later   tw  pull one wave sooner  (project sheets)
          -- `tt`, not `tc`: notes.nvim binds `<leader>tc` globally to the task cockpit,
          -- and a buffer-local map shadows it, so `tc` here made the cockpit unreachable
          -- from every markdown buffer -- the one place you most want it.
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

          -- Convert current line to a task, or add an indented subtask if it's
          -- already one.
          vim.keymap.set(
            "n",
            "<leader>tt",
            smart_task,
            { buffer = buf, desc = "Convert line to task / add subtask", silent = true }
          )

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

          -- Wave step, on a project sheet: tW pushes a task one wave LATER (out to the
          -- roadmap), tw pulls it one wave SOONER. Same shape as the priority cycle, but a
          -- bounded ladder rather than a ring - sooner stops at the current wave, later opens
          -- the next patch version. A no-op in a buffer with no `Version:` line.
          for _, m in ipairs { { "W", 1, "Push task one wave later" }, { "w", -1, "Pull task one wave sooner" } } do
            local key, dir, desc = m[1], m[2], m[3]
            vim.keymap.set("n", "<leader>t" .. key, function()
              local lnum = vim.api.nvim_win_get_cursor(0)[1]
              cycle_wave(lnum, lnum, dir)
            end, { buffer = buf, desc = desc, silent = true })
            vim.keymap.set("x", "<leader>t" .. key, function()
              vim.cmd "normal! \27"
              cycle_wave(vim.fn.line "'<", vim.fn.line "'>", dir)
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
    -- A `build = function() vim.fn["mkdp#util#install"]() end` fails with E117 under
    -- `Lazy! build` (the plugin's autoload isn't on rtp yet), which is how this silently
    -- shipped with no app/bin and a dead <leader>mp. The ":"-prefixed form makes lazy
    -- source the plugin first. Manual fallback, if it ever regresses:
    --   cd ~/.local/share/nvim/lazy/markdown-preview.nvim/app
    --   ./install.sh v$(node -p "require('../package.json').version")
    build = ":call mkdp#util#install()",
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
