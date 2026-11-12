-- Hyprland 0.57+ reads only Lua; the hyprlang .conf format is gone.
-- Each module is one concern; require() runs it in its own scope, so an error in
-- one does not stop the rest. Reload: `hyprctl reload`, or save any file here.
-- Reference: https://wiki.hypr.land/configuring/

require("conf.env")
require("conf.monitors")
require("conf.autostart")
require("conf.look-and-feel")
require("conf.input")
require("conf.rules")
require("conf.keybindings")
require("conf.leader")
