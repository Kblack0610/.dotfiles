-- The pin leader: Super+A opens a which-key tree of submaps, each drawn by
-- ~/.config/waybar/pin-hint.sh from its described binds (`hyprctl binds -j`).
-- A leaf runs its command, closes the hint and leaves the tree; a branch opens its
-- child's hint and submap; Escape goes back one level and q leaves.
-- Every bind in the tree is dont_inhibit, so it works over a shortcut-inhibiting client.
local k = require("conf.keys")
local dsp = hl.dsp
local HINT = "~/.config/waybar/pin-hint.sh "
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
    k.bind(key, desc, k.run(dsp.exec_cmd(cmd), dsp.exec_cmd(HINT .. "close"), dsp.submap("reset")),
        "exec " .. cmd, through)
end

local function branch(key, desc, sm)
    k.bind(key, desc, open(sm), "submap " .. sm, through)
end

local function exits(parent)
    if parent then
        k.bind("escape", "back", open(parent), "submap " .. parent, through)
    else
        k.bind("escape", "exit", k.run(dsp.exec_cmd(HINT .. "close"), dsp.submap("reset")), "submap reset", through)
    end
    k.bind("q", "exit", k.run(dsp.exec_cmd(HINT .. "close"), dsp.submap("reset")), "submap reset", through)
end

local function float(cmd) return "kitty --class floating-term -e " .. cmd end
local function paused(script) return float("sh -c '" .. script .. " ; echo ; read -r _'") end

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
    exits(nil)
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
