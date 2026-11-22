---
name: pipeline-eval
description: >-
  A pipeline and output pass: time per stage, slot holders, merge line, waits, rework; then root fixes and a report. Use for "output is down", "find the bottleneck", "where does a task's time go", "pipeline eval pass N". Tokens: usage-cleanup; CI: ci-cleanup.
metadata:
  category: ops
  tags: [pipeline, fleet, queue, dispatch, shepherd, sessions, flow, throughput, bottleneck]
  system: [dispatch]
  reviewed: "2026-11-16"
---

# Pipeline eval

One pass over how work moves from intake to landed. It produces a measured baseline for every stage (queue and dispatch, plan approval, phases, gates and CI, review and merge, wind-down), a ranked list of where the time goes, one PR per lever that removes the wait, and the same numbers again afterwards, so the next pass adds a column instead of starting over. The method (finding shape, in flight, baseline, one lever per PR, re-measure, proposals, next pass) is `~/.local/src/docs/analysis-streams.md`; this file holds what is specific to the pipeline.

Every number comes from a deterministic source, never a model's score of a transcript:

| Stage | Source |
|---|---|
| queue wait and run, by origin | `agent-queue stats --json --flow --since D`, `agent-queue list --json --state all --since D` |
| why dispatch did not start something | `~/.local/state/agentctl/fleet-dispatch/activity.log` (outcome and reason per pass) |
| time per session stage, waits by reason, CI reruns, PR open to merged, conflicts, phase ticks and unticks, wind-down | `fleet-sessions stages --from T --to T --json` (replays `~/.agent/shepherd/watch.log`) |
| sessions with no PR, time use, cost | the nightly session outcomes, read through the day-log record's `agents.outcomes` |
| ETA accuracy | `fleet-bench accuracy --json` and `fleet-bench report` |
| output and pace: phases in vs out, items started and landed | `fleet-bench pipeline`, `fleet-bench throughput`, `fleet-bench flow --since D` |
| WIP cap, queued age, class of service: runnable against the cap, each class started against its share, the starved ones | `fleet-bench pipeline` (last lines), `agent-queue mix`; `fleet-bench pipeline --check cap`, `age` or `mix` is one Sentinel watch each |
| which dispatch limit binds now (pace target, load, run units, holds) | `fleet-dispatch headroom --json`, `fleet-dispatch run --dry-run` |
| who holds the live slots: open job and time split per project | `fleet-sessions --json` (`open_job`; `queue` is a session waiting its landing turn) |
| merge line: batches cut vs merged, waiters per project | the project's merge-train PRs (`gh pr list --state all --search 'chore(train) in:title created:>=D'`), and `open_job == "queue"` counts |
| fleet host uptime in the window | the boot spans of `journalctl --list-boots` clipped to the window; cross-check against `activity.log`, which is per host and gets a line every pass, so a gap is a pass that never ran |
| trend | `day-log week --json` and the daily records in `~/.agent/daylog/` (`work.stages` from 2026-11-05) |

The day-log skill's "The snapshot schema" says what each record field means. When a source lacks a number you need, extend the tool that owns it, with a fixture test, and add it to the day-log record; never count by hand. This file holds only the procedure.

## Scope and triggers

- The human asks where a task's time goes, why work waits, why output is down, or for "pipeline eval pass N".
- A queue wait, a NEEDS total or the ETA error in `day-log week` keeps growing and nobody can say which stage.
- After a pipeline lever lands, to prove what it moved.

Siblings: token spend is `usage-cleanup`; CI pass rate and CI time are `ci-cleanup`; one session's progress is `shepherd`; ETAs themselves are `fleet-bench`.

## Steps

1. **In flight first.** `agent-queue list`, `gh pr list` on both dotfiles repos, and the agent-runtime board rows for queue, dispatch, shepherd and wind-down.
2. **Baseline.** Pick a window of at least 7 days that ends at a local midnight. Save every source's JSON under `~/.cache/pipeline-eval/p<N>/`. Per stage record: time (p50, p90 and total minutes), how often it waits on the human (`NEEDS` by reason), rework (`STALLED:ci_red`, `ci.rerun_after_red`, `plans.phases_unticked`, conflicts), sessions with no PR, and the ETA basis rows. Split `agent-queue` wait into items held by an `after:` predecessor and free items, and split session stages into agent worktrees and the human's main sessions (`by_project`): the same wait means different things in each. Name every source you could not read cleanly and keep it out of the totals. Before reading any per-day count, take the window's up hours from the uptime row of the source table and divide the counts of starts, done and added (not stage minutes) by them when the host was down for part of the window.
3. **Find the binding stage.** Walk output backwards from landed: is the merge line merging what reaches it (batches merged of cut), do sessions hold slots without working (`open_job` and the time split per project), and does dispatch start nothing (activity.log reasons, `headroom`)? The first stage whose input exceeds its output is the bottleneck; every stage behind it only queues. For "output is down" a same-day window is fine for this step; the stage table still uses the 7-day window.
4. **Spread before you push.** When one project's merge line or pool binds, starting more of its items only lengthens its line, and a landing waiter costs no tokens or CPU, so dispatch holds nothing for the line and counts no waiter toward the pace target (the `fleet-dispatch` skill owns that rule). The line's own fixes (batch size, slot overlap, ejecting a red PR, queue order) are queue items in the project that owns the line.
5. **Find the waste.** For each stage, the largest minutes first: which reason, which project, and the file or behaviour behind it (a dispatch gate, a hook, a merge rule, a missing nudge). Write down what you ruled out, with its number.
6. **Rank levers,** deletion first, by minutes saved per day. A stage another skill owns (CI reds, token spend) goes to that skill's next pass as a board row.
7. **Fix, one lever per PR,** through `dotfiles-land`.
8. **Re-measure** per the method, over the same window length.
9. **Report.** Write `~/.notes/lab/projects/current/agent-runtime/docs/pipeline-eval-p<N>.md` with these sections: a table with one row per stage and one column per measured point (the baseline, then each pass); the top waits with their numbers; what was fixed, with the PR and what it moved; what is left, each lever as one proposal (stream `pipeline-eval`, project `agent-runtime`, evidence the report path). Publish it as an Artifact page and page the human with the link: `agent-notify -p normal -t pipeline-eval '<link>'`.
10. **Queue the next pass** per the method (`--project agent-runtime`, slug `pipeline-eval-p<N+1>`, baseline `~/.notes/lab/projects/current/agent-runtime/docs/pipeline-eval-p<N>.md`). Queue it before `agent-land`.

## Do NOT

- Do not score transcripts with a model, and do not start a live claude probe to measure anything.
- Do not read `agent-queue stats` wait as dispatch latency without the `after:` split: a held item waits by design.
- Do not restate fleet-bench, day-log, shepherd, usage-cleanup or ci-cleanup here; name them.
