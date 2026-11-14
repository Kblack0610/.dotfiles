---
name: debug
description: >-
  Take one bug from symptom to a proven fix: prove what runs, reproduce, find the root cause, fix it there, re-run the repro on the real surface. Use for "debug this", "why is X broken", "it crashes", "still broken", "regression". A sweep: bug-bash; fleet reds: fix-red; PR checks: fix-ci.
metadata:
  category: ops
  tags: [debugging, bugs, root-cause, triage, unity]
  reviewed: "2026-11-13"
---

# Debug

One bug, any repo, one spine of nine steps. The result is a merged fix whose original repro now passes on the surface the human saw, or a cause named with evidence and the reason it is not fixed yet. The spine is shared; a repo's instruments (how to run one test, where logs land, how to tell which copy is live) come from its debugging adapter doc, and an engine's bug classes from a reference file here.

The steps are ordered against the failures our sessions repeat most: a process's own "ok" taken as proof, debugging a copy that is not the one running, a guessed fix with no repro, and a flake read as a pass or a fail.

## Scope and triggers

- A human reports one bug: "debug this", "why is X broken", "not working", "it crashes", "this regressed", "still broken", "didn't that session fix this".
- A fix you made did not take, or a test fails and its message does not explain why.

Not for a sweep across a repo (`bug-bash`), a tripped watch, runner or unit (`fix-red`), the red checks on one PR (`fix-ci`), CI failing across many runs (`ci-failures`), or lag, hitches and looks (`game-eval`). For a read-only second opinion on the cause, dispatch the `root-cause-analyst` agent: it runs steps 0 to 6 (Step 0 through Root cause) and stops before the fix.

## Step 0

1. Run `lessons pick ~/.agent/lessons/<project>.md <symptom word>`. Most bugs are a trap someone already wrote down.
2. Read the repo's debugging adapter; `references/adapter-contract.md` says where it lives and what it answers. With none, use the repo's CLAUDE.md and testing docs.
3. In a Unity repo (it has `ProjectSettings/`), read `references/unity.md`.
4. Keep a logbook in your replies: each hypothesis, the experiment, its result. Failed hypotheses stay in it; they are data.

## Steps

1. **Symptom.** Expected against actual, the exact error text, where (repo, build kind, platform, process), since when, how often. For "still broken", find the earlier fix first (`git log -S`, its PR, its queue item) and what it proved: a fix never re-run against the original report is the first suspect.
2. **Prove the target.** Before reading code, prove which copy runs: the process, the path of its binary or script, its commit or build time. Merged is not deployed, a stow link points at the main checkout and not your worktree, a daemon runs old code until it restarts, a tool can answer from another editor, clone or host. The adapter names this repo's checks.
3. **Reproduce.** Make it fail on demand, as small and as automated as you can: a failing test, a script, one command whose output shows the failure. Intermittent: run it N times (the adapter's count, else 10) and record the rate. Cannot reproduce: go to step 4 and instrument for the next occurrence; do not fix by inspection. This repro is the negative control for step 8.
4. **Observe.** Read the whole error and stack, then the logs around the first occurrence; the last one is usually fallout. When the failure crosses components, log once at each boundary with one unique marker (`DBG-<slug>`), run once, and read where the values first go wrong. Read the artifact a step claims to make (the results file, the row, the file on disk), never its exit code or "done" line alone. A screenshot region is not evidence of state.
5. **Eliminate.** Write two to four hypotheses, each with the observation that would rule it out, and go make that observation. Change one variable per experiment and revert one that did not pan out before the next. When guessing stalls, narrow mechanically: `git bisect run <script>` in a scratch worktree, never your working checkout (exit 125 skips an unbuildable commit; keep the script outside the repo), turn half the system or half the input off, or diff against a working sibling (a green run's log, a similar code path that works).
6. **Root cause.** Trace backward from the bad value to where it first became bad, and fix it at that point; where it surfaced is only the trigger. A fix that is a retry, a sleep, a longer timeout, a null guard, a catch-all, or a silenced log or assertion treats a symptom: ask why once more. After three failed fixes, stop: the model of the system is wrong. Write what the three taught you and question the design, or ask the human, instead of trying a fourth.
7. **Fix.** Turn the repro into a regression test and watch it fail. Make one change at the root, with no refactor bundled in. Grep for siblings of the same pattern and fix or file each. Remove the step 4 logging (grep the marker).
8. **Prove on the real surface.** Re-run the step 3 repro on the surface where the human saw the bug (the deployed copy, the player build, the device, the live service), and show the command, its result and the artifact. The regression test passes now and failed before. Intermittent: the same N runs as step 3, rates compared. Then the repo's gate and the usual landing flow.
9. **Record.** A trap the next session would fall into goes in the project's lessons file, rewriting the lesson that covers it if one does. An answer you needed that the adapter lacked goes into the adapter in the same PR (create it from the contract the first time). A missing log line, marker or switch that made this hard is a finding: add it, or file it.

## Hand back

One reply holds the symptom and the cause, the cause shown by a `file:line` or the log line that proves it; each rejected hypothesis with the observation that killed it; the fix PR and the siblings fixed or filed; the repro's command and result before and after, on the real surface; and what could not be run, and why.

## Do NOT

- Do not edit before step 3 has a repro or step 4 shows where it breaks. A guessed fix left in place while testing another makes both results unreadable.
- Do not take a process's own success signal as proof: check the thing it claims to have made.
- Do not debug a copy that is not the one running.
- Do not pass a flake with a retry, a skip, a sleep or a longer timeout. Find the race.
- Do not publish a cause you have not seen in a trace, a log or a repro. A subagent's confident cause is a hypothesis until you observe it.
- Do not leave debug logging behind.
