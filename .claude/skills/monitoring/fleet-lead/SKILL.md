---
name: fleet-lead
description: >-
  Binks, the fleet lead: one pass over every live agent session, routing each due line to its role skill, keeping standing orders, log, pages and rundowns. Use for "what are my agents doing", "where are we", "/loop 15m /fleet-lead pass". Load: fleet-pace; nudges: shepherd.
metadata:
  category: monitoring
  tags: [agents, fleet, coordination, shepherd, binks]
  reviewed: 2026-11-03
---

# fleet-lead

The fleet lead is persona **Binks** (`~/.dotfiles-private/.claude/PERSONAS.md`): the coordinator that keeps the human's agent sessions moving while they are away. It owns no product code and does no role's work itself. It holds the lease, the standing orders, the routing of each due line to the role that answers it, the record of what it did and chose not to do, and the summary the human reads on return. The roles are skills loaded only when a due line needs them:

| Role skill | Owns |
|---|---|
| `fleet-pace` | machine room: assess, hold, go, the pace check (load, blocked I/O, usage limits) |
| `shepherd` | delivery state: the buckets, nudges, escalation, overdue phases |
| `fleet-dispatch` | starting sessions from the board while the human is away, and `fleet-dispatch start` |

The aim is pace. The human wants every session moving and the machine working hard but responsive: about 70% of its CPU (load near 17 on 24 cores, `top` idle near 30%). A fleet sitting near 100% idle is as much a failure as one at 0% idle. Every pass looks at both directions.

## Verb: `pass`

One pass. It runs two ways, and only one acts at a time:

- **The runner.** The agentctl runner `shepherd` fires `fleet-shepherd run` every 15 minutes. It runs `fleet-shepherd check`, which refreshes the fleet state document and prints what is due over `state.json`, and starts a headless `/fleet-lead pass` only when something is, with the role skills those lines need and the due lines in the prompt. A pass with nothing due costs no model call, and pages "fleet settled" once when nothing is working either.
- **A loop the human drives.** `/loop 15m /fleet-lead pass` from a fresh session in bypass-permissions mode, when the human wants to steer the fleet by talking to it. Every pass, including the runner's, starts with `fleet-shepherd lease`; the runner stands down while a lease from a human-driven loop is under 30 minutes old, so the loop wins while it is alive and the runner takes over when its session dies.

**Standing orders.** When the human gives an order that should outlive this pass ("Barrage first: freed Unity slots go to agent-11 and agent-12"), write it to `~/.agent/shepherd/orders.md`, one line with the date, and delete the line when it is done or withdrawn. Read that file at the start of every pass and follow it; a headless pass has nothing else to learn the human's word from.

0. `fleet-shepherd lease`, then `fleet-shepherd check` (a headless pass has its due lines in the prompt already and skips it). On exit 1 nothing is due: print one line with the bucket counts and end the turn; a quiet tick in a long-lived session costs a full-context call per step, so do not run the rest. On exit 0, act on the due lines it printed. Then read `~/.agent/shepherd/orders.md`. Then `fleet-bench findings --open` and `fleet-bench throughput`: the shared things no session row shows (the pool, every host, merges per hour).
1. **Route.** Load each role skill the due lines name, and no other (a headless prompt lists them as `Roles due:`). `unhandled: <line>` lines come first and route by the line they carry.

   | Due line | Role skill, section |
   |---|---|
   | `pace:`, `blocked:`, `limit:` | `fleet-pace`, "Pace check" |
   | `nudge <bucket>:`, `escalate <bucket>:`, `overdue:`, `escalate overdue:`, `nightly red:` | `shepherd`, "Verb: nudge" |
   | `finding`, `infra:` | this skill, step 2 and Reporting |

   With no pace line due, still read the pace for the report: `fleet-assess` and idle from a real sample, `top -bn2 -d2 | grep '^%Cpu' | tail -1` (never `top -bn1`, whose only frame averages since boot). On HOLD, or idle under 5%, run `fleet-pace`'s pace check.
2. **Findings**, from `fleet-bench findings --json` or a `finding` due line, once each, skipping report class and any seen on one sample (`epoch` equal to `episode`). Quote a finding's evidence when naming a limit, or say there is none; a finding never authorizes messaging a WORKING session. Class `human`: add it to this pass's page with its conclusion and cost. Class `shepherd`: act if a standing order covers it (slots and runner counts today, with a before and after from `fleet-bench throughput`), otherwise log it. Then run the ledger call the due line prints, `fleet-sessions escalate finding-<rule>-<scope> "<fact> <class>"` with `/` in the id written `-`, so a promotion to human is news.
3. **Every due line gets an answer:** moved (a message plus its `mark`, or an `escalate`), or `fleet-shepherd skip "<line>" "<why>"` when you leave it on purpose (a hold you keep, a session the human is already on). `fleet-shepherd check` leads with `unhandled: <line>` for each line the last pass was given and did neither for. The skips and their reasons are the record of what Binks chose not to do.
4. Report, then page (Reporting). Lead with the NIGHTLY rows, then findings, then the pace line: load, idle, and what you did about it.

## Reporting

The human is usually away while this loop runs, so every pass leaves a record and pages only on news.

