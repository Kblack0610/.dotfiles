-- notes.datetag: the editor half of a task's date tags: `#c1026` (created) and
-- `#due1031` (due). The notes CLI owns the format (md::created_tag / md::due_tag /
-- md::tag_date in notes-cli); this mirrors only what the editor needs:
--
--   stamp_focus(lines, date)  give every open `## Focus` task without a created tag one,
--                             so a task typed by hand is dated the day it was written
--                             (markdown.lua runs it on save in a daily note)
--   age(text, today)          days since a line's created tag, for the cockpit
--   note_date(path)           the date a daily note's file name carries
--
-- Month-day only: the year is the occurrence nearest `today`, as md::tag_date reads it.
-- The long `#cYYMMDD` form (older lines, dates far from today) is read too.

local M = {}

local DAY = 24 * 60 * 60

-- Seconds at local noon for y/m/d, or nil when that day does not exist (os.time
-- normalises 02-30 to 03-02, so the round trip is the validity check).
local function noon(y, m, d)
  local t = os.time { year = y, month = m, day = d, hour = 12 }
  local back = os.date("*t", t)
  if back.year ~= y or back.month ~= m or back.day ~= d then
    return nil
  end
  return t
end

-- The date a created tag's digits name, as seconds at noon. `MMDD` resolves to the
-- nearest of last, this and next year to `today` (a {year,month,day} table).
local function tag_time(digits, today)
  local now = noon(today.year, today.month, today.day)
  if #digits == 6 then
    return noon(2000 + tonumber(digits:sub(1, 2)), tonumber(digits:sub(3, 4)), tonumber(digits:sub(5, 6)))
  end
  local m, d = tonumber(digits:sub(1, 2)), tonumber(digits:sub(3, 4))
  local best
  for k = -1, 1 do
    local t = noon(today.year + k, m, d)
    if t and (not best or math.abs(t - now) < math.abs(best - now)) then
      best = t
    end
  end
  return best
end

-- The digits of the created tag on `line` (`1026` or `261026`), or nil.
local function created_digits(line)
  for digits in line:gmatch "%f[%S]#c(%d+)%f[^%w]" do
    if #digits == 4 or #digits == 6 then
      return digits
    end
  end
  return nil
end

-- True when `line` already carries an origin: a created tag or a legacy since-comment.
local function has_origin(line)
  return created_digits(line) ~= nil or line:find("<!-- since:", 1, true) ~= nil
end

-- Insert `tag` after the task text: before a trailing `<!-- -->` marker and before the
-- trailing run of #tags, so `x #urgent` becomes `x #c1026 #urgent`. The CLI puts the
-- tags in canonical order on the next carry; this only has to land in the right region.
local function insert_tag(line, tag)
  local head, marker = line:match "^(.-)%s*(<!%-%-.*%-%->)%s*$"
  local text, tags = head or (line:gsub("%s+$", "")), ""
  while true do
    local rest, last = text:match "^(.-)(%s+#%S+)$"
    if not rest then
      break
    end
    text, tags = rest, last .. tags
  end
  local out = text .. " " .. tag .. tags
  return marker and (out .. " " .. marker) or out
end

-- `{year,month,day}` from a daily note path (`.../2026-10-26.md`), or nil.
function M.note_date(path)
  local y, m, d = (path or ""):match("[^/]*$"):match "^(%d%d%d%d)%-(%d%d)%-(%d%d)%.md$"
  if not y then
    return nil
  end
  return { year = tonumber(y), month = tonumber(m), day = tonumber(d) }
end

-- Pure: stamp `#cMMDD` (of `date`, a {year,month,day} table) onto every open task in the
-- `## Focus` section that has no origin yet. Returns (lines, changed_row_numbers).
-- Done `[x]` tasks and the empty `- [ ] ` placeholder are left alone.
function M.stamp_focus(lines, date)
  local tag = string.format("#c%02d%02d", date.month, date.day)
  local out, changed = {}, {}
  local in_focus = false
  for i, l in ipairs(lines) do
    if l:match "^##%s" then
      in_focus = l:match "^##%s+Focus%s*$" ~= nil
    elseif in_focus and l:match "^%-%-%-%s*$" and (lines[i + 1] or ""):find("[[", 1, true) then
      in_focus = false -- the link footer, as sweep_focus bounds the section
    end
    if in_focus and l:match "^%s*%- %[[ /]%]%s+%S" and not has_origin(l) then
      l = insert_tag(l, tag)
      changed[#changed + 1] = i
    end
    out[i] = l
  end
  return out, changed
end

-- Whole days from a line's origin (created tag, else a legacy since-comment) to `today`
-- ({year,month,day}), or nil when the line has none. Never negative.
function M.age(text, today)
  local digits = created_digits(text)
  local t = digits and tag_time(digits, today)
  if not digits then
    local y, m, d = text:match "since:(%d%d%d%d)%-(%d%d)%-(%d%d)"
    t = y and noon(tonumber(y), tonumber(m), tonumber(d))
  end
  if not t then
    return nil
  end
  local days = math.floor((noon(today.year, today.month, today.day) - t) / DAY + 0.5)
  return math.max(days, 0)
end

return M
