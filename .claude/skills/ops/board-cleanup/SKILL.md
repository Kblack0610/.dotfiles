---
name: board-cleanup
description: >-
  A full agent-board cleanup pass: baseline, standard fixes, dedup and drop, rewrite, rank, link, size, re-measure, report. Use for "audit the board", "clean up the board", "the board is full", "remove the fluff". One pile of wants: process-requests; what dispatch picks: fleet-dispatch.
metadata:
  category: ops
  tags: [board, backlog, triage, dedup, notes, fleet]
  reviewed: "2026-11-13"
---

# Board cleanup

One pass that leaves the agent boards smaller and every open row at the row standard. It runs the cleanup tools that already exist, in order, over every board, then counts the same numbers again, so the next pass starts from a counted line. It writes no rows of its own: every edit is the `notes` CLI's, recorded in `~/.notes` git, so any one of them can be reverted.

The row standard is the notes-cli README, "The task row": `type(area): title` under 80 chars, one priority, `#size/` from `#pts/`, an epic (`#of/`), detail on indented lines. `notes doctor --projects` checks it. The board-size KPI is `board_open` in `fleet-bench room` against `board_open_max` (`~/.config/agentctl/kpi-thresholds`), alerted by the board-open watch.

## Scope and triggers

- The human says the board is full, asks for a board audit or cleanup, or the board-open watch fires.
- `notes doctor --projects` reports a board over its size budget or duplicate rows.

Not for a raw pile of new wants (`process-requests`), which rows dispatch runs next (`fleet-dispatch`), or the queue's depth and load (`fleet-pace`).

## Steps

1. **In flight first.** `agent-queue list --state running` and `gh pr list` on both dotfiles repos: another session may already be cleaning a board. Note the `~/.notes` HEAD (`git -C ~/.notes rev-parse HEAD`) so step 5 can diff everything the pass wrote.
2. **Baseline.** Save these to the scratchpad:
   - `fleet-bench room` (board_open against its max);
   - `notes doctor --projects` (findings by kind and project);
   - from `notes board --json`, per project, the open agent rows: total, `doing`, with no detail line, with no `#pts/`, untriaged, with no `#of/`, and older than 14 and 30 days (`.since`);
   - `agent-queue list --json --state active` by state. A `doing` row with a live queue item is in the queue, not stale; count those without one separately.
3. **Standard fixes the doctor names.** Duplicate rows it prints get `notes ptask <p> --agent drop --dup <id> -- "<raw>"` against the older one. `notes doctor --projects --untyped` proposes a typed row for each untyped one; apply the right ones with `ptask <p> --agent edit --was --text "<row>" -- "<old raw>"`.
4. **The backlog pass, board by board, biggest first:** `agentctl-inbox-triage --backlog --project <p>`. It rewrites rows to the standard (long titles move to detail lines), drops dups and rows that say they are done or are not tasks, and moves a row to the project it is about. It makes one Opus call per 40 rows on the inbox-backlog agent's own day budget (`~/.config/agentctl/agents/inbox-backlog.conf`), so it never spends the intake sweep's; a run that stops at that budget picks up the rest the next day, from the board it stopped on. Then, as needed: `--backlog --priority` (untriaged rows), `--backlog --link` (rows with no epic), `--backlog --size` (rows with no points).
5. **Review what it wrote.** `git -C ~/.notes diff <step-1 HEAD> -- '*/agent/README.md'` and read every drop and dup. A wrong one is reopened with `notes ptask <p> --agent reopen <id>`, or edited back; say how many in the report.
6. **Shipped rows.** `agent-land` closes the row its PR names, so a row a PR named is already closed (2026-11-13: 1 of 678 PR-named ids was still open, and it was a false match). A row delivered by a PR that never named it is found only by reading: for the oldest rows of each board, compare against `gh pr list --state merged --search "<key words>"`, and close one only when the PR delivers the whole row, `notes ptask <p> --agent done <id> --proof pr:<N>`.
7. **Quick wins.** Do not queue them by hand. Dispatch pulls eligible rows on its own (`fleet-dispatch`); `agent-queue add` holds automated adds while the queue is a day of drain deep. A clean, typed, sized row with a detail line saying what done looks like is what makes a row eligible, so steps 3 to 5 are how the quick wins get picked.
8. **Re-measure and report.** Run step 2 again. Report the before and after numbers per project, what was dropped, merged, rewritten and moved (counts and a few examples), the wrong drops undone, and what is left: rows older than 30 days, rows with no detail. Old age alone never drops a row; list the oldest for the human instead.
9. **Queue the next pass** a week out, before landing: `agent-queue add --project agent-runtime --slug board-cleanup-<YYMMDD> --tags at:<YYYY-MM-DDTHH:MM, 7 days on> "board-cleanup pass; baseline <this report>"`, and one for the boards a budget stop left, the next day.

## Do NOT

- Hand-edit a board file: every write goes through `notes ptask`, so the ingest record and git history stay true.
- Drop a row for being old or unclear. The human decides stale; the pass lists it.
- Close a `doing` row or a row with child rows: the first is a live queue item, the second a heading.
- Queue quick wins by hand while `fleet-bench room` reads full.
