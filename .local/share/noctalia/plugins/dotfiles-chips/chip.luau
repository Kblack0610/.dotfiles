--!nonstrict
-- One waybar chip from config.base in Noctalia's bar. `desk chip <id>` says how to run it
-- and `desk chip <id> run` runs it, so this file only draws what desk prints.
-- Usage: docs/desk.md, "Noctalia".

local module = noctalia.getConfig("module")
local home = noctalia.getenv("HOME") or ""
local desk = home .. "/.local/bin/desk"
local spec = nil
local busy = false
local hasDetail = false
local published = nil
local PANEL = "dotfiles/chips:detail"
-- Off (config.toml `dropdown = false`) for a chip whose click acts, such as cycling the mic:
-- it keeps its click and its plain tooltip.
local dropdown = noctalia.getConfig("dropdown") ~= false

-- A chip's class picks a palette role, so a theme switch recolours it. The classes are
-- the ones the chip scripts print (pango.sh LEVEL_CLASS, timebox, audio_input).
local ROLE = {
  critical = "error", overdue = "error", final = "error",
  warn = "tertiary",
  muted = "on_surface_variant", other = "on_surface_variant",
}

local function quote(s)
  return "'" .. string.gsub(s, "'", "'\\''") .. "'"
end

local function lastLine(s)
  local last = nil
  for line in string.gmatch(s or "", "[^\n]+") do
    last = line
  end
  return last
end

-- What the chip draws: its text in a palette role, its key while Super+A b is open (onIpc
-- "letters"), and a divider on the side config.toml names (`divider`), since a pod has no
-- divider of its own and the chips in one run together.
local divider = noctalia.getConfig("divider") or ""
local face = { text = "", color = "on_surface" }
local letter = nil

local function bar()
  return ui.label({ text = "│", color = "on_surface_variant/0.5" })
end

