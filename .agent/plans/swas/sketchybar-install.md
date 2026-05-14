# SketchyBar install + config (Waybar analog for macOS)

Date: 2026-05-14
Project: dotfiles
Goal: install a status bar similar to Waybar, wired to AeroSpace workspaces, with a stable shell-script config (no Lua).

## Decisions
- **SketchyBar** (FelixKratz/formulae) chosen over Übersicht/xbar/SwiftBar — closest behaviour/feature parity with Waybar, actively maintained, pairs natively with AeroSpace via a custom event trigger.
- **Shell-script config**, not SbarLua. Stability over flair; matches the rest of the dotfiles repo (zsh / bash).
- **No `sf-symbols` cask** — it's the Apple symbol-browser app and needs sudo. The SF Pro / SF Symbols *fonts* used by the bar ship with macOS by default.
- **Color palette** ported from `~/.dotfiles/.config/waybar/style.css` (Jackie Brown theme) so the macOS bar feels like the Linux bar.
- **Direct symlink** for `~/.config/sketchybar` rather than running stow at the repo root — repo's stow setup is partial (some dirs symlinked, others hardlinked/copied), and a targeted `ln -s` is the safest move.

## Tasks
- [x] Add packages to `~/.dotfiles/.config/brewfile/Brewfile` (tap + formula + font cask).
- [x] `brew install sketchybar font-sketchybar-app-font`.
- [x] Create `~/.dotfiles/.config/sketchybar/` (sketchybarrc + colors + icons + items/ + plugins/).
- [x] Add `exec-on-workspace-change` + `after-startup-command` to `aerospace.toml` so workspace indicators update on switch.
- [x] Symlink `~/.config/sketchybar -> ~/.dotfiles/.config/sketchybar`.
- [x] `brew services start sketchybar`; verify bar renders.

## Layout
- Left: Apple glyph · workspaces 1–9 (active = gold bg) · front app label
- Right: clock · battery · volume · cpu

## File map
```
~/.dotfiles/.config/sketchybar/
  sketchybarrc              entry point
  colors.sh                 palette (ported from waybar)
  icons.sh                  SF Symbols glyphs
  items/{apple,spaces,front_app,clock,battery,volume,cpu}.sh
  plugins/{aerospace,front_app,clock,battery,volume,cpu}.sh
```

## Verification
- `pgrep sketchybar` → PID 88955 (running).
- `sketchybar --query bar` shows 15 items registered.
- `sketchybar --query clock` returns "Thu May 14 10:06"; battery returns "100%"; front_app returns "Firefox".
- `brew services list | grep sketchybar` → started.

## Caveats / follow-ups
- **AeroSpace not currently running** on this machine (`pgrep aerospace` empty). Workspace highlights are static at the moment; once AeroSpace launches (start-at-login=true → next login, or `open -a AeroSpace`), the `exec-on-workspace-change` hook will start firing.
- **`~/.config/aerospace/aerospace.toml` is hardlinked** to `~/.dotfiles/.config/aerospace/aerospace.toml` (same inode) rather than symlinked. Edits propagate either way, but `stow` won't see them as managed. Re-stowing would require removing the hardlinked copy first and is not required for sketchybar to work.
- **`sketchybar-app-font`** is installed for future per-app icons; not used by the current minimal config.
- **CPU sample** is single-shot (`top -l 1 -n 0`) every 5s. If that ever feels jumpy, swap to a 2-sample diff.

## How to iterate
- Reload bar after config changes: `brew services restart sketchybar` (or `sketchybar --reload`).
- Tail logs: `tail -f /opt/homebrew/var/log/sketchybar/sketchybar.{out,err}.log`.
