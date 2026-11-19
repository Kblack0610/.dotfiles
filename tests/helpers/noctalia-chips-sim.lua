-- noctalia-chips-sim.lua <plugin-dir>: run the dotfiles/chips plugin's chip.luau and detail.luau
-- under plain Lua with a stub Noctalia, driven by commands on stdin, so tests check the
-- dropdown's hover, click and close logic without a running shell. Commands, one per line:
--   chip <id> [nodrop]     load a chip (nodrop: config.toml `dropdown = false`)
--   hover <id> on|off      pointer enters or leaves the chip
--   click <id>             left click on the chip
--   panelhover on|off [bool]  pointer enters or leaves a node in the panel (bool: passed as a
--                          boolean, not the documented "true"/"false" string)
--   letter <id>            `desk panel` opening the panel for <id> (Super+A b)
--   settle                 run the togglePanel calls queued so far (the host runs them later)
--   drop                   lose the queued togglePanel calls, as a host that never answers
--   tick <ms>              advance the clock (nowMs) by <ms>; one frame, delivered only while
--                          the panel wants frame ticks
--   show                   print "panel=<shown chip or closed>" and each chip's tooltip
-- The stub's json.decode maps the tokens its runAsync prints back to tables, so no JSON parser.
local dir = arg[1]
local PANEL = "dotfiles/chips:detail"

local state, watchers = {}, {}
local tokens, ntok = {}, 0
local queue = {}
local now = 0
local panelOpen, frameTicks, panelHover = false, false, nil
local chips, order = {}, {}
local detail

local function token(t)
    ntok = ntok + 1
    tokens["T" .. ntok] = t
    return "T" .. ntok
end

local function node(kind)
    return function(props, children)
        return { kind = kind, props = props or {}, children = children or {} }
    end
end
local ui = setmetatable({}, { __index = function(_, k) return node(k) end })

-- The last onHover the panel rendered: the panel's own hover callback.
local function findHover(n)
    if type(n) ~= "table" then return nil end
    if n.props and type(n.props.onHover) == "function" then return n.props.onHover end
    for _, c in ipairs(n.children or {}) do
        local f = findHover(c)
        if f then return f end
    end
end

local function api(conf)
    return {
        getConfig = function(k) return conf[k] end,
        getenv = function() return "/home/sim" end,
        nowMs = function() return now end,
        setUpdateInterval = function() end,
        runStream = function() end,
        runAsync = function(cmd, cb)
            if not cb then return end
            local id = string.match(cmd, "chip '([^']+)'")
            if string.match(cmd, " run$") then
                cb({ stdout = token({ text = id, tooltip = id .. " first\n" .. id .. " second",
                    detail = { { { t = id .. " first" } }, { { t = id .. " second" } } } }) })
            else
                cb({ stdout = token({ mode = "once", click = "", right_click = "", middle_click = "" }) })
            end
        end,
        togglePanel = function(id, ctx)
            assert(id == PANEL, "unknown panel " .. tostring(id))
            queue[#queue + 1] = ctx or ""
        end,
        json = {
            decode = function(s) return tokens[s] end,
            encode = function(t) ntok = ntok + 1; return "E" .. ntok end,
        },
        state = {
            get = function(k) return state[k] end,
            set = function(k, v)
                if state[k] == v then return end
                state[k] = v
                for _, fn in ipairs(watchers[k] or {}) do fn(v) end
            end,
            watch = function(k, fn)
                watchers[k] = watchers[k] or {}
                table.insert(watchers[k], fn)
            end,
        },
    }
end

local function load(file, env)
    setmetatable(env, { __index = _G })
    local chunk = assert(loadfile(dir .. "/" .. file, "t", env))
    chunk()
    return env
end

local function closePanel()
    if panelOpen then
        panelOpen, frameTicks, panelHover = false, false, nil
        detail.onClose()
    end
end

detail = load("detail.luau", {
    ui = ui,
    noctalia = api({}),
    panel = {
        render = function(tree) panelHover = findHover(tree) end,
        close = closePanel,
        setNeedsFrameTick = function(on) frameTicks = on end,
    },
})

local function settle()
    local q = queue
    queue = {}
    for _, ctx in ipairs(q) do
        if panelOpen then
            closePanel()
        else
            panelOpen = true
            detail.onOpen(ctx)
        end
    end
end

local cmds = {}
function cmds.chip(id, opt)
    local env = { ui = ui, noctalia = api({ module = id, dropdown = opt ~= "nodrop", divider = "" }) }
    env.barWidget = {
        render = function() end,
        setVisible = function() end,
        setTooltip = function(t) env.tip = t end,
        clearTooltip = function() env.tip = "" end,
    }
    chips[id] = load("chip.luau", env)
    order[#order + 1] = id
end
function cmds.hover(id, on) chips[id].onHover(on == "on") end
function cmds.click(id) chips[id].onClick() end
function cmds.panelhover(on, kind)
    local v = on == "on"
    if panelHover then panelHover(kind == "bool" and v or tostring(v), "") end
end
function cmds.drop() queue = {} end
function cmds.letter(id) queue[#queue + 1] = id end
function cmds.settle() settle() end
function cmds.tick(ms)
    now = now + tonumber(ms)
    if panelOpen and frameTicks then detail.onFrameTick(ms) end
end
function cmds.show()
    print("panel=" .. (panelOpen and tostring(state["dotfiles.detail.shown"]) or "closed"))
    for _, id in ipairs(order) do
        print("tooltip " .. id .. "=" .. string.gsub(chips[id].tip or "", "\n", "|"))
    end
end

for line in io.lines() do
    local words = {}
    for w in string.gmatch(line, "%S+") do words[#words + 1] = w end
    if #words > 0 then
        local fn = assert(cmds[words[1]], "unknown command " .. words[1])
        fn(table.unpack(words, 2))
    end
end
