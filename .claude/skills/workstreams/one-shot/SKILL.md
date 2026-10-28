---
name: one-shot
description: Take one task from description to landed and wound down with no check-ins - work under autopilot rules, implement in a fresh worktree, run the project's own merge gate, open the PR, merge it, record it on the agent board with proof, pull the main checkout, then run wind-down. Use when the user says "one shot this", "/one-shot <task>", "do it all and land it", "just ship this end to end", or "do the whole thing, validate, PR and wind down". Pass --pr-only to stop after the PR is open. Stops only at the autopilot hard gates (destructive, release, money, secrets, external sends) or after two failed fix attempts on a red gate. Differs from /my:autopilot (decision posture only, no delivery steps), /kb:implement (opens a PR and stops, assumes PR CI), /captain (batches of tickets, not one task), and wind-down (only the session note and teardown). Not for releases, which stay with release-coordinator and the user.
metadata:
  category: workstreams
  tags: [delivery, landing, autonomy, session]
  reviewed: "2026-10-27"
---

# one-shot

Carries one task the whole way: work, validation, PR, merge, board record, wind-down, in a single run with no questions. It owns no procedure of its own. Each step points at the rule or skill that already owns it, so when that source changes this skill does not drift.

## When to Use

- The user hands over one well-scoped task and wants it landed without being asked anything.
- The user wants the session to close itself once the work is merged.

Not for a pile of tasks (`/captain`), a release (`release-coordinator`), or landing a tree that is already dirty (`ingest-worktree`).

## Steps

1. **Posture.** Follow `~/.claude/commands/my/autopilot.md` for the whole run: decide every reversible fork yourself, log each non-obvious one as `assumed: <X> because <Y>`, and stop only at its hard-stop boundary. Do not enter plan mode and wait. Write a short plan to `~/.claude/plans/<slug>.md`, however small the task, ending in a `## Phases` checklist (one `- [ ] <task>` line when the task is one step), and proceed. That file is how `fleet-sessions` and wind-down's step 0 tell a finished run from an unfinished one: with no plan file the row reads UNCLEAR, `finished` stays false, and the session can never close itself.

2. **Preflight.** Read the project CLAUDE.md, especially any "working alongside other agents" and merge-gate sections. Then:
   - `git fetch`, `gh pr list`, `git worktree list`. If another session already has this work in flight, build on it or stop and report. Do not start a second copy.
   - Cut a worktree off the remote tip per `~/.claude/CLAUDE.md` (`wt new`, or `git worktree add ~/.worktrees/<repo>-<slug> -b <branch> origin/<base>`). If the session already sits in a clean, current agent worktree, branch there instead.
   - `notes ptask <project> --agent add "<short title>"` then `start` it (one `start` only: a second one toggles it off).

3. **Implement.** Make the smallest change that fully solves the task, matching the surrounding code. Send broad exploration to Explore subagents. Update the docs the project CLAUDE.md says a change of this kind must touch.

4. **Validate.** Run the project's merge gate exactly as its CLAUDE.md defines it. Example, unity-core-playground: EditMode, plus each class from `scripts/test/affected-classes.py origin/main HEAD`, one `scripts/test/run.sh --filter <class>` per call, reading the counts (0/0 means the arguments were refused, not a pass). If the repo defines no gate, run its lint, typecheck and tests. A red result goes back to step 3. If it is still red after two fix attempts, or the red also fails on a clean `origin/<base>`, do not land: file it on the agent board and go to step 8 in blocked mode.

5. **PR.** Re-fetch. If the branch is behind, `git merge origin/<base>` (a pushed branch is never rebased, never force-pushed) and re-run the affected part of step 4. Stage by path, never `git add -A`. Push and `gh pr create` with: summary, the `assumed:` lines, and the classes/checks run with their counts. Follow the writing-style rules (ASCII, `de-ai-writing`). With `--pr-only`, skip to step 7.

6. **Land.** `~/.claude/CLAUDE.md` gives standing authorization; do not ask. Gate the merge on the branch being current and the head being the one validated:
   ```bash
   git fetch origin && test "$(git rev-list --count HEAD..origin/<base>)" -eq 0 && gh pr merge <N> --squash --match-head-commit "$(git rev-parse HEAD)"
   ```
   One landing step per call, absolute paths, no `;` or pipes after a push or merge. Then reap the worktree (`wt done`, or `git worktree remove`) and do the project's post-land step (unity-core-playground: pull the main checkout only when the editor is not playing, otherwise report "pull waiting").

7. **Record.** Tick the plan's phase (`- [x] <task> (#N)`). Close the agent-board row: `notes ptask <project> --agent done "<title>" --proof pr:<N>`. Then put the result on the human's sheet too, because a one-shot is always an ask the human wrote. If a sheet row already asked for this work, `done --proof pr:<N>` it. Otherwise add one tagged `#oneshot` and close it straight away:
   ```bash
   notes ptask <project> add "<title> #oneshot" '#low' && notes ptask <project> done "<title> #oneshot" --proof pr:<N>
   ```
   `#low` stops the CLI defaulting the row to `#high`. Quote it, or zsh reads it as a comment. With `--pr-only`, add the `#oneshot` row but leave it open with the PR in the title, and leave the agent row started. If the project has no sheet (`no current project named ...`), say so in the wind-down note and skip it.

8. **Wind down.** Invoke the `wind-down` skill. The note lists: the PR and merge commit, what was validated with counts, the `assumed:` tally, and anything left on the board.
   - **`--pr-only`**: the open PR is the end the human asked for, so skip wind-down's step 0 (it would read the open PR as unlanded and refuse).
   - **Blocked mode** (hard gate or red gate): write the note, but do NOT arm the teardown. Finish with the blocker and the exact next step, so the user sees it in an open window.

## Do NOT

- Land on a red gate, a 0/0 count, or a branch behind its base. The local gate is often the only check a PR gets.
- Run a repo's full slow suite when its CLAUDE.md says to run only the affected classes.
- Force-push, rebase a pushed branch, or `reset --soft` onto a moved base.
- Cross the autopilot hard-stop boundary: no release tags, deploys, secrets or external sends, even though the rest of the run is autonomous.
- Close the window over a blocked run. A teardown that hides the blocker is worse than no wind-down.
