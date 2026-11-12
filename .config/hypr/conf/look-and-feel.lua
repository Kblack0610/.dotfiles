-- Colors come from conf/theme.lua, which theme-switch writes in full from the palette
-- (gitignored; the installers and the post-merge hook render it). Layout lives here.
-- A clone where theme-switch has not run yet gets neutral greys and a notice, not a dead config.
local ok, theme = pcall(require, "conf.theme")
if not ok then
    theme = { active1 = "ccccccee", active2 = "888888ee", inactive = "444444aa", shadow = "1a1a1aee" }
    pcall(hl.notification.create, { text = "conf/theme.lua missing: run theme-switch <theme>", timeout = 10000, icon = "warning" })
end

local function gradient(a, b)
    return { colors = { "rgba(" .. a .. ")", "rgba(" .. b .. ")" }, angle = 45 }
end
local inactive = "rgba(" .. theme.inactive .. ")"

hl.config({
    general = {
        gaps_in  = 5,
        gaps_out = 20,
        border_size = 2,
        col = {
            active_border   = gradient(theme.active1, theme.active2),
            inactive_border = inactive,
        },
        resize_on_border = false,
        allow_tearing    = false, -- see https://wiki.hypr.land/configuring/extra/tearing/
        layout = "dwindle",
    },

    decoration = {
        rounding       = 10,
        rounding_power = 2,
        active_opacity   = 0.9,
        inactive_opacity = 0.8,
        shadow = {
            enabled      = true,
            range        = 4,
            render_power = 3,
            color        = "rgba(" .. theme.shadow .. ")",
        },
        blur = {
            enabled  = true,
            size     = 3,
            passes   = 1,
            vibrancy = 0.1696,
        },
    },

    animations = { enabled = true },

    dwindle = { preserve_split = true },
    master  = { new_status = "master" },

    -- A group IS the active window, just stacked: its border runs the active gradient
    -- in reverse, so a stacked tile reads apart from a plain focused one at a glance.
    group = {
        col = {
            border_active   = gradient(theme.active2, theme.active1),
            border_inactive = inactive,
        },
        groupbar = {
            enabled            = true,
            render_titles      = true,
            height             = 24,
            indicator_height   = 4,
            font_size          = 11,
            font_weight_active   = "bold",
            font_weight_inactive = "normal",
            gradients          = true,
            col = {
                active   = gradient(theme.active1, theme.active2),
                inactive = inactive,
            },
            text_color          = "rgba(1c1c1cff)",
            text_color_inactive = "rgba(b0b0b0ff)",
            rounding          = 6,
            gradient_rounding = 6,
            gaps_in  = 3,
            gaps_out = 4,
        },
    },

    misc = {
        force_default_wallpaper = -1,
        disable_hyprland_logo   = false,
    },
})

hl.curve("easeOutQuint",   { type = "bezier", points = { {0.23, 1},    {0.32, 1} } })
hl.curve("easeInOutCubic", { type = "bezier", points = { {0.65, 0.05}, {0.36, 1} } })
hl.curve("linear",         { type = "bezier", points = { {0, 0},       {1, 1} } })
hl.curve("almostLinear",   { type = "bezier", points = { {0.5, 0.5},   {0.75, 1} } })
hl.curve("quick",          { type = "bezier", points = { {0.15, 0},    {0.1, 1} } })

for _, a in ipairs({
    { "global",        10,   "default" },
    { "border",        5.39, "easeOutQuint" },
    { "windows",       4.79, "easeOutQuint" },
    { "windowsIn",     4.1,  "easeOutQuint", "popin 87%" },
    { "windowsOut",    1.49, "linear",       "popin 87%" },
    { "fadeIn",        1.73, "almostLinear" },
    { "fadeOut",       1.46, "almostLinear" },
    { "fade",          3.03, "quick" },
    { "layers",        3.81, "easeOutQuint" },
    { "layersIn",      4,    "easeOutQuint", "fade" },
    { "layersOut",     1.5,  "linear",       "fade" },
    { "fadeLayersIn",  1.79, "almostLinear" },
    { "fadeLayersOut", 1.39, "almostLinear" },
    { "workspaces",    1.94, "almostLinear", "fade" },
    { "workspacesIn",  1.21, "almostLinear", "fade" },
    { "workspacesOut", 1.94, "almostLinear", "fade" },
    { "zoomFactor",    7,    "quick" },
}) do
    hl.animation({ leaf = a[1], enabled = true, speed = a[2], bezier = a[3], style = a[4] })
end
