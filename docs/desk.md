# desk: switch the bar and the notifier

`desk` (`.local/bin/desk`) picks which part fills each desktop slot and is the one way scripts and keybinds talk to whichever part is running.

| Slot | Parts | Unit |
|---|---|---|
| bar | `waybar-classic`, `waybar-modern`, `noctalia` | `waybar.service` (our `launch.sh` drop-in), `noctalia.service` |
| notify | `dunst`, `swaync` | `dunst.service`, `swaync.service` |

## Use

```
desk current                 # bar=waybar-classic, notify=dunst
desk use bar waybar-modern   # record it and switch now
desk use notify swaync       # the notifier with a control panel
desk parts                   # every slot's parts and units
```

From the keyboard: Super+A, then d, then `c` waybar-classic, `m` waybar-modern, `n` noctalia, `d` dunst or `s` swaync. Super+A, then b, opens the bar's panels (see "Panel keys"). desk's answer comes back as a notification. `tests/unit/desk.bats` checks that every part has a key and each key runs the part its label names.

The choice lives in `~/.local/state/desk/parts` and survives logout: `desk.service` (wanted by `graphical-session.target`) runs `desk start` at login. A slot with no line runs its first part.

Scripts and binds never signal a part directly:

- `desk signal custom/<chip>` re-runs that chip now, and every chip sharing its signal number. It reads the chip's `"signal"` from `.config/waybar/config.base` (or `config.pin-full`), then sends it to waybar as `SIGRTMIN+N` or to Noctalia over its plugin IPC.
- `desk notify close|close-all|history|dnd` drives the notifier (Super+N, Shift, Ctrl, Alt). Under swaync, `history` opens the control panel.
- `desk notify show <tag> <notify-send args>` sends one popup per tag that the next send with that tag replaces, and `desk notify drop <tag>` closes it. It works under dunst and swaync alike: it sends `x-canonical-private-synchronous`, the replace hint both honour (swaync ignores `x-dunst-stack-tag` and a `dunstify -r` id it did not hand out), and keeps the server's id in `$XDG_RUNTIME_DIR/desk/` for the close. The leader hint (`pin-hint.sh`) and the module toggles (`modules.sh`) use it.

desk never enables, disables or masks a unit: `~/.config/systemd` is this repo, so that would dirty the tree. A slot whose parts run as different units gets `Conflicts=` between them (`dunst.service.d/desk.conf`), so starting one stops the other.

## The two bars

Both read the same chips from `config.base`; they differ only in stylesheet. `launch.sh` gives classic the theme's `style.css` and modern the tracked `style-modern.css`, which imports `style.css`, then `palette.css` (written by `theme-switch` from the active palette), then `layout-modern.css` (a clear bar with three rounded islands). A theme switch recolours both. The pin bar loads `style.css`, so it keeps the classic look under either.

## Noctalia

`desk use bar noctalia` runs the Noctalia shell (`noctalia.service`, which conflicts with `waybar.service`). Its bar is laid out in the tracked `.config/noctalia/config.toml`: Noctalia's own workspaces, clock, volume, network, Bluetooth, tray and control center, `sysmon` for CPU and GPU temperature and memory, and `caffeine` for waybar's idle inhibitor, plus our chips. The bar itself is clear, and the chips sit in pods (`[[bar.default.capsule_group]]`, referenced as `group:<id>` in a lane): live input, the fleet and the host on the left, sound and network, system load, the tray and the clock (time and date) on the right. Pods have a border in the palette's outline grey and 10 px between readings. The workspaces and the clock get the bar's own `capsule_*` style; a group does not inherit it, so each sets the same fill, border, padding and spacing, which `tests/unit/desk.bats` checks. The network widget hides its interface name to leave the right half room: each half of the bar clips at the middle.

