---
name: coordinate
description: >-
  Human-only: hold this window open as a coordinator that follows every row, item and PR it filed until each is merged and live, woken by chain events, steps in on failures. Use for "be the coordinator", "do not close this", "make sure all of this gets done". Running the work: one-shot.
argument-hint: "[plan file or goal]"
disable-model-invocation: true
metadata:
  category: workstreams
  tags: [coordinator, session, close-flow, follow-through]
  reviewed: "2026-11-19"
---

# coordinate

The human typed `/coordinate`: this window stays open and sees its work through. The chain still does the work (one fresh session per phase, dispatch picks the rows); you follow it until every piece is merged and live, step in when one stalls or fails, and answer the human whenever they type here. No model or script starts this mode: critical work alone is never a reason to stay open (wind-down step 0), so only the human's own `/coordinate` makes one.

## Scope and triggers

- The human typed `/coordinate`, optionally with a plan file or a goal ("the CI fixes from this review").
- Covers: the hold, the ledger of what you filed, the event watch, stepping in, the final report.
- Not for: building phases yourself (the plan standard's Chain rule still holds: queue them), a whole-fleet view (`fleet-lead`), nudging other sessions (`shepherd`), every red at once (`fix-red`, which can run under this mode).

## Steps

### 1. Hold the window

```bash
fleet-sessions label self +manual +coordinator
```

`manual` is the one keep the close flow, the shepherd's close and park nudges and `/wind-down auto` all honour (`~/.local/src/docs/fleet-states.md`, "Close verdict"); `coordinator` only names the mode on the panel and the tmux window. Labels outlive a reboot and a restore.

If `$AGENT_QUEUE_ITEM` is set, close your own item now (`agent-land` its PR, or `agent-queue move <slug> done --proof <what landed>`): it frees its slot under the cap, and with no item owning the window, an `agent-queue cancel` or `return` cannot close it.

### 2. Write the ledger

The ledger is a `## Follow-through` section in the plan file the work serves (`~/.claude/plans/<slug>.md`; write a short one with Context and this section when there is none). One line per thing to see through, the id first, then a few words:

```markdown
## Follow-through
- [ ] ar-3663 governor admit drops stale caps
- [ ] coord-agnostic-ci-p2 docs pass
- [ ] Kblack0610/.dotfiles-private#1089 runs-on-light
```

A row id, a queue item slug or a PR as `owner/repo#N`. Fill it from what this conversation already filed (the plan's Results, `inboxed` lines, PRs opened) and from `agent-queue list --json` filtered on the plan. An outbox follow-up has no id until triage files it: leave it as its text for now; step 4 swaps in the id. It is not `## Phases`, so reap and the phase counters never read it.

### 3. Arm the watch

Start `Monitor` with command `coord-watch <plan file>`, `timeout_ms` 1800000 and a description naming the plan. `coord-watch` (`~/.local/bin/coord-watch`) tails the chain event log and prints one line per event on an open ledger line, or on triage acting on your outbox lines (`#from/<your writer>`); it reads the ledger at start, so every re-arm picks up the lines you added.

### 4. Act on each event

| Event | Do |
|---|---|
| `filed`, `moved`, `dup`, `dropped` with your `#from/` | Put the row id it names on the ledger line; a `dup` or `dropped` names the twin row: track that one. |
| `added`, `started`, `item-moved` | Nothing to say unless the human asked for progress. |
| `merged` | Prove it live the way that repo goes live (deploy, autopull, a release), then tick the line. Merge is not live. |
| `land-failed`, `item-cancelled`, `returned`, `reopened` | Read the item and its `why`; fix the cause, re-file it, or take the step over (see below). |

Tell the human one line per tick or intervention, never per event.

### 5. On each Monitor expiry: the stall check, then re-arm

A stall makes no event, so the 30 minute expiry is the check. For each open line with no event since the last arm:

- A running item: `agent-queue show <slug>` and its session in `fleet-sessions`. Idle at a prompt, held on a slot, or no push in a while: get its go-ahead over SendMessage and take the step over from its worktree (push, fix CI, land), never report "waiting on" it.
- A row nobody starts: why dispatch skipped it is the `fleet-dispatch` skill's question; fix the row (size, gate, tag) rather than waiting.
- A pending ask: `agent-ask show <id>`; relay it once in plain words if the human has not seen it.

Then arm `coord-watch` again.

### 6. Done

Every ledger line is ticked (merged and live, or dropped with a reason the human accepted). Write the final report (what landed, what was dropped and why, what you took over), then:

```bash
fleet-sessions label self -manual -coordinator
```

End on the report. The normal quiet timer closes the window, which leaves the human time to reply; their own `/wind-down` closes it at once.

## Talking to it

The human types in this window at any time; another session reaches it over SendMessage (`fleet-comms`). A new ask from the human joins the ledger as a line. The human ends the mode early with `/wind-down`, or by asking you to stop coordinating (run step 6's label removal and say so).
