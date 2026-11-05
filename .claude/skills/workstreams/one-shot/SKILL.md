---
name: one-shot
description: >-
  Take one task to landed with no check-ins: worktree, final-pass, gate, PR, merge, queue record, wind-down. Use for "one shot this", "/one-shot <task>", "just ship this end to end". --pr-only stops at the PR.
metadata:
  category: workstreams
  tags: [delivery, landing, autonomy, session]
  reviewed: "2026-11-03"
---

# one-shot

Carries one task the whole way: work, validation, PR, merge, queue record, wind-down, in a single run with no questions. It owns no procedure of its own. Each step points at the rule or skill that already owns it, so when that source changes this skill does not drift.

## Scope and triggers

Take one task from description to landed and wound down with no check-ins - work under autopilot rules, implement in a fresh worktree, run final-pass, run the project's own merge gate, open the PR, merge it, record it on its agent-queue item, then run wind-down. Use when the user says "one shot this", "/one-shot <task>", "do it all and land it", "just ship this end to end", or "do the whole thing, validate, PR and wind down". Pass --pr-only to stop after the PR is open. Stops only at the autopilot hard gates (destructive, release, money, secrets, external sends) or after two failed fix attempts on a red gate. Differs from /my:autopilot (decision posture only, no delivery steps), /kb:implement (opens a PR and stops, assumes PR CI), /captain (batches of tickets, not one task), and wind-down (only the session note and teardown). Not for releases, which stay with release-coordinator and the user.

## When to Use

- The user hands over one well-scoped task and wants it landed without being asked anything.
- The user wants the session to close itself once the work is merged.

Not for a pile of tasks (`/captain`), a release (`release-coordinator`), or landing a tree that is already dirty (`ingest-worktree`).

## Steps

1. **Posture.** Follow `~/.claude/commands/my/autopilot.md` for the whole run: decide every reversible fork yourself, log each non-obvious one as `assumed: <X> because <Y>`, and stop only at its hard-stop boundary. Do not enter plan mode and wait. Write a short plan to `~/.claude/plans/<slug>.md`, however small the task, ending in a `## Phases` checklist (one `- [ ] <task>` line when the task is one step), and proceed. That file is how `fleet-sessions` and wind-down's step 0 tell a finished run from an unfinished one: with no plan file the row reads UNCLEAR, `finished` stays false, and the session can never close itself.

2. **Preflight.** Read the project CLAUDE.md, especially any "working alongside other agents" and merge-gate sections. Then:
   - `git fetch`, `gh pr list`, `git worktree list`. If another session already has this work in flight, build on it or stop and report. Do not start a second copy.
   - Cut a worktree off the remote tip per `~/.claude/CLAUDE.md` (`wt new`, or `git worktree add ~/.worktrees/<repo>-<slug> -b <branch> origin/<base>`). If the session already sits in a clean, current agent worktree, branch there instead.
   - The task's record is its agent-queue item, and only that. A session fleet-dispatch started already has one: `$AGENT_QUEUE_ITEM`. Otherwise add it as running, `agent-queue add --running --project <project> --slug <slug> "<task>"` (it records this tmux session); `<slug>` below is that item. Add no board or sheet row; an item promoted from the board closes its own row when it lands.

3. **Implement.** Make the smallest change that fully solves the task, matching the surrounding code. Send broad exploration to Explore subagents. Update the docs the project CLAUDE.md says a change of this kind must touch.

   3a. **Final pass.** Run `final-pass` on the diff (`~/.claude/skills/final-pass/SKILL.md`). It skips small or docs-only diffs on its own. It goes here, before Validate, so the gate checks its edits too.

4. **Validate.** A project with a gate script (its CLAUDE.md names it; unity-core-playground: `docs/operations/ci.md`, One change, start to finish, driven by `playground-headless-test`) runs it in step 6, once the PR is open. A repo with no gate script runs its lint, typecheck and tests now, before the PR. A red result goes back to step 3. If it is still red after two fix attempts, or the red also fails on a clean `origin/<base>`, do not land: file it on the agent board and go to step 7 in blocked mode.

5. **PR.** Re-fetch. If the branch is behind, `git merge origin/<base>` (a pushed branch is never rebased, never force-pushed) and re-run the affected part of step 4. Stage by path, never `git add -A`. Push and `gh pr create` with: summary, the `assumed:` lines, the classes/checks run with their counts, and for an item promoted from a board row the `Task: <id>` line its brief names. Follow the writing-style rules (ASCII, `de-ai-writing`). A project whose gate-and-land command opens the PR itself (unity-core-playground: its Checks reads the gate line from the body) gets the body file that command names instead.

6. **Gate and land.** `~/.claude/CLAUDE.md` gives standing authorization; do not ask. Start ONE background command and act only on its result:
   ```bash
   <the project's gate command> && agent-land <N> --item <slug> --plan ~/.claude/plans/<slug>.md --phase "<task>"
   ```
   `agent-land` waits for the PR's checks, merges the validated head, records the PR on the item and moves it to done, closes the board row when the item came from the board, and ticks the plan phase. With no gate script the command is `agent-land` alone. A project doc that gives its own gate-and-land command wins; add `--item --plan --phase` to its `agent-land`.
   - `landed #N`: go to step 7.
   - A red gate: back to step 3, commit, push, and start the same command.
   - Exit 3: the branch is behind. Merge `origin/<base>` (unity-core-playground: `scripts/git/merge-main.sh`), push, and start the same command.
   - Exit 1 names the failed step. Fix it and re-run; a PR already merged skips straight to recording.
   - A sheet row the human wrote for this work: also `notes ptask <project> done "<row>" --proof pr:<N>`.
   - Then do any post-land step the project's CLAUDE.md names (unity-core-playground has none). Wind-down releases the worktree.
   - **`--pr-only`**: drop the `agent-land` part and stop at the gate's result. Record the open PR on the item: `agent-queue set <slug> pr=<N>; agent-queue move <slug> done --status ok`. A board row stays started; the human's merge closes it.

7. **Wind down.** Invoke the `wind-down` skill in its `auto` mode, so step 0's checks run. The note lists: the PR and merge commit, what was validated with counts, the `assumed:` tally, and anything left on the board.
   - **`--pr-only`**: the open PR is the end the human asked for, so invoke it without `auto`; step 0's finished check would read the open PR as unlanded and refuse.
   - **Blocked mode** (a red gate you cannot fix, or a hard gate with nothing else in the task left to build: autopilot's hard-stop pauses only that action): `agent-queue move <slug> waiting`, write the note, but do NOT arm the teardown. Finish with the blocker and the exact next step, so the user sees it in an open window.

## Do NOT

- Land on a red gate, a 0/0 count, or a branch behind its base. The gate is often the only check a PR gets.
- Run a repo's full slow suite when its CLAUDE.md says to run only the affected classes.
- Force-push, rebase a pushed branch, or `reset --soft` onto a moved base.
- Cross the autopilot hard-stop boundary: no release tags, deploys, secrets or external sends, even though the rest of the run is autonomous.
- Close the window over a blocked run. A teardown that hides the blocker is worse than no wind-down.
