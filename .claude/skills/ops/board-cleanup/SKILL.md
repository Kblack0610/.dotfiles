---
name: board-cleanup
description: >-
  A full agent-board cleanup pass: baseline, standard fixes, dedup and drop, rewrite, rank, link, size, re-measure, report. Use for "audit the board", "clean up the board", "the board is full", "remove the fluff". One pile of wants: process-requests; what dispatch picks: fleet-dispatch.
metadata:
  category: ops
  tags: [board, backlog, triage, dedup, notes, fleet]
  reviewed: "2026-11-15"
---

# Board cleanup

One pass that leaves the agent boards smaller and every open row at the row standard. It runs the cleanup tools that already exist, in order, over every board. Its in-flight, baseline, re-measure, report and next-pass steps follow `~/.local/src/docs/analysis-streams.md`; read it first. It lands no PRs, so the rank, lever, PR and proposal rules there do not apply. It writes no rows of its own: every edit is the `notes` CLI's, recorded in `~/.notes` git, so any one of them can be reverted.

The row standard is the notes-cli README, "The task row": `type(area): title` under 80 chars, one priority, `#size/` from `#pts/`, an epic (`#of/`), detail on indented lines. `notes doctor --projects` checks it. The board-size KPI is `board_days` in `fleet-bench room`, the board's weight in days of what the profile ships, against `board_days_max` (`~/.config/agentctl/kpi-thresholds`), alerted by the board-open watch; the sweep keeps each project's unpinned rows to `agent_board_days` of its own shipped weight.

## Scope and triggers

- The human says the board is full, asks for a board audit or cleanup, or the board-open watch fires.
- `notes doctor --projects` reports a board over its size budget or duplicate rows.

Not for a raw pile of new wants (`process-requests`), which rows dispatch runs next (`fleet-dispatch`), or the queue's depth and load (`fleet-pace`).

## Steps

1. **In flight first,** per the method, on both dotfiles repos: another session may already be cleaning a board. Note the `~/.notes` HEAD (`git -C ~/.notes rev-parse HEAD`) so step 5 can diff everything the pass wrote.
2. **Baseline.** Save these to the scratchpad:
   - `fleet-bench room` (board_days against its max, with board_open and backlog rows);
   - `notes doctor --projects` (findings by kind and project);
   - from `notes board --json`, per project, the open agent rows: total, `doing`, with no detail line, with no `#pts/`, untriaged, with no `#of/`, and older than 14 and 30 days (`.since`);
   - `agent-queue list --json --state active` by state. A `doing` row with a live queue item is work in the queue; count the `doing` rows with none separately, as the stale ones.
   - `fleet-bench chain`: `urgent_per_board` and `stale_urgent_d`, with the lines under the table that name the boards and the oldest row; and the share of queued items that are high, `agent-queue list --json --state queued | jq -s 'map(select(.priority == "high")) | length'` over its `length`.
3. **Standard fixes the doctor names.** Duplicate rows it prints get `notes ptask <p> --agent drop --dup <id> -- "<raw>"` against the older one. `notes doctor --projects --untyped` proposes a typed row for each untyped one; apply the right ones with `ptask <p> --agent edit --was --text "<row>" -- "<old raw>"`.
4. **The backlog pass, board by board, biggest first:** `agentctl-inbox-triage --dry-run --backlog --project <p>`, then read its answers in `~/.local/state/agentctl/inbox-triage/backlog-<p>.jsonl` (every dup, drop and move; a wrong one is deleted from the file, or set to `keep` with its `project` cleared, since a `project` alone still moves the row), then the same command without `--dry-run`, which writes only those reviewed answers. It rewrites rows to the standard (the old title stays as a `was:` line), drops dups and rows that say they are done or are not tasks, and moves a row to the project it is about; a plan's finish row stays on its board and keeps its plan slug, since ask-sweep finds it by that slug there. It makes one Opus call per 40 rows on the inbox-backlog agent's own day budget (`~/.config/agentctl/agents/inbox-backlog.conf`), so it never spends the intake sweep's; a dry run stopped at that budget keeps the answers it got, and the next dry run asks only about the rest. Then, as needed: `--backlog --priority` (untriaged rows) and `--backlog --link` (rows with no epic), both on the inbox-priority agent's budget, and `--backlog --size` (rows with no points) on inbox-size's.
5. **Review what it wrote.** `git -C ~/.notes diff <step-1 HEAD> -- '*/agent/README.md'` and read every drop and dup. A wrong one is reopened with `notes ptask <p> --agent reopen <id>`, or edited back; say how many in the report.
6. **Rank.** Urgent says what starts first only while it is short: on each board `urgent_per_board` names past `urgent_per_board_max` (`~/.config/agentctl/kpi-thresholds`), and for each urgent row past `stale_urgent_d_max`, read the row against the rubric (`priority_rule` in `agentctl-inbox-triage`) and demote it (`notes ptask <p> --agent tag <id> --remove urgent --add high`), fold the copies of one cause into one row, close it with proof when it shipped, or keep it and say why in the report. A `#requested` urgent row is the human's: keep it, and list it for them. Then `agentctl-inbox-triage --backlog --priority --retag-high` re-judges every board's `#high` rows by the same rubric, on the inbox-priority budget; review its tags as in step 5.
7. **Shipped rows.** `agent-land` closes the row its PR names, so a row a PR named is already closed (2026-11-13: 1 of 678 PR-named ids was still open, and it was a false match). A row delivered by a PR that never named it is found only by reading: for the oldest rows of each board, compare against `gh pr list --state merged --search "<key words>"`, and close one only when the PR delivers the whole row, `notes ptask <p> --agent done <id> --proof pr:<N>`.
8. **Quick wins.** Do not queue them by hand. Dispatch pulls eligible rows on its own (`fleet-dispatch`); `agent-queue add` holds an add past its cap of runnable items, leaving its board row un-started. A clean, typed, sized row with a detail line saying what done looks like is what makes a row eligible, so steps 3 to 6 are how the quick wins get picked.
9. **Re-measure and report** per the method: step 2 again, the numbers per project, what was dropped, merged, rewritten and moved (counts and a few examples), the wrong drops undone, and what is left: rows older than 30 days, rows with no detail. Old age alone never drops a row; list the oldest for the human instead.
10. **Queue the next pass** a week out every pass: the board refills weekly whatever "left" says, so this overrides the method's "left names a lever" condition (`--project agent-runtime`, slug `board-cleanup-<YYMMDD>`, baseline this report), and one for the boards a budget stop left, the next day.

## Do NOT

- Hand-edit a board file: every write goes through `notes ptask`, so the ingest record and git history stay true.
- Drop a row for being old or unclear. The human decides stale; the pass lists it.
- Close a `doing` row or a row with child rows: the first is a live queue item, the second a heading.
- Queue quick wins by hand while `fleet-bench room` reads full.