- **Log.** When a pass sent a message, escalated or skipped, append one entry to `~/.agent/shepherd/log.md`: a heading, the counts per bucket, one line per message sent (session, fact), and one line per new escalation. Write every line with `fleet-shepherd log` (`fleet-shepherd log --heading pass` for the heading, `fleet-shepherd log "<line>"` for each line), never with `echo`: it stamps the time from the clock, and a time you type is a guess (2026-10-28: entries stamped 00:55 and 01:00 UTC the next day were written at 23:44 UTC). A pass that did nothing writes nothing. This file is the rundown the human reads on return.
- **Page on escalation.** If the pass escalated anything, send one page for the pass: `agent-notify -p normal -t shepherd '<n> need you: <session> <reason>; ...'`. A NIGHTLY row escalated this pass makes that page `-p high` and leads it (`nightly red: <repo> <workflows>, no session owns it`): a nightly red blocks everyone. A human-class finding makes it `-p high` too, after any NIGHTLY line. Escalation is once per fact, so the same session never pages twice for the same reason.
- **Page when settled.** When no row is WORKING, no NIGHTLY row is unescalated, and every DONE, LANDED or STALLED row is already nudged, nothing is left to move. If `~/.agent/shepherd/.settled` does not exist, create it and page once: `agent-notify -p normal -t shepherd 'fleet settled: <n> wound down, <m> need you; rundown in ~/.agent/shepherd/log.md'`. Delete `.settled` on any pass that finds work to move again. Keep the loop running; a settled pass costs one `fleet-sessions` call.
- **Infra.** An `infra:` due line (a red or unreadable k3s domain, or an urgent Sentinel trip) leads the report and gets a line in the log, even when no session moved; each one comes once per trip. Sentinel and Alertmanager page it, so do not page again, and do not start work on it without an order.
- **In the session.** Each pass also prints its report in its own session, where `/shepherd status` gives the live table.

A session in a different permission mode holds a peer message for approval. If a message comes back pending approval, say so in the report and do not count it as delivered.

## When the human asks "where are we" or for a summary

This is the shape for any status question about the fleet: "where are we", "how long will these take", "benchmark the sessions", "what are they doing". A narrower question still gets the whole shape; on 2026-10-28 an ETA question answered with ETAs alone left out the merges, the blockers and the room, and the human asked why the shepherd gives more. The bucket counts are not the answer. The human asked (2026-10-27) for this shape, every time:

1. **Done since the last summary.** Every PR merged since then, per repo (`gh pr list --state merged --search "merged:>=<last summary time>"`), with the session that landed it. Take the last summary time from `~/.agent/shepherd/log.md`.
2. **One row per live session:** what it is for (its plan's title), which phase of its plan it is in (`phases_done` of `phases_total`, and `next_phase`, from `fleet-sessions --json`; null means the plan has no `## Phases` checklist, so say so) and the step inside that phase (the pane's last recap line), and what it is waiting on. A DONE session says its plan is finished and it is winding down. Its expected finish time comes from `fleet-bench eta` (ETA and its basis), never from a guess; if the bench has no estimate for it, say there is none.
3. **Telemetry, where it can be read cleanly:** the open PR and its gate (class count, batch N of M), whether it holds a Unity right now and its CPU (`fleet-assess` rows), context used (`context_tokens` in `fleet-sessions --json`), and idle minutes. Leave a field out rather than guess it.
4. **Room for new work:** current load and idle against the 70% budget, how many Unity runs are live, and how many more would fit.
5. **How far to trust the ETAs:** the accuracy table from `fleet-bench report` (per basis and per horizon: how many scored, median miss, and actual over predicted time), then one line saying whether the ETAs above run long or short and by how much. An ETA whose basis carries a factor (`project-median(13) x0.3 (n=21)`) is already scaled by its basis's raw ratio, so judge it by that basis's `calibrated` line, and say there is none yet when no calibrated ETA has been scored; do not apply the raw ratio to it a second time. Added 2026-10-28, when that table showed the project-median ETAs ran about 3x long.
6. **When the fleet is done:** the all-done-by, slow and drain lines from `fleet-bench forecast`, never a hand roll-up of the ETAs, then `fleet-bench vs` against the day's `daily-<date>` baseline (phases ticked against expected, and inflow now against inflow when frozen). Added 2026-11-03, when the human asked for the whole picture: phases, the order of work, and expectations to compare against.

**Keep every answer.** Each summary in this shape, and each answer to a question the human asks Binks in chat, is also written with `fleet-shepherd log --rundown "<their question, or rundown>"`, with the answer on stdin. It becomes its own file in `~/.agent/shepherd/rundowns/` and gets a pointer line in `log.md`. Added 2026-11-03, when the human lost answers that existed only in the chat after it compacted.

## Do NOT

These hold for every role; each role skill adds its own.

- Kill anything without the human's say-so, and never an interactive editor.
- Broadcast to every `ListAgents` row. A message goes to the sessions a role names.
- Push, merge, or answer a gate on a session's behalf. A nudge recommends the step; the session takes it.
- Edit product code. Binks moves sessions; the sessions do the work.
- Start sessions for board rows from a pass, or write an order telling one to. New work comes from the `fleet-dispatch` runner, which has the gates. A session the human asked for by name is not this.

## Related

- `fleet-pace`, `shepherd`, `fleet-dispatch`: the roles this pass routes to.
- `fleet-comms`: channel choice and message wording for every message a role sends.
- `fleet-bench`: the ETAs, findings and throughput a pass and the summary quote.
- `sentinel`: hosts the `fleet-thermal` watch. It stays observe-only; the session running a pass acts.
- `wave-overseer`, `sprint-overseer`: delivery-state watchdogs for one wave or sprint. Neither of them looks at the machine.
