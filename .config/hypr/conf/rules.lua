-- Window rules. match fields are regexes; each rule is named so `hyprctl` errors point here.
local function rule(name, match, effects)
    effects.name  = name
    effects.match = match
    hl.window_rule(effects)
end

local function floating(name, class, w, h)
    rule(name, { class = "^(" .. class .. ")$" }, { float = true, size = { w, h }, center = true })
end

-- Popups launched by binds and the pin leader.
floating("floating-term", "floating-term", 720, 460)
floating("control-menu",  "control-menu",  1400, 820)
floating("storage-term",  "storage-term",  1100, 760)
floating("oculante",      "oculante",      1400, 900)
rule("keys", { class = "^(keys)$" }, { fullscreen = true })

-- Home workspaces.
rule("kitty-ws1",    { class = "^(kitty)$" },                     { workspace = "1" })
rule("firefox-ws2",  { class = "^(firefox)$" },                   { workspace = "2" })
rule("freerdp-ws4",  { class = "^(com\\.freerdp\\.client\\.sdl3)$" }, { workspace = "4" })
rule("vnc-ws5",      { class = "^(Vncviewer)$" },                 { workspace = "5" })
rule("chat-ws8",     { class = "^(slack|discord|[Ss]potify|REAPER)$" }, { workspace = "8" })
rule("chat-group",   { class = "^(slack|discord|[Ss]potify|REAPER)$", float = false }, { group = "set" })
rule("unityhub-ws9", { class = "^([Uu]nity[Hh]ub)$" },            { workspace = "9" })
rule("unity-tiled-ws3", { class = "^([Uu]nity([Hh]ub)?-.*)$", float = false }, { workspace = "3" })
rule("unity-ws3",    { class = "^([Uu]nity)$" },                  { workspace = "3 silent" })
rule("scrcpy-ws7",   { class = "^(scrcpy)$" },                    { workspace = "7", group = "barred" })

-- Steam on 9, games on 10 (Super+0); each takes you there. Steam's floating dialogs and toasts
-- stay on the focused workspace, so a friend-online popup never pulls you away. Proton and
-- Steam-launched games map as steam_app_<appid>; a standalone game has no shared class, so it is
-- caught only when it sets the Wayland content type to game.
rule("steam-ws9",       { class = "^(steam)$", float = false }, { workspace = "9" })
rule("steam-game-ws10", { class = "^(steam_app_.+)$" },         { workspace = "10" })
rule("game-ws10",       { content = "game" },                   { workspace = "10" })

-- Automation windows land on 7 without stealing focus.
local quiet = function() return { workspace = "7", no_initial_focus = true, suppress_event = "activate" } end
rule("playwright-ws7", { class = "^(chromium|Chromium|chrome|Chrome|google-chrome|Google-chrome)$", title = ":.*Playwright.*" }, quiet())
rule("firefox-default-ws7", { class = "^(firefox-default)$" }, quiet())
rule("emulator-ws7", { class = "^([Ee]mulator(64)?(-arm)?|qemu-system)$" }, quiet())
