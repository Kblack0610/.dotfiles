# Machine mode

How much of this workstation background work may use. Four modes on one scale, named for who gets the machine rather than where you are, because `fleet-presence` already reports `here` and `away` on its own and a mode is what you want, which can differ from where you are.

| | reserved | shared | open (default) | full |
|---|---|---|---|---|
| Runners taking new jobs | 0 | 1 | 2 | 2 |
| Local Unity runs, always open + when there is room | 1 + 0 | 2 + 0 | 2 + 1 | 2 + 1 |
| New agent sessions from fleet-dispatch | paused | as today | as today | as today |
| Level | low | mid | mid | high |

"As today" means board rows wait for you to be away and queued items do not. A session started by hand (`fleet-dispatch start`) works in every mode. The numbers live in `.config/machine-mode/modes`.

## Level

The level says how fast the fleet starts work. `mid` is the confs' own numbers. Each level multiplies five limits where they are read, by the factors in `.config/machine-mode/levels`:

| Limit | Read by | low | mid | high |
|---|---|---|---|---|
| `DISPATCH_PER_PASS` | fleet-dispatch | 1 | 3 | 6 |
| `DISPATCH_NIGHT_MAX` | fleet-dispatch | 3 | 6 | 12 |
| `DISPATCH_MAX_LOAD`, a core | fleet-dispatch | 0.9 | 1.5 | 2.1 |
| `CLAUDE_ACCT_PACE_SLACK_PCT`, points past pace | claude-acct room | 1 | 5 | 10 |
| `CLAUDE_ACCT_RESERVE_PCT`, kept for you | claude-acct room | 20 | 15 | 10 |

The numbers here are today's conf values. The conf is the baseline: change it there and every level follows. Nothing is written when you switch, so the next dispatch pass and the next `claude-acct room` read the new level. `cl`, `claude-acct pick` and hand starts never read it. Run units (`DISPATCH_MAX_LIVE`), budgets, and the thermal, memory and GitHub gates are not scaled. `fleet-dispatch headroom` prints the level next to the limits it is applying now.

## Use

```bash
machine-mode            # the mode, and what each part reads right now
machine-mode reserved   # switch
machine-mode next       # the next mode, wrapping
```

The waybar chip appears in every mode except `open`, as the mode's initial (F, R or S) with the rest in its hover, and a click there runs `machine-mode next`. In `open` the bar shows nothing, because the bar has no width to spare on a 1920 monitor, so leave `open` with the command. The chip is neutral. Amber means the last switch never reached the cluster, so the runners are not where the letter says. It has no text on a machine with no pool runners.

## What a switch does

- Runners: writes `{"slots": N}` under this host's key in the `ci-runner-governor-override` ConfigMap (`monitoring`). The governor moves one slot per cycle toward N, and a busy runner finishes its job.
- Local Unity: writes `~/.agent/machine-mode.env`, which `slots.sh` in unity-core-playground reads.
- Agent starts: sets or releases `agent-hold` on `dispatch`, by `machine-mode`. A `dispatch` hold set by anyone else is left alone.

## What it does not do

- Dropping a slot is not instant: the ConfigMap takes about a minute to reach the pod, the governor runs every 60 seconds, then a running job finishes. Expect minutes, and longer if a gate is running.
- A local Unity run already going is not touched. The new number applies to the next one.
- Other builds agents start are not capped. They already run at a low priority.
- `open` means the two runners on 12 of the 24 threads, as it always has. A third slot waits on a day of load data.

## Troubleshooting

| What you see | Why | What to do |
|---|---|---|
| `could not reach the cluster`, chip amber | The local parts applied and the ConfigMap write failed. Nothing else writes runner labels | Fix cluster access and run the same mode again |
| `moving to 0` for a long time | A job is running, or the pool floor holds: the governor keeps 2 runners admitted across the pool | Read the governor log: `kubectl --context "$CC_KUBE_CONTEXT" -n monitoring logs deploy/ci-runner-governor --tail=20`. A `PINNED` line ending `at the pool floor` means another host's runners are down |
| `runners: ? of ?` | Prometheus did not answer, or the governor is not exporting | The switch still applied; check the governor pod |
| `paused by <name>` | Another session holds `dispatch`, and machine-mode leaves it | `agent-hold show dispatch`, then ask the holder |
| `the hold was lifted` | Someone released the hold while the mode stayed reserved | Run `machine-mode reserved` to pause again |
| `no pool runners on this machine` | No `actions.runner.*-unity-pool-*` unit here | Run it on the workstation |
| `level <word> is not in .../levels, so nothing is scaled` | A mode row names a level the levels file does not list | Fix the row in `modes` or add the level to `levels`; until then the confs' own numbers apply |
| A Unity run ignores the mode | That worktree's `slots.sh` predates the mode | Merge main into it |
