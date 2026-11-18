--!nonstrict
-- A chip's dropdown: its waybar tooltip with the colours, bold titles and <tt> tables kept.
-- chip.luau publishes each chip's runs under "dotfiles.detail:<module>" and the clicked
-- chip under "dotfiles.detail.want"; this panel says which it shows in "dotfiles.detail.shown".
-- `desk chip <id> run` parses the pango into those runs (its `detail`).
-- Usage: docs/desk.md, "Noctalia".

local FONT_SIZE = 14
local open = nil
local watched = {}

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

local function line(runs, i)
  if #runs == 0 then
    return ui.label({ key = "l" .. i, text = " ", fontSize = FONT_SIZE })
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
  return ui.row({ key = "l" .. i, gap = 0, align = "end" }, labels)
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
    panel.render(ui.column({ padding = 12 }, { ui.label({ text = (open or "?") .. ": no detail yet" }) }))
    return
  end
  local lines = {}
  for i, runs in ipairs(d.lines or {}) do
    lines[i] = line(runs, i)
  end
  local sections = {}
  if (d.click or "") ~= "" then
    sections[#sections + 1] = ui.row({ justify = "end" }, {
      ui.button({ text = "Open", glyph = "external-link", variant = "ghost", controlSize = "sm", onClick = runClick(d.click) }),
    })
  end
  sections[#sections + 1] = ui.scroll({ flexGrow = 1, gap = 2 }, lines)
  panel.render(ui.column({ flexGrow = 1, gap = 4, padding = 12 }, sections))
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

-- context: a chip id from `noctalia msg panel-open dotfiles/chips:detail custom/ci`; a chip
-- click passes none and names itself in "dotfiles.detail.want".
function onOpen(context)
  show((context ~= nil and context ~= "") and context or noctalia.state.get("dotfiles.detail.want"))
  noctalia.state.set("dotfiles.detail.shown", open)
end

function onClose()
  open = nil
  noctalia.state.set("dotfiles.detail.shown", nil)
end

-- Another chip clicked while this panel is open: show that chip's detail in place.
noctalia.state.watch("dotfiles.detail.want", function(module)
  if open ~= nil and module ~= nil and module ~= open then
    show(module)
    noctalia.state.set("dotfiles.detail.shown", open)
  end
end)
