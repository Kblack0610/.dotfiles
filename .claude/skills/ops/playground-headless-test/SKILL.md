---
name: playground-headless-test
description: >-
  Run unity-core-playground tests safely: one class locally, gate a merge on the runner pool, read the nightly. Use for "run the tests", "gate this PR", "is this green", "why did the nightly fail". Not for a live editor.
metadata:
  category: ops
  tags: [unity, testing, ci, playground, headless]
  reviewed: 2026-11-02
---

# Playground headless test

Runs the playground's tests without hurting the workstation, which is the human's and is shared with every other session, and turns a run into a merge decision. Every CI rule lives in the repo's `docs/operations/ci.md` (Rules); this file restates none of them. When the two disagree, the doc wins and this file gets fixed in the same turn.

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
5. Gate with the command in `docs/operations/ci.md`, One change, start to finish, in the background, committed. Its Rules decide where it runs, what it picks, when to gate again after merging main, and what a FAIL or ONMAIN means; do not pick the place or the classes by hand.
6. Land: `gh pr checks <n> --watch`, branch current with main (`test "$(git rev-list --count HEAD..origin/main)" -eq 0`), then `gh pr merge <n> --squash --match-head-commit <sha> --subject "<title> (#n)"`.
7. At session start, read main's last nightly as `docs/operations/ci.md` rule 10 says.

## Do NOT

- Do not run the whole PlayMode suite or a player build on the workstation (`docs/operations/ci.md` rule 3).
- Do not call Unity `-runTests` by hand or use port 7770: a `-host` that cannot bind joins the human's game.
- Do not loop run.sh in zsh with unsplit args; wrap the loop in `bash -c`.
- Do not stop Unity with `pkill -f` or a `pgrep -f` waiter; they match your own shell. Filter `ps -eo pid,comm,args` on `$2=="Unity"`.
- Do not touch `External/unity-core` (checkout, merge, commit) while a run uses that tree.
- If Unity aborts with "Requested file descriptor exceeds maximum", run with `ulimit -n 65536`.
