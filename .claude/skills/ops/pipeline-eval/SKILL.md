---
name: pipeline-eval
description: >-
  A delivery pipeline evaluation pass, intake to landed: time per stage, human waits, rework, sessions with no PR, ETA accuracy; then root fixes and a report. Use for "evaluate the pipeline", "where does a task's time go", "pipeline eval pass N". Tokens: usage-cleanup; CI: ci-cleanup.
metadata:
  category: ops
  tags: [pipeline, fleet, queue, dispatch, shepherd, sessions, flow]
  reviewed: "2026-11-05"
---

# Pipeline eval

One pass over how work moves from intake to landed. It produces a measured baseline for every stage (queue and dispatch, plan approval, phases, gates and CI, review and merge, wind-down), a ranked list of where the time goes, one PR per lever that removes the wait, and the same numbers again afterwards, so the next pass adds a column instead of starting over.

Every number comes from a deterministic source, never a model's score of a transcript:

| Stage | Source |
|---|---|
| queue wait and run, by origin | `agent-queue stats --json --flow --since D`, `agent-queue list --json --state all --since D` |
| why dispatch did not start something | `~/.local/state/agentctl/fleet-dispatch/activity.log` (outcome and reason per pass) |
| time per session stage, waits by reason, CI reruns, PR open to merged, conflicts, phase ticks and unticks, wind-down | `fleet-sessions stages --from T --to T --json` (replays `~/.agent/shepherd/watch.log`) |
| sessions with no PR, time use, cost | the nightly session outcomes, read through the day-log record's `agents.outcomes` |
| ETA accuracy | `fleet-bench accuracy --json` and `fleet-bench report` |
| trend | `day-log week --json` and the daily records in `~/.agent/daylog/` (`work.stages` from 2026-11-05) |

The day-log skill's "The snapshot schema" says what each record field means. When a source lacks a number you need, extend the tool that owns it, with a fixture test, and add it to the day-log record; never count by hand. This file holds only the procedure.

## When to Use

- The human asks where a task's time goes, why work waits, or for "pipeline eval pass N".
- A queue wait, a NEEDS total or the ETA error in `day-log week` keeps growing and nobody can say which stage.
- After a pipeline lever lands, to prove what it moved.

Siblings: token spend is `usage-cleanup`; CI pass rate and CI time are `ci-cleanup` and `ci-cost`; one session's progress is `shepherd`; ETAs themselves are `fleet-bench`.

## Steps

1. **In flight first.** `agent-queue list`, `gh pr list` on both dotfiles repos, and the agent-runtime board rows for queue, dispatch, shepherd and wind-down. A lever another session owns is theirs; send what you found with `fleet-comms`.
2. **Baseline.** Pick a window of at least 7 days that ends at a local midnight. Save every source's JSON under `~/.cache/pipeline-eval/p<N>/`. Per stage record: time (p50, p90 and total minutes), how often it waits on the human (`NEEDS` by reason), rework (`STALLED:ci_red`, `ci.rerun_after_red`, `plans.phases_unticked`, conflicts), sessions with no PR, and the ETA basis rows. Split `agent-queue` wait into items held by an `after:` predecessor and free items, and split session stages into agent worktrees and the human's main sessions (`by_project`): the same wait means different things in each. Name every source you could not read cleanly and keep it out of the totals.
3. **Find the waste.** For each stage, the largest minutes first: which reason, which project, and the file or behaviour behind it (a dispatch gate, a hook, a merge rule, a missing nudge). Write down what you ruled out, with its number.
4. **Rank levers, deletion first.** A lever that removes a wait, a gate or a repeat run ranks above one that adds a check. Then rank by minutes saved per day. A stage another skill owns (CI reds, token spend) goes to that skill's next pass as a board row.
5. **Fix, one lever per PR,** through `dotfiles-land`, with a test and a negative control for any script change. A pass with several PRs is one queue item: merge each earlier PR by hand once `gh pr checks <N>` is all green (`gh pr merge <N> --squash --match-head-commit <sha>`), and run `agent-land <N> --item <slug>` only on the last.
6. **Re-measure the same way** once a lever's merge is in the main checkout (stow serves `~/.dotfiles`). Use the same window length, after the landing. If only the measuring waits on new data, queue it as an `at:` item naming the plan file, close this pass's item, and wind down.
7. **Report.** Write `~/.notes/lab/projects/current/agent-runtime/docs/pipeline-eval-p<N>.md` with these sections: a table with one row per stage and one column per measured point (the baseline, then each pass); the top waits with their numbers; what was fixed, with the PR and what it moved; what is left, as board rows with owners. Publish it as an Artifact page and page the human with the link: `agent-notify -p normal -t pipeline-eval '<link>'`.

## Do NOT

- Do not quote a number a named source did not print this session.
- Do not score transcripts with a model, and do not start a live claude probe to measure anything.
- Do not read `agent-queue stats` wait as dispatch latency without the `after:` split: a held item waits by design.
- Do not bundle levers in one PR: the before and after then measures nothing.
- Do not restate fleet-bench, day-log, shepherd, usage-cleanup or ci-cleanup here; name them.
