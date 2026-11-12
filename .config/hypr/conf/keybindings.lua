-- Global binds. Every bind carries a description: `keys` and the pin hint list them,
-- and tests/unit/hypr_keys_doc.bats fails on one without.
local k = require("conf.keys")
local p = require("conf.programs")
local dsp, win = hl.dsp, hl.dsp.window
local S = "SUPER + "
local SCRIPTS = "~/.config/hypr/scripts/"

-- Let RustDesk and VDI clients receive chords Hyprland does not bind.
hl.config({ binds = { disable_keybind_grabbing = true } })

-- Launchers
local shot = [[grimblast copysave area $HOME"/Media/Pictures/"$(date +'%F-%T.png')]]
k.bind("F7", "screenshot an area", k.run(dsp.exec_cmd(shot), dsp.submap("reset")), "exec " .. shot)
k.exec(S .. "C", "Firefox", "firefox")
k.exec(S .. "RETURN", "terminal", p.terminal)
k.bind(S .. "Q", "close the window", win.close(), "close")
k.exec(S .. "E", "screenshots folder", p.fileManager .. " ~/Media/Pictures")
k.exec(S .. "I", "newest screenshot", [[sh -c 'f=$(ls -t "$HOME"/Media/Pictures/* 2>/dev/null | head -1); [ -n "$f" ] && oculante "$f"']])
k.exec(S .. "D", "app launcher", p.menu)
k.exec(S .. "B", "karakeep bookmarks", "~/.local/bin/karakeep-menu")
k.exec(S .. "K", "kblab sites", "~/.local/bin/kblab-menu")
k.exec(S .. "P", "display mode", SCRIPTS .. "display-mode.sh")

-- Picture in picture: float, 640x360, pinned into a top corner.
local function pip(keys, desc, side)
    k.bind(keys, desc, k.run(
        win.float({ action = "toggle" }),
        win.resize({ x = 640, y = 360 }),
        win.move({ direction = side }),
        win.move({ direction = "up" }),
        win.pin()), "pip " .. side)
end
pip(S .. "SHIFT + P", "picture-in-picture top right", "right")
pip(S .. "SHIFT + O", "picture-in-picture top left", "left")

-- Pin bar and notifications
k.exec(S .. "SHIFT + M", "show or hide the pin bar", "~/.config/waybar/pin.sh toggle")
k.exec(S .. "SHIFT + comma", "pin bar small or big", "~/.config/waybar/pin.sh size")
k.exec(S .. "N", "close the newest notification", "dunstctl close")
k.exec(S .. "SHIFT + N", "close every notification", "dunstctl close-all")
k.exec(S .. "CTRL + N", "notification history", "dunstctl history-pop")
k.exec(S .. "ALT + N", "pause or resume notifications", "dunstctl set-paused toggle")

-- Layout
k.bind(S .. "ALT + P", "pseudotile the window", win.pseudo(), "pseudo")
k.bind(S .. "W", "flip the split direction", dsp.layout("togglesplit"), "layout togglesplit")
k.bind(S .. "F", "fullscreen", win.fullscreen(), "fullscreen")

-- Voice
k.exec(S .. "R", "voice typing", "~/.local/bin/gungan stream")
k.exec(S .. "SHIFT + R", "record and transcribe", "~/.local/bin/gungan --type record")
k.exec(S .. "ALT + R", "voice to a Claude session", "~/.local/bin/agent-voice")
k.exec(S .. "CTRL + R", "stop recording", SCRIPTS .. "gungan-force-stop.sh")

-- Stacks (groups)
k.bind(S .. "T", "stack this window into tabs or unstack it", dsp.group.toggle(), "group toggle")
k.bind(S .. "SHIFT + T", "take this window out of its stack", win.move({ out_of_group = true }), "group out")
k.exec(S .. "G", "stack every window on the workspace", SCRIPTS .. "group-all.sh")
k.exec(S .. "ALT + G", "unstack every window on the workspace", SCRIPTS .. "ungroup-all.sh")
k.bind(S .. "SHIFT + G", "merge into the stack next to it", k.run(
    win.move({ into_group = "left" }), win.move({ into_group = "right" }),
    win.move({ into_group = "up" }), win.move({ into_group = "down" })), "group merge")
k.bind(S .. "SHIFT + H", "previous tab in the stack", dsp.group.prev(), "group prev")
k.bind(S .. "SHIFT + L", "next tab in the stack", dsp.group.next(), "group next")

