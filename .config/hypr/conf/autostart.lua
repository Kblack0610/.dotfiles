local programs = require("conf.programs")

hl.on("hyprland.start", function()
    hl.exec_cmd("dbus-update-activation-environment --systemd WAYLAND_DISPLAY XDG_CURRENT_DESKTOP")
    hl.exec_cmd("hyprpaper")
    hl.exec_cmd("hypridle")
    hl.exec_cmd(programs.terminal)
    hl.exec_cmd("~/.config/hypr/scripts/unity-workspace-router.py")
    hl.exec_cmd("pkill -RTMIN+11 waybar")
end)

-- The waybar submap chip reads live state; refresh it at start (above) and on every reload.
hl.on("config.reloaded", function()
    hl.exec_cmd("pkill -RTMIN+11 waybar")
end)
