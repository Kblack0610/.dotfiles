---
name: fix-ci
description: >-
  Fix the red checks on one PR at their root cause: two attempts, then file it and stop. Use for "fix CI on this PR", "the checks are red", `/fix-ci <pr>`. Why CI keeps failing across runs: ci-failures.
argument-hint: "[pr | owner/repo#N]"
allowed-tools: [Bash, Read, Write, Edit, Glob, Grep, Task]
metadata:
  category: ops
  tags: [ci, github, pr]
  reviewed: "2026-11-12"
---

# fix-ci

Fix the failing checks on the current branch's PR. If the repo has a CI doc (`docs/operations/ci.md` or what its CLAUDE.md names), it wins over this file.

## Scope and triggers

- One PR's red checks: `/fix-ci <pr>`, or the current branch's PR with no argument. fleet-dispatch starts a session on it for a parked PR that went red.

Not for reds that recur across many runs - that is `ci-failures`. Not for a whole CI cleanup pass - that is `ci-cleanup`.

## Steps

1. Find the PR: the argument when given (`owner/repo#N` means `-R owner/repo` on every `gh` call below), else the current branch's (`gh pr view --json number,headRefOid`). Then its red checks (`gh pr checks <pr>`).
2. Read the failure: `gh run view <run> --log-failed`. Diff it against the last green run of the same workflow on the base branch (`gh run list --workflow <wf> --branch <base> --status success -L 1`); a line both logs share is not the cause.
3. Check the base: if the same check is red on a clean `origin/<base>`, it still blocks this PR. Fix it, revert its cause, or quarantine it the way the repo's CI doc says, through its own PR. If that is beyond this session, file a board row naming the check and the base run, and stop. Never excuse it on this PR.
4. Reproduce locally with the repo's own scripts (read `package.json`, `Makefile`, `scripts/`), fix the root cause, and rerun only what the change can affect.
5. Push, then wait on the event: `gh pr checks <pr> --watch --fail-fast` in the background. Never a sleep loop.
6. Two fix attempts at most. Still red: file a board row with the run URL and what you tried, and stop.

## Do NOT, to get green

- Rerun a test failure. A rerun is only for an infra fault the log names (runner lost, registry 5xx, rate limit), once per PR tip.
- Raise a timeout, add a retry, add a skip, or silence logged errors.
- Treat a red check as optional.

A test that is truly flaky goes into the repo's quarantine (owner plus expiry) per its CI doc, or gets fixed. Nothing else.
