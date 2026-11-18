# desk: switch the bar and the notifier

`desk` (`.local/bin/desk`) picks which part fills each desktop slot and is the one way scripts and keybinds talk to whichever part is running.

| Slot | Parts | Unit |
|---|---|---|
| bar | `waybar-classic`, `waybar-modern` | `waybar.service` (our `launch.sh` drop-in) |
| notify | `dunst`, `swaync` | `dunst.service`, `swaync.service` |

## Use

```
desk current                 # bar=waybar-classic, notify=dunst
desk use bar waybar-modern   # record it and switch now
desk use notify swaync       # the notifier with a control panel
desk parts                   # every slot's parts and units
```

The choice lives in `~/.local/state/desk/parts` and survives logout: `desk.service` (wanted by `graphical-session.target`) runs `desk start` at login. A slot with no line runs its first part.

Scripts and binds never signal a part directly:

- `desk signal custom/<chip>` re-runs that chip now, and every chip sharing its signal number. It reads the chip's `"signal"` from `.config/waybar/config.base` (or `config.pin-full`).
- `desk notify close|close-all|history|dnd` drives the notifier (Super+N, Shift, Ctrl, Alt). Under swaync, `history` opens the control panel.

desk never enables, disables or masks a unit: `~/.config/systemd` is this repo, so that would dirty the tree. A slot whose parts run as different units gets `Conflicts=` between them (`dunst.service.d/desk.conf`), so starting one stops the other.

## The two bars

Both read the same chips from `config.base`; they differ only in stylesheet. `launch.sh` gives classic the theme's `style.css` and modern the tracked `style-modern.css`, which imports `style.css`, then `palette.css` (written by `theme-switch` from the active palette), then `layout-modern.css` (a clear bar with three rounded islands). A theme switch recolours both. The pin bar loads `style.css`, so it keeps the classic look under either.

## The control panel

`swaync` adds a panel with Wi-Fi and Bluetooth toggles, the volume, the media player, do-not-disturb and the notifications (`.config/swaync/config.json`). Under swaync the bar shows a bell chip (`custom/notify`): click opens the panel, right click toggles do-not-disturb. `theme-switch` writes `.config/swaync/style.css`, which keeps swaync's own layout and swaps its colours.

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| No bar after login | `desk.service` failed (a part did not start) or the graphical session target was not reached | `systemctl --user status desk.service waybar.service`, then `desk start` |
| `desk use` says a part "needs X, which is not installed" | the part's package is missing | install it (`packages.conf` lists it), then rerun |
| A chip does not refresh on a keybind | the chip has no `"signal"` key, so `desk signal` exits 2 | add `"signal": N` to the module in `config.base` |
| swaync shows its default grey look | `~/.config/swaync/style.css` is not there: theme-switch writes it into the repo and the link is missing | `theme-switch "$(cat ~/.config/theme/current)" --only swaync`, then `dotfiles-deploy --missing` |
| The wrong notifier pops up after one crashed | both own `org.freedesktop.Notifications`, and D-Bus starts whichever it finds first | `desk start` brings back the recorded part, and Conflicts= stops the other |
