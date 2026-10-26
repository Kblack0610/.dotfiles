---
name: playground-headless-test
description: "Run unity-core-playground tests the safe way: iterate on one class locally with scripts/test/run.sh, gate a merge on the runner pool with scripts/test/ci-gate.sh, prove a new check with a negative control, and read the nightly. Use when the user says \"run the tests\", \"gate this PR\", \"is this green\", \"run <Class> headless\", \"why did the nightly fail\", or before merging any playground change to code, assets or game data. It is a thin driver over the repo's docs/development/testing.md and docs/operations/ci.md (Who gates what) plus the traps that have hung runs or loaded the workstation. Not for driving a live editor over MCP (CLAUDE.md, Driving the sandbox) and not for content work itself (playground-new-content, playground-ingest)."
metadata:
  category: ops
  tags: [unity, testing, ci, playground, headless]
  reviewed: "2026-10-26"
---

# Playground headless test

Runs the playground's tests without hurting the workstation, which is the human's and is shared with every other session, and turns a run into a merge decision. The repo docs are the source of truth; when this file and `docs/operations/ci.md` disagree, the doc wins and this file gets fixed in the same turn.

## When to Use

- When iterating on one test class while writing or fixing it.
- When gating a playground PR before `gh pr merge`.
- When a nightly run on main is red and you need to read it.

Not for MCP-driven play in an editor: CLAUDE.md "Driving the sandbox over MCP".

## Steps

1. Check holds first: `agent-hold list`. A `unity` hold means start no new Unity run until it clears; wait on it in the background, do not poll by hand.
2. Iterate locally on one class at a time:
   `scripts/test/run.sh --filter <Namespace.Class>` (add `--platform EditMode` for an EditMode class). A fresh worktree seeds `Library/` itself (`scripts/setup/library.sh`). Run it in the background and wait for the notification.
3. Read the counts. `0/0` or no `==> n/m` line means run.sh refused the arguments, not that tests passed. Failure detail is in `Logs/test-runs/<stamp>/results.xml`.
4. Prove a new check can fail: plant one fault per assertion (a bad asset, an entry removed from an allow list), run, see it red, revert, confirm `git status` is clean in the repo and in `External/asset-library`.
5. Gate on the pool, never locally: push the branch, then `scripts/test/ci-gate.sh`. It runs EditMode plus the PlayMode classes the branch can affect and prints a line for the PR body. FAIL on your change blocks; ONMAIN is red on main too and goes on the agent board.
6. Land: `gh pr checks <n> --watch`, branch current with main (`test "$(git rev-list --count HEAD..origin/main)" -eq 0`), then `gh pr merge <n> --squash --match-head-commit <sha> --subject "<title> (#n)"`.
7. At session start, read main's last nightly FAIL / FLAKY / ONMAIN lines (`docs/operations/ci.md`); a non-FLAKY red on main comes before your own work.

## Do NOT

- Do not run the whole PlayMode suite locally, and do not use run.sh as the merge gate.
- Do not call Unity `-runTests` by hand or use port 7770: a `-host` that cannot bind joins the human's game.
- Do not loop run.sh in zsh with unsplit args; wrap the loop in `bash -c`.
- Do not stop Unity with `pkill -f` or a `pgrep -f` waiter; they match your own shell. Filter `ps -eo pid,comm,args` on `$2=="Unity"`.
- Do not touch `External/unity-core` (checkout, merge, commit) while a run uses that tree.
- If Unity aborts with "Requested file descriptor exceeds maximum", run with `ulimit -n 65536`.
