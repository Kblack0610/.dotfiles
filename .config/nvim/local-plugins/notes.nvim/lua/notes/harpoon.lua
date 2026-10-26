-- notes.harpoon: the order lab's harpoon list is rebuilt in. Pure (no harpoon, no shell),
-- so it is testable headless; init.lua's sync feeds it `notes projects --stats` and applies
-- the result.

local M = {}

-- The stages lab pins, in slot order. Same list and order as the daily note's `## Projects`
-- (`QUICK_STAGES`, notes-cli/src/daily.rs): prod is visited directly, draft has nothing yet.
M.STAGES = { "beta", "alpha" }

-- `notes projects --stats` rows -> the sheets of every beta/alpha project under lab_root,
-- beta first, then by name. Rows outside lab (employment, lazer) are left out.
function M.stage_sheets(stats_lines, lab_root)
  local rank = {}
  for i, s in ipairs(M.STAGES) do rank[s] = i end
  local prefix = lab_root .. "/"
  local rows = {}
  for _, line in ipairs(stats_lines) do
    local f = vim.split(line, "\t", { plain = true })
    local stage, sheet = f[3], f[#f]
    if rank[stage] and sheet:find(prefix, 1, true) == 1 then
      table.insert(rows, { rank = rank[stage], name = f[2], sheet = sheet })
    end
  end
  table.sort(rows, function(a, b)
    if a.rank ~= b.rank then return a.rank < b.rank end
    return a.name < b.name
  end)
  local sheets = {}
  for _, r in ipairs(rows) do table.insert(sheets, r.sheet) end
  return sheets
end

-- The new list: the index, every beta/alpha sheet (tagged `notes_auto`), then each item the
-- user added, in their order. Last sync's auto entries are dropped, so a project that left
-- beta/alpha leaves the list; a hand-added sheet that is now beta/alpha joins the auto block
-- rather than appearing twice. Daily notes are shed, as lab has always done.
--
-- opts: index (abs path), lab_root, daily_dir (abs, trailing slash).
function M.lab_slots(items, stats_lines, opts)
  local sheets = M.stage_sheets(stats_lines, opts.lab_root)
  local owned = { [opts.index] = true }
  for _, s in ipairs(sheets) do owned[s] = true end

  local out = { { value = opts.index, context = {} } }
  for _, s in ipairs(sheets) do
    table.insert(out, { value = s, context = { notes_auto = true } })
  end
  for _, item in ipairs(items) do
    local path = vim.fn.fnamemodify(item.value, ":p")
    local auto = item.context and item.context.notes_auto
    local daily = path:find(opts.daily_dir, 1, true) == 1
    if not (auto or owned[path] or daily) then
      table.insert(out, item)
    end
  end
  return out
end

return M
