---
name: ci-cost
description: "Cut CI run time from measured data, one lever at a time: measure where the minutes go (job timings per workflow, runner-hours per day, gate median split by EditMode and PlayMode, queue time, Unity launch and exit cost, per-class durations, retries), attribute them, rank the levers by runner-hours times the share of runs they touch, change one lever per PR with a test and a negative control, re-measure the same way, and append the before/after to the repo's cost doc. Use when the user asks \"why does CI take so long\", \"why is a small change a 40 minute gate\", \"cut our CI time\", \"where do the runner hours go\", \"is the pool overloaded\", \"did that harness change actually save anything\", or to pick the next CI cost lever. Playground-first (unity-core-playground: scripts/test/ci-cost.py, docs/operations/ci-cost.md) but the procedure fits any repo with self-hosted runners. Elsewhere: running or gating tests and reading a red nightly is playground-headless-test, agent fleet ETAs are fleet-bench, game frame-time perf is game-eval."
metadata:
  category: ops
  tags: [ci, cost, benchmark, testing, unity, playground]
  reviewed: "2026-10-29"
---

# CI cost

Turns "CI is slow" into a measured list of where the runner minutes go, a ranked lever, one PR that pulls it, and a before/after number recorded where the next session will read it. On 2026-10-29 the playground pool spent about 36 runner-hours a day: about 20 on branch Multi dispatches that ran every class, 12 on merge gates whose EditMode job ran all 4,419 tests for a one-line change, and 4 on the nightly. None of that was visible until it was counted from run data. This skill is how it gets counted, and recounted after every change.

The repo doc is the source of truth for the findings and the history: `docs/operations/ci-cost.md` (cost model, levers, measured before/after log) and the script that reproduces its numbers, `scripts/test/ci-cost.py`. This file is only the procedure. When they disagree, the doc wins and this file gets fixed in the same turn.

## When to Use

- When the user asks why CI, a gate, or a dispatch takes as long as it does.
- When choosing the next harness change to cut CI time.
- After a harness change lands, to prove what it saved.
- When the runner pool queue is long and nobody knows which workflow fills it.

Not for running tests or gating a PR - that is `playground-headless-test`. Not for agent-session ETAs - that is `fleet-bench`.

## Steps

1. **Answer the question asked.** The cost is run time: wall minutes per run and runner-minutes summed over jobs. Do not speculate about billing or infrastructure unless the user asks (2026-10-29 the user asked what the build does and got a billing answer, which was wrong).
2. **Measure from data, never from memory.**
   - Run `scripts/test/ci-cost.py` first; it prints runner-hours per workflow per day, the gate median split into EditMode and PlayMode, queue times, and the slowest classes. Extend the script rather than hand-computing a number it should own.
   - For anything it does not cover: `gh run list --workflow <wf> --json databaseId,event,headBranch,createdAt,updatedAt` and `gh run view <id> --json jobs` for per-job start and end times. Cache every JSON response in the scratchpad and reuse it: a loop over runs hits the GitHub API rate limit (403) fast, and a 502 mid-loop leaves partial data to filter out before you count anything.
   - Unity fixed cost per launch: from a run's `editor.log` timestamps, launch to first test, then last test to process exit. Name the big phases (asset refresh, script compile, activation, domain reload) with their seconds.
   - Per-class durations and retry counts: the run's results artifacts (`durations.txt`, the suite summary's FAIL, FLAKY, ONMAIN and solo-run lines).
   - Unity measurements on the workstation only when `agent-hold list` shows no `unity` hold.
3. **Attribute.** Put every minute in one bucket: which workflow and trigger (nightly, gate, branch dispatch, release), then fixed per-launch cost, per-test cost, over-picking (classes picked that the change cannot affect), retries and solo reruns, or a slow test. Check and rule out the cheap suspects too, and write the ruled-out list down so the next pass does not redo it.
4. **Rank levers** by runner-hours saved per day: minutes saved per run times runs per day that the lever touches. A big saving on a rare run loses to a small one on every gate. Note the floor (a Unity launch costs about a minute however little it runs) so targets stay honest.
5. **Change one lever per PR.** Each PR carries a test of the new behavior and a negative control (revert the guard, watch the test fail). A picker change ships with a `test_affected_classes.py` case for each rule, plus a replay of past gate picks showing pick sizes before and after and that no class that went red in those runs falls out of its pick.
6. **Re-measure the same way** after it lands, with the same script and the same window length, and append the before/after row to `docs/operations/ci-cost.md`. An estimate in a plan is replaced by the measured number, never left standing.
7. **File the next lever** on the agent board (`notes ptask <project> --agent add "ci cost: <lever>" '#tier/3'`), checking for an existing row first.

## House rules

- The nightly on main stays full: every test, every class, every multi-process job. Breadth moves to the nightly, never out of CI.
- Never widen a gate to catch what the nightly catches; teach the picker the dependency it missed, with a test (docs/operations/ci.md "Who gates what").
- Harness, CI and gate changes are tier 3: run them attended, never through unattended dispatch.
- Never cancel a pool gate run another session started; measure around it.

## Do NOT

- Do not quote a number you did not count in this session or read from the cost doc with its date.
- Do not hand-count timings in a shell loop when `scripts/test/ci-cost.py` could own the number; a number only one session can reproduce cannot be compared later.
- Do not bundle levers in one PR: the before/after then measures nothing.
- Do not drop coverage to hit a target. If a cut needs a test to stop running on gates, it still runs nightly, and the doc says where.
