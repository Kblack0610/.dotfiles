---
name: ci-cost
description: >-
  Cut CI time from measured data, one lever per PR, re-measured. Use for "why does CI take so long", "cut our CI time", "where do the runner hours go", "is the pool overloaded". Running tests: playground-headless-test.
metadata:
  category: ops
  tags: [ci, cost, benchmark, testing, unity, playground]
  reviewed: 2026-11-03
---

# CI cost

Turns "CI is slow" into a measured list of where the runner minutes go, a ranked lever, one PR that pulls it, and a before/after number recorded where the next session will read it.

The repo docs own everything but the procedure: `docs/operations/ci-cost.md` (how to measure, open levers, the before/after log), `scripts/ci-cost.py` (the numbers), and `docs/operations/ci.md` Rules (what a CI change must carry). This file is only the procedure. When they disagree, the doc wins and this file gets fixed in the same turn.

## When to Use

- When the user asks why CI, a gate, or a dispatch takes as long as it does.
- When choosing the next harness change to cut CI time.
- After a harness change lands, to prove what it saved.
- When the runner pool queue is long and nobody knows which workflow fills it.

Not for running tests or gating a PR - that is `playground-headless-test`. Not for agent-session ETAs - that is `fleet-bench`. Not for why gates are red - that is `ci-failures`. A whole cleanup pass is `ci-cleanup`.

## Steps

1. **Answer the question asked.** The cost is run time: wall minutes per run and runner-minutes summed over jobs. Do not speculate about billing or infrastructure unless the user asks.
2. **Measure from data, never from memory.**
   - Run `scripts/ci-cost.py` first; it prints runner-hours per workflow per day, the gate median split into EditMode and PlayMode, queue times, and the slowest classes. Extend the script rather than hand-computing a number it should own.
   - For what the script does not give (Unity launch cost, per-class time, a gate's pick, EditMode per assembly) and how to read a window without fooling yourself, follow `docs/operations/ci-cost.md`, Measuring.
   - Raw `gh run list` / `gh run view --json jobs` calls: cache every response in the scratchpad and reuse it; a loop over runs hits the API rate limit fast, and a 502 mid-loop leaves partial data.
3. **Attribute.** Put every minute in one bucket: which workflow and trigger (nightly, gate, branch dispatch, release), then fixed per-launch cost, per-test cost, over-picking (classes picked that the change cannot affect), repeat gates (a re-gate after only a main merge, a second gate of a gated commit, a `run_attempt` above 1), solo reruns of a batch red, a cold Library import, or a slow test. Count the workstation's local Unity hours too (the run ledger `scripts/test/slots.sh` writes); the pool numbers leave them out. Check and rule out the cheap suspects too, and write the ruled-out list down so the next pass does not redo it.
4. **Rank levers, deletion first.** A lever that removes a mechanism, a knob, a rule or a duplicate step ranks above any that adds one (`docs/operations/ci.md` rule 13). Then rank by runner-hours saved per day: minutes saved per run times runs per day that the lever touches. A big saving on a rare run loses to a small one on every gate. Note the floor (a Unity launch costs about a minute however little it runs) so targets stay honest.
5. **Change one lever per PR,** carrying what `docs/operations/ci.md` rules 1 and 13 require (a test, a negative control, a replay for a picker change, a mechanism removed for one added).
6. **Re-measure the same way** after it lands, with `scripts/ci-cost.py --days N --before <end of the before window>`, and append the before/after row to `docs/operations/ci-cost.md`. An estimate in a plan is replaced by the measured number, never left standing.
7. **Report in this shape**, whenever the user asks how CI is doing or what a change bought:
   1. The answer in one or two sentences, including what got worse.
   2. One table from `--before`: metric, before, after, and a column for what the plan expected. Keep the rows it prints: pool and gate runner-hours, gate wall, runner-minutes, EditMode, PlayMode, queue, Multi on a branch, nightly.
   3. A second table of decisions: each one with its PR and what it measured, including what was dropped or deferred and why.
   4. What makes the windows not comparable: slots, routing, gate count, load, runs still going, one night against one night.
   5. What has not been measured yet, and the next lever.
   Say which change caused a number only if that lever was measured alone.
8. **File the next lever** on the agent board (`notes ptask <project> --agent add "ci(cost): <lever> #size/s" '#tier/3'`), checking for an existing row first.

## Do NOT

- Do not quote a number you did not count in this session or read from the cost doc with its date.
- Do not hand-count timings in a shell loop when `scripts/ci-cost.py` could own the number; a number only one session can reproduce cannot be compared later.
- Do not bundle levers in one PR: the before/after then measures nothing.
- Do not drop coverage to hit a target: the nightly runs every class (`docs/operations/ci.md` rule 10).
- Do not cancel another session's pool gate run; measure around it (rule 7).