Each chip is the `dotfiles/chips` plugin (`.local/share/noctalia/plugins/dotfiles-chips/`) with a `module` setting such as `custom/ci`. The plugin holds no chip logic: `desk chip <id>` reads that module from `config.base` (stream, poll interval or run once, signal, left, right and middle click), and `desk chip <id> run` runs its exec and prints JSON: text and tooltip with the pango stripped, the tooltip again as styled runs (`detail`), the text as styled runs (`runs`, only when it has a colour or alpha, which the bar draws run by run), one class, and the module's `format` applied with `{icon}` from `format-icons`. A streaming chip runs as `desk chip <id> stream`, which restarts the exec after its `restart-interval` (5 s by default) like waybar, and kills the exec when Noctalia closes the stream. So a chip changes in `config.base` and shows the same on all three bars. A module with no exec (Bluetooth, the clock) has a Noctalia widget of its own instead. Noctalia hot-reloads a `.luau` edited in place, but its watch follows the file it opened, and git replaces the file, so `.githooks/post-merge` restarts `noctalia.service` when a merge in the stowed main checkout changes the plugin; after a checkout or rebase there, restart it by hand.

Hovering a chip opens its dropdown, the `dotfiles/chips:detail` panel with the whole waybar tooltip in colour. Noctalia's own tooltip is plain text, 280 px wide and three lines at most, so a chip with a dropdown sets none. The panel stays open while the pointer is on the chip or in the panel, and closes 400 ms after it is on neither (`GRACE_MS` in `detail.luau`, room to cross from the bar to the panel). Hovering another chip switches it in place. A click pins it: it then stays open until the chip is clicked again, and hovering other chips leaves it alone; a panel opened by a Super+A b letter is pinned too. `tests/helpers/noctalia-chips-sim.lua` runs both scripts under plain Lua with a stub Noctalia, which is how `tests/unit/desk.bats` checks this. The panel shows the tooltip with bold titles in the primary colour, the scripts' `<span color>` values in their colours, and `<tt>` tables in monospace so the columns line up. `desk chip <id> run` parses the pango into that panel's `detail` field, lines of styled runs (`t` text, `c` colour, `a` alpha, `b` bold, `m` monospace). The chip's own on-click moves to the panel's Open button. A chip with no tooltip still runs its on-click, and so does one whose widget sets `dropdown = false` in `config.toml` (gungan, audio-input, machine-mode: their click starts the stream or cycles the mic or mode). `desk panel custom/ci` opens one from a script or keybind.

