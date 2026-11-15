-- Bind helpers plus the bind registry.
--
-- 0.57 reports every Lua bind's action as an opaque "HL.Dispatcher(exec_cmd)" in
-- `hyprctl binds -j`, so the command a bind runs is not readable from Hyprland.
-- Every bind made here is also recorded in HYPR_BINDS, which `hypr-binds` reads with
-- `hyprctl repl 'return hypr_binds_json()'`: the same fields as `hyprctl binds -j`
-- (submap, modmask, key, description, dispatcher, arg), with the action spelled out.
-- control-menu runs a row whose dispatcher is "exec", so a leaf's arg is its command.
local M = {}

HYPR_BINDS = {}
local current = ""

local MODS = { SUPER = 64, CTRL = 4, CONTROL = 4, ALT = 8, SHIFT = 1 }

local function split(keys)
    local mask, key = 0, nil
    for part in keys:gmatch("[^+%s]+") do
        local bit = MODS[part:upper()]
        if bit then mask = mask | bit else key = part end
    end
    return mask, key
end

-- bind(keys, description, action, label, opts): label is "<dispatcher> <arg>", the
-- action as the registry reports it.
function M.bind(keys, desc, action, label, opts)
    local o = { description = desc }
    for name, v in pairs(opts or {}) do o[name] = v end
    hl.bind(keys, action, o)
    local mask, key = split(keys)
    local dispatcher, arg = label:match("^(%S+)%s*(.*)$")
    table.insert(HYPR_BINDS, {
        submap = current, modmask = mask, key = key, description = desc,
        dispatcher = dispatcher, arg = arg,
    })
end

-- exec(keys, description, cmd, opts): a bind that runs one shell command.
function M.exec(keys, desc, cmd, opts)
    M.bind(keys, desc, hl.dsp.exec_cmd(cmd), "exec " .. cmd, opts)
end

-- run(...): a function action that dispatches each argument in order.
function M.run(...)
    local steps = { ... }
    return function()
        for _, d in ipairs(steps) do hl.dispatch(d) end
    end
end

-- submap(name, fn): define a submap; binds made inside fn are recorded under it.
function M.submap(name, fn)
    hl.define_submap(name, function()
        local outer = current
        current = name
        fn()
        current = outer
    end)
end

local function str(s)
    return '"' .. (tostring(s):gsub('[%c"\\]', function(c)
        return string.format("\\u%04x", c:byte())
    end)) .. '"'
end

function hypr_binds_json()
    local rows = {}
    for _, b in ipairs(HYPR_BINDS) do
        rows[#rows + 1] = string.format(
            '{"submap":%s,"modmask":%d,"key":%s,"description":%s,"dispatcher":%s,"arg":%s}',
            str(b.submap), b.modmask, str(b.key), str(b.description), str(b.dispatcher), str(b.arg))
    end
    return "[" .. table.concat(rows, ",") .. "]"
end

return M
