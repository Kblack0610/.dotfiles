---
name: fleet-dispatch
description: >-
  Start agent sessions from the board while the human is away, and start any session by hand the one way (`fleet-dispatch start`). Use for "what would dispatch pick", "why did it skip that row", "start a session for this row", "pause dispatch". Moving live sessions is shepherd.
metadata:
  category: monitoring
  tags: [agents, fleet, dispatch, queue, board]
  reviewed: 2026-11-05
---

# fleet-dispatch

The intake role of `fleet-lead` (Binks). `fleet-dispatch` feeds the shepherd while the human is away. The agentctl runner `fleet-dispatch` runs `fleet-dispatch run` on the `SCHEDULE` in its conf (off while the conf says `ENABLED=no`; `agentctl enable fleet-dispatch` arms it, `agentctl disable fleet-dispatch` turns it off again); this skill is for running it by hand and reading what it decided. It is the only thing that starts sessions from the board unasked: a `fleet-lead` pass does so only to heal a starved queue (below), and no order should tell one to.

Away comes from `fleet-presence`: no keypress in any tmux client and no desktop input for `AWAY_AFTER_MIN` minutes (set in the conf). It takes no time of day, because a night is a long away. When the human comes back, new starts stop at the next pass and running sessions carry on. If it prints `unread`, usually because `hypridle` is not running, dispatch treats the human as here and starts nothing.

Who may take a row is `~/.config/fleet-dispatch/workers.json`, walked in file order:

- `requested`: `#requested` rows tagged `#worker/requested`, on `unity-core-playground`, up to tier 2.
- `fleet`: rows the human tagged `#worker/fleet`, up to tier 1, with a `#tier/N`.
- `board`: `unity-core-playground` agent-board rows with no `#worker` tag, up to tier 2. No tags are needed, because the judge reads the tier. A row tagged `#tier/3` stays out.

The human sheet stays opt-in: `board` never reads it. Tier 3 (CI, gates, runners, build, deploy, harness and tooling) never gets a merging session; it runs unattended only to an open PR, as a `night` queue item (below). A row whose text starts `ci:` or `infra:` counts as tier 3 whatever its tag says. What each tier means is defined in `~/.config/fleet-dispatch/policy.md`, under Tier.

- `fleet-dispatch run --dry-run` runs the gates, says what would stop a real pass, and prints the picks without starting anything. It still judges new rows, up to `DISPATCH_JUDGE_MAX`. `fleet-dispatch run` starts them.
- `fleet-dispatch report` shows the latest verdict for every row it has judged: picked or skipped, size, judged tier, area, and the one-line reason. A verdict made under an older policy is marked stale.
- `fleet-dispatch candidates` lists the open rows it would judge next.
- `agent-hold set dispatch "<reason>"` pauses it; `agent-hold release dispatch` resumes it.
- Night items: `fleet-dispatch fill` also judges the open agent-lane rows of `DISPATCH_NIGHT_PROJECTS` (agent-runtime, notes-cockpit) and promotes up to `DISPATCH_NIGHT_MAX` (3 active, one an area) whose verdict says tier 3 is the only reason to skip (`tier3_only`) as queue items tagged `night`, which agent-queue holds to its night window; each brief stops at an open PR. It skips `#requested`, `decide:`, device, the human's machine, secrets, prod and wishes; it ranks subtract-or-fix rows first, then `kpi:`/`dream`/`retro` rows, then most urgent and oldest. Each row is `start`ed; `done` waits for the human's merge. `fleet-dispatch fill --dry-run` lists them as `night`.

## A pass, in order