A pod has no divider of its own, so the chips in one ran together. Each chip draws a thin bar on the side its widget names in `config.toml` (`divider = "after"`, or `"before"` when the widget ahead of it is one of Noctalia's). Every chip but a pod's last takes `after`, so a chip that hides takes its divider with it.

### Panel keys

Super+A, then b, opens any bar panel by a letter. While that submap is open each chip shows its letter in the bar, as `(c)`, and the hint lists the rest: chips `u` needs you, `h` health, `f` fleet, `p` projects, `a` agents, `d` queue, `c` ci, `t` timebox, `w` webcam, `x` passthrough, `r` printer, `l` load, `s` storage, `n` notifications; Noctalia's `space` control center, `v` audio, `i` network, `b` bluetooth, `m` media, `k` calendar, `o` session, `y` tray. The letter toggles the panel and leaves the submap; Escape goes back, q leaves, and every way out clears the letters. The keys live in one table, `PANELS` in `.config/hypr/conf/leader.lua`. Each leaf runs `desk panel <target>`: a `custom/*` chip opens its dropdown, anything else is a Noctalia panel id and context (`noctalia msg panel-open` lists them). `desk panel letters` sends the letters to every chip over the plugin IPC. Under waybar there is no panel to open, so `desk panel` exits 2 and the key shows desk's reason as a notification.

Notifications stay with the notify slot: `config.toml` sets `[notification] enable_daemon = false`. Noctalia ignores dunst's `x-dunst-stack-tag`, and its handling of the `x-canonical-private-synchronous` hint that `desk notify show` and fleet pages send is untested, so it is not offered as a notifier.

`theme-switch` writes `.config/noctalia/palettes/dotfiles.json`, which `config.toml` selects (`custom_palette = "dotfiles"`), and reloads Noctalia. Settings changed in Noctalia's own settings window go to `~/.local/state/noctalia/settings.toml` and win over `config.toml`. That file is a stow link to the copy tracked in `~/.dotfiles-private` (it can hold a home location or a plugin key, so not this public repo). Noctalia writes through the link, so a change made in the window shows in `git -C ~/.dotfiles-private diff` and lands like any other change. Delete a line there to get the `config.toml` value back. Leave Noctalia's built-in Hyprland template off: it writes `~/.config/hypr/noctalia.lua` and edits `hyprland.lua` to source it, a second writer of the colours `theme-switch` already puts in `hypr/conf/theme.lua`. For the same reason `config.toml` turns its wallpaper off (hyprpaper owns it); its idle actions are off by default, which leaves idle to hypridle.

## The control panel

`swaync` adds a panel with Wi-Fi and Bluetooth toggles, the volume, the media player, do-not-disturb and the notifications (`.config/swaync/config.json`). Under swaync the bar shows a bell chip (`custom/notify`): click opens the panel, right click toggles do-not-disturb. `theme-switch` writes `.config/swaync/style.css`, which keeps swaync's own layout and swaps its colours. Agent pages are quiet: `notification-visibility` mutes agent-notify's normal pages (it sends high as normal too, and names them Agents, Health or Needs you), so they wait in the panel, grouped by that name, and the bell shows a dot; urgent pages and every other app still pop up. A page replaces the earlier one with the same title, so the panel holds the newest per title.

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| No bar after login | `desk.service` failed (a part did not start) or the graphical session target was not reached | `systemctl --user status desk.service waybar.service`, then `desk start` |
| `desk use` says a part "needs X, which is not installed" | the part's package is missing | install it (`packages.conf` lists it), then rerun |
| A chip does not refresh on a keybind | the chip has no `"signal"` key, so `desk signal` exits 2 | add `"signal": N` to the module in `config.base` |
| swaync shows its default grey look | `~/.config/swaync/style.css` is not there: it is a gitignored render, which stow and `dotfiles-deploy` never link, so theme-switch links it when it writes it | `theme-switch "$(cat ~/.config/theme/current)" --only swaync` renders and links it |
| The wrong notifier pops up after one crashed | both own `org.freedesktop.Notifications`, and D-Bus starts whichever it finds first | `desk start` brings back the recorded part, and Conflicts= stops the other |
| Noctalia shows its own colours, not the theme's | `~/.config/noctalia/palettes/dotfiles.json` is missing, for the same reason | `theme-switch "$(cat ~/.config/theme/current)" --only noctalia` renders and links it |
| A Noctalia chip reads `custom/<x> ?` in red | `desk chip custom/<x>` failed: the module is not in `config.base`, or desk is not on PATH at `~/.local/bin/desk` | run `desk chip custom/<x>` and fix what it says |
| A change made in Noctalia's settings window does not show in `git -C ~/.dotfiles-private diff` | `~/.local/state/noctalia/settings.toml` is a plain file, not the stow link: it was deleted, so Noctalia wrote a fresh one | `dotfiles-deploy --apply` shows the diff, backs the plain file up under `~/.local/state/dotfiles-deploy/backup/` and puts the link back; copy any line you want to keep from the backup into the tracked file |
| A Noctalia chip does not refresh on a keybind | the chip polls or streams, so the signal is ignored, or the plugin is not loaded | `noctalia msg plugin dotfiles/chips:chip all refresh <N>` by hand; check `[plugins] enabled` in `config.toml` |
| A chip's dropdown panel is see-through, tinted by the window behind it | the panel was set to `placement = "attached"`: an attached panel takes the bar's `background_opacity`, which is 0 on this clear bar | keep `placement = "floating"` in the plugin's `[[panel]]` (`plugin.toml`); floating panels are solid |
| A chip's dropdown reads `custom/<x>: no detail yet` | the chip has not finished its first run since the plugin loaded, so it has not published its detail | wait for its next refresh, or `desk signal <x>`; `desk chip custom/<x> run \| jq .detail` shows what the panel will draw |
| Hovering a chip opens nothing, or its dropdown never closes | a Luau error in `chip.luau` or `detail.luau` stops its handlers | `journalctl --user -u noctalia.service -n 50`; `make -C tests test-files FILES=unit/desk.bats` runs both scripts against the stub |
| A plugin change is in the main checkout but the bar acts as before | the bar runs the old script: a checkout or rebase replaced the file and Noctalia's watch missed it (the journal has no `[plugin-widget] hot reload: reloaded` line since); a merge restarts it through `.githooks/post-merge` | `systemctl --user restart noctalia.service`, which closes an open dropdown and restarts the streaming chips |
