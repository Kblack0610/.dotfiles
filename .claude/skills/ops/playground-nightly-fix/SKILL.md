---
name: playground-nightly-fix
description: >-
  Take a red playground nightly (Tests and Multi) to two clean nights: one owner, one row and one queue item per cause, then a queued validation that closes or re-triages. Use for "fix the nightly", "get main green", "nightly is red again". Explaining reds: ci-failures.
metadata:
  category: ops
  tags: [unity, ci, nightly, playground, queue]
  reviewed: 2026-11-05
---

# Playground nightly fix

The loop that takes unity-core-playground's red nightly to green and proves it. The rules (stop-the-line, one gate per fix, quarantine with an expiry) live in the repo's `docs/operations/ci.md` (Rules, rule 10); this file is the procedure and restates none of them. Reading one run: `playground-headless-test`. Why reds recur across many runs: `ci-failures`.

## When to Use

- When a scheduled `test.yml` or `multi.yml` run on main is red, or Home's NEEDS YOU shows a Nightly row.
- When a validation item from an earlier pass fires.

Not for one PR's gate red (`/my:fix-ci`) or for CI time (`ci-cost`).

## Steps

1. **Own it, once.** Grep the agent board for an open "fix(nightly)" row and the queue for a `nightly-` item (`agent-queue list --state active | grep nightly-`). If a live session owns them, hand it your findings and stop. Otherwise take the row: `notes ptask unity-core-playground --agent start <id>` and `agent-queue add --running --priority urgent --from board:unity-core-playground:<id> --slug nightly-green-<id> "<task>"`.
2. **Read every red back to the last green**, for both workflows: `gh run list -w test.yml --event schedule -L 7` and `-w multi.yml`. Tests: the playmode-report job summary or `gh run download <id> -n playmode-summary`; Multi: each job's summary (`summary.txt` in `multi-runs` and `two-process-runs`). For each failed job, note the runner name: infra reds group by host (`aws-burst-1-*`, a light runner's clone error) across runs.
3. **Drop what main already fixed.** `git fetch` and `git log origin/main --since=<nightly time> -- <test file>`; a likely fix gets a gate-only check item.
4. **One row per cause.** Group by cause (content, code, multiplayer, host). Before `notes ptask ... --agent add`, grep the board for the class or the host name and fold into the open row. Each row names its runs and says "under <owner row>".
5. **One queue item per cause.** `agent-queue add --project unity-core-playground --priority urgent|high --from board:unity-core-playground:<row> --slug nightly-fix-<cause>-<row>` with a brief that carries: the classes and run ids, the main commits since the nightly, "root cause before fix" for a cause a fix already missed (dispatch `root-cause-analyst`), the negative control (gate the class on `origin/main` first), quarantine with an expiry when it cannot be fixed today, which human decisions to ask via `agent-ask` (secrets, hosts), and "close your row, never the owner row". Let fleet-dispatch start them; start one by hand (`fleet-dispatch start --item <slug>`) only when `fleet-dispatch headroom` has room.
6. **Queue the validation.** `agent-queue add --project unity-core-playground --priority high --tags "at:<next day>T09:45" --slug nightly-validate-<date> "<brief>"`. Tests starts 02:00 and Multi 04:30 PST with a 5 h cap, so 09:45 is after both. The brief: read both scheduled runs; FAIL-free and every fix item closed: close the fix rows with `--proof run:<id>` and queue one more validation for the next night; any red: run this skill from step 2, then queue the next validation.
7. **Close.** Two scheduled nights in a row with no FAIL line in Tests or Multi (or every remaining red quarantined with an expiry and a row): `notes ptask ... --agent done <owner row> --proof run:<tests id>,run:<multi id>`, `agent-queue move nightly-green-<id> done`. A merge alone is never the proof; a hand-started full run does not clear the Sentinel watch, which reads scheduled runs only.

## Gotchas

- A class reading `ok` in one night is not closed: two nights, and an `UNCONFIRMED` line is not a pass.
- A runner red repeats per run id on the board; grep the host name before filing.
- `fleet-dispatch` never gives a `ci:`-prefixed row a merging session, so name test and content fixes `fix(test)`/`fix(content)`.
- No queue hold waits for a workflow run; the `at:` time is the hold, and the validation item must check the runs are finished before judging (a late or cancelled run is a red to triage).
