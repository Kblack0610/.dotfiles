---
name: playground-headless-test
description: "Run unity-core-playground tests the safe way: iterate on one class locally with scripts/test/run.sh, gate a merge on the runner pool with the workstation taking it only when the pool is backed up, prove a new check with a negative control, and read the nightly. Use when the user says \"run the tests\", \"gate this PR\", \"is this green\", \"run <Class> headless\", \"why did the nightly fail\", or before merging any playground change to code, assets or game data. It is a thin driver over the repo's docs/development/testing.md and docs/operations/ci.md (Who gates what) plus the traps that have hung runs or loaded the workstation. Not for driving a live editor over MCP (CLAUDE.md, Driving the sandbox) and not for content work itself (playground-new-content, playground-ingest)."
metadata:
  category: ops
  tags: [unity, testing, ci, playground, headless]
  reviewed: 2026-10-30
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
5. Gate on the runner pool. Run EditMode and the PlayMode classes the branch can affect (`scripts/test/affected-classes.py`) with `scripts/test/suite.sh --retry --batch 12 --baseline main --classes <that list>` in your worktree, in the background, committed and with nothing uncommitted: suite.sh pushes the branch and becomes `ci-gate.sh`, or runs it on the workstation when the pool is backed up and a slot is free, so do not pick by hand. Jobs take Linux slots first and the Mac Studio is overflow; `ci-gate.sh --host=mac-studio` is a check that needs a Mac. The pick is at most about 40 classes plus a broad set (20 to 30 minutes); ALL comes only from a Unity version change or `--full`, and the nightly runs the rest. Once green, merge main and merge; do not gate again unless the merge touched files your pick depends on. Group phases that touch the same area into one gate (CLAUDE.md, Working alongside other agents). FAIL on your change blocks; ONMAIN is red on main too and goes on the agent board.
6. Land: `gh pr checks <n> --watch`, branch current with main (`test "$(git rev-list --count HEAD..origin/main)" -eq 0`), then `gh pr merge <n> --squash --match-head-commit <sha> --subject "<title> (#n)"`.
7. At session start, read main's last nightly FAIL / FLAKY / ONMAIN lines (`docs/operations/ci.md`); a non-FLAKY red on main comes before your own work.

## Do NOT

- Do not run the whole PlayMode suite locally; gate on the affected classes.
- Do not gate with an uncommitted tree: the pool tests what is pushed, so suite.sh --classes keeps that gate on the workstation. Commit first.
- Do not run a player build (`scripts/build.sh`, `PlaygroundBuild.Build*`) on the workstation: it compiles every shader on every core for an hour (2026-10-26, load 33 on 24, 0% idle). Ask the human first.
- Do not call Unity `-runTests` by hand or use port 7770: a `-host` that cannot bind joins the human's game.
- Do not loop run.sh in zsh with unsplit args; wrap the loop in `bash -c`.
- Do not stop Unity with `pkill -f` or a `pgrep -f` waiter; they match your own shell. Filter `ps -eo pid,comm,args` on `$2=="Unity"`.
- Do not touch `External/unity-core` (checkout, merge, commit) while a run uses that tree.
- If Unity aborts with "Requested file descriptor exceeds maximum", run with `ulimit -n 65536`.
