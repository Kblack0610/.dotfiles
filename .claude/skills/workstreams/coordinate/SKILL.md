---
name: coordinate
description: >-
  Keep this window open as a coordinator, watching every row, item and PR it filed until each is live and validated. Only on the human's words: /coordinate, "stay coordinator", "stay open until this lands". Never for critical work alone. Doing the work: one-shot.
argument-hint: "[plan file, goal, or sprint <project>]"
metadata:
  category: workstreams
  tags: [coordinator, session, close-flow, follow-through]
  system: [sessions]
  reviewed: "2026-11-23"
---

# coordinate

The human asked this window to stay and see its work through: this window stays open until it does. The chain still does the work (one fresh session per phase, dispatch picks the rows); you follow it until every piece is merged and live and the human has validated it, step in when one stalls or fails, and answer the human whenever they type here. Only the human's own words in this conversation start this mode: critical work alone is never a reason to stay open (wind-down step 0), and no script starts it.

## Scope and triggers

- The human typed `/coordinate`, optionally with a plan file, a goal ("the CI fixes from this review") or `sprint <project>` (follow that project's open sprint to its cut), or told this session in their own words to stay and see the work through ("stay coordinator", "remain open until this all lands"). `/wind-down` routes such an order here (its step 0.3).
- Covers: the hold, the ledger of what you filed, the event watch, stepping in, the final report and the human's validation.
- Not for: building phases yourself (the plan standard's Chain rule still holds: queue them), a whole-fleet view (`fleet-lead`), nudging other sessions (`shepherd`), every red at once (`fix-red`, which can run under this mode).

## Steps

### 1. Hold the window

```bash
fleet-sessions label self +manual +coordinator
```

First quote the order in one line, `coordinating at the human's word: "<their words>"`; with no such words from the human in this conversation, do not start (close, or ask them). `manual` is the keep the close flow, the shepherd's close and park nudges and `/wind-down auto` all honour while it is quiet under `FLEET_CHAT_CLOSE_H` (`~/.local/src/docs/fleet-states.md`, "Close verdict"); `coordinator` only names the mode on the panel and the tmux window. Labels outlive a reboot and a restore.

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

Sprint mode is the literal form `sprint <project>`, where `<project>` is listed under `.sprints` in `notes board --json`; any other argument is a goal. Its ledger is the open sprint's committed rows, whoever filed them. When `~/.claude/plans/sprint-<project>-<version>.md` exists (a resumed window), keep it and add only the row ids it lacks; otherwise write it (Context: the version, its cut, done of committed) and fill `## Follow-through` from the board:

```bash
notes board --json | jq -r '.sprints[] | select(.project=="<project>" and (.queued|not)) | .tasks[]
  | "- [\(if .state=="open" or .state=="doing" then " " else "x" end)] \(.id) \(.text)\(if .state=="deferred" then " (deferred)" else "" end)"'
```

Empty output means the project has no open sprint (not focus, or already rolled): stop and tell the human, never arm a watch on an empty ledger. A project under two profiles adds `and .profile=="<profile>"`.

A new ask you give this window goes through `sprint` step 5: the next window unless it is an interrupt, never a relock of this one. It joins the ledger only when it lands in this sprint.

### 3. Arm the watch

Start `Monitor` with command `coord-watch <plan file>`, `timeout_ms` 1800000 and a description naming the plan. `coord-watch` (`~/.local/bin/coord-watch`) tails the chain event log and prints one line per event on an open ledger line, or on triage acting on your outbox lines (`#from/<your writer>`); it reads the ledger at start, so every re-arm picks up the lines you added, and it keeps a cursor per plan, so a re-arm first replays whatever landed while no watch ran. It exits 2 when the plan has no `## Follow-through` heading; the id is the first word of the line, so keep it bare.

It is the one watch: its `land-failed`, `merged` and `done` events already carry each PR's state, so never write a gh poll loop of your own. While the `coordinator` label is on, the Stop check `stop-post.d/89-coord-watch.sh` blocks a turn that ends with no live `coord-watch` of this session (it writes `~/.local/state/coord-watch/session-<id>.pid` while it runs), so a compaction or a missed expiry cannot leave the window unwatched.

### 4. Act on each event

| Event | Do |
|---|---|
| `filed` with your `#from/` | Put its `id` on the ledger line that still holds the text. |
| `dup` with your `#from/` | Its `id` is the row your line joined: track that one. |
| `dropped` with your `#from/` | Its `why` names the twin it was dropped for: track that row, or strike the line with the reason. |
| `moved` with your `#from/` | Triage routed it to a project (`to=`); the `filed` event brings the id. |
| `added`, `started`, `item-moved`, `planned`, `settled` | Progress; nothing to say unless the human asked for it. |
| `merged` | One PR of the line merged; a row can carry several. Nothing to tick yet. |
| `done` (or `item-moved` with `to=done`) | The line's work is closed: prove it live the way that repo goes live (deploy, autopull, a release), then tick it. Merge is not live. |
| `land-failed`, `item-cancelled`, `reopened`, `unstarted`, `refused`, `reaped`, or any action not listed here | Read the item (`agent-queue show <slug>`) or the row and the `why`; fix the cause, re-file it, or take the step over (step 5). |

Tell the human one line per tick or intervention, never per event.

### 5. On each Monitor expiry: the stall check, then re-arm

A stall makes no event, so the 30 minute expiry is the check. For each open line with no event since the last arm:

- A running item: `agent-queue show <slug>` and its session in `fleet-sessions`. Idle at a prompt, held on a slot, or no push in a while: get its go-ahead over SendMessage and take the step over from its worktree (push, fix CI, land), never report "waiting on" it.
- A row nobody starts: why dispatch skipped it is the `fleet-dispatch` skill's question; fix the row (size, gate, tag) rather than waiting.
- A pending ask: `agent-ask show <id>`; relay it once in plain words if the human has not seen it, never again on a later expiry.

In sprint mode, also re-read the project's non-queued `.version` from the board: a version other than the plan's is the roll, so go to step 6.

Then arm `coord-watch` again. An expiry that found no stall and changed nothing ends its turn with no text: the human reads nothing new, and a repeated status or question is noise.

### 6. Validate with the human

In sprint mode the version roll ends the follow-through: rows still open then carry to the next window (`sprint` step 6), so strike them as `carried to <next version>` and put the window score in the final report.

Every ledger line is ticked (merged and live, or dropped with a reason the human accepted). Merged and live is not done: the human validates it. A ticked line is no longer watched (`coord-watch` reads only open lines and exits 3 on a ledger with none), so the watch ends here: stop the Monitor (TaskStop) and drop the mode label, keeping the hold:

```bash
fleet-sessions label self -coordinator   # keep manual; the Stop check 89-coord-watch.sh reads this label
```

Write the final report (what landed and how to check each piece, what was dropped and why, what you took over), and in the same turn file the validation ask and set it to reopen this session:

```bash
agent-ask post --options 'a=validated: drop the hold and let the window close|b=not yet: name what is wrong, it joins the ledger' \
  --recommend a --why "every ledger line is merged and live" --context "<plan file>" "Validated <goal>?"
```

```bash
agent-ask reopen-on-answer <id>
```

Then end the turn and wait with nothing armed: no Monitor, cron or wakeup. The answer reaches this session by itself: `agent-ask deliver` types it into the live pane, and if the window closed on its quiet timer meanwhile, `reopen-on-answer` starts it again with the answer. `manual` keeps the window until quiet `FLEET_CHAT_CLOSE_H`. The ask (the `!N` count and the asks list) is what shows the wait. A re-armed watch on a ticked ledger is only a timer: 2026-11-22 one woke 58 times over 29h (about $7) and repeated the question each time. `stop-post.d/86-empty-wakes.sh` blocks that after 4 empty expiries.

A "not yet" adds its lines to the ledger, then `fleet-sessions label self +coordinator` and arm the watch again (step 3); steps 4 and 5 carry them.

### 7. Done

On the human's "validated", drop the hold (step 6 already stopped the watch):

```bash
fleet-sessions label self -manual -coordinator
rm -f ~/.local/state/coord-watch/<plan basename>.ts   # the watch's cursor
```

End on one line saying the hold is dropped. The normal quiet timer closes the window; the human's own `/wind-down` closes it at once.

## Talking to it

The human types in this window at any time; another session reaches it over SendMessage (`fleet-comms`). A new ask from the human joins the ledger as a line. An analysis ask ("are we on time", "why is CI red", "what merged today") is answered here by the skill that owns it (`release-coordinator`, `ci-cleanup`, `day-log`, `fleet-bench`); the answer does not join the ledger unless it files work. The human ends the mode early with `/wind-down`, or by asking you to stop coordinating (run step 7's label removal and say so).
