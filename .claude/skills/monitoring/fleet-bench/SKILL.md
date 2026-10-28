---
name: fleet-bench
description: >-
  Benchmark the agent fleet from counted facts: where every live session is in its plan, when it should finish, and afterwards how far off that prediction was. Verbs: report | eta | sample. Use when the user asks "how accurate are the ETAs", "when will agent-N be done", "benchmark the sessions", "how fast is the fleet moving", "show me the scorecard", or when the shepherd writes a "where are we" summary and needs an ETA per session. Model-free: it spends no Claude or gateway credits. Not for load or holds (fleet-overseer) and not for what one session did after it ended (session-outcomes).
metadata:
  category: monitoring
  tags: [agents, fleet, benchmark, estimates, observability]
  reviewed: "2026-10-27"
---

# fleet-bench

On 2026-10-27 the shepherd told the human when each session would finish ("about 9:00 PM", "tomorrow around midday") by assuming one phase per hour. Nothing kept those numbers and nothing checked them. The first one scored, an hour later, took up to 2.6x as long as predicted. This skill is the record and the check. It is a component of its own, like `fleet-dispatch`: the shepherd only reads it.

Every number here is counted from samples. None is a model's grade, because model-graded evals on this fleet read 10/10 almost every time and rank nothing.

## Where to look

- `fleet-bench report`: every live session (phase done/total, bucket, ETA, what the ETA is based on), then how accurate past ETAs were, then the sampler's last agentctl outcome.
- `fleet-bench eta`: one line per live session, or `--json` for scripts. The shepherd's "where are we" summary takes its ETAs from here.
- Prefix + Ctrl-g (`fleet.sh`) lists the `fleet-bench` runner with every other agentctl unit, red when its last outcome is STALLED or it failed.
- `agentctl status fleet-bench` and `agentctl logs fleet-bench -f` for one run's detail.

## Verbs

- `sample`: one pass. It reads `fleet-sessions --json`, appends one line per live session to `progress.jsonl`, writes an estimate for any session whose phase count has no estimate yet, and scores every estimate whose session has since finished. The agentctl runner `fleet-bench` runs it every 10 minutes: `fleet-sessions` has no event to wait on, so this is a steady poll, and one run costs about 14 s, mostly `gh`.
- `eta [--json]`: the newest estimate per live session from the newest sample. A finished session has none.
- `report`: as above. Read-only.

## How the numbers are made

State is in `~/.agent/bench/` (override with `FLEET_BENCH_DIR`).

| File | One line per | Fields that matter |
|---|---|---|
| `progress.jsonl` | session per sample | `epoch`, `session_id`, `target`, `project`, `bucket`, `phases_done`, `phases_total`, `finished`, `idle_min`, `context_tokens`, `nudged` |
| `estimates.jsonl` | session per phase count | `made_epoch`, `eta_epoch`, `per_phase_min`, `basis` |
| `scores.jsonl` | estimate whose session finished | `error_min`, `ratio`, `horizon_min`, `done_bound` |

- **Phase time.** A phase is measured only when the samples saw both its start and its end, so a session's first phase on the record is never measured (it may have started hours earlier). When one sample sees two phases tick at once, the gap is split evenly between them. The time includes waiting on the human.
- **ETA** = now + phases left x per-phase minutes. Per-phase is the median measured phase time of that session (`basis: session-median(n)`), else of every session in its project (`project-median(n)`), else `BENCH_DEFAULT_PHASE_MIN`, 60 (`default`). A new estimate is written only when the phase count changes, so one estimate stands for each step of a plan and is scored as it was made.
- **Finish** is the first sample that reads `finished` (fleet-sessions' DONE work conditions). If that was the session's first sample at all, the real finish was earlier, and the score says `done_bound: upper`.
- **Score.** `error_min` = finish - ETA (positive means it ran long). `ratio` = actual duration / predicted duration (2 means it took twice as long). `horizon_min` = how far ahead the ETA looked. The report gives medians by basis and by horizon (under 2h, 2-8h, over 8h).
- `project` is the tmux target with the server, the window and any `-agent-N` removed, so every `unity-core-playground-agent-*` session shares one project median.

A hand-made estimate can be added as a line in `estimates.jsonl` with `basis: "shepherd-guess"` and the same fields. It is scored like any other. The first five, from the 2026-10-27 evening summary, are there.

## Outcomes

`sample` publishes through `agent-proof.sh`'s `proof_report`: WORKED when it wrote lines, NOOP when no session is live, STALLED with exit 1 when `fleet-sessions` failed. On STALLED nothing is written: the history gets a gap, and every number around it stays correct.

## Cost

None. The sampler calls no model. It uses no Claude subscription usage and no gateway allowance.

## Do NOT

- Read a score as a grade of the session. A long ratio usually means the plan's phases were uneven or the session waited on the human, which the samples' `bucket` field shows.
- Edit `progress.jsonl` to fix a number. Fix the sampler. The history is the source every number is rebuilt from.
- Add a model call to `sample`. Judgment belongs in a separate runner that reads these files.

## Related

- `fleet-overseer`: the shepherd. Its summary reads `fleet-bench eta`, and `fleet-sessions` (which it owns) is this skill's input.
- `agentctl-session-outcomes` (DREAMING.md "Session outcomes"): PRs, reverts, corrections and cost per ended session. The bench joins it by `session_id`; it does not count those again.
