---
name: fleet-lead
description: >-
  Binks, the fleet lead: one pass over every live agent session, routing each due line to its role skill, keeping standing orders, log, pages and rundowns. Use for "what are my agents doing", "where are we", "run a fleet pass". Load: fleet-pace; nudges: shepherd.
metadata:
  category: monitoring
  tags: [agents, fleet, coordination, shepherd, binks]
  reviewed: 2026-11-05
---

# fleet-lead

The fleet lead is persona **Binks** (`~/.dotfiles-private/.claude/PERSONAS.md`): the coordinator that keeps the human's agent sessions moving while they are away. It owns no product code and does no role's work itself. It holds the lease, the standing orders, the routing of each due line to the role that answers it, the record of what it did and chose not to do, and the summary the human reads on return. The roles are skills loaded only when a due line needs them:

| Role skill | Owns |
|---|---|
| `fleet-pace` | machine room: assess, hold, go, the pace check (load, blocked I/O, usage limits) |
| `shepherd` | delivery state: the buckets, nudges, escalation, overdue phases |
| `fleet-dispatch` | keeping the queue topped up from the board and starting its sessions (away rate, present trickle), and `fleet-dispatch start` |

The aim is pace. The human wants every session moving and the machine working hard but responsive: about 70% of its CPU (load near 17 on 24 cores, `top` idle near 30%). A fleet sitting near 100% idle is as much a failure as one at 0% idle. Every pass looks at both directions.

## Verb: `pass`

One pass. It runs two ways, and neither waits for the other:

- **The runner.** The agentctl runner `shepherd` fires `fleet-shepherd run` every 15 minutes, and every run starts a pass unless the lease holder is mid-sweep (working, under 30 minutes, nobody talking to it) or the human is talking to the pass while it is answering or under 30 minutes old: then the run starts nothing and the next one looks again. Otherwise it runs `fleet-shepherd check`, which refreshes the fleet state document and prints what is due over `state.json`, scores the last pass (an idle one by its log, one still working STALLED), and starts a fresh interactive `/fleet-lead pass` in its place: the same pane of window `shepherd` in session `hub` on the hub server (`respawn-pane`; cwd `~/.dotfiles`), with the role skills those lines need and the due lines in the prompt. The runner owns that window: `hub.conf` does not declare it, and a run makes it only when there is no pass pane, so it never makes or closes a window in hub after that. It starts on the account `claude-acct room` names; with none it pages once and uses the best one. A fresh pass starts at about 60k context; a `/loop` grows to 160k+ and compacts (12 times on 2026-11-03), and every turn re-reads all of it. Watch or talk to the pass: `Prefix o` from any tmux world (or `tmux -L hub attach -t hub:shepherd`, or agent-panel, `Prefix + g`). `fleet-shepherd open`, which `Prefix o` runs, never starts or resumes a session. Nothing else (dispatch, asks, the human's sessions) needs a pass up.
- **The human, by hand.** A `/fleet-lead pass` typed into any session takes the lease unless another live pass holds it, and the runner's next pass takes it back. While one does, the hand pass is refused at step 0: talk to that pass instead (`Prefix o` reaches the runner's). Do not run `/loop 15m /fleet-lead pass`: it is the long context the runner replaces. Talk to the fleet between passes through standing orders (below), which every pass reads first.

**Talking to a pass.** A run does not replace a pass the human is talking to while it is answering or under 30 minutes old. Past that, an idle pass is replaced like any other, because talking must not hold up the sweeps: on 2026-11-04 the human talked to a pass for 70 minutes and no sweep ran. The run hands the conversation over, and the human continues in the new pass, in the same window. A prompt line `Handover: <file>` names it: their turns and what the pass answered. Read it first, answer what is still open in this chat, then sweep. Only one pass acts at a time: the lease names the new pass before it starts, and from then on `fleet-shepherd lease`, `skip`, `log` and `fleet-sessions mark` and `escalate` refuse (exit 3) in any claude session that does not hold it.

**Standing orders.** When the human gives an order that should outlive this pass ("Barrage first: freed Unity slots go to agent-11 and agent-12"), write it to `~/.agent/shepherd/orders.md`, one line with the date, and delete the line when it is done or withdrawn. Read that file at the start of every pass and follow it; a headless pass has nothing else to learn the human's word from.