-- Focus, move, resize (vim keys)
for _, kd in ipairs({ { "h", "left" }, { "l", "right" }, { "k", "up" }, { "j", "down" } }) do
    local key, d = kd[1], kd[2]
    k.bind(S .. key, "focus " .. d, dsp.focus({ direction = d }), "focus " .. d)
    k.bind(S .. "CTRL + " .. key, "move the window " .. d, win.move({ direction = d }), "move " .. d)
end
for _, r in ipairs({ { "h", "narrower", -40, 0 }, { "l", "wider", 40, 0 }, { "k", "shorter", 0, -40 }, { "j", "taller", 0, 40 } }) do
    local key = table.remove(r, 1)
    k.bind(S .. "ALT + " .. key, r[1], win.resize({ x = r[2], y = r[3], relative = true }),
        "resize " .. r[2] .. " " .. r[3], { repeating = true })
end

-- Workspaces
for i = 1, 10 do
    local key = tostring(i % 10)
    k.bind(S .. key, "workspace " .. i, dsp.focus({ workspace = i }), "workspace " .. i)
    k.bind(S .. "SHIFT + " .. key, "send the window to workspace " .. i, win.move({ workspace = i }), "movetoworkspace " .. i)
end
k.bind(S .. "S", "show or hide the scratchpad", dsp.workspace.toggle_special("magic"), "togglespecialworkspace magic")
k.bind(S .. "SHIFT + S", "send the window to the scratchpad", win.move({ workspace = "special:magic" }), "movetoworkspace special:magic")
k.bind(S .. "mouse_down", "next workspace", dsp.focus({ workspace = "e+1" }), "workspace e+1")
k.bind(S .. "mouse_up", "previous workspace", dsp.focus({ workspace = "e-1" }), "workspace e-1")

-- Remote desktop: these fire even while a client inhibits shortcuts.
local through = { dont_inhibit = true }
k.exec("CTRL + ALT + SHIFT + Escape", "escape from RustDesk", SCRIPTS .. "rustdesk-escape.sh", through)
k.exec("CTRL + ALT + SHIFT + G", "full keyboard passthrough to RustDesk on or off", SCRIPTS .. "rustdesk-grab-toggle.sh", through)
k.exec("CTRL + ALT + SHIFT + B", "fullscreen under the bar or over it", SCRIPTS .. "fullscreen-bar.sh", through)

-- Mouse
k.bind(S .. "mouse:272", "drag to move the window", win.drag(), "drag", { mouse = true })
k.bind(S .. "mouse:273", "drag to resize the window", win.resize(), "resize", { mouse = true })

-- Media keys work on the lock screen; volume and brightness repeat while held.
local held = { locked = true, repeating = true }
k.exec("XF86AudioRaiseVolume", "volume up", "wpctl set-volume -l 1 @DEFAULT_AUDIO_SINK@ 5%+", held)
k.exec("XF86AudioLowerVolume", "volume down", "wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%-", held)
k.exec("XF86AudioMute", "mute", "wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle", held)
k.exec("XF86AudioMicMute", "mute the mic", "wpctl set-mute @DEFAULT_AUDIO_SOURCE@ toggle", held)
k.exec("XF86MonBrightnessUp", "brightness up", "brightnessctl -e4 -n2 set 5%+", held)
k.exec("XF86MonBrightnessDown", "brightness down", "brightnessctl -e4 -n2 set 5%-", held)
k.exec("XF86AudioNext", "next track", "playerctl next", { locked = true })
k.exec("XF86AudioPause", "play or pause", "playerctl play-pause", { locked = true })
k.exec("XF86AudioPlay", "play or pause", "playerctl play-pause", { locked = true })
k.exec("XF86AudioPrev", "previous track", "playerctl previous", { locked = true })

-- Hardware
k.exec(S .. "SHIFT + K", "laptop keyboard on or off", SCRIPTS .. "toggle-laptop-keyboard.sh toggle")
k.exec(S .. "SHIFT + F", "hold the left mouse button or let go", SCRIPTS .. "bg-autoclicker.sh")

-- VDI passthrough: a submap with one bind, so every other chord reaches the VDI client.
k.bind(S .. "grave", "VDI passthrough on", k.run(
    dsp.submap("passthru"),
    dsp.exec_cmd([[notify-send -t 2000 "Hyprland" "VDI passthrough ON - Super+Esc to exit"; pkill -RTMIN+11 waybar]])),
    "submap passthru")
k.submap("passthru", function()
    k.bind(S .. "Escape", "VDI passthrough off", k.run(
        dsp.submap("reset"),
        dsp.exec_cmd([[notify-send -t 2000 "Hyprland" "VDI passthrough OFF"; pkill -RTMIN+11 waybar]])),
        "submap reset")
end)
