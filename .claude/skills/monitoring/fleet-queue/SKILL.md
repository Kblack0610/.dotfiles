---
name: fleet-queue
description: >-
  Operate the agent-queue: add items and plans, holds (after, night, at:, pr:), states, tags (red, cause:), agent-land. Use for "queue this", "why is the item not starting", "close the item". How starts are chosen: fleet-dispatch.
paths:
  - ".local/bin/agent-queue"
  - ".local/bin/agent-land"
  - ".config/agentctl/QUEUE.md"
metadata:
  category: monitoring
  tags: [agent-queue, agent-land, queue, holds, plan]
  reviewed: "2026-11-06"
---

# fleet-queue

The agent-queue is the one intake for agent work: one file per item under `~/.agent/queue/<state>/`, and the item is the only record of that work. `agent-queue` is its only writer. `~/.config/agentctl/QUEUE.md` owns the design, the item fields and where each record lives; read it for the fields. This skill is the operator path: file an item, see why it is not running, close it.

## Scope and triggers

- You are starting tracked work, or a session needs its queue item (`$AGENT_QUEUE_ITEM`, else `agent-queue mine`).
- An item sits queued and you need to know why.
- A PR is ready to land and its item must close.

Not for how dispatch picks and starts sessions (`fleet-dispatch`), or an account having no room (`fleet-accounts`).

## File an item

1. Your own task, unless `$AGENT_QUEUE_ITEM` is set: `agent-queue add --running --project <p> "<task>"`.
2. Work for later: `agent-queue add --project <p> [--priority urgent|high|low] [--tags "t1 t2"] [--weight heavy|light] [--after <slug>] "<task>"`. A bare add is high priority. An item not from the board files its own story row.
3. A plan: `agent-queue add --plan <plan.md> --dry-run` first, then without `--dry-run`. It makes one oneshot item per unchecked `## Phases` line, each `after` the one before. The first starts at once and so does each next one when its predecessor closes ok. `AGENT_QUEUE_START=0` only queues.
4. `agent-queue list [--state queued|running|waiting|done|active|all]` prints TSV: state, priority, slug, project, mode, then session, hold or status, tags, from. `show <slug>` prints one item; `next` prints the head.

## States and moves

- queued -> running when a session starts on it; running -> waiting while its session waits on the human or owns a pending ask (`fleet-dispatch reap` does this); -> done when closed.
- `agent-queue move <slug> <state>`; `done` needs `--status ok|failed|cancelled`. `--if <state>` makes the move conditional and exits 3 when the item is elsewhere. `cancel <slug>`, `bump <slug> <priority>`, `set <slug> key=value` (for example `pr=<N>`).
- `agent-land` normally does the closing. Use `move ... done` by hand only for work with no PR.

## Why an item is not starting

1. `agent-queue list --state queued`: the sixth column is the hold. Holds are `after <slug>` (that slug must be done ok; a failed predecessor never releases it), `night` (only inside the night window, `AGENT_QUEUE_NIGHT`, default 01:00-06:00), `at:HH:MM` (not before that time TODAY; once the time of day has passed it holds nothing, so use `at:YYYY-MM-DDTHH:MM` for a later day), and `pr:<owner>/<repo>#N` (until the PR is MERGED; a failing `gh` also holds).
2. No hold: it is a dispatch gate. `fleet-dispatch stopped` names it in one line, and `fleet-dispatch run --dry-run` shows what a pass would pick. Common ones: no account has room (`fleet-accounts`), load or `fleet-assess` HOLD (`fleet-pace`), run units full (heavy holds 2 units, light 1; `fleet-dispatch headroom`). A pass starts at most `DISPATCH_PER_PASS` (the conf sets 3).
3. Tags: `red` is read by `fleet-dispatch`, not by `agent-queue`: it sorts the item first, briefs it on the `fix-red` skill, which reviews and merges its own PR, and exempts it from the board waiting while the human is present. `cause:<sig>` marks a red item `fleet-bench triage` filed for a recurring failure (routes in `~/.config/agentctl/triage-routes`); a queued fix keeps its cause from being filed again for `TRIAGE_FIX_DAYS`, and `TRIAGE_FIX_CAP` limits new ones a day.
4. A running item whose session is dead is the shepherd's to nudge or reap (`shepherd`).

## Land and close

1. `agent-land <pr>` runs fetch, item-line, checks, merge, proof, item, board, plan. Add `--item <slug>` when the session records more than one item, `--plan <file> --phase "<text>"` to tick a plan phase, `--dry-run` to see the steps.
2. The item is `--item`, then `$AGENT_QUEUE_ITEM`, then `agent-queue mine`. With none it refuses before any gh call; add one with `agent-queue add --running`.
3. Exit 0 landed, 1 a step failed (fix it and re-run; an already merged PR skips checks and merge, so the re-run finishes the record step), 2 usage (more than one item without `--item`, or the removed `--project` and `--title`), 3 behind origin base or a catch-up conflict (merge the base, re-run).
4. A `night` item stops at the open PR. Close it by hand: `agent-queue set <slug> pr=<N>`, then `agent-queue move <slug> done --status ok`.

## Do NOT

- Do not write into `~/.agent/queue/` by hand or `mv` an item; every transition goes through `agent-queue`, so two writers cannot both move one.
- Do not file an item for a want nobody has set up: that is a board row, and `agent-queue` is not a notes list.
- Do not `cancel`, `move` or `bump` another session's item. Do not dispatch around a gate by adding an item with a fake hold or tag.
- Do not merge a PR with `gh pr merge` and skip `agent-land`; the item, board row and plan then never close.
