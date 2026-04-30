# theme — unified dotfiles theme switcher

Single-command color theme switcher across kitty, nvim, lualine, neo-tree,
starship, lazygit, waybar, hyprland, and wallpaper. Two themes ship by
default: `jackie-brown` (warm/day) and `tokyonight` (cool/night).

## Usage

```bash
theme-switch jackie-brown        # apply day theme
theme-switch tokyonight          # apply night theme
theme-switch --auto              # pick day/night based on current hour
theme-switch --current           # show active theme
theme-switch --list              # list available themes
theme-switch --dry-run <name>    # preview without writing
theme-switch --only kitty,waybar <name>   # apply to a subset
theme-switch --help              # full help
```

State lives at `~/.config/theme/current` (single-line file).

## Automatic day/night switching (systemd timers)

Two user-level systemd timers flip the theme on schedule. Each timer
invokes `theme-switch` with an **explicit theme name** — there's no
clock-based decision in the systemd path, so a `Persistent=true` catch-up
always applies the intended theme regardless of when catch-up actually
runs:

| Timer                | Fires        | ExecStart                          |
| -------------------- | ------------ | ---------------------------------- |
| `theme-day.timer`    | `07:00` daily | `theme-switch jackie-brown`        |
| `theme-night.timer`  | `19:00` daily | `theme-switch tokyonight`          |

Both are `Persistent=true`, so a missed run (laptop closed, machine off)
is caught up at next user-manager start.

The clock-based picker (`theme-switch --auto`) is for **manual** invocation
only — it picks based on the hour at the moment you run it. The window
is hardcoded in `theme-switch` near the top:

```bash
AUTO_DAY_THEME="jackie-brown"
AUTO_NIGHT_THEME="tokyonight"
AUTO_DAY_START=7    # inclusive — 07:00
AUTO_NIGHT_START=19 # exclusive — 19:00
```

### Inspect

```bash
systemctl --user list-timers theme-day.timer theme-night.timer
systemctl --user status theme-day.timer
journalctl --user -u theme-day.service -n 20

# Did the unit actually exec? (ExecMainStartTimestamp = empty means never)
systemctl --user show theme-night.service -p ExecMainStartTimestamp -p ExecMainStatus
```

### Change the schedule or themes

Edit `~/.dotfiles/.config/systemd/user/theme-{day,night}.{service,timer}`,
then:

```bash
systemctl --user daemon-reload
systemctl --user restart theme-day.timer theme-night.timer
```

### Disable automation

```bash
systemctl --user disable --now theme-day.timer theme-night.timer
```

## File layout

```
.local/src/theme/
├── theme-switch          # the switcher (symlinked into ~/.local/bin/)
├── palettes/             # <name>.sh — sourceable color variables
│   ├── jackie-brown.sh
│   └── tokyonight.sh
├── templates/            # full-file replacements per tool
│   ├── kitty/<name>.conf
│   └── waybar/<name>.css
└── wallpapers/           # <name>-N.{jpg,png,webp}, picked at random
```

systemd unit files live at `~/.dotfiles/.config/systemd/user/theme-*.{service,timer}`.

## Adding a new theme

1. `cp palettes/tokyonight.sh palettes/<name>.sh` and edit the colors.
2. `cp templates/kitty/tokyonight.conf templates/kitty/<name>.conf` and edit.
3. `cp templates/waybar/tokyonight.css templates/waybar/<name>.css` and edit.
4. Drop matching wallpapers in `wallpapers/<name>-1.jpg`, `<name>-2.jpg`, …
   (or set `THEME_WALLPAPER_PREFIX=other-prefix` in the palette file to
   reuse an existing wallpaper set).
5. `theme-switch <name>` to apply.

## What each tool gets

| Tool      | How it's updated                                                  |
| --------- | ----------------------------------------------------------------- |
| kitty     | full template copy + `SIGUSR1` live reload                        |
| nvim      | colorscheme name patched in `init.lua`                            |
| lualine   | branch fg color patched                                           |
| neo-tree  | `NeoTreeModified` highlight patched                               |
| starship  | 7 color values patched in `starship.toml`                         |
| lazygit   | 11 color values patched in `config.yml` (restart lazygit to see)  |
| waybar    | full template copy + `SIGUSR2` live reload                        |
| hyprland  | active/inactive border + shadow rgba patched + `hyprctl reload`   |
| wallpaper | random pick matching prefix; backend: hyprpaper > swww > swaybg   |
