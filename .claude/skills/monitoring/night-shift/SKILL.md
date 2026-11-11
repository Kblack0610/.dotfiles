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

One file per night, and it is also the morning's inbox report: `$(notes path refs)/<M>/night-shift.md`, where `<M>` is the morning the human reads it, `M=$(date -d "$( [ "$(date +%H)" -lt 6 ] && echo today || echo tomorrow)" +%F)`. That day's `notes today` links it into the daily note's Refs. `start` writes line 1 `# Night shift, <M>`, line 3 `Morning report pending.`, then `## Bedtime`; `morning` replaces the pending line with the summary and appends `## Morning`. A file that already has `## Morning` is finished: a second `morning` (by hand, then queued) says so and stops. A second `start` on the same night adds focus to the existing file, keeps its start time and does not queue a second morning. Night watches are named `night-<slug>` and carry `source: night-shift`, which is how `status` and `morning` find them.

## Verb: `start [focus...]`

1. **Baseline.** Run these and write the counts and names under `## Bedtime` with the start time (`date -Iseconds`):
   - `watch-companion-loop list | awk '$1=="TRIP"{print $2}'`: every watch already red, at any severity (`tripped` lists only high and urgent). They are not news in the morning unless they change.
   - `agentctl status sentinel` must read `active (running)`. If it does not, tell the human now, before they sleep. The shift has nothing to run on.
   - `agent-queue list | awk '{print $1}' | sort | uniq -c`: items per state (column 1 is the state, column 4 the project).
   - For each focus repo, `gh pr list -R <owner/repo> --json number,title,labels` for the PRs in flight.
2. **Arm the focus.** For each thing the human named:
   - Check first: `grep -il '<repo or subject>' ~/.agent/watches/*.yaml | grep -v '/night-'`, then read the `what:` of each hit. Only a watch whose `what:` asks the same question covers the focus; one that only names the repo does not. When one does, list it under the focus and write nothing. Two watches on one question page twice.
   - Otherwise write `~/.agent/watches/night-<slug>.yaml` per `sentinel` (Verb: `watch`). Prefer a `command` probe when the question has an exit code. Use `probe: agent` when the question is whether something is flowing: `interval: 90m`, `agent_max_turns: 8`, and one read-only `signal:` per fact the check needs (gh, git, log tails). That gives about six check-ins a night, each a short Sonnet pass on the observe lane.
   - A probe or signal asks the code the system decides with: call a read-only function or subcommand of the script the system decides with, from main (fetched by `gh api -H "Accept: application/vnd.github.raw"`, as `playground-main-checks` runs `release-ready.py checks`). Read the function first and use it only when it makes GET calls and writes nothing. With no such code, read the state directly and say in `what:` which proxy it uses. Why: a label or status re-derived by hand can disagree with the code that decides, so the watch trips on a healthy system.
   - Every night watch gets `severity: normal`, so nothing buzzes the phone overnight; the human reads it in the morning. Set `high` only when the human said to wake them for it.
   - Set `expiry:` to `<M>T12:00` local, after the morning run, which removes it. Expiry is only the fallback for a morning that never runs.
   - Also required: `what`, `why`, `where`, `action` (`--strict` refuses a manifest without them), `created: $(date -Iseconds)` (expiry and the age column count from it), `source: night-shift`, and `subject`, `trip`, `next` for a readable page.
   - Validate with `sentinel-manifest validate --strict <file>`, then `watch-companion-loop list night-<slug>`. An agent watch runs its first check-in within a minute, so read its first verdict before the human sleeps: `awk '$2=="night-<slug>"' ~/.local/state/agentctl/sentinel/activity.log | tail -1`.
3. **Queue the morning**, unless `agent-queue list | grep night-shift-morning-<M>` shows it already: `agent-queue add --project dotfiles --priority high --weight light --tags "at:<M>T08:30" --slug night-shift-morning-<M> "check(night-shift): run /night-shift morning (observe-only: write the report, change nothing else)"`. `at:` is a not-before hold, so the run can start late; the 12:00 expiry leaves it room. Why: the report is waiting when the human wakes, with nothing for them to remember.
4. **Tell the human** in three lines: what is armed and how often it checks, which standing watches cover the rest, and that only high and urgent standing watches can page them overnight.

## Verb: `status`

`watch-companion-loop list | grep -E 'night-|TRIP'` and `grep -E 'night-' ~/.local/state/agentctl/sentinel/activity.log | tail -n 20`. Answer in one plain line, then the list.

## Verb: `morning`

Open the newest record, `ls -t $(notes path refs)/*/night-shift.md | head -1`, and read the start time `S` from its `## Bedtime`. With no file there was no shift; with `## Morning` already in it the report is done. Either way say so and stop. When the night watches are already gone (expired), say in the report that it ran late and has no live state. Then:

Log lines read `[<ts>] <watch> <prev> -> <new> <detail>`, so awk on fields works where grep flavours differ (here `grep` is ugrep). For an agent watch the state is OK for a verdict starting HEALTHY and TRIP for anything else, and the detail after the dash is the verdict text.

1. **Check-ins.** `awk -v s="[$S" '$0 >= s && $2 ~ /^night-/' ~/.local/state/agentctl/sentinel/activity.log`: every verdict each night watch gave, in order, including the `TRIP -> TRIP` passes step 2 drops. Report each focus as its runs of state with times ("SUSPECT 21:42 to 00:45, then HEALTHY") and quote the last non-HEALTHY verdict.
2. **What changed.** `awk -v s="[$S" '$0 >= s && $4 == "->" && $3 != $5 && $6 != "pending"'` on the same log: every watch that tripped, errored or recovered overnight. Compare `watch-companion-loop tripped` now with the bedtime list: new, cleared, still red.
3. **Pages.** `agent-notify list` since `S`: what reached the phone and what was held. A low `watch expired and was removed` page for a night watch is expected and needs no line in the report.
4. **Merges.** For each focus repo, `gh pr list -R <owner/repo> --state merged --limit 100 --search "merged:>=$(date -u -d "$S" +%Y-%m-%dT%H:%M:%SZ)" --json number,title,mergedAt` (UTC, since search reads the offset form unreliably). For the whole fleet's day, `day-log` is the owner.
5. **Write it** in the record: replace `Morning report pending.` with three to five lines (did the night go as intended, what went wrong and where, what waits on the human), then append `## Morning` with Focus (one line per focus: outcome, PR numbers, times), New reds, Cleared, Needs you. Run `python3 ~/.claude/skills/de-ai-writing/scripts/check.py <record>`. If `<M>` is today, `notes link-refs`. Then page once per `inbox-report` step 5 (normal, so it does not buzz), and say the same in chat when a human is there.
6. **Clean up.** Remove each `night-*` watch still present per `sentinel` (Verb: `stop`); one that already expired is gone, and its log lines are still the record. A red the report names gets a board row or queue item through its owner (`fix-red`, the session on it), never a fix from here.

## Do NOT

- Change anything the fleet runs: no edits, pushes, merges, reruns, restarts, kills, queue moves or board edits. The shift writes only its record, its `night-*` watches and its one morning queue item. Why: the human asked for a shift that cannot hurt anything while they sleep, and the sessions and runners that own the work already act.
- Start a `/loop`, cron, `sleep` or tmux session to check in. Sentinel's loop is the only cadence. Why: a session loop re-reads its whole context every tick and dies with the session.
- Arm a night watch with no `expiry`, or one that duplicates a standing watch.
- Raise a night watch above `normal` unless the human asked to be woken for it.
