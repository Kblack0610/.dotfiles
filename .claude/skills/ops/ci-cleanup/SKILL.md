---
name: ci-cleanup
description: >-
  A whole CI cleanup pass: baseline, bandaid inventory, shared-state architecture review, fixes by cause, bandaids removed, re-measure, report. Use for "clean up CI", "raise the pass rate", "CI pass N of M", "fix causes, not bandaids". One red: ci-failures; CI time: ci-cost.
metadata:
  category: ops
  tags: [ci, flaky, quarantine, testing, unity, playground]
  system: [ci]
  reviewed: "2026-11-10"
---

# CI cleanup

One pass that leaves CI greener because causes were fixed, not hidden: every bandaid listed with its real cause, the shared state behind batch-only reds found, and each bandaid removed once its cause is gone. The pass itself (finding shape, in flight, baseline, one lever per PR, re-measure, report, proposals, next pass) is `~/.local/src/docs/analysis-streams.md`; read it first. This file holds what is specific to CI.

It composes three skills and restates none of them: `ci-failures` counts reds, `ci-cost` counts time, `playground-headless-test` runs and gates. The doctrine (gate, quarantine, reruns, timeouts, stop-the-line) is `~/.local/src/docs/ci.md`; the repo's CI doc owns its specifics (`docs/operations/ci.md` in unity-core-playground). When this file and either doc disagree, the doc wins and this file is fixed in the same turn.

## Scope and triggers

- The human asks to clean up CI, raise the pass rate, or run "CI cleanup pass N".
- Nightlies stay red for days and single-red triage has not moved them.
- Local or gate pass rate is low and nobody can say which part is the tests and which the harness.

Not for one PR's red (`fix-ci`), not for one recurring red (`ci-failures` then its owner), not for cutting minutes alone (`ci-cost`).

## Steps

1. **In flight first,** per the method, plus the plans of sessions on CI (grep `~/.claude/plans` for ci, quarantine, nightly).
2. **Baseline, from the scripts only.** `ci-failures` (3 days, all workflows) and `ci-cost` (`scripts/ci-cost.py --days 1` online, then its re-gate table) plus the local run ledger pass rate (`~/.local/state/unity-test-runs/runs.tsv`, and `test-failures.tsv` for the tests red on many unrelated branches). Record every number in the plan with its window. A cached `--offline` read must cover the window you quote. Pass 2 onward, re-read both windows per the method with `--until` and `--offline`. Check that the last pass's fixes have had a nightly: if none has run on them (a pass started hours after the last, or a nightly that died before its tests), the pass reads that nightly before its report, and says so when it cannot. Count batch-only reds with `batch-only.py --run <Tests run id>` (in this skill's folder), never by hand.
3. **Bandaid inventory.** Each with file:line, the real cause, and an action. Grep list for the playground: the batch-then-solo rerun in `scripts/test/suite.sh`; `scripts/test/quarantine.txt` (expiries this week; remove a pure duplicate line in this pass yourself); raised ceilings in `PlayTestSession.cs` and their commits (`git log -S`); widened tolerances (`git log --grep 'allow\|tolerance\|lag'`); wall-clock deadlines the fixed-delay guard misses (`realtimeSinceStartup +`); host exclusions (`linux-only-classes.txt`); job and script timeouts (guards, keep). A test bandaid that must stay becomes a quarantine by `ci.md` "Red handling"; a guard that stays (a timeout, a host exclusion) gets an owner, an expiry and a written why.
4. **Architecture: what one class leaves for the next.** Batch-only reds come from shared state. Check, with file:line: is the session reset between classes, or does `SwapTo` the current game no-op; does a class that stops the server leave later classes to time out; statics reset once per launch instead of per class; runtime writes to static catalogs and settings that TearDown does not restore exactly; one saves folder for the launch; fixed ports. Prove a leak with a two-class batch in leak order: red before, green after.
5. **Fix by cause, one area per branch, one gate each,** per `playground-headless-test` and the repo's ci.md. Fan independent areas out to background agents, each in its own `~/.worktrees/<repo>-<slug>`. Each brief carries the method's landing rule (fix PRs `--partial`, the report PR closes the item), says that a branch cut from `origin/main` tracks it, so push with `git push -u origin HEAD:<branch>`, and says to wait for the gate's own result before reporting, since a background agent can stop while its Unity run still works. A fix PR's gate red that is not the branch's (an unowned flake) becomes this pass's next fix on its own branch, per ci.md's stop-the-line rule: never a rerun. Read the failure text before calling anything load; compare hosts within the same run (the plan balances batches), not across runs, before blaming a host. Pool caps and slot counts go to home-config by PR with a before and after.
6. **Remove the bandaid** in the PR that fixes its cause, or the next one: lift the quarantine line, put the ceiling back, delete the rerun once `batch-only.py` reads zero batch-only reds on a nightly.
7. **Re-measure** with the same scripts and windows (`ci-cost.py --before <first landing>`, `ci-failures --days 1`, the ledger) and add the rows to `docs/operations/ci-cost.md`'s log. That log has word and date caps in `docs/budgets.txt`: keep one row per cleanup series and replace the last pass's row rather than adding one. Say what one day cannot show.
8. **Report** in `docs/operations/ci-cleanup.md` (current pass only) per the method, adding sections for CI cost, failure analysis, what ran, cleaned up (bandaid -> PR) and architecture findings; from pass 2 the table's columns are the original baseline, the last pass and this pass. Proposals per the method, evidence the Artifact page. On the last pass of a series, the report is also the series summary: cost and failure analysis per pass, every bandaid removed (with PR) and every one kept (owner, expiry, why), the architecture changes and whether shared components were the cause, whether the pass rate is acceptable against ci.md's rules, and what another pass would take on. The report's date cap is 0 (`check-docs.py`): name PRs and passes, never a date. Publish it as a new Artifact page per pass, titled `CI Cleanup Pass N`, and page per the method (`-t ci-cleanup`).
9. **Queue the next pass** per the method, unless this pass was the series' last: `--project <project>` (the project of this pass's item), slug `ci-cleanup-<project>-p<N+1>`, baseline `docs/operations/ci-cleanup.md`.

## Do NOT

- Do not break `~/.local/src/docs/ci.md` "Tiers" or "Red handling" to get a green.
- Do not fix in another session's area; message it.
