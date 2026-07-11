# timebox

A stopwatch + recurring-lap timeboxing tool. Start named stopwatches (one per operation
you are doing), get a recurring "switch now" reminder for timeboxing, and track how much
time each operation got today.

It is a one-shot CLI: every command mutates files under `~/.local/state/timebox/` and
exits. Elapsed time is computed (`now - started_at`), never ticked, so nothing runs in the
background. The Waybar module both renders the live countdown and, on each poll, fires the
"switch now" notification when a lap boundary comes due.

## Layout

- `crates/timebox-core` - pure logic (state machine, computed elapsed, recurring laps,
  stats, the JSONL event log). Reused verbatim by the future HTTP API / web backend.
- `crates/timebox-cli` - the `timebox` binary: CLI + the Waybar `status --json` module.

## Install

```sh
cargo build --release
ln -sf "$PWD/target/release/timebox" ~/.local/bin/timebox
```

Or let the dotfiles installer do it: `build_local_rust_tools()` in
`installation_scripts/base_functions.sh` already lists `timebox`.

## Usage

```sh
timebox start deep-work --lap 25m   # start a stopwatch, remind me to switch every 25 min
timebox status                      # human view of all stopwatches
timebox switch email                # stop the active op, start "email" in one step
timebox pause                       # pause the active op (laps pause with it)
timebox resume
timebox lap                         # manually close the current lap window now
timebox stats                       # per-operation time today (+ lap counts)
timebox stop --all
timebox config                      # show resolved paths + settings
```

`--lap` accepts `25m | 1h | 90s | 1500`. `--sound` plays a beep on each boundary
(bundled `assets/switch.wav`, or set `sound_file` / `sound = true` in config).

## Alerts

Four layers, most-to-least passive:

- Waybar countdown (`custom/timebox`) - always visible (shows `idle_text` when nothing is
  running); color walks green -> gold -> red as the switch approaches.
- Desktop notification via `agent-notify` at each boundary.
- Sound - opt-in per stopwatch (`--sound`) or globally (`sound = true`).
- Screen flash - a brief red tint via Hyprland's `screen_shader` (`flash = true`, runs
  `timebox-flash`, which restores any pre-existing shader).

## Waybar interaction

The `custom/timebox` module is clickable:

- Left-click -> `timebox-menu` (wofi/rofi): start / switch / pause / resume / lap / stop /
  stats without a terminal.
- Right-click -> pause the active stopwatch.
- Middle-click -> manual lap.

Helper scripts (in `~/.local/bin`): `timebox-menu`, `timebox-flash`. The flash shader is
`~/.config/hypr/shaders/flash.frag`.

Note: because firing rides the Waybar poll, if the bar is not running the "switch now"
alert is late, not lost - it flushes the next time you run any `timebox` command (and the
lap is always recorded at its true boundary time). Precise firing with the bar closed is a
planned upgrade (a systemd user timer, or the Phase-2 daemon).

## Storage

- `~/.local/state/timebox/events.jsonl` - append-only event log, the source of truth.
  Every start/stop/pause/resume/lap/switch is recorded, so any future stat is a fold over
  this log with no migration.
- `~/.local/state/timebox/state.json` - the live snapshot (a rebuildable cache).
- `~/.local/state/timebox/timebox.log` - diagnostics.

## Config

See `~/.dotfiles/.config/timebox/config.toml`. Keys: `state_dir`, `default_lap`, `sound`,
`sound_file`, `icon`. All optional.

## Roadmap

- Phase 2: local HTTP/JSON API + a small web SPA (reuses `timebox-core`); optional resident
  daemon for precise firing; optional derived SQLite read-model if stats ever get slow.
- Phase 3: containerize, deploy to home-k3s, expose at `stopwatch.kennethblack.me` via the
  Cloudflare tunnel; PWA for mobile.
