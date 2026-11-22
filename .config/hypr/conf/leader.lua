-- The pin leader: Super+A opens a which-key tree of submaps, each drawn by
-- ~/.config/waybar/pin-hint.sh from its described binds (`hyprctl binds -j`).
-- A leaf runs its command, closes the hint and leaves the tree; a branch opens its
-- child's hint and submap; Escape goes back one level and q leaves.
-- Every bind in the tree is dont_inhibit, so it works over a shortcut-inhibiting client.
local k = require("conf.keys")
local dsp = hl.dsp
local HINT = "~/.config/waybar/pin-hint.sh "

-- Leaving the leader: close the hint, then drop back to the global binds.
local function leave(...)
    local steps = { ... }
    steps[#steps + 1] = dsp.exec_cmd(HINT .. "close")
    steps[#steps + 1] = dsp.submap("reset")
    return k.run(table.unpack(steps))
end
local BIN = "$HOME/.local/bin/"
local through = { dont_inhibit = true }

-- The hint's name for a submap: "main" for pinbar, X for pinbar-X.
local function hint(sm)
    return HINT .. (sm == "pinbar" and "main" or sm:gsub("^pinbar%-", ""))
end

local function open(sm)
    return k.run(dsp.exec_cmd(hint(sm)), dsp.submap(sm))
end

local function leaf(key, desc, cmd)
    k.bind(key, desc, leave(dsp.exec_cmd(cmd)),
        "exec " .. cmd, through)
end

local function branch(key, desc, sm)
    k.bind(key, desc, open(sm), "submap " .. sm, through)
end

local function exits(parent)
    if parent then
        k.bind("escape", "back", open(parent), "submap " .. parent, through)
    else
        k.bind("escape", "exit", leave(), "submap reset", through)
    end
    k.bind("q", "exit", leave(), "submap reset", through)
end

local function float(cmd) return "kitty --class floating-term -e " .. cmd end
local function paused(script) return float("sh -c '" .. script .. " ; echo ; read -r _'") end

-- The bar's panels by key (Super+A b; docs/desk.md, "Panel keys"): a custom/* chip opens its
-- dropdown, anything else is a Noctalia panel id and its context. While the submap is open
-- each of these chips shows its key in the bar.
local PANELS = {
    { "u", "needs you", "custom/needs" },
    { "h", "health", "custom/health" }, { "f", "fleet", "custom/fleet" },
    { "p", "projects", "custom/projects" }, { "a", "agents", "custom/ai-agents" },
    { "d", "queue", "custom/queue" }, { "c", "ci", "custom/ci" },
    { "t", "timebox", "custom/timebox" }, { "w", "webcam", "custom/webcam" },
    { "x", "passthrough", "custom/passthrough" }, { "r", "printer", "custom/printer" },
    { "l", "load", "custom/load" }, { "s", "storage", "custom/storage" },
    { "n", "notifications", "custom/notify" },
    { "space", "control center", "control-center" }, { "v", "audio", "control-center audio" },
    { "i", "network", "control-center network" }, { "b", "bluetooth", "control-center bluetooth" },
    { "m", "media", "control-center media" }, { "k", "calendar", "control-center calendar" },
    { "o", "session", "session" }, { "y", "tray", "tray-drawer" },
}
local letters = {}
for _, p in ipairs(PANELS) do
    if p[3]:match("^custom/") then letters[#letters + 1] = p[3] .. "=" .. p[1] end
end
local LETTERS_ON = BIN .. "desk panel letters '" .. table.concat(letters, " ") .. "'"

-- Entry: Super+A, and Ctrl+Shift+A for when a client grabs Super.
k.bind("SUPER + A", "pin leader", open("pinbar"), "submap pinbar")
k.bind("CTRL + SHIFT + A", "pin leader", open("pinbar"), "submap pinbar", through)

k.submap("pinbar", function()
    leaf("space", "control menu", "kitty --class control-menu -e $HOME/.local/bin/control-menu")
    leaf("p", "toggle the pin bar", "~/.config/waybar/pin.sh toggle")
    branch("a", "agents >", "pinbar-agents")
    branch("k", "keys >", "pinbar-keys")
    branch("t", "timebox >", "pinbar-timebox")
    branch("i", "inputs >", "pinbar-input")
    branch("m", "machine mode >", "pinbar-mode")
    branch("u", "utils >", "pinbar-utils")
    branch("s", "settings >", "pinbar-settings")
    branch("d", "desk parts >", "pinbar-desk")
    k.bind("b", "bar panels >", k.run(dsp.exec_cmd(LETTERS_ON), dsp.exec_cmd(hint("pinbar-panels")),
        dsp.submap("pinbar-panels")), "submap pinbar-panels", through)
    exits(nil)
end)

-- Each of its own ways out (a key, Escape, q) clears the letters from the chips.
k.submap("pinbar-panels", function()
    local off = dsp.exec_cmd(BIN .. "desk panel letters off")
    for _, p in ipairs(PANELS) do
        local cmd = "out=$(" .. BIN .. "desk panel " .. p[3] .. ' 2>&1) || notify-send -t 3000 desk "$out"'
        k.bind(p[1], p[2], leave(off, dsp.exec_cmd(cmd)), "exec " .. cmd, through)
    end
    k.bind("escape", "back", k.run(off, dsp.exec_cmd(hint("pinbar")), dsp.submap("pinbar")), "submap pinbar", through)
    k.bind("q", "exit", leave(off), "submap reset", through)
end)

k.submap("pinbar-agents", function()
    leaf("a", "agent panel", BIN .. "tmx popup " .. BIN .. "agent-panel")
    leaf("w", "all sessions", BIN .. "tmx popup " .. BIN .. "tmx pick")
    leaf("c", "scratch claude", "$HOME/.local/src/tmux/scratch.sh popup")
    leaf("n", "pick a page", BIN .. "tmx popup " .. BIN .. "agent-notify pick")
    leaf("o", "open the newest page", BIN .. "agent-notify open")
    leaf("h", "triage the newest page", BIN .. "agent-notify triage")
    exits("pinbar")
end)

k.submap("pinbar-keys", function()
    for _, l in ipairs({ { "a", "all keys", "all" }, { "h", "hyprland keys", "hypr" },
                         { "t", "tmux keys", "tmux" }, { "n", "nvim keys", "nvim" } }) do
        leaf(l[1], l[2], "kitty --class keys -e " .. BIN .. "keys " .. l[3])
    end
    exits("pinbar")
end)

k.submap("pinbar-input", function()
    for _, l in ipairs({ { "m", "umc mic" }, { "c", "brio" }, { "g", "instruments" },
                         { "b", "instruments and mic" }, { "w", "instruments and brio" } }) do
        leaf(l[1], l[2], "~/.config/waybar/audio_input.sh set " .. l[1])
    end
    exits("pinbar")
end)

k.submap("pinbar-mode", function()
    for _, l in ipairs({ { "r", "reserved" }, { "s", "shared" }, { "o", "open" }, { "f", "full" } }) do
        leaf(l[1], l[2], BIN .. "machine-mode " .. l[2])
    end
    exits("pinbar")
end)

-- Which bar and notifier run (desk, docs/desk.md). desk's own line, or its error (a part
-- not installed), comes back as a notification, since a keybind has no terminal.
k.submap("pinbar-desk", function()
    for _, l in ipairs({
        { "c", "bar", "waybar-classic" }, { "m", "bar", "waybar-modern" }, { "n", "bar", "noctalia" },
        { "d", "notify", "dunst" }, { "s", "notify", "swaync" },
    }) do
        local use = "desk use " .. l[2] .. " " .. l[3]
        leaf(l[1], l[2] .. ": " .. l[3],
            'notify-send -t 3000 desk "$(' .. BIN .. use .. ' 2>&1 || echo "' .. use .. ' failed")"')
    end
    exits("pinbar")
end)

k.submap("pinbar-utils", function()
    leaf("h", "ssh into a host", float("$HOME/.config/waybar/machines.sh pick"))
    leaf("r", "reload the pin", "~/.config/waybar/pin.sh reload")
    branch("y", "sync >", "pinbar-sync")
    branch("g", "git >", "pinbar-git")
    exits("pinbar")
end)

k.submap("pinbar-settings", function()
    for _, l in ipairs({ { "a", "agents" }, { "f", "fleet" }, { "t", "timebox" }, { "m", "machines" } }) do
        leaf(l[1], "hide/show " .. l[2], "~/.config/waybar/modules.sh toggle " .. l[2])
    end
    leaf("l", "module list", float("~/.config/waybar/modules.sh menu"))
    leaf("s", "pin size", "~/.config/waybar/pin.sh size")
    exits("pinbar")
end)

local TB = BIN .. "timebox"
local function prompt(question, verb)
    return float("sh -c 'printf \"" .. question .. "\" ; read -r op ; [ -n \"$op\" ] || exit ; "
        .. "printf \"lap [e.g. 25m, blank=default]: \" ; read -r lap ; if [ -n \"$lap\" ] ; then "
        .. TB .. " " .. verb .. " \"$op\" --lap \"$lap\" ; else " .. TB .. " " .. verb .. " \"$op\" ; fi'")
end

k.submap("pinbar-timebox", function()
    leaf("t", "task queue panel", float(BIN .. "timebox-panel"))
    leaf("a", "add a task", float(BIN .. "timebox-panel act add"))
    leaf("d", "done: next task", TB .. " done")
    leaf("l", "load a preset", float(BIN .. "timebox-panel act load"))
    leaf("s", "start an op", prompt("start op: ", "start"))
    leaf("w", "switch op", prompt("switch to op: ", "switch"))
    leaf("m", "toggle sound", 'agent-notify -t timebox "$(' .. TB .. ' toggle sound)"')
    leaf("b", "toggle flash", 'agent-notify -t timebox "$(' .. TB .. ' toggle flash)"')
    leaf("p", "pause", TB .. " pause")
    leaf("r", "resume", TB .. " resume")
    leaf("x", "stop all", TB .. " stop --all")
    leaf("o", "status and stats", paused(TB .. " status ; echo ; " .. TB .. " stats"))
    exits("pinbar")
end)

k.submap("pinbar-sync", function()
    leaf("d", "restow dotfiles", paused("cd $HOME/.dotfiles && stow -v . ; echo ; echo [done]"))
    leaf("n", "pull notes", paused("git -C $HOME/.notes pull --ff-only"))
    exits("pinbar-utils")
end)

k.submap("pinbar-git", function()
    leaf("p", "pull dotfiles and notes", paused('for d in $HOME/.dotfiles $HOME/.notes ; do echo "== $d ==" ; git -C "$d" pull --ff-only ; done'))
    leaf("s", "dotfiles git status", paused("git -C $HOME/.dotfiles status"))
    exits("pinbar-utils")
end)
