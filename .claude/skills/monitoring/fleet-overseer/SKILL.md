---
name: fleet-overseer
description: >-
  Watch this machine's shared resources (CPU load, memory, temperature) across every running agent session, decide when the fleet must stop, stop it with the least force that works, and tell each session when to continue. Verbs: assess | hold | go. Use when the box is hot or slow, when many agents run heavy jobs at once (headless Unity, builds, test suites), when the sentinel fleet-thermal watch trips or clears, or when the user says "the machine is melting", "stop all the agents", "cut the runs", "tell everyone to pause", "can they start again", "who is using all the CPU". Not for wave or sprint delivery state - that is wave-overseer and sprint-overseer. Not for how to word a peer message - that is fleet-comms, which this skill uses.
metadata:
  category: monitoring
  tags: [agents, fleet, load, thermal, hold, coordination]
  reviewed: "2026-10-23"
---

# fleet-overseer

This skill is the coordinator role from 2026-10-23, written down. About 15 sessions each started headless Unity runs, load reached 96 on 24 cores, Tctl reached 95.8 C, and the timing-sensitive test classes went red. Stopping them took an improvised process-tree trace, a hand-built kill, a dozen one-off messages, and a second kill when shell loops respawned the editors. This skill makes that a three-verb routine.

It owns no product code and no delivery state. It owns one question: does this machine have room for what is running, and if not, who stops and when do they start again.

## Tools

- `fleet-assess` prints headroom (load against cores, Tctl, memory), active holds, a verdict, and one row per heavy process: pid, CPU, nice, class, tmux session, worktree. `--watch-probe` prints one line and exits 1 on HOLD.
- `agent-hold set | release | check | list` is the durable pause. The session preflight prints every active hold, and a resource's gate (for Unity tests, `scripts/test/run.sh`'s slot helper) calls `check`.
- The `fleet-thermal` sentinel watch runs `fleet-assess --watch-probe` every minute and pages on a state change. A trip means "run `assess`", and a clear means "run `go`".

The class column tells you how each consumer can be stopped:

| Class | What it is | How it stops |
|---|---|---|
| `claude` | a Claude session drove it | a `fleet-comms` message, plus the hold |
| `shell` | a tmux pane with no Claude, usually a suite loop | the hold at the resource gate, or a kill. It has no inbox |
| `agentctl` | an agentctl unit | `agentctl stop <name>` |
| `orphan` | reparented to init, its driver gone | nothing will reap it; a kill, with the human's OK |

## Verdicts

| Verdict | Meaning |
|---|---|
| HOLD | Over the high mark (load at 3x cores, or memory under 10% free, or Tctl at 95 with load at 2x), or between the marks while a hold is set |
| CLEAR | A hold is set and the machine is under the low mark (load under 1.5x cores, memory at 25% free or more). Safe to send GO |
| OK | Nothing held, nothing over the line |

The gap between the marks is deliberate. A hold set at 3x and lifted at 2.9x would flap and page on every sample. Load is the main signal; temperature alone is not. This box is a Zen 4 part, which boosts until it reaches 95 C, so readings in the 90s with one busy thread are normal. The thresholds are the `FLEET_*` variables at the top of `fleet-assess`, and that block is the one place to change them.

## Verb: `assess`

1. Run `fleet-assess`. Quote the headroom line and the verdict to the user as given.
2. Group the rows by worktree and class. Run `ListAgents` and match its names to the SESSION column.
3. Say who is consuming what, and how each can be stopped (the class table). Name anything at nice 0 or below that is a batch job: it is competing with the human's desktop.
4. On HOLD, recommend `hold` and the resource name. On CLEAR, recommend `go`. On OK, stop there and send nothing.

## Verb: `hold <resource> "<reason>"`

Go down the ladder only as far as you need to:

1. **Set the hold.** `agent-hold set <resource> --roster <the claude sessions> "<reason with the numbers>"`. This pages the human (high) and makes every new session and every gate see it.
2. **Message the Claude sessions on the roster**, one `fleet-comms` message each, naming the hold.
3. **Lower the priority** of batch consumers that are still running: `renice -n 19 -p <pid>` and `ionice -c3 -p <pid>`. This is reversible and needs no ask.
4. **Kill only when the human asks.** Then kill only batch process trees (the driving `run.sh`, its `timeout`, the editor), and never an interactive editor, meaning a Unity without `-batchmode`. The CPU throttles itself at 95 C, so the hardware is safe while the human decides, and a killed run is lost work.

Shell loops will respawn whatever you kill until their gate honors the hold. If a loop keeps coming back, kill its driving loop (the `shell`-class ancestor) with the human's OK, and do not re-kill its children over and over.

Report the before and after numbers from `fleet-assess`.

## Verb: `go <resource>`

1. Run `fleet-assess`. Continue only on CLEAR. On HOLD, say what is still over the line and stop.
2. `agent-hold release <resource>`. It prints the roster.
3. Send GO to each session on that roster with one `fleet-comms` message: "hold `<resource>` released; restart one run at a time" (the slot queue paces Unity runs).
4. Run `fleet-assess` again a little later, after the restarted runs have had time to begin. If it reads HOLD again, the restart was too wide: set the hold again with a smaller roster and tell the human.

## Do NOT

- Kill anything without the human's say-so, and never an interactive editor.
- Broadcast to every `ListAgents` row. The roster is the sessions consuming the resource.
- Lift a hold on a timer, or because the session that set it went quiet. Lift it on CLEAR.
- Treat a Tctl reading in the 90s on its own as an emergency.
- Edit the sentinel watch to go quiet while it is tripped. It is red because the machine is, and the clear edge is the GO signal.

## Related

- `fleet-comms`: channel choice and message wording, used by `hold` and `go`.
- `sentinel`: hosts the `fleet-thermal` watch. It stays observe-only; the session running this skill acts.
- `wave-overseer`, `sprint-overseer`: delivery-state watchdogs. Neither of them looks at the machine.
