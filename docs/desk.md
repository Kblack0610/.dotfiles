# desk: switch the bar and the notifier

`desk` (`.local/bin/desk`) picks which part fills each desktop slot and is the one way scripts and keybinds talk to whichever part is running.

| Slot | Parts | Unit |
|---|---|---|
| bar | `waybar-classic` | `waybar.service` (our `launch.sh` drop-in) |
| notify | `dunst` | `dunst.service` |

## Use

```
desk current                 # bar=waybar-classic, notify=dunst
desk use bar waybar-classic  # record it and switch now
desk parts                   # every slot's parts and units
```

The choice lives in `~/.local/state/desk/parts` and survives logout: `desk.service` (wanted by `graphical-session.target`) runs `desk start` at login. A slot with no line runs its first part.

Scripts and binds never signal a part directly:

- `desk signal custom/<chip>` re-runs that chip now, and every chip sharing its signal number. It reads the chip's `"signal"` from `.config/waybar/config.base` (or `config.pin-full`).
- `desk notify close|close-all|history|dnd` drives the notifier (Super+N, Shift, Ctrl, Alt).

desk never enables, disables or masks a unit: `~/.config/systemd` is this repo, so that would dirty the tree. A slot whose parts run as different units gets `Conflicts=` between them, so starting one stops the other.

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| No bar after login | `desk.service` failed (a part did not start) or the graphical session target was not reached | `systemctl --user status desk.service waybar.service`, then `desk start` |
| `desk use` says a part "needs X, which is not installed" | the part's package is missing | install it (`packages.conf` lists it), then rerun |
| A chip does not refresh on a keybind | the chip has no `"signal"` key, so `desk signal` exits 2 | add `"signal": N` to the module in `config.base` |
