# Machine mode

How much of this workstation background work may use. Four modes on one scale, named for who gets the machine rather than where you are, because `fleet-presence` already reports `here` and `away` on its own and a mode is what you want, which can differ from where you are.

| | reserved | shared | open (default) | full |
|---|---|---|---|---|
| New agent sessions from fleet-dispatch | as today, at the low level | as today | as today | as today |
| Level | low | mid | mid | high |

"As today" means board rows wait for you to be away and queued items do not. No mode stops dispatch: reserved slows it with the low level, and `agent-hold set dispatch` is the full stop. A session started by hand (`fleet-dispatch start`) works in every mode. The numbers live in `.config/machine-mode/modes`.

## Level

The level says how fast the fleet starts work. `mid` is the confs' own numbers. Each level multiplies five limits where they are read, by the factors in `.config/machine-mode/levels`:

| Limit | Read by | low | mid | high |
|---|---|---|---|---|
| `DISPATCH_PER_PASS` | fleet-dispatch | no cap | no cap | no cap |
| `DISPATCH_MAX_LOAD`, a core | fleet-dispatch | 0.54 | 0.9 | 0.99 |
| `CLAUDE_ACCT_PACE_SLACK_PCT`, points past pace | claude-acct room | 1 | 5 | 10 |
| `CLAUDE_ACCT_RESERVE_PCT`, kept for you | claude-acct room | 13 | 10 | 7 |

The numbers here are today's conf values. `DISPATCH_PER_PASS` is unset, and 0 is no cap at every level, so the scaled load limit is what bounds a pass; set it above 0 and the level scales it again (the two claude-acct rows come from `.config/claude-acct/pace.conf`; their names are the levels file's column keys, not env vars, so exporting one changes nothing). The conf is the baseline: change it there and every level follows. Nothing is written when you switch, so the next dispatch pass and the next `claude-acct room` read the new level. `cl`, `claude-acct pick` and hand starts are never refused by it: pick's rank ignores the level, and only its stderr hint about an automatic start follows it. The pace targets (`DISPATCH_TARGET_PRESENT`, `DISPATCH_TARGET_AWAY`), budgets, and the thermal, memory and GitHub gates are not scaled. `fleet-dispatch headroom` prints the level next to the limits it is applying now.

## Use

```bash
machine-mode            # the mode, and what each part reads right now
machine-mode reserved   # switch
machine-mode next       # the next mode, wrapping
machine-mode hours      # the day's parts and which one is now
machine-mode auto       # give the mode back to the clock
```

The waybar chip shows in every mode, `open` included, as the mode's initial (F, R, S or O) with the rest in its hover, right of the disk chip on the desktop bar. A click on it runs `machine-mode next`. The chip is neutral: a mode is your choice, not a health state.

`Super+A m` opens the mode menu, then one key picks the mode:

| Keys | Mode |
|---|---|
| `Super+A m r` | reserved |
| `Super+A m s` | shared |
| `Super+A m o` | open |
| `Super+A m f` | full |

The leaves call `machine-mode <mode>`, the only writer, as the command line does (`.config/hypr/conf/leader.lua`, submap `pinbar-mode`).

## Clock hours

The system's clock hours live in one file, `.config/machine-mode/hours`: each row is a part of the day, its window in local time, the mode it runs in, and what it is for. The parts cover the day with no gap and no overlap, which `tests/unit/machine_mode.bats` checks.

| Part | Window | Mode | For |
|---|---|---|---|
| day | 06:00-01:00 | open | your hours: board rows wait until you are away, queued items start |
| night | 01:00-06:00 | full | unattended: nightly builds and tests, twice the starts |

- The systemd timer `machine-clock.timer` runs `machine-mode clock` at 01:00 and 06:00, the start of each part (`Persistent=true`, so a boundary missed while the machine was off applies at the next boot). It switches to that part's mode once; inside a part nothing runs, so a mode you set by hand stands until the next part begins.
- A mode you set by hand holds past a boundary while `fleet-presence` says you are here, so going to `reserved` at 00:30 to play a build is not undone at 01:00. The tick then exits 75 and the unit retries every 15 minutes, so the part's mode applies at the first retry after you are away, as the old runner's tick did. If you are still here at the next boundary, that boundary's own tick takes over.
- `machine-mode auto` gives the mode back to the clock at once, whether you are here or not.
- Nightly work belongs in the `night` row: a runner's `SCHEDULE=`, a CI cron, an `at:` item. The hub Schedules tab lists what runs when.
- The two times in `machine-clock.timer` copy the part starts of the hours file; `tests/unit/machine_mode.bats` fails when they differ, so change both together. It was a 15-minute agentctl runner (`machine-clock`, 1191 NOOP to 23 WORKED) until ar-4456.
- A held hand mode exits 75 and a state file that could not be written exits 1; `Restart=on-failure` retries both every 15 minutes. An hours file that cannot be read exits 2, which is not retried.

## What a switch does

- Level: writes the mode, who set it and the part it was set in to `~/.agent/machine-mode.env`; fleet-dispatch and claude-acct read the level from there when they next start work. Nothing else on this machine or the cluster changes.
- Agent starts: no mode stops them. Reserved's `low` level is the trickle; `agent-hold set dispatch` is the one full stop, and machine-mode only reports a hold, never sets or lifts one.

## What it does not do

- It moves no CI. Every CI job runs as an ARC scale-set pod or a KEDA Forgejo pod that kube-scheduler places, this workstation is in home-config's `no_ci_hosts`, and a local Unity run here takes a host-local lock (unity-core-playground `scripts/test/slots.sh`, one run at a time). The runner pin, the Unity slot count and the release lane went with the ci-runner-governor (hc-955).
- Other builds agents start are not capped. They already run at a low priority.

Timed values: `pace-conf set <KEY> <value> --until <time>` lays a window over a pace.conf key, and it ends by itself with no timer ([pace-conf.md](pace-conf.md)).

## Troubleshooting

| What you see | Why | What to do |
|---|---|---|
| `paused by machine-mode` | A hold left by a machine-mode older than this doc; no mode sets one now | `agent-hold release dispatch` |
| `paused by <name>` | Someone holds `dispatch`; machine-mode never sets or lifts that hold | `agent-hold show dispatch`, then ask the holder |
| `level <word> is not in .../levels, so nothing is scaled` | A mode row names a level the levels file does not list | Fix the row in `modes` or add the level to `levels`; until then the confs' own numbers apply |
| The mode did not change at a part's start | You set the mode by hand and were here at the boundary | `machine-mode` shows `set by hand`; it applies at the first 15-minute retry after you are away, or run `machine-mode auto` to hand it back now |
| `no part of .../hours holds the time now` | A hand edit left a gap in the hours file | Fix the windows so they cover the day; `machine_mode.bats` checks the shipped file |
| `systemctl --user status machine-clock` reads failed or auto-restart | The tick could not write `~/.agent/machine-mode.env`, or a hand mode is held; `journalctl --user -u machine-clock` names it | Fix the state directory's permissions; a held mode applies at the first retry after you are away |
