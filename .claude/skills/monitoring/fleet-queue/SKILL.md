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

1. Your own task, unless `$AGENT_QUEUE_ITEM` is set: `agent-queue add --running --project <p> [--row <id>] "<task>"`. `--row` names the open agent board row you are working, starts it and refuses an id that is not open or that a live item already names.
2. Work for later: `agent-queue add --project <p> [--priority urgent|high|low] [--tags "t1 t2"] [--weight heavy|light] [--after <slug>] "<task>"`. A bare add by hand is high; a session (`$CLAUDE_CODE_SESSION_ID` or `$AGENT_QUEUE_ITEM` set) names `--priority` or is refused: low unless it blocks a release or a red on main. An urgent add by the human at hand (by hand or from a session they sit in; `--from` defaults to human, and a dispatched session's `$AGENT_QUEUE_ITEM` makes it not) starts its session at once unless a hold (night, `at:`, `ask:`, `after:`, the dispatch hold) keeps it; any other waits for a dispatch pass. An item with no `--row` that is not from the board files its own story row, with the task as the row's brief, less a first line that is the row's own words: the row is the task, the item is the run, so a returned item's next promote takes its brief back from the row, and `agent-queue retask` rewrites both.
3. A plan (whether an epic runs as one: `~/.local/src/docs/lifecycle.md`, "Taking an epic on"): `agent-queue add --plan <plan.md> --dry-run` first, then without `--dry-run`, which from a session names `--priority` as step 2 says. It makes one oneshot item per unchecked `## Phases` line, each `after` the one before, unless the line says `(independent)` (after `--after` alone) or `(after N)` (after phase N's item); `(with N)` joins phase N's item; a marker may carry a note, `(independent; why)`, with no parenthesis inside it. A line that opens `P<N>` is phase N (so `P9` above `P8` is still 9 and 8), else its place in the list is its number. At urgent or high, filed by the human at hand, each phase whose wait is met starts at once, and each next one when its predecessor closes ok; at low, or from a machine filer or a dispatched session, the first ones wait for a dispatch pass. Bumping an item to urgent never lifts its `after:`; `bump` names the hold and `agent-queue set <slug> after=` is the release. `AGENT_QUEUE_START=0` only queues.
4. `agent-queue list [--state queued|running|review|waiting|done|active|all]` prints TSV: state, priority, slug, project, mode, then session, hold or status, tags, from. `show <slug>` prints one item; `next` prints the head.

## States and moves

- queued -> running when a session starts on it; running -> waiting while its session waits on the human or owns a pending ask (`fleet-dispatch reap` does this); -> review (`on a PR`) while it sits on an open PR with its session ended; -> done when closed.
- `agent-queue move <slug> <state>`; `done` needs `--status ok|failed|cancelled`, `cancelled` (and `agent-queue cancel <slug>`) takes `--why "<reason>"`, required from a session or script and kept on the item as `cancelled_by` and `cancel_why`; work the human asked for (`from: human`, or a `#requested` row) cancels from a session or script only with `--ask <id>`, an ask the human answered (not the judge), and `done --status ok` on an item with `pr:` refuses until it has `merged:` (agent-land, or reap on merge, writes it); `done --status ok` with no `pr:` also closes the item's board row, `--proof item:<slug>`, and warns on stderr when that close fails. `--if <state>` makes the move conditional and exits 3 when the item is elsewhere. `cancel <slug>`, `bump <slug> <priority>`, `set <slug> key=value` (for example `pr=<N>`). `retask <slug> "<task>"` (or stdin) rewrites a queued item's task when it holds a wrong fact; the header stays. `reopen <slug> [--to running|waiting] [--why text]` puts back an item a false close finished (a reap that read a live session as gone) and starts its board row again; it reopens a `failed` close as it is, and an `ok` close only with `--unland <owner>/<repo>#<N>`, the PR it closed on that was not its work: that PR comes off `pr:` and `merged:`, and its row reopens through `notes ptask reopen` before it starts. It exits 1 when the row will not reopen or start.
- Sending items back to their board is `agent-queue return <slug> --why "<reason>"`, never `cancel`: it closes the item `cancelled` with `end_reason: returned`, un-starts its row, and takes every queued item `after:` it along (`cancel_cause: returned with <slug>`). A plain `cancel` leaves those items dead, and a cancel of an item behind a dead `after:` records `cancel_cause:` with the root cause. A chain left dead behind a failed or cancelled item is the reap's to settle (`agent-queue settle-dead`): machine work returns, and the human's gets one retry, replan or drop ask. Why: 2026-11-12 a bulk return by cancel lost about 40 chains (ar-2299).
- `agent-land` normally does the closing. Use `move ... done` by hand only for work with no PR.

## Why an item is not starting

1. `agent-queue list --state queued`: the sixth column is the hold. Holds are `after <slug>` (that slug must be done ok; a failed predecessor never releases it), `night` (only inside the night window: the `night` row of `.config/machine-mode/hours`, `machine-mode hours` prints it), `at:HH:MM` (not before that time TODAY; once the time of day has passed it holds nothing, so use `at:YYYY-MM-DDTHH:MM` for a later day), `pr:<owner>/<repo>#N` (until the PR is MERGED; a failing `gh` also holds), `nightly:<repo>` (until that repo's scheduled runs for today have finished), and `ask:<id>[=<option>[+<option>]]` (until the human answers that agent-ask, with one of those options as the answer's first word; an ask that offers options must name them; pending, cancelled, judge-answered or missing holds), and `hold:<resource>` (while `agent-hold` holds that resource, by anyone; a session that finds one it needs held runs `agent-queue requeue <slug> --hold <resource>` and winds down), and `rbw:<folder>/<name>` (until `rbw list` shows that entry; locked rbw holds; file it with any ask that has the human add a key, so the deploy starts on its own). The full rules: agentctl `QUEUE.md`, "Order and tags".
2. No hold: it is a dispatch gate. `fleet-dispatch stopped` names it in one line, and `fleet-dispatch run --dry-run` shows what a pass would pick. Common ones: no account has room (`fleet-accounts`), load or `fleet-assess` HOLD (`fleet-pace`), run units full (heavy holds 2 units, light 1; `fleet-dispatch headroom`). A pass starts at most `DISPATCH_PER_PASS` (the conf sets 3).
3. Tags: `red` is read by `fleet-dispatch`, not by `agent-queue`: it sorts the item first, briefs it on the `fix-red` skill, which reviews and merges its own PR, and exempts it from the board waiting while the human is present. `cause:<sig>` marks a red item `fleet-bench triage` filed for a recurring failure (routes in `~/.config/agentctl/triage-routes`); a fix in hand (queued, running, or closed with its PR unmerged) keeps its cause from being filed again; one that closed with the red still here is retried, tagged `retry:<earlier slugs>`, up to `TRIAGE_FIX_TRIES` (2) items in `TRIAGE_FIX_DAYS`, then goes to the human sheet; `TRIAGE_FIX_CAP` limits new ones a day.
4. A running item whose session is dead is the shepherd's to nudge or reap (`shepherd`).

## Land and close

1. `agent-land <pr>` runs fetch, item-line, checks, merge, proof, item, board, plan. Add `--item <slug>` when the session records more than one item, `--plan <file> --phase "<text>"` to tick a plan phase, `--dry-run` to see the steps. Run it from a checkout of the PR's repo: the number is read in `--repo <owner>/<repo>`, else the repo of the item's own `pr:`, else this checkout's, and a PR outside this checkout's origin, or a merged one that is not the item's, is refused.
2. The item is `--item`, then `$AGENT_QUEUE_ITEM`, then `agent-queue mine`. With none it refuses before any gh call; add one with `agent-queue add --running`. An item taken from the session, not named by `--item`, takes only a PR in its project's repo: a side PR in another repo is refused before anything is touched, so name its item (`--partial` while the item's own PR is still to land).
3. Exit 0 landed, 1 a step failed (fix it and re-run; an already merged PR skips checks and merge, so the re-run finishes the record step), 2 usage (more than one item without `--item`, or the removed `--project` and `--title`), 3 behind origin base or a catch-up conflict (merge the base, re-run).
4. A `night` item stops at the open PR: `agent-queue set <slug> pr=<owner>/<repo>#<N>`, then `agent-queue move <slug> review`. `fleet-dispatch reap` records `merged:` and closes it once the PR merges.

## Do NOT

- Do not write into `~/.agent/queue/` by hand or `mv` an item; every transition goes through `agent-queue`, so two writers cannot both move one.
- Do not file an item for a want nobody has set up: that is a board row, and `agent-queue` is not a notes list.
- Do not `cancel`, `move` or `bump` another session's item. Do not dispatch around a gate by adding an item with a fake hold or tag.
- Do not merge a PR with `gh pr merge` and skip `agent-land`; the item, board row and plan then never close.
