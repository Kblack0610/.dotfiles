# theme — unified dotfiles theme switcher

Single-command color theme switcher across kitty, nvim, lualine, neo-tree,
starship, lazygit, waybar, hyprland, and wallpaper.

Eight themes ship:

| Theme            | Feel                                          | Day/night |
| ---------------- | --------------------------------------------- | --------- |
| `jackie-brown`   | warm browns and gold                          | day       |
| `ayaka`          | soft pink-purple                              | night     |
| `tokyonight`     | cool blue-violet                              | -         |
| `dark-one-nuanced` | muted Atom One dark                         | -         |
| `arthur`         | earth browns, cornflower blue                 | -         |
| `1984-orwellian` | ration-brown ground, telescreen cyan          | -         |
| `batman`         | Gotham greys, bat-signal gold                 | -         |
| `cyberpunk-neon` | neon navy, cyan and magenta                   | -         |

Only `jackie-brown` and `ayaka` are wired to the day/night timers; the rest are
manual (`theme-switch <name>`). The last four are ports of the corresponding
[kitty-themes](https://github.com/dexpota/kitty-themes) entries - see
"Porting a kitty theme" below for what is and is not carried over verbatim.

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

## One-off: recolor a single terminal (`--here`)

A normal `theme-switch <name>` is **global** — it rewrites shared config files,
saves state, and reloads every kitty window. To give just **one** terminal a
different theme for a one-off (without touching the global theme or any other
window), use `--here`:

```bash
theme-switch tokyonight --here   # recolor ONLY the window you run this in
theme-switch --here --reset      # restore that window to its configured colors
theme-switch tokyonight --here --dry-run   # preview the colors it would send
```

`--here` is kitty-only and writes **nothing** — no config files, no
`~/.config/theme/current`. It recolors the live window by emitting standard
terminal color OSC sequences (background → OSC 11, foreground → OSC 10,
cursor → OSC 12, selection → OSC 17/19, palette → OSC 4) read from
`templates/kitty/<name>.conf`. kitty colors are per-OS-window, so only the
window you're in changes; opening a new window shows the global theme again.

Inside tmux the sequences are wrapped in the tmux passthrough envelope, so this
relies on `set -g allow-passthrough on` in `.tmux.conf` (already enabled). It
also works outside tmux (sequences are emitted raw). Note `--here` only changes
terminal colors — nvim/starship/etc. are per-process and unaffected.

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
   Its structure is identical across every theme; only the nine colors it uses
   (background, panel background, text, accent, alert, dim, ok, warn, info)
   differ, so a hex-for-hex substitution is the whole job.
4. Either point `THEME_NVIM_COLORSCHEME` at an already-installed colorscheme, or
   write `~/.dotfiles/.config/nvim/colors/<name>.lua` and name that. The existing
   hand-written ones (`arthur`, `1984-orwellian`, `batman`, `cyberpunk-neon`,
   `jackie-brown`) are one `local p = { ... }` palette block followed by an
   identical body of `hi()` calls - copy one and replace the block.
5. Drop matching wallpapers in `wallpapers/<name>-1.jpg`, `<name>-2.jpg`, ...
   (or set `THEME_WALLPAPER_PREFIX=other-prefix` in the palette file to
   reuse an existing wallpaper set). Without any, the wallpaper step warns and
   every other tool still applies.
6. `theme-switch <name> --dry-run` to check every tool resolves, then
   `theme-switch <name>` to apply.

## Porting a kitty theme

`arthur`, `1984-orwellian`, `batman` and `cyberpunk-neon` came from
[kitty-themes](https://github.com/dexpota/kitty-themes) (`kitten themes` reads
the same set). A kitty theme is only 16 ANSI colors plus a background,
foreground and cursor, which is a fraction of what a palette here has to fill,
so the port follows one rule:

- **ANSI colors are carried over verbatim.** Whatever the upstream theme says
  color0-15 are, that is what kitty, nvim's terminal colors and the ANSI-driven
  tools get. Quirks included: Batman genuinely has no red (its color1 is gold),
  and Cyberpunk Neon's ramp is deliberately scrambled (color2 is magenta).
- **UI-role colors are chosen for legibility, and the deviation is written down
  in the palette file's header.** These are roles kitty has no opinion about
  (panel background, dim text, the starship/lazygit/hyprland accents) or where
  the upstream value is unusable in the role - 1984's bright-black is pure
  black, which erases every dim-text element; Batman's #6e6e6e foreground is too
  faint for body text; Cyberpunk Neon leaves selection as `none` and gives the
  active tab a background indistinguishable from the window.

The second rule needs the first to stay honest: if the ANSI ramp drifts too, the
theme stops being the theme it claims to be. Every deviation is a comment in
`palettes/<name>.sh` saying which role and why.

## What each tool gets

| Tool       | How it's updated                                                 | Target   |
| ---------- | ---------------------------------------------------------------- | -------- |
| kitty      | full template copy + `SIGUSR1` live reload                        | generated |
| waybar     | full template copy + `SIGUSR2` live reload                        | generated |
| sketchybar | `colors.sh` rebuilt from the palette (no per-theme template)      | generated |
| nvim       | colorscheme name patched in `init.lua`                            | tracked  |
| lualine    | branch fg color patched                                           | tracked  |
| neo-tree   | `NeoTreeModified` highlight patched                               | tracked  |
| starship   | 7 color values patched in `starship.toml`                         | tracked  |
| lazygit    | 11 color values patched in `config.yml` (restart lazygit to see)  | tracked  |
| hyprland   | border + shadow rgba patched in `conf.d/look-and-feel.conf`, then `hyprctl reload` | tracked  |
| wallpaper  | random pick matching prefix; backend: hyprpaper > swww > swaybg   | n/a      |

## Tracked vs generated

The palette (`palettes/<name>.sh`) and the templates are the source of truth. A
**generated** target is written in full from them and is gitignored -- git never
sees it, so switching themes cannot dirty the repo.

That distinction is load-bearing. These three files were tracked for years while
`theme-day.timer` and `theme-night.timer` rewrote them at 07:00 and 19:00 every
day, so the repo dirtied itself twice daily and every session had to decide to
hold the churn. A generator aimed at its own source is not mess to sweep up, it
is a loop to cut.

Because a fresh clone has none of them -- and `sketchybarrc` hard-`source`s
`colors.sh` -- the installers call `setup_theme()` after `apply_dotfiles` to
render them once. It passes `--only` the generated targets on purpose: every
**tracked** target above already ships correct, and re-patching those at install
time would hand a fresh machine a dirty tree before first login.

The remaining `tracked` rows are hand-authored config with a few values patched
in place, so they still churn on a theme switch. Converting each to its tool's
native include (hyprland `source =`, lazygit `LG_CONFIG_FILE`, an nvim palette
module) is the follow-up that finishes the job.
