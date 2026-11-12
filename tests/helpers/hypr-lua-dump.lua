-- hypr-lua-dump.lua <config-dir> <binds|registry>: load the real Hyprland Lua config under
-- plain Lua with a stub `hl`, so tests read what it declares without a running Hyprland.
--   binds     every hl.bind call as submap<TAB>keys<TAB>description, in call order
--   registry  hypr_binds_json(), the registry hypr-binds reads over `hyprctl repl`
-- Any hl.* not stubbed below is a no-op that returns a value describing itself.
local dir, mode = arg[1], arg[2]
package.path = dir .. "/?.lua;" .. package.path

local function stub(path)
    return setmetatable({}, {
        __index = function(t, k)
            local v = stub(path .. "." .. k)
            rawset(t, k, v)
            return v
        end,
        __call = function() return path end,
    })
end

hl = stub("hl")
local submap, out = "", {}
hl.bind = function(keys, _, opts)
    out[#out + 1] = table.concat({ submap, keys, (opts or {}).description or "" }, "\t")
end
hl.define_submap = function(name, a, b)
    local outer = submap
    submap = name
    ;(b or a)()
    submap = outer
end

-- conf/theme.lua is rendered by theme-switch and gitignored, so a fresh clone (CI) has none;
-- the colors do not matter to a bind dump.
local theme = io.open(dir .. "/conf/theme.lua")
if theme then
    theme:close()
else
    package.preload["conf.theme"] = function() return setmetatable({}, { __index = function() return "00000000" end }) end
end

dofile(dir .. "/hyprland.lua")

if mode == "binds" then
    for _, l in ipairs(out) do print(l) end
elseif mode == "registry" then
    print(hypr_binds_json())
else
    io.stderr:write("usage: hypr-lua-dump.lua <config-dir> <binds|registry>\n")
    os.exit(2)
end
