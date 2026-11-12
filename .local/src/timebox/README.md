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
timebox queue add guitar 5m         # queue a task (see Queue)
timebox queue go                    # start the head task
timebox done                        # finish the head task, start the next
timebox lap                         # manually close the current lap window now
timebox stats                       # per-operation time today (+ lap counts)
timebox stop --all
timebox toggle sound                # flip an alert (or: toggle flash off)
timebox config                      # show resolved paths + settings
```

`--lap` accepts `25m | 1h | 90s | 1500`. `--sound` plays a beep on each boundary
(bundled `assets/switch.wav`, or set `sound_file` / `sound = true` in config).

## Queue

A queue of tasks, each an op and a length. The head task runs as a normal stopwatch with
its length as the lap. When the lap runs out you get the usual alerts (three red flashes,
a notification, the sound) and the same task starts again; the bar chip turns red and shows
the misses (`guitar 4:12 x2 (+3)`: missed twice, three tasks waiting). Only `timebox done`
moves on: the head leaves the queue and the next task starts. The last `done` goes idle.

```sh
timebox queue                       # list (`--json` for the panel)
timebox queue add work at desk 10m  # the op may have spaces; the last word is the length
timebox queue rm 2                  # positions start at 1
timebox queue mv 3 1                # a new head starts at once if the queue is on
timebox queue go                    # start the head
timebox queue load practice         # replace the queue with a preset, then `queue go`
timebox queue clear                 # empty it (stops the head)
```

Starting or switching to another op by hand turns the queue off (its tasks stay; `queue go`
picks it up again), and so does stopping the head. Pause and resume hold it. Every change is
an event in `events.jsonl` (`queue_add`, `queue_rm`, `queue_mv`, `queue_done` with its miss
count, `queue_clear`, `queue_load`).

Presets live in config:

```toml
[presets]
practice = ["work 5m", "guitar 3m", "computer 10m"]
```

The panel (`timebox-panel`, Super+A t t, or a left-click on the chip) is an fzf float over
the queue, with `timebox status` beside it: `a` add, `d` done, `r` remove, `J`/`K` move,
Enter go, `p` pause or resume, `l` load a preset, `x` clear all, `q` close. Its keys are
plain commands too (`timebox-panel act <verb> [pos]`).

## Alerts

Four layers, most-to-least passive:

- Waybar countdown (`custom/timebox`) - always visible (shows `idle_text` when nothing is
  running); its class walks `ready` -> `active` -> `urgent` as the switch approaches, and is
  `final` in the last 10 seconds, which `layout.css` blinks red. A queue task that timed out
  is `overdue` (solid red) until `timebox done`.
- Desktop notification via `agent-notify` at each boundary.
- Sound - opt-in per stopwatch (`--sound`) or globally (`sound = true`).
- Screen flash - three red pulses via Hyprland's `screen_shader` (`flash = true`, runs
  `timebox-flash`, which restores any pre-existing shader; `TIMEBOX_FLASH_COUNT` changes
  the count).

`timebox toggle sound|flash [on|off]` overrides `sound` / `flash` at runtime (stored in
`state.json`, shown in the tooltip and `timebox status`). `flash` covers both the screen
flash and the final-10s bar blink. Both are also on the leader (Super+A t m, Super+A t b).

## Waybar interaction

The `custom/timebox` module is clickable:

- Left-click -> `timebox-panel`, the task queue (see Queue).
- Right-click -> pause the active stopwatch.
- Middle-click -> `timebox done`.

The leader has the rest under Super+A t (`PIN.md`): start or switch a one-off op, pause,
resume, stop, status, the alert toggles. Helper scripts (in `~/.local/bin`): `timebox-panel`,
`timebox-flash`. The flash shader is
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
`sound_file`, `flash`, `flash_cmd`, `icon`, `idle_text`, `[presets]`. All optional.

## Roadmap

- Phase 2: local HTTP/JSON API + a small web SPA (reuses `timebox-core`); optional resident
  daemon for precise firing; optional derived SQLite read-model if stats ever get slow.
- Phase 3: containerize, deploy to home-k3s, expose at `stopwatch.kennethblack.me` via the
  Cloudflare tunnel; PWA for mobile.
