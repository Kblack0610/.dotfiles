-- notes.harpoon: the order lab's and hub's harpoon lists are rebuilt in. Pure (no harpoon, no shell),
-- so it is testable headless; init.lua's sync feeds it `notes projects --stats` and applies
-- the result.

local M = {}

-- The stages lab pins, in slot order: the ones being built (`notes projects --stages` is the
-- ladder); prod is visited directly, draft has nothing yet.
M.STAGES = { "beta", "alpha", "dev" }

-- `notes projects --stats` rows -> the sheets of every beta/alpha/dev project under lab_root,
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

-- The hub list (any ~/.notes cwd outside lab, which is where the hub notes nvim runs): today's
-- daily in slot 1, the projects index in slot 2, then the user's own pins - but only for the
-- day they were made. When slot 1 is not today's daily the day has turned, and the list
-- starts over as just those two, so yesterday's pins and dailies never pile up.
--
-- opts: daily (abs path of today's note), index (abs path of the projects index).
function M.hub_slots(items, opts)
  local first = items[1] and vim.fn.fnamemodify(items[1].value, ":p")
  local out = {
    { value = opts.daily, context = {} },
    { value = opts.index, context = {} },
  }
  if first ~= opts.daily then return out end
  for _, item in ipairs(items) do
    local path = vim.fn.fnamemodify(item.value, ":p")
    if path ~= opts.daily and path ~= opts.index then table.insert(out, item) end
  end
  return out
end

return M
