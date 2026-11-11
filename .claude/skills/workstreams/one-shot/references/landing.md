# one-shot: landing cases off the main path

The cases step 6 and step 7 of `../SKILL.md` name by section. Read the one the run is in.

## Work that can only run later

Work that can only run after a set time, a day of data or a night's log is not waited on. Land what is done, queue the rest as an `at:` item whose task text names the plan file (the `at:` rule in agentctl `QUEUE.md`; a new session's brief carries only the task text), mark those phases `- [-] <name>: queue item <slug>`, and go to step 7. A session sitting on a `sleep` reads as STALLED, holds a dispatch unit, and holds back every item queued `after:` it.

## Blocked on another queue item

Work blocked on another queue item (one that fixes its red, or a PR that must land first) is not waited on either: nothing wakes an idle session when that item lands, and reap keeps this item in `running/`. Check the blocker first (`agent-queue show <blocker>`): done ok means carry on now.

- Record the open PR on this item: `agent-queue set <slug> pr=<owner>/<repo>#<N>`.
- Queue the rest: `agent-queue add --project <p> --after <blocker> "<next step, naming the plan file, the PR and its branch>"`, and mark the phase `- [-] <name>: queue item <new slug>`. A blocker that closes failed never releases an `after:` hold, so the wind-down note names the blocker.
- Wind down without `auto`, as `--pr-only` does: once the session is gone, reap parks this item in `review/` and closes it when the PR merges.

## Blocked mode

A red gate you cannot fix, or a hard gate with nothing else in the task left to build (autopilot's hard-stop pauses only that action). A red that another queue item fixes is not blocked mode: it is "Blocked on another queue item" above, which queues an `--after` item instead of filing an ask. File the blocker with `agent-ask post`, which is what `fleet-dispatch reap` reads to hold a live session's item in `waiting/` (a bare `agent-queue move <slug> waiting` goes back to `running/` on its next pass), write the note, but do NOT arm the teardown. Finish with the blocker and the exact next step, so the user sees it in an open window.