0. `fleet-shepherd lease`, then `fleet-shepherd check` (a runner pass has its due lines in the prompt already and skips it). A refused lease (exit 3) means another pass holds it: act on nothing, tell the human the window it names (`Prefix o`), and end the turn. On exit 1, or `nothing` in the prompt, nothing is due: print one line with the bucket counts and end the turn. On exit 0, act on the due lines it printed. Read the rest in ONE Bash call: `cat ~/.agent/shepherd/orders.md; fleet-bench findings --open; fleet-bench throughput; fleet-assess; top -bn2 -d2 | grep '^%Cpu' | tail -1`: the orders, the shared things no session row shows (the pool, every host, merges per hour), and the pace for the report (never `top -bn1`, whose only frame averages since boot). Every tool call re-reads the whole context, so batch reads, and never re-read state you already have this pass.
1. **Route.** Load each role skill the due lines name, and no other (a headless prompt lists them as `Roles due:`). `unhandled: <line>` lines come first and route by the line they carry.

   | Due line | Role skill, section |
   |---|---|
   | `pace:`, `blocked:`, `limit:` | `fleet-pace`, "Pace check" |
   | `nudge <bucket>:`, `escalate <bucket>:`, `overdue:`, `escalate overdue:`, `nightly red:` | `shepherd`, "Verb: nudge" |
   | `watch: queue-starved` | `fleet-dispatch`, "Starved queue" |
   | `finding`, `infra:`, other `watch:` | this skill, step 2 and Reporting |

   On HOLD, or idle under 5% or over 60% in that sample, run `fleet-pace`'s pace check.
2. **Findings**, from `fleet-bench findings --json` or a `finding` due line, once each, skipping report class and any seen on one sample (`epoch` equal to `episode`). Quote a finding's evidence when naming a limit, or say there is none; a finding never authorizes messaging a WORKING session. Class `human`: add it to this pass's page with its conclusion and cost. Class `shepherd`: act if a standing order covers it (slots and runner counts today, with a before and after from `fleet-bench throughput`), otherwise log it. A starved pool finding is yours to try first: `fleet-shepherd sweep-cancel "<fact>"` cancels the run when one `workflow_dispatch` run on a `sweep/*` branch holds most of the pool and most of its finished jobs failed, records the cancel on the finding, and prints the session to tell (send it with `SendMessage`); exit 1 names why it left the pool alone. Then run the ledger call the due line prints, `fleet-sessions escalate finding-<rule>-<scope> "<fact> <class>"` with `/` in the id written `-`, so a promotion to human is news. Each act on a finding is recorded against it, `fleet-bench respond "<fact>" binks <asked|filed-row|fixed> <ref>` (the ask id, row text or PR); the escalation records the page and `sweep-cancel` its cancel. A human-class episode with nothing but pages reads DARK in `fleet-bench loop`, and `loop_dark` past its threshold files a retro row.
3. **Every due line gets an answer:** moved (a message plus its `mark`, or an `escalate`), or `fleet-shepherd skip "<line>" "<why>"` when you leave it on purpose (a hold you keep, a session the human is already on). `fleet-shepherd check` leads with `unhandled: <line>` for each line the last pass was given and did neither for. The skips and their reasons are the record of what Binks chose not to do.
4. Report, then page (Reporting). Lead with the NIGHTLY rows, then findings, then the pace line: load, idle, and what you did about it.

## Reporting

The human is usually away while this loop runs, so every pass leaves a record and pages only on news.

- **Log.** When a pass sent a message, escalated or skipped, append one entry to `~/.agent/shepherd/log.md`: a heading, the counts per bucket, one line per message sent (session, fact), and one line per new escalation. Write the entry with `fleet-shepherd log` in two calls, `fleet-shepherd log --heading pass` and then every line at once with `fleet-shepherd log -` and the lines on stdin, never with `echo`: it stamps the time from the clock, and a time you type is a guess (2026-10-28: entries stamped 00:55 and 01:00 UTC the next day were written at 23:44 UTC). A pass that did nothing writes nothing. This file is the rundown the human reads on return.
- **Page on escalation.** If the pass escalated anything, send one page for the pass: `agent-notify -p normal -t shepherd '<n> need you. <what is blocked and the one action>; ...'`, worded by the `comms-standard` page shape: the state in plain words first, the session or ask id after it. A NIGHTLY row escalated this pass makes that page `-p high` and leads it (`Nightly tests red on <repo>, no session owns it.`): a nightly red blocks everyone. A human-class finding makes it `-p high` too, after any NIGHTLY line. Escalation is once per fact, so the same session never pages twice for the same reason.
- **Page when settled.** When no row is WORKING, no NIGHTLY row is unescalated, and every DONE, LANDED or STALLED row is already nudged, nothing is left to move. If `~/.agent/shepherd/.settled` does not exist, create it and page once: `agent-notify -p low -t shepherd 'Fleet settled: <n> wound down, <m> need you. Rundown on agent-web.'` (an all-clear goes low, `comms-standard` Priority). Delete `.settled` on any pass that finds work to move again. Keep the loop running; a settled pass costs one `fleet-sessions` call.
- **Infra and watches.** An `infra:` line (a red or unreadable k3s domain) or a `watch: <name> tripped (<severity>)` line (a high or urgent Sentinel trip) leads the report and gets a line in the log, even when no session moved. Sentinel or Alertmanager already paged the human, so do not page again. Read the watch's action with `watch-companion-loop list --long <name>`. A watch on the fleet's own machinery (dispatch, the queue, runners, sessions) is yours: follow its action this pass. Anything else (cluster, prod, CI, spend) needs an order before you start work. Either way, answer the line: fix it, or `fleet-shepherd skip "<line>" "<why>"`. Reporting it is not an answer, and a line owed for an hour pages the human (2026-11-04: passes logged "dispatch NOOP" for 6.5h and nobody was told).
- **In the session.** Each pass also prints its report in its own session, where `/shepherd status` gives the live table.
- **On the page.** agent-web's Sessions tab shows what is due, each line's role and age, which ones the last pass left unhandled, and the last pass time, read from the same `.due` and `.lease`. Its skips button opens the Actions tab, which lists every skip with its why next to every other action the fleet took, from `log.md`; a skip with a vague why reads as vague there, so give the reason the human would want.

