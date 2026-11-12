-- Hyprland 0.57+ reads only Lua; the hyprlang .conf format is gone.
-- Each module is one concern. Hyprland reports an error in one module (hyprctl
-- configerrors) and still loads the rest: with conf/theme.lua missing, look-and-feel
-- failed and all 163 binds loaded (seen 2026-11-12). Reload: `hyprctl reload`, or save any file here.
-- Reference: https://wiki.hypr.land/configuring/

require("conf.env")
require("conf.monitors")
require("conf.autostart")
require("conf.look-and-feel")
require("conf.input")
require("conf.rules")
require("conf.keybindings")
require("conf.leader")