1. Reap: an item whose session is gone is closed, and a live one moves to `waiting/` while its Claude waits on the human (agent-panel `waiting`, an open plan or dialog) or has a pending ask, back to `running/` after. An agent-lane row started with no active item naming it is un-started, with a `failed` verdict, once reap has seen it that way for `DISPATCH_ORPHAN_HOURS` (72); first sightings are in `~/.agent/dispatch/orphans.tsv`. Room is `DISPATCH_MAX_LIVE` minus live sessions the runner started (`origin: run`), capped at `DISPATCH_PER_PASS`.
2. Gates, each refusing when it cannot read its source: no `dispatch` hold; `fleet-presence` says away; `fleet-assess` not HOLD; cluster not red; 1-minute load under `DISPATCH_MAX_LOAD` per core; GitHub budget not LOW; real idle above `DISPATCH_MIN_IDLE` percent on a two-frame `top` sample. At launch, `claude-acct room` must name an account under its weekly pace, or the row waits. A nightly red is deliberately not a gate: nightlies stay red while sessions merge normally, and the NIGHTLY row handles it.
   Findings sampled in the last `DISPATCH_FINDING_FRESH_MIN` minutes hold only the items they are about, and the pass starts up to room queued items nothing holds, reading the gates again before each start after the first (`run --dry-run` names each held one): `starved pool:<pool>` holds items whose repo (origin's name) has jobs waiting in that pool, every item when the finding names no `repos`; `throughput-drop <project>` holds items on that project's repo; `starved <host>` holds every item. A `blind` finding holds nothing: it is a reader's gap, not a fault. Unreadable findings hold everything.
3. Candidates: every open `[ ]` row a worker may take, of each `alpha`, `beta` or `prod` project in `DISPATCH_PROFILES`. A project is left out while its wave lock is held, or when `project-map.json` has no repo for it.
4. Judgment: one sonnet call for up to `DISPATCH_JUDGE_MAX` rows not judged before, in worker order, against `~/.config/fleet-dispatch/policy.md`. Every verdict, skip included, lands in `~/.agent/dispatch/verdicts.jsonl`, so a row is judged once until its text, the policy or `workers.json` changes. To change what gets picked, edit the policy, not the script.
5. Picks: verdict `dispatch` with size S or M, clear and agent-only, naming one `area`, judged no higher a tier than the row counts as, made under the current policy. Never two sessions on one area: an active queue item holds its area until reap closes it. Worker order first, then `#urgent`, then prod before beta before alpha.
6. Launch: `fleet-dispatch start` (below) with the row and a `/one-shot <row> ...` brief, on the world that declares `@agents`. The pass publishes WORKED only when a session started; BLOCKED when a gate, a finding or no account room left a queue item waiting (amber on every dashboard, never a page; `queue-starved` pages); NOOP when nothing was runnable, the fleet is at its live cap, or the human held dispatch; FAILED when it could not judge or could not start its pick. A WORKED pass that a limit stopped while runnable items waited and every gate was open says `under-used: ... <limit> is the limit` and logs it. `fleet-dispatch headroom` shows the window before raising `DISPATCH_PER_PASS` or `DISPATCH_MAX_LIVE`: how many could start now, and the room under load, idle and run units (a heavy queue item holds 2 of `DISPATCH_MAX_LIVE`, a light one 1; `agent-queue add --weight` sets it). Each real pass leaves that count in `~/.agent/dispatch/headroom.json`; `stats` publishes it as `could_start`, and the waybar Dispatch chip goes amber while it is over 0. Nothing raises a limit on its own; the human picks it.

## Starting a session by hand: `fleet-dispatch start`

Every session an agent starts goes through `fleet-dispatch start`: the dispatch pass above, a session you start for a board row, and a reboot restore (`session-snapshot` restore). It opens the session (for a row, after re-reading the row, `ptask start`ing it, which stamps an id on a row with none, and checking it reads `[/]`), tags it `@dispatch` on its server (the status line shows `dispatch: <project>: <row>`; the human reads it as "an agent started this") and records `session: <server>:<name>` on its queue item, the one record `reap` and `fleet-sessions` read (a bare name means `lab`). There is no separate session ledger. Never `wt new` + `claude` by hand, and never `tmux set-option @dispatch` on a session afterwards: on 2026-10-28 the human had to ask twice why sessions an agent started carried no label.

- For a queue item: `fleet-dispatch start --item <slug> [--model <m>]`. It cuts a fresh worktree with `wt new --detach` and moves the item to `running/`.
- For a row: `fleet-dispatch start --project <p> [--agent] --row <id> --brief <file> [--model <m>]`. Write the brief to a file first: `/one-shot <task>`, then where the row is and how to record it done. `start` claims the row, promotes it to a queue item (slug and `from: board:<project>:<id>` from the row's id, priority from the row, high on a bare row; a row with no id is refused when its project has no `code`) and starts that item. Do not `start` the row yourself first: `start` refuses a row that is not open.
- To queue a row without starting it: `fleet-dispatch promote --project <p> [--profile <x>] [--agent] --raw "<line>"`, what the Board tab's Start runs. It takes the row's exact line, refuses one that changed or is already started, and the item waits for the human to be away like any board item.
- One conversation: `fleet-dispatch start --project <p> --server <server> --session <name> --cwd <dir> --resume <claude session id> [--item <slug>]`. With `--item` (a running or waiting item) the item records the new session, `origin: resume`; without one the session is only tagged. The sheet is left alone, `--row` is refused, and a session name that already exists on that server is refused unless `--window <name>` says to open it as a window of that session. It reopens in the permission mode its transcript last shows.
- A lost server or a reboot: `fleet-dispatch restore [--server <s>] [--dry-run]`, below.

Only the sessions the dispatch pass started count against `DISPATCH_MAX_LIVE` and its area rule; hand launches and restores carry the label and their item but hold none of its slots. `start` does not check the `dispatch` hold, which pauses only the runner. Before starting anything, read `agent-hold list` and `fleet-pace`'s pace check as for any other new work.

A dispatched session is an ordinary session from then on: the `shepherd` buckets, nudges and escalations apply to it unchanged, and its `/one-shot` records done on its row with proof. If it needs the human, it asks in its own conversation, files the same question with `agent-ask post`, and stops; the human answers in the session or from a board, and either way the answer lands in the session and closes the ask. Every pass that starts or reaps something appends a line to `~/.agent/dispatch/log.md`. `fleet-dispatch stats` counts it for the feed (HA sensor "Dispatch queue", Prometheus): runnable items and the oldest one's age, the queue's started, done and failed by the hour (from `agent-queue stats`), reap moves, and the items reaped `DISPATCH_FLAP_MOVES` or more times in an hour. Read those numbers, not the log, to answer "is dispatch moving".

## A world server died: `fleet-dispatch restore`

`fleet-dispatch record` runs every minute from `fleet-state.service` and keeps `~/.agent/dispatch/panes/<server>.json` for each world in `.config/tmux-servers/`: every pane's session, window name, cwd and Claude session id. When the server it described is gone or restarted, it pages (`tmux <server> server died`) and renames the record to `<server>.lost.json`. A clean reboot pages the same way.

`fleet-dispatch restore` runs `tmx ensure`, then reopens each conversation through `start --resume --window`, as a window of the session it was in and in the permission mode its transcript last shows. It skips a conversation that is running, or that wound down on purpose (a `.request` or `.fired` in `~/.agent/spin-down/`), and lists plain shells and vanished folders without reopening them. A queue item needs no re-attaching: the same `<server>:<session>` comes back. All reopened renames the record to `<server>.restored.json`; a failure keeps it, so a rerun finishes the rest. `--dry-run` shows the list first.

## Starved queue: a fleet-lead pass may start the head item

`fleet-dispatch starved` exits 1 when an urgent or high queue item has been runnable over `DISPATCH_STARVED_MIN` minutes and no run pass started anything (the Sentinel watch `queue-starved` runs it, and its trip reaches the pass as a `watch:` due line). On 2026-11-04 four gates in turn held every pass for 7.5h while the shepherd watched and could not act. A `fleet-lead` pass that sees it:

1. `fleet-dispatch run --dry-run` and `agent-hold list` in one call, to read what stops a real pass.
2. If the block is load (the pace check says HOLD), account room (`claude-acct room`), or an `agent-hold` anyone set, leave it: those are the gates working. Answer the line with `fleet-shepherd skip` naming the gate; the watch has already paged the human.
3. Otherwise start the oldest item `starved` named, one per pass: `fleet-dispatch start --item <slug>`. Log it (`fleet-shepherd log "healed starved: <slug>, gate was <what dry-run said>"`) and file the gate that held it as an agent-board row, because a start by hand fixes the item, not the pass.

## Do NOT

The fleet-wide list is in `fleet-lead`; this is this role's own.

- Widen dispatch beyond `DISPATCH_PROFILES=bnb`, relax the policy, raise a worker's `max_tier`, add a worker, or put `#worker/*` on a row, without the human asking. An agent filing a row may add its own `#tier/N` reading; assignment is the human's.

## Related

- `fleet-lead`: the pass, and the rule that it never starts board work.
- `one-shot`: what every dispatched session runs.
- `session-snapshot`: the reboot restore that calls `start --resume`.
