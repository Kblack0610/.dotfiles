# one-shot: landing cases off the main path

Read the section that matches when step 6 or step 7 of `../SKILL.md` names it. The main path (`agent-land` lands, then wind-down `auto`) needs none of this.

## Forgejo repo (home-config)

`gh` sees only the GitHub mirror, so `agent-land` cannot run there. Open and merge through the `forgejo-ops` PR API, then `agent-queue set <slug> pr=<owner>/home-config#<N> merged=<sha>; agent-queue move <slug> done --status ok` (reap proves that sha in the checkout project-map `paths` has for the repo the ref names, then closes the row), and tick the plan phase by hand. With `--pr-only`, whoever merges records it: `agent-queue set <slug> merged=<sha>; agent-queue move <slug> done --status ok`.

## A sheet row the human wrote for this work

Also `notes ptask <project> done "<row>" --proof pr:<N>`.

## Work that can only run later

Work left that can only run after a set time, a day of data or a night's log is not waited on. Land what is done, queue the rest as an `at:` item whose task text names the plan file (the `at:` rule in agentctl `QUEUE.md`; a new session's brief carries only the task text), mark those phases `- [-] <name>: queue item <slug>`, and go to step 7. A session sitting on a `sleep` reads as STALLED, holds a dispatch unit, and holds back every item queued `after:` it.

## Blocked on another queue item

Work blocked on another queue item (one that fixes its red, or a PR that must land first) is not waited on either: nothing wakes an idle session when that item lands, and reap keeps this item in `running/`. Check the blocker first (`agent-queue show <blocker>`): done ok means carry on now.

- Record the open PR on this item: `agent-queue set <slug> pr=<owner>/<repo>#<N>`.
- Queue the rest: `agent-queue add --project <p> --after <blocker> "<next step, naming the plan file, the PR and its branch>"`, and mark the phase `- [-] <name>: queue item <new slug>`. A blocker that closes failed never releases an `after:` hold, so the wind-down note names the blocker.
- Wind down without `auto`, as `--pr-only` does: once the session is gone, reap parks this item in `waiting/` and closes it when the PR merges.

## Blocked mode

A red gate you cannot fix, or a hard gate with nothing else in the task left to build (autopilot's hard-stop pauses only that action; a red another queue item fixes is the case above). File the blocker with `agent-ask post`, which is what `fleet-dispatch reap` reads to hold a live session's item in `waiting/` (a bare `agent-queue move <slug> waiting` goes back to `running/` on its next pass), write the note, but do NOT arm the teardown. Finish with the blocker and the exact next step, so the user sees it in an open window.
