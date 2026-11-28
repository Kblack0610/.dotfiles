---
name: fix-ci
description: >-
  Fix a red CI run at its root cause: one PR's checks, or a suite on main (the nightly). Two attempts, then file it and stop. Use for "fix CI on this PR", "the checks are red", "fix the nightly", "main is red", `/fix-ci <pr>`. Reds across runs: ci-cleanup.
argument-hint: "[pr | owner/repo#N]"
allowed-tools: [Bash, Read, Write, Edit, Glob, Grep, Task]
metadata:
  category: ops
  tags: [ci, github, pr]
  system: [ci]
  reviewed: "2026-11-24"
---

# fix-ci

Fix a red CI run: the failing checks on the current branch's PR, or a suite red on main. If the repo has a CI doc (`docs/operations/ci.md` or what its CLAUDE.md names), it wins over this file.

## Scope and triggers

- One PR's red checks: `/fix-ci <pr>`, or the current branch's PR with no argument. fleet-dispatch starts a session on it for a parked PR that went red.
- A suite red on main (unity-core-playground's `Tests (all)` nightly): the `playground-nightly` route starts this skill the hour the watch trips, or "fix the nightly", "main is red", a Nightly row on Home. Steps 2 to 6 apply to each cause; "A red on main" below adds the owner and rows.

Not for reds that recur across many runs or a whole CI cleanup pass - that is `ci-cleanup`.

## Steps

1. Find the PR: the argument when given (`owner/repo#N` means `-R owner/repo` on every `gh` call below), else the current branch's (`gh pr view --json number,headRefOid`). Then its red checks (`gh pr checks <pr>`).
2. Read the failure: `gh run view <run> --log-failed`. Diff it against the last green run of the same workflow on the base branch (`gh run list --workflow <wf> --branch <base> --status success -L 1`); a line both logs share is not the cause.
3. Check the base: if the same check is red on a clean `origin/<base>`, it still blocks this PR. Fix it, revert its cause, or quarantine it the way the repo's CI doc says, through its own PR. If that is beyond this session, file a board row naming the check and the base run, and stop. Never excuse it on this PR. A queue item that fixes a red base claims each PR the red holds by adding it to its own `pr:` (`agent-queue set <slug> pr="<its refs> <owner>/<repo>#<N>"`): fleet-sessions then reads that PR's session as WORKING, waiting on the item, and the shepherd sends it no CI red nudge. A claim makes the PR the item's to land: it lands its own fix with `agent-land <fix> --item <slug> --partial`, then each claimed PR with `agent-land <N> --item <slug>` (`--partial` on all but the last), which records each merge and closes the item. Claim only a PR whose red is the base's alone.
4. Reproduce locally with the repo's own scripts (read `package.json`, `Makefile`, `scripts/`), fix the root cause, and rerun only what the change can affect.
5. Push, then wait on the event: `gh pr checks <pr> --watch --fail-fast` in the background. Never a sleep loop.
6. Two fix attempts at most. Still red: file a board row with the run URL and what you tried, and stop.

## A red on main

The repo's runbook owns the steps only it has: reading the run, naming the merge whose gate missed it, quarantine and the close (unity-core-playground: `docs/operations/nightly-red.md`). This skill owns the loop around them.

1. **Own it, once.** Grep the board for an open "fix(nightly)" row and the queue for a `nightly-` item (`agent-queue list --state active | grep nightly-`). A live owner gets your findings and you stop. Else take the row (`notes ptask <project> --agent start <id>`) and `agent-queue add --running --priority urgent --from board:<project>:<id> --slug nightly-green-<id> "<task>"`.
2. **One row per cause** (content, code, multiplayer, host; row naming and `#urgent` per the runbook, never `#urgent` on the owner row): grep the board for the class or host and fold into the open row. One fix item per cause, pulled from its row by dispatch (`nightly-fix-<id>`; never a board-origin `agent-queue add` of it, which writes no item).
3. **Prove each fix on its affected tests**, as the runbook says. The full proof is the next scheduled run on main: start no full run by hand (`Tests (all)`, `agentctl-playground-night`). On main, the runbook's quarantine deadline replaces step 6's "file and stop": a cause not fixed by it is quarantined with an owner and an expiry.
4. **Close the owner row** on the close item the owner files held for the next nightly (the runbook's last step), never on a merge: `notes ptask <project> --agent done <owner row> --proof run:<id>`, then `agent-queue move nightly-green-<id> done`. A bare `agent-land <N>` closes only its own item, so the owner session lands each PR on an item of its own.

## Do NOT, to get green

- Rerun a test failure. A rerun is only for an infra fault the log names (runner lost, registry 5xx, rate limit), once per PR tip. A red of jobs cancelled at their timeout and nothing else is one. When the item's `rerun_tries:` names this head, dispatch already reran it (`own_parked_pr`), so a second cut is the code's, a hang; otherwise rerun it once yourself.
- Raise a timeout, add a retry, add a skip, or silence logged errors.
- Treat a red check as optional.

A test that is truly flaky goes into the repo's quarantine (owner plus expiry) per its CI doc, or gets fixed. Nothing else.
