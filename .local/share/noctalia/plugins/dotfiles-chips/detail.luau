--!nonstrict
-- A chip's dropdown: its waybar tooltip with the colours, bold titles and <tt> tables kept.
-- chip.luau publishes each chip's runs under "dotfiles.detail:<module>" and the hovered or
-- clicked chip under "dotfiles.detail.want"; this panel says which it shows in
-- "dotfiles.detail.shown". The other keys are described in chip.luau.
-- `desk chip <id> run` parses the pango into those runs (its `detail`).
-- Usage: docs/desk.md, "Noctalia".

local S = "dotfiles.detail."
local FONT_SIZE = 14
-- How long an unpinned panel stays open with neither its chip nor itself hovered: room to
-- cross the gap from the bar to the panel, and for the hover to move from the panel to its
-- Open button (only the innermost node reports, so the panel reports a leave first).
local GRACE_MS = 400
local open = nil
local watched = {}
local inPanel = false
local closeIn = nil

local function idle()
  return open ~= nil and not inPanel and noctalia.state.get(S .. "hover") == nil
    and noctalia.state.get(S .. "pinned") == false
end

-- Frame ticks run only while a close is pending.
local function check()
  if idle() then
    if closeIn == nil then
      closeIn = GRACE_MS
      panel.setNeedsFrameTick(true)
    end
  elseif closeIn ~= nil then
    closeIn = nil
    panel.setNeedsFrameTick(false)
  end
end

function onFrameTick(deltaMs)
  if closeIn == nil then
    return
  end
  closeIn = closeIn - (tonumber(deltaMs) or 0)
  if closeIn <= 0 then
    closeIn = nil
    panel.setNeedsFrameTick(false)
    if idle() then
      panel.close()
    end
  end
end

local function hovered(state)
  inPanel = state == "true"
  check()
end

-- A run's alpha (<span alpha>) on a hex colour becomes its alpha byte, on a role "role/a".
local function colour(run)
  local c = run.c or (run.b and "primary") or "on_surface"
  if run.a == nil then
    return c
  end
  if string.match(c, "^#%x%x%x%x%x%x$") then
    return c .. string.format("%02x", math.floor(run.a * 255 + 0.5))
  end
  return c .. "/" .. tostring(run.a)
end

-- Each line reports hover too: the scroll it sits in may take the pointer from the column.
local function line(runs, i)
  if #runs == 0 then
    return ui.row({ key = "l" .. i, onHover = hovered }, { ui.label({ text = " ", fontSize = FONT_SIZE }) })
  end
  local labels = {}
  for j, run in ipairs(runs) do
    labels[j] = ui.label({
      text = run.t,
      fontSize = FONT_SIZE,
      color = colour(run),
      fontWeight = run.b and "bold" or nil,
      fontFamily = run.m and "monospace" or nil,
      maxLines = 1,
    })
  end
  return ui.row({ key = "l" .. i, gap = 0, align = "end", onHover = hovered }, labels)
end

local function runClick(cmd)
  return function()
    panel.close()
    noctalia.runAsync(cmd)
  end
end

local function render()
  local d = open and noctalia.state.get("dotfiles.detail:" .. open)
  if type(d) ~= "table" then
    panel.render(ui.column({ padding = 12, onHover = hovered }, { ui.label({ text = (open or "?") .. ": no detail yet" }) }))
    return
  end
  local lines = {}
  for i, runs in ipairs(d.lines or {}) do
    lines[i] = line(runs, i)
  end
  local sections = {}
  if (d.click or "") ~= "" then
    sections[#sections + 1] = ui.row({ justify = "end" }, {
      ui.button({ text = "Open", glyph = "external-link", variant = "ghost", controlSize = "sm", onClick = runClick(d.click), onHover = hovered }),
    })
  end
  sections[#sections + 1] = ui.scroll({ flexGrow = 1, gap = 2 }, lines)
  panel.render(ui.column({ flexGrow = 1, gap = 4, padding = 12, onHover = hovered }, sections))
end

local function watch(module)
  if module and not watched[module] then
    watched[module] = true
    noctalia.state.watch("dotfiles.detail:" .. module, function()
      if open == module then
        render()
      end
    end)
  end
end

local function show(module)
  open = module
  watch(module)
  render()
end

-- context: a chip id from `desk panel` (Super+A b), which opens it pinned; a chip's hover or
-- click passes none and names itself in "dotfiles.detail.want".
function onOpen(context)
  noctalia.state.set(S .. "opening", nil)
  if context ~= nil and context ~= "" then
    noctalia.state.set(S .. "pinned", true)
    show(context)
  else
    show(noctalia.state.get(S .. "want"))
  end
  noctalia.state.set(S .. "shown", open)
  inPanel = false
  check()
end

function onClose()
  open = nil
  inPanel = false
  closeIn = nil
  noctalia.state.set(S .. "opening", nil)
  noctalia.state.set(S .. "pinned", nil)
  noctalia.state.set(S .. "shown", nil)
end

-- Another chip hovered or clicked while this panel is open: show that chip's detail in place.
noctalia.state.watch(S .. "want", function(module)
  if open ~= nil and module ~= nil and module ~= open then
    show(module)
    noctalia.state.set(S .. "shown", open)
  end
end)

noctalia.state.watch(S .. "hover", check)
noctalia.state.watch(S .. "pinned", check)