local function draw()
  local parts = {}
  if divider == "before" then
    parts[#parts + 1] = bar()
  end
  if letter ~= nil then
    parts[#parts + 1] = ui.label({ text = "(" .. letter .. ")", color = "primary", fontWeight = "bold" })
  end
  parts[#parts + 1] = ui.label({ text = face.text, color = face.color })
  if divider == "after" then
    parts[#parts + 1] = bar()
  end
  barWidget.render(ui.row({ gap = 10, align = "center" }, parts))
end

local function paint(text, color)
  face = { text = text, color = color }
  barWidget.setVisible(text ~= "")
  draw()
end

local function show(line)
  local chip = noctalia.json.decode(line or "")
  if type(chip) ~= "table" then
    return
  end
  local text = chip.text or ""
  -- Noctalia's tooltip is plain text, 280 px wide and three lines at most, so a chip with a
  -- dropdown sets none: hovering it opens the whole tooltip in colour (onHover, detail.luau).
  hasDetail = dropdown and type(chip.detail) == "table" and #chip.detail > 0
  local tip = (not hasDetail) and chip.tooltip or ""
  if tip ~= "" then
    barWidget.setTooltip(tip)
  else
    barWidget.clearTooltip()
  end
  if hasDetail then
    -- Published only when it changed, so an open panel is not rebuilt on every poll.
    local detail = { lines = chip.detail, click = spec and spec.click or "" }
    local key = noctalia.json.encode(detail)
    if key ~= published then
      published = key
      noctalia.state.set("dotfiles.detail:" .. module, detail)
    end
  end
  paint(text, ROLE[chip.class or ""] or "on_surface")
end

-- busy: a slow chip (a Prometheus read) never stacks a second run behind the first.
local function refresh()
  if busy then
    return
  end
  busy = true
  noctalia.runAsync(desk .. " chip " .. quote(module) .. " run", function(res)
    busy = false
    -- No output is an empty chip: waybar hides one that prints nothing (fleet_pulse when all is well).
    show(lastLine(res.stdout) or "{}")
  end, 30000)
end

local function broken(why)
  barWidget.setTooltip(why)
  paint(module .. " ?", "error")
end

-- Until desk answers, update() ticks rarely and does nothing.
noctalia.setUpdateInterval(60000)

noctalia.runAsync(desk .. " chip " .. quote(module), function(res)
  local s = noctalia.json.decode(lastLine(res.stdout) or "")
  if type(s) ~= "table" then
    broken("desk chip " .. module .. ": " .. (res.stderr or "no answer"))
    return
  end
  spec = s
  if spec.mode == "stream" then
    noctalia.runStream(desk .. " chip " .. quote(module) .. " stream", show)
  else
    if spec.mode == "poll" then
      noctalia.setUpdateInterval(math.max(1, spec.interval) * 1000)
    end
    refresh()
  end
end, 10000)

function update()
  if spec ~= nil and spec.mode == "poll" then
    refresh()
  end
end

-- The dropdown's state, shared with detail.luau: "want" is the chip to show, "shown" the one
-- shown (detail.luau writes it), "hover" the chip under the pointer, "pinned" false for a
-- panel hover opened (it closes when the pointer leaves) and true once clicked, and
-- "opening" the time of a togglePanel not yet answered by onOpen, so a quick sweep does not
-- toggle it twice. One the host never answered goes stale after OPEN_WAIT_MS, so a dropped
-- open does not leave every chip's dropdown dead.
local S = "dotfiles.detail."
local OPEN_WAIT_MS = 1000

local function opening()
  local at = noctalia.state.get(S .. "opening")
  return at ~= nil and noctalia.nowMs() - at < OPEN_WAIT_MS
end

local function openPanel(pinned)
  noctalia.state.set(S .. "want", module)
  noctalia.state.set(S .. "pinned", pinned)
  noctalia.state.set(S .. "opening", noctalia.nowMs())
  noctalia.togglePanel(PANEL)
end

-- Hovering a chip with a dropdown opens it, as waybar's tooltip does, or switches an open
-- unpinned panel to it; detail.luau closes it once neither the chip nor the panel is hovered.
function onHover(on)
  if not hasDetail then
    return
  end
  if on == true or on == "true" then
    noctalia.state.set(S .. "hover", module)
    local shown = noctalia.state.get(S .. "shown")
    if shown == nil then
      if opening() then
        noctalia.state.set(S .. "want", module)
      else
        openPanel(false)
      end
    elseif shown ~= module and noctalia.state.get(S .. "pinned") == false then
      noctalia.state.set(S .. "want", module)
    end
  elseif noctalia.state.get(S .. "hover") == module then
    noctalia.state.set(S .. "hover", nil)
  end
end

-- A click pins the dropdown hover opened (its on-click is the panel's Open button); clicking
-- a pinned chip closes it, and another chip's click switches the panel to it, pinned.
-- A chip with no tooltip runs its on-click, as on waybar.
function onClick()
  if hasDetail then
    local shown = noctalia.state.get(S .. "shown")
    if shown == nil then
      -- A click while a hover's open is on its way pins it rather than toggling it shut.
      if opening() then
        noctalia.state.set(S .. "want", module)
        noctalia.state.set(S .. "pinned", true)
      else
        openPanel(true)
      end
    elseif shown == module and noctalia.state.get(S .. "pinned") ~= false then
      noctalia.togglePanel(PANEL)
    else
      noctalia.state.set(S .. "pinned", true)
      noctalia.state.set(S .. "want", module)
    end
  elseif spec ~= nil and spec.click ~= "" then
    noctalia.runAsync(spec.click)
  end
end

function onRightClick()
  if spec ~= nil and spec.right_click ~= "" then
    noctalia.runAsync(spec.right_click)
  end
end

-- `desk signal` sends the signal number, as waybar's SIGRTMIN+n reaches every chip on it.
-- `desk panel letters` sends "custom/ci=c custom/fleet=f ..." (leader.lua's PANELS) on entering
-- Super+A b and "off" on leaving it; a chip with no key in the list shows none.
function onIpc(event, payload)
  if event == "refresh" and spec ~= nil and spec.mode ~= "stream" and tostring(spec.signal) == payload then
    refresh()
  elseif event == "letters" then
    letter = nil
    for id, key in string.gmatch(payload or "", "(%S+)=(%S+)") do
      if id == module then
        letter = key
      end
    end
    draw()
  end
end

-- Fires because plugin.toml binds middle to "none" (Noctalia's default opens settings).
function onMiddleClick()
  if spec ~= nil and (spec.middle_click or "") ~= "" then
    noctalia.runAsync(spec.middle_click)
  end
end
