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
local PANEL = "dotfiles/chips:detail"

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

local function show(line)
  local chip = noctalia.json.decode(line or "")
  if type(chip) ~= "table" then
    return
  end
  local text = chip.text or ""
  barWidget.setVisible(text ~= "")
  barWidget.setText(text)
  -- Noctalia's tooltip is plain text, 280 px wide and three lines at most, so hover shows the
  -- tooltip's first line and a click opens the whole of it in colour (detail.luau).
  local title = string.match(chip.tooltip or "", "[^\n]+")
  if title then
    barWidget.setTooltip(title)
  else
    barWidget.clearTooltip()
  end
  hasDetail = type(chip.detail) == "table" and #chip.detail > 0
  noctalia.state.set("dotfiles.detail:" .. module, { lines = chip.detail or {}, click = spec and spec.click or "" })
  barWidget.setColor(ROLE[chip.class or ""] or "on_surface")
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
  barWidget.setVisible(true)
  barWidget.setText(module .. " ?")
  barWidget.setTooltip(why)
  barWidget.setColor("error")
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

-- A chip with a dropdown opens it (its on-click is the panel's Open button); clicking the
-- chip whose panel is open closes it, and another chip's click switches the panel to it.
-- A chip with no tooltip runs its on-click, as on waybar.
function onClick()
  if hasDetail then
    local shown = noctalia.state.get("dotfiles.detail.shown")
    noctalia.state.set("dotfiles.detail.want", module)
    if shown == nil or shown == module then
      noctalia.togglePanel(PANEL)
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
function onIpc(event, payload)
  if event == "refresh" and spec ~= nil and spec.mode ~= "stream" and tostring(spec.signal) == payload then
    refresh()
  end
end

-- Fires because plugin.toml binds middle to "none" (Noctalia's default opens settings).
function onMiddleClick()
  if spec ~= nil and (spec.middle_click or "") ~= "" then
    noctalia.runAsync(spec.middle_click)
  end
end
