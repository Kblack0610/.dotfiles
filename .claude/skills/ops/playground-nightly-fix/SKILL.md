---
name: playground-nightly-fix
description: >-
  Take a red playground nightly, Tests (all), to green the same day: one owner, one row and one fix item per cause, each fix proved by an on-demand night run. No wait for tonight. Use for "fix the nightly", "get main green", "nightly is red again". Explaining reds: ci-failures.
metadata:
  category: ops
  tags: [unity, ci, nightly, playground, queue]
  reviewed: 2026-11-12
---

# Playground nightly fix

The loop that takes unity-core-playground's red nightly to green and proves it, the same day. Nothing in it waits for a scheduled night: the `playground-nightly` route starts this skill the hour the watch trips, every fix item starts at once, and each proves its own fix with an on-demand `agentctl-playground-night` once it merges. The night is `Tests (all)` alone (`NIGHT_RUNS` in `scripts/release-ready.py`); Multi, HD, Soak and Slim tour are parked (`EXTENDED_RUNS`) and run only from their re-admission PR (the repo's `docs/operations/nightly.md#re-admission`), so a red there is never this skill's. The rules (stop-the-line, one gate per fix, quarantine with an expiry) live in the repo's `docs/operations/ci.md` (Rules, rule 10); this file is the procedure and restates none of them. Reading one run: `playground-headless-test`. Why reds recur across many runs: `ci-failures`.

## Scope and triggers

- When `Tests (all)` (`test.yml`) on main is red, the `playground-nightly` watch trips, or Home's NEEDS YOU shows a Nightly row.
- When a validation item from an earlier pass fires.

Not for one PR's gate red (`fix-ci`) or for CI time (`ci-cost`).

## Steps

1. **Own it, once.** Grep the agent board for an open "fix(nightly)" row and the queue for a `nightly-` item (`agent-queue list --state active | grep nightly-`). If a live session owns them, hand it your findings and stop. Otherwise take the row: `notes ptask unity-core-playground --agent start <id>` and `agent-queue add --running --priority urgent --from board:unity-core-playground:<id> --slug nightly-green-<id> "<task>"`.
2. **Read every red back to the last green**: `scripts/release-ready.py night` names the newest full run, scheduled or on demand; then `gh run list -w test.yml -L 7`. The playmode-report job summary or `gh run download <id> -n playmode-summary` lists the reds. For each failed job, note the runner name: infra reds group by host (`aws-burst-1-*`, a light runner's clone error) across runs.
3. **Drop what main already fixed.** `git fetch` and `git log origin/main --since=<nightly time> -- <test file>`; a likely fix gets a gate-only check item.
4. **Name the merge its gate did not pick.** For a class that was green the night before and is not flaky, walk `git log <last green>..<first red> --first-parent` to the merge that broke it, then run `scripts/test/affected-classes.py <merge>^1 <merge> --why` and `--kind=editmode` if it is an EditMode fixture. If the class is not in the output the gate never ran it (a `nightly:` line in the `--why` output means the cap left it out): file a `fix(picker)` row naming the merge and the class, with a test in `scripts/test/tests/` (ci.md rule 1, teach the picker, never widen the gate). If it is picked, the gate passed it, so the cause is flake or order: say so on the cause's row. Worked example: #1891 and `YardGamesPlayTests`. Skip a red that fails on every night or on infra.
5. **One row per cause.** Group by cause (content, code, multiplayer, host). Before `notes ptask ... --agent add`, grep the board for the class or the host name and fold into the open row. Each row names its runs and says "under <owner row>".
6. **One queue item per cause.** `agent-queue add --project unity-core-playground --priority urgent|high --from board:unity-core-playground:<row> --slug nightly-fix-<cause>-<row>` with a brief that carries: the classes and run ids, the main commits since the nightly, "root cause before fix" for a cause a fix already missed (dispatch `root-cause-analyst`), the negative control (gate the class on `origin/main` first), quarantine with an expiry when it cannot be fixed today, which human decisions to ask via `agent-ask` (secrets, hosts), "close your row, never the owner row", and the proof: once the fix merges, run `agentctl-playground-night` as a background command and take its exit as the signal, never a poll (a second start while a night runs follows it or exits 75 busy). The item closes only when that run's own verdict lines (the `OK`/`RED` lines it prints, on the commit its `night: main at <sha>` line names, which must contain the fix) read OK; a red there is the same item's next attempt. Never `--after` a validation or tag a fix `nightly:` or `at:`: a fix held for tonight is the wait this skill exists to remove. Let fleet-dispatch start them; start one by hand (`fleet-dispatch start --item <slug>`) only when `fleet-dispatch headroom` has room.
7. **Turn off what is not fixed today.** A case red in the batch is a red even when its solo rerun passes (testing.md, Quarantine). By 18:00 PST every case red in a real run since the last green, batch or solo, has a fix merged on main or a `scripts/test/quarantine.txt` line (expiry at most two weeks, the fix row in the reason; testing.md, Quarantine), in one PR; replay each of those runs' `results.xml` (`gh run download <id> -p 'test-runs-*'`) through `scripts/test/results.py <xml> --known <branch quarantine.txt> --allow-skips`: every case it still lists as Failed has its fix merged. Then run the night on demand: `agentctl-playground-night` in the background (Tests (all) on main, waited on, its verdict in `agentctl status playground-night` and the `playground-nightly` watch, rechecked when it ends), and give each new red, batch or solo, the same treatment before the scheduled run. A fix in review is not a fix: quarantine it and take the line off in the fix PR.
8. **Prove the whole night.** When every fix item has closed, run `agentctl-playground-night` yourself in the background, the same day, on a commit that holds every fix. Its verdict is the validation: all OK clears the `playground-nightly` watch at its next probe; any RED goes back to step 2 at once. Then queue the close, the one thing that waits for tonight: `agent-queue add --project unity-core-playground --priority high --from board:unity-core-playground:<owner row> --tags nightly:unity-core-playground --slug nightly-close-<id> "read tonight's night verdict and run step 9 of playground-nightly-fix"`. It holds the close, never a fix.
9. **Close.** Two night verdicts in a row with no red (the step 8 run and the next one: tonight's scheduled night, read by the close item, or a second on-demand run if it finishes first), batch or solo, each from a scheduled night or a `playground-night` run on main (or every remaining red quarantined with an expiry and a row): `notes ptask ... --agent done <owner row> --proof run:<tests id>,run:<second tests id>`, `agent-queue move nightly-green-<id> done`. A merge alone is never the proof.

## Gotchas

- A class reading `ok` in one night is not closed: two nights, and an `UNCONFIRMED` line is not a pass. An `ok` line in a shard's `summary.txt` that ends `(only the cases it failed in its batch; the rest passed there)` is a batch red: count it.
- A runner red repeats per run id on the board; grep the host name before filing.
- `fleet-dispatch` never gives a `ci:`-prefixed row a merging session, so name test and content fixes `fix(test)`/`fix(content)`.
- A missing, late or cancelled run is a red to triage: `release-ready.py night` reports it as RED with the reason, so judge by its lines.
- A bare `agent-land <N>` closes the session's own item and its board row. The owner session lands each of its PRs on an item of its own (`agent-queue add --running ...`, then `agent-land <N> --item <slug>`), so the owner row stays open until step 9.