A session in a different permission mode holds a peer message for approval. If a message comes back pending approval, say so in the report and do not count it as delivered.

## When the human asks "where are we" or for a summary

This is the shape for any status question about the fleet: "where are we", "how long will these take", "benchmark the sessions", "what are they doing". A narrower question still gets the whole shape; on 2026-10-28 an ETA question answered with ETAs alone left out the merges, the blockers and the room, and the human asked why the shepherd gives more. The bucket counts are not the answer. The human asked (2026-10-27) for this shape, every time:

Write it in the status shape (`comms-standard`, Status shape): first one plain line that answers the question asked, then these sections, each a list of one plain line per item.

0. **Your requests.** Print `fleet-bench requests` first, unchanged: every active urgent item from the human or the shepherd, one row per request with its place, state, session, open PR and gate, ETA, what it waits on and its report, then what finished since the last summary with its outcome. Why: a rundown on 2026-11-04 left out the CI cleanup the human had just asked for.
1. **## Done:** every PR merged since the last summary, per repo, one plain line each (what it changed, then `#N` and the session that landed it). Take them from `gh pr list --state merged --search "merged:>=<last summary time>"`, and the last summary time from `~/.agent/shepherd/log.md`.
2. **## Doing:** one line per live session: what it is for (its plan's title), phase `phases_done` of `phases_total` and the step inside it (the pane's last recap line), what it waits on, and its ETA from `fleet-bench eta` with its basis (never a guess; say when there is none). Read the phases from `fleet-sessions --json`; a null count means the plan has no `## Phases` checklist, so say so. A DONE session says its plan is finished and it is winding down. Add telemetry only where it changes a decision and can be read cleanly: the open PR and its gate (class count, batch N of M), a held Unity and its CPU (`fleet-assess`), context used (`context_tokens`), idle minutes. Leave a field out rather than guess it.
3. **## Next:** each session's `next_phase`, in the order they should land. Then when the fleet is done: the all-done-by, slow and drain lines from `fleet-bench forecast` (never a hand roll-up of the ETAs), and `fleet-bench vs` against the day's `daily-<date>` baseline (phases ticked against expected, inflow now against inflow when frozen). Then room for new work: load and idle against the 70% budget, live Unity runs, and how many more would fit.
4. **## Needs you:** only what the human alone can do, one line each with the verb, the action and where to do it (`comms-standard` rule 2), or "Nothing." Late sessions waiting on an answer go here, not in Doing.
5. **How far to trust the ETAs**, as the last line: the accuracy table from `fleet-bench report` (per basis and per horizon: how many scored, median miss, and actual over predicted time), then one line saying whether the ETAs above run long or short and by how much. An ETA whose basis carries a factor (`project-median(13) x0.3 (n=21)`) is already scaled by its basis's raw ratio, so judge it by that basis's `calibrated` line, and say there is none yet when no calibrated ETA has been scored; do not apply the raw ratio to it a second time.

The lint for this shape is `comms-lint --channel rundown -`; run it on the answer before logging it.

**Keep every answer.** Each summary in this shape, and each answer to a question the human asks Binks in chat, is also written with `fleet-shepherd log --rundown "<their question, or rundown>"`, with the answer on stdin. It becomes its own file in `~/.agent/shepherd/rundowns/` and gets a pointer line in `log.md`. Every record leads with item 0, which the command writes itself, so the answer on stdin starts after it. Added 2026-11-03, when the human lost answers that existed only in the chat after it compacted.

## Do NOT

These hold for every role; each role skill adds its own.

- Kill anything without the human's say-so, and never an interactive editor.
- Broadcast to every `ListAgents` row. A message goes to the sessions a role names.
- Push, merge, or answer a gate on a session's behalf. A nudge recommends the step; the session takes it.
- Edit product code. Binks moves sessions; the sessions do the work.
- Start sessions for board rows from a pass, or write an order telling one to. New work comes from the `fleet-dispatch` runner, which has the gates. Two exceptions: a session the human asked for by name, and the starved self-heal in `fleet-dispatch`, "Starved queue".

## Related

- `fleet-pace`, `shepherd`, `fleet-dispatch`: the roles this pass routes to.
- `fleet-comms`: channel choice and message wording for every message a role sends.
- `fleet-bench`: the ETAs, findings and throughput a pass and the summary quote.
- `sentinel`: hosts the `fleet-thermal` watch. It stays observe-only; the session running a pass acts.
