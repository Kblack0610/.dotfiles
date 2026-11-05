---
name: ci-cleanup
description: >-
  A whole CI cleanup pass: baseline, bandaid inventory, shared-state architecture review, fixes by cause, bandaids removed, re-measure, report. Use for "clean up CI", "raise the pass rate", "CI pass N of M", "fix causes, not bandaids". One red: ci-failures; CI time: ci-cost.
metadata:
  category: ops
  tags: [ci, flaky, quarantine, testing, unity, playground]
  reviewed: "2026-11-05"
---

# CI cleanup

One pass that leaves CI greener because causes were fixed, not hidden: a measured baseline, every bandaid listed with its real cause, the shared state behind batch-only reds, one fix per branch, each bandaid removed once its cause is gone, and the same numbers again at the end.

It composes three skills and restates none of them: `ci-failures` counts reds, `ci-cost` counts time, `playground-headless-test` runs and gates. The repo's CI doc owns the rules (`docs/operations/ci.md` in unity-core-playground: gate, quarantine, timeouts, stop-the-line). When this file and the doc disagree, the doc wins and this file is fixed in the same turn.

## When to Use

- The human asks to clean up CI, raise the pass rate, or run "CI cleanup pass N".
- Nightlies stay red for days and single-red triage has not moved them.
- Local or gate pass rate is low and nobody can say which part is the tests and which the harness.

Not for one PR's red (`/my:fix-ci`), not for one recurring red (`ci-failures` then its owner), not for cutting minutes alone (`ci-cost`).

## Steps

1. **In flight first.** `agent-queue list --state active`, `gh pr list`, the plans of sessions on CI (grep `~/.claude/plans` for ci, quarantine, nightly). Never edit a file on another session's open branch; send a finding in its area with `fleet-comms`.
2. **Baseline, from the scripts only.** `ci-failures` (3 days, all workflows) and `ci-cost` (`scripts/ci-cost.py --days 1` online, then its re-gate table) plus the local run ledger pass rate (`~/.local/state/unity-test-runs/runs.tsv`, and `test-failures.tsv` for the tests red on many unrelated branches). Record every number in the plan with its window. A cached `--offline` read must cover the window you quote. Pass 2 onward: the last pass's report is the baseline; re-read the original baseline's window and the last pass's window with today's scripts (`--until`, `--offline`), so a counting change (a new bucket) is not read as an improvement.
3. **Bandaid inventory.** Each with file:line, the real cause, and an action. Grep list for the playground: the batch-then-solo rerun in `scripts/test/suite.sh`; `scripts/test/quarantine.txt` (expiries this week; remove a pure duplicate line in this pass yourself); raised ceilings in `PlayTestSession.cs` and their commits (`git log -S`); widened tolerances (`git log --grep 'allow\|tolerance\|lag'`); wall-clock deadlines the fixed-delay guard misses (`realtimeSinceStartup +`); host exclusions (`linux-only-classes.txt`); job and script timeouts (guards, keep). A bandaid that must stay gets an owner, an expiry and a written why.
4. **Architecture: what one class leaves for the next.** Batch-only reds come from shared state. Check, with file:line: is the session reset between classes, or does `SwapTo` the current game no-op; does a class that stops the server leave later classes to time out; statics reset once per launch instead of per class; runtime writes to static catalogs and settings that TearDown does not restore exactly; one saves folder for the launch; fixed ports. Prove a leak with a two-class batch in leak order: red before, green after.
5. **Fix by cause, one area per branch, one gate each,** per `playground-headless-test` and the repo's ci.md. Fan independent areas out to background agents, each in its own `~/.worktrees/<repo>-<slug>`. Only the report PR lands with `agent-land`: the session's `$AGENT_QUEUE_ITEM` is inherited, so a fix PR merged with it closes the pass's item early. Fix PRs merge with `gh pr checks <N> --watch` then `gh pr merge <N> --squash --match-head-commit <sha>`, and agent briefs say so; a branch cut from `origin/main` tracks it, so push with `git push -u origin HEAD:<branch>`. A brief also says to wait for the gate's own result before reporting, since a background agent can stop while its Unity run still works. A fix PR's gate red that is not the branch's (an unowned flake) becomes this pass's next fix on its own branch, per ci.md's stop-the-line rule: never a rerun. Read the failure text before calling anything load; compare hosts within the same run (the plan balances batches), not across runs, before blaming a host. Pool caps and slot counts go to home-config by PR with a before and after.
6. **Remove the bandaid** in the PR that fixes its cause, or the next one: lift the quarantine line, put the ceiling back, delete the rerun once batch-only reds are zero.
7. **Re-measure** with the same scripts and windows (`ci-cost.py --before <first landing>`, `ci-failures --days 1`, the ledger) and add the rows to `docs/operations/ci-cost.md`'s log. That log has word and date caps in `docs/budgets.txt`: keep one row per cleanup series and replace the last pass's row rather than adding one. Say what one day cannot show.
8. **Report** in `docs/operations/ci-cleanup.md` (current pass only) with these sections: CI cost, failure analysis, what ran, cleaned up (bandaid -> PR), architecture findings, what looks good, a before/after table for every step-2 metric (from pass 2: one column each for the original baseline, the last pass and this pass), left for the next pass. The report's date cap is 0 (`check-docs.py`): name PRs and passes, never a date. Publish it as a new Artifact page per pass, titled `CI Cleanup Pass N`, and page the human with the link (`agent-notify -p normal -t ci-cleanup <link>`).

## Do NOT

- Do not widen the gate, rerun blind, or raise a timeout or ceiling to pass.
- Do not quote a number the scripts did not print this session.
- Do not fix in another session's area; message it.
- Do not quarantine without owner, expiry and the row the repo doc asks for.
- Do not restate ci.md, ci-failures, ci-cost or playground-headless-test here; link them.
