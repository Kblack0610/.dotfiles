---
name: ci-failures
description: >-
  Explain why CI is red across many runs: failure mix, recurring signatures, reds on main, infra vs test, one owner per cause. Use for "why is CI always red", "what keeps failing", "is this flaky", "why did the nightly fail". One PR's reds: /my:fix-ci; CI time: ci-cost.
metadata:
  category: ops
  tags: [ci, github-actions, failures, flaky, triage]
  reviewed: "2026-11-03"
---

# CI failures

Turns "CI keeps going red" into a counted list: every red run in a window, the cause it belongs to, which causes recur, which are on the base branch (so every branch inherits them), and one owner for each. It explains and routes; it fixes nothing.

The repo's CI doc owns what a red means, quarantine, and stop-the-line (`docs/operations/ci.md` in unity-core-playground, or what the repo's CLAUDE.md names). This file is only the procedure and restates none of those rules. When they disagree, the doc wins and this file gets fixed in the same turn.

## When to Use

- When the user asks why CI is red so often, what keeps failing, or whether something is flaky.
- When a nightly or main is red and the cause is not obvious from one log.
- Before choosing which red to fix first, or when a red has no owner.
- After a fix lands, to show its signature stopped.

Not for one PR's red checks - that is `/my:fix-ci`. Not for CI time or runner-hours - that is `ci-cost`. Running or gating playground tests is `playground-headless-test`. A whole cleanup pass (baseline, bandaids, causes, report) is `ci-cleanup`.

## Steps

1. **Scope the window.** Repo, workflows, base branch, days. Default: every workflow, 3 days, base `main`. Say the window in the answer.
2. **Count with the script, never by hand:**
   `~/.claude/skills/ci-failures/ci-failures.py --repo OWNER/NAME [--workflow test.yml]... --days 3`
   It prints red rate per workflow, red runs per bucket, a "where" table (workflow / job / failed step), and the signature table; `--json` has every record. The first pass fetches about three API calls per failed job (the account shares 5,000 an hour across sessions); after that, pass `--until <the first pass's end>` with `--offline` and reuse the cache. It exits 3 and says PARTIAL when gh failed partway: report that, do not present low counts as the answer.
3. **Read the buckets.** `infra` (runner lost or killed, disk, network, rate limit, host key), `timeout`, `test`, `check` (lint, docs, build, a PR-body check), `derived` (failed only because an earlier job did, never counted), `pending` (a check red by design until another run finishes, such as the playground's gate line on a PR pushed before its gate; listed, and a run red only on those is not red). The script decides by fixed patterns at the top of `ci-failures.py`; when a bucket is wrong, fix the pattern there (with a fixture in `tests/fixtures/ci-failures/`), not the count in your answer. Write down the suspects you ruled out.
4. **Base-branch reds come first.** A signature with `main: yes` is red on the base too, so it fails every branch. Find the first bad commit: `gh run list -R <repo> --workflow <wf> --branch main --json headSha,conclusion,createdAt` gives the last green and first red, and `git log <green>..<red>` the PRs between them. The repo's stop-the-line rule says what happens next.
5. **Flaky needs evidence.** `green@sha: yes` means the same job also went green on the same commit. That is a lead, not a verdict: rule out a changed PR body, variable, secret, test pick (a dispatch input) or moving base between the two runs before calling it flaky. Never rerun a job to find out. Quarantine only by the repo CI doc's rule.
6. **One owner per cause.** For each signature that recurs or sits on main, find its owner: an open PR, a board row (grep the board first), or a session already on it. No owner: file one row, `notes ptask <project> --agent add "ci red: <signature>, <runs> runs, sample <url>" '#tier/3'`.
7. **Report in this shape:**
   1. The answer in one or two sentences: the red rate and the one or two causes that drive it.
   2. The bucket table and the top of the "where" table, as printed.
   3. The top signatures that recur or sit on main, each with its owner (PR, row, session) or the row just filed.
   4. What was ruled out, and what the window cannot show (runs still going, PARTIAL, a workflow not read).
   5. For a trend, the same command for the previous window (`--until <start of this one>`), counted the same way.

## Do NOT

- Do not rerun a job to diagnose it; the log and the same-commit history already say what a rerun would.
- Do not call a test flaky from one red, or from `green@sha` alone (step 5).
- Do not quote a rate or count you did not get from the script in this session.
- Do not fix here. Fixing is `/my:fix-ci` on one PR, or the owner's PR.
- Do not restate a repo CI rule in a row, a PR or this file; link the doc.
