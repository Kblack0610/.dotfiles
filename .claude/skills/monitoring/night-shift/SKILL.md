---
name: night-shift
description: >-
  Overnight observe-only check-ins: bedtime baseline, expiring Sentinel watches for what you name, a morning report. Use for "night shift", "watch things while I sleep", "make sure X goes through overnight". Standing watches: sentinel.
metadata:
  category: monitoring
  tags: [monitoring, overnight, observe-only, sentinel]
  reviewed: "2026-11-09"
---

# night-shift

The human goes to bed and wants to wake up knowing the night went as intended, and where it did not. The fleet already works all night: Sentinel's standing watches and the shepherd runner (every 15 minutes) never stop. This skill adds no loop of its own. At bedtime it writes a baseline and arms one temporary Sentinel watch for each thing the human names. In the morning it writes one report. Everything in between runs on Sentinel's observe lane.

## Scope and triggers

- "night shift", "I'm going to bed, keep an eye on things", "make sure the grouped CI goes through tonight", "what happened overnight".
- Verbs: `start [focus...]` at bedtime, `status` at any time, `morning` when the human is back.

Not for a standing watch that should outlive the night: that is `sentinel`. Not for moving stalled sessions: the shepherd runner does that all night (`fleet-lead`, `shepherd`). Not for fixing a red: the report names it, and `fix-red` or the owning session fixes it.

## The record

One file per night: `~/.agent/night-shift/<YYYY-MM-DD>.md`, dated by the evening the shift started. `start` writes the `## Bedtime` section and `morning` appends `## Morning`. Night watches are named `night-<slug>` and carry `source: night-shift`, which is how `status` and `morning` find them.

## Verb: `start [focus...]`

1. **Baseline.** Run these and write the counts and names under `## Bedtime` with the start time (`date -Iseconds`):
   - `watch-companion-loop tripped`: the watches already red. They are not news in the morning unless they change.
   - `agentctl status sentinel` must read `active (running)`. If it does not, tell the human now, before they sleep. The shift has nothing to run on.
   - `agent-queue list`: how many items are running and in review, by project.
   - For each focus repo, `gh pr list -R <owner/repo> --json number,title,labels` for the PRs in flight.
2. **Arm the focus.** For each thing the human named:
   - Check first: `grep -il '<repo or subject>' ~/.agent/watches/*.yaml`. When a standing watch already asks the question, list it under the focus and write nothing. Two watches on one question page twice.
   - Otherwise write `~/.agent/watches/night-<slug>.yaml` per `sentinel` (Verb: `watch`). Prefer a `command` probe when the question has an exit code. Use `probe: agent` when the question is whether something is flowing: `interval: 90m`, `agent_max_turns: 8`, and one read-only `signal:` per fact the check needs (gh, git, log tails). That gives about six check-ins a night, each a short Sonnet pass on the observe lane.
   - Every night watch gets `severity: normal`, so nothing buzzes the phone overnight; the human reads it in the morning. Set `high` only when the human said to wake them for it.
   - Set `expiry:` to an ISO time the next morning (default 09:00 local). It is removed on its own if `morning` never runs.
   - Validate with `sentinel-manifest validate --strict <file>`, then `watch-companion-loop list night-<slug>`.
3. **Tell the human** in three lines: what is armed and how often it checks, which standing watches cover the rest, and that only high and urgent standing watches can page them overnight.

## Verb: `status`

`watch-companion-loop list | grep -E 'night-|TRIP'` and `grep -E 'night-' ~/.local/state/agentctl/sentinel/activity.log | tail -n 20`. Answer in one plain line, then the list.

## Verb: `morning`

Read the start time `S` from tonight's `## Bedtime`. Then:

Log lines read `[<ts>] <watch> <prev> -> <new> <detail>`, so awk on fields works where grep flavours differ (here `grep` is ugrep).

1. **Check-ins.** `awk -v s="[$S" '$0 >= s && $2 ~ /^night-/' ~/.local/state/agentctl/sentinel/activity.log`: every verdict each night watch gave, in order. A focus that went SUSPECT, then HEALTHY again, is reported with both times.
2. **What changed.** `awk -v s="[$S" '$0 >= s && $4 == "->" && $3 != $5 && $6 != "pending"'` on the same log: every watch that tripped, errored or recovered overnight. Compare `watch-companion-loop tripped` now with the bedtime list: new, cleared, still red.
3. **Pages.** `agent-notify list` since `S`: what reached the phone and what was held.
4. **Merges.** For each focus repo, `gh pr list -R <owner/repo> --state merged --search "merged:>=<S>" --json number,title,mergedAt`. For the whole fleet's day, `day-log` is the owner.
5. **Write it** under `## Morning` in the `comms-standard` status shape: one line that answers "did the night go as intended", then Focus (one line per focus: outcome, PR numbers, times), New reds, Cleared, Needs you. Lint with `comms-lint --channel rundown -`, then say the same in chat.
6. **Clean up.** Remove each `night-*` watch per `sentinel` (Verb: `stop`). A red the report names gets a board row or queue item through its owner (`fix-red`, the session on it), never a fix from here.

## Do NOT

- Change anything the fleet runs: no edits, pushes, merges, reruns, restarts, kills, queue moves or board edits. The night shift observes and reports. Why: the human asked for a shift that cannot hurt anything while they sleep, and the sessions and runners that own the work already act.
- Start a `/loop`, cron, `sleep` or tmux session to check in. Sentinel's loop is the only cadence. Why: a session loop re-reads its whole context every tick and dies with the session.
- Arm a night watch with no `expiry`, or one that duplicates a standing watch.
- Raise a night watch above `normal` unless the human asked to be woken for it.
