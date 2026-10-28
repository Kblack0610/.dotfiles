---
name: fleet-bench
description: >-
  Benchmark the agent fleet from counted facts: where every live session is in its plan, when it should finish, and afterwards how far off that prediction was. Verbs: report | eta | headline | scorecard | nightly | sample | review | asks. Use when the user asks "how accurate are the ETAs", "when will agent-N be done", "benchmark the sessions", "how fast is the fleet moving", "show me the scorecard", "how often does CI go red before merge", "review a sample of merged PRs", "which asks are blocking", "what is waiting on me", or when the shepherd writes a "where are we" summary and needs an ETA per session. Model-free except `review`, which runs a local non-Claude model only once its runner names a route. Not for load or holds (fleet-overseer) and not for what one session did after it ended (session-outcomes).
metadata:
  category: monitoring
  tags: [agents, fleet, benchmark, estimates, observability]
  reviewed: "2026-10-28"
---

# fleet-bench

On 2026-10-27 the shepherd told the human when each session would finish ("about 9:00 PM", "tomorrow around midday") by assuming one phase per hour. Nothing kept those numbers and nothing checked them. The first one scored, an hour later, took up to 2.6x as long as predicted. This skill is the record and the check. It is a component of its own, like `fleet-dispatch`: the shepherd only reads it.

Every number here is counted from samples. None is a model's grade, because model-graded evals on this fleet read 10/10 almost every time and rank nothing.

## Where to look

- `~/.notes/lab/projects/current/agent-runtime/bench/latest.md`: the nightly scorecard, one row per session over the last 24h (phase now, phases ticked, hours working, hours waiting on you, hours stalled, nudges, peak context, then PRs merged, CI reds, reverts and cost), and under it the review sample. One dated file per day sits beside it. It syncs with notes, so it reads on the phone.
- The nightly page (`-t bench`, 06:30): the headline line and the scorecard path.
- `~/.notes/lab/projects/current/agent-runtime/bench/asks.md`: every pending ask, the ones blocking a live session first, rewritten at 08:00 and 18:00. The page that comes with it (`-t asks`) names the top three and what each session recommends.
- `fleet-bench report`: every live session (phase done/total, bucket, ETA, what the ETA is based on), then how accurate past ETAs were, then the last agentctl outcome of `fleet-bench`, `fleet-bench-nightly`, `fleet-review` and `ask-digest`.
- `fleet-bench eta`: one line per live session, or `--json` for scripts. The shepherd's "where are we" summary takes its ETAs from here.
- Prefix + Ctrl-g (`fleet.sh`) has a `bench` section under the asks: the headline, then one ETA row per live session. Its runners section lists `fleet-bench` and `fleet-bench-nightly` with every other agentctl unit, red when the last outcome is STALLED or the run failed.
- `agentctl status fleet-bench` and `agentctl logs fleet-bench -f` for one run's detail.

## Verbs

- `sample`: one pass. It reads `fleet-sessions --json`, appends one line per live session to `progress.jsonl`, writes an estimate for any session whose phase count has no estimate yet, and scores every estimate whose session has since finished. The agentctl runner `fleet-bench` runs it every 10 minutes: `fleet-sessions` has no event to wait on, so this is a steady poll, and one run costs about 14 s, mostly `gh`.
- `eta [--json]`: the newest estimate per live session from the newest sample. A finished session has none.
- `report`: as above. Read-only.
- `headline`: the last `BENCH_WINDOW_H` (24) hours in one line: sessions, phases ticked, hours waiting on you, hours stalled, ETAs scored and their median ratio.
- `scorecard`: writes `<date>.md` and `latest.md` in `BENCH_SCORECARD_DIR` and prints the path.
- `nightly`: `scorecard`, then one `agent-notify -p normal -t bench` page with the headline. The agentctl runner `fleet-bench-nightly` runs it at 06:30, after session-outcomes (02:30) has counted the night's PRs, so the page arrives as the morning summary. WORKED when the file was written, STALLED (exit 1) when it was not.
- `review [--pick]`: for every PR that session-outcomes lists as merged in the window and `pr-ci.jsonl` has not counted, one `gh pr view` and one `gh run list --branch` give its size and its CI runs from its first commit to merge. Then, when the runner's conf names a `ROUTE`, the reviewer reads up to `BENCH_REVIEW_MAX` (5) of them: the largest per session at most `BENCH_REVIEW_MAX_LINES` (2000) diff lines, largest first. `--pick` prints that list and calls nothing. The agentctl runner `fleet-review` runs it at 02:45, after session-outcomes (02:30) and before the 06:30 scorecard.

- `asks [--page]`: every pending ask from `agent-ask list --all --pending`, joined to the newest sample of the session its `session` field names (a session id or a tmux session name). It prints the digest; `--page` also writes `asks.md` in `BENCH_SCORECARD_DIR` and sends one `agent-notify -p normal -t asks` page with the counts and the top three. The agentctl runner `ask-digest` runs `--page` at 08:00 and 18:00.

- `ledger [--json|--check]`: the consolidation ledger. It counts runner confs (`runners`, `runners_on` without `ENABLED=no`), generated `agentctl-*.timer` files, files with a direct headless `claude -p|--print` outside agentctl-run (`launches_direct`, gitignored build output skipped), distinct `last-outcome` verdicts, pending asks and those older than `ASK_STALE_DAYS` (14), and open agent-board rows. `--check` prints each of `runners`, `timers` and `launches_direct` that is over `~/.config/agentctl/ledger-baseline` and exits 1 (2 with no baseline). To add a runner, timer or launch, retire one or raise the baseline in the same PR with a why. The scorecard carries the counts and the check under "Consolidation ledger". `--launches DIR...` prints the scan's matches; `runner_contract.bats` uses it.

## How the numbers are made

State is in `~/.agent/bench/` (override with `FLEET_BENCH_DIR`).

| File | One line per | Fields that matter |
|---|---|---|
| `progress.jsonl` | session per sample | `epoch`, `session_id`, `target`, `project`, `bucket`, `phases_done`, `phases_total`, `finished`, `idle_min`, `context_tokens`, `nudged` |
| `estimates.jsonl` | session per phase count | `made_epoch`, `eta_epoch`, `per_phase_min`, `basis` |
| `scores.jsonl` | estimate whose session finished | `error_min`, `ratio`, `horizon_min`, `done_bound` |
| `pr-ci.jsonl` | merged PR | `repo`, `number`, `session_id`, `merged_epoch`, `additions`, `deletions`, `ci_runs`, `ci_red` |
| `reviews.jsonl` | reviewed PR | `status` (ok or failed), `block`, `flag`, `nit`, `findings[]` (`severity`, `where`, `summary`), `route`, `exit` |

- **Phase time.** Each plan file is its own timeline, so a session that starts a new plan does not count the switch as a phase. A phase is measured only when the samples saw both its start and its end, so a session's first phase on the record is never measured (it may have started hours earlier). When one sample sees two phases tick at once, the gap is split evenly between them. The time includes waiting on the human.
- **ETA** = now + phases left x per-phase minutes. Per-phase is the median measured phase time of that session (`basis: session-median(n)`), else of every session in its project (`project-median(n)`), else `BENCH_DEFAULT_PHASE_MIN`, 60 (`default`). A new estimate is written only when the phase count changes, so one estimate stands for each step of a plan and is scored as it was made.
- **Finish** is the first sample that reads `finished` (fleet-sessions' DONE work conditions). If that was the session's first sample at all, the real finish was earlier, and the score says `done_bound: upper`.
- **Score.** `error_min` = finish - ETA (positive means it ran long). `ratio` = actual duration / predicted duration (2 means it took twice as long). `horizon_min` = how far ahead the ETA looked. The report gives medians by basis and by horizon (under 2h, 2-8h, over 8h).
- **Scorecard hours.** Each sample owns the time until the next sample of that session, in that sample's bucket: WORKING is working, NEEDS is waiting on you, STALLED is stalled. A gap longer than `BENCH_GAP_CAP_MIN` (20, two cadences) counts as 20 minutes, because a longer gap means the sampler itself was down. Nudges count each time the shepherd's `nudged` flag turns on. PRs merged, reverts and cost are the newest session-outcomes line for that `session_id`, `-` when it has not been observed yet.
- **CI reds.** Runs on the PR's branch from its first commit (or its opening, if earlier) to its merge. Red is `failure`, `timed_out` or `startup_failure`; `cancelled` is a superseded run and does not count. Earlier runs on the same branch name belong to an older PR and are left out. The scorecard sums them per session; the headline sums them over the window.
- **Review.** `agentctl-run --role review` with `AGENT_AUTHOR_FAMILY=anthropic`: the role pins a local Qwen model and refuses to start on the author's family, and every fleet session is Claude, so a review can never be Claude marking Claude. The reviewer gets the kb-reviewer rubric and the diff, may read but not write, and must answer one `FINDING <BLOCK|FLAG|NIT> <file>:<line> <defect>` line per finding, then `REVIEW DONE`. Only those lines are counted. A run that exits non-zero or never says `REVIEW DONE` is `status: failed`, never a clean review. Each PR is reviewed once.
- **Ask rank.** An ask whose session is live ranks by age in hours x (1 + phases left in that session's plan + 1 if the session has an open PR), highest first: an old ask holding a long plan comes before a new one holding nothing. The rest have no live session behind them (headless asks from the wave and delivery loops, and asks whose session has ended). They are listed oldest first and never paged one by one, because ranking them by age alone would put the same stale asks at the top of every page. On 2026-10-28, 11 of 16 pending asks were of that kind, 10 of them 35 to 61 days old.
- `project` is the tmux target with the server, the window and any `-agent-N` removed, so every `unity-core-playground-agent-*` session shares one project median.

A hand-made estimate can be added as a line in `estimates.jsonl` with `basis: "shepherd-guess"` and the same fields. It is scored like any other. The first five, from the 2026-10-27 evening summary, are there.

## Outcomes

Each runner publishes under its own name (`$AGENTCTL_NAME`) through `agent-proof.sh`'s `proof_report`.

- `sample`: WORKED when it wrote lines, NOOP when no session is live, STALLED with exit 1 when `fleet-sessions` failed. On STALLED nothing is written: the history gets a gap, and every number around it stays correct.
- `asks --page`: WORKED when it paged, NOOP when nothing is pending (`asks.md` still rewritten, so it never shows a stale list), STALLED with exit 1 when `agent-ask list` failed or `asks.md` could not be written.
- `review`: WORKED when it counted or reviewed something (the detail says `review off` while there is no route), NOOP when nothing new merged, STALLED with exit 1 when `gh` failed while counting or any review failed.

## Turning the review on

The runner ships with no `ROUTE`, so it only counts CI. The review needs a gateway route that serves the `review` role's pinned model, `reasoning (Qwen3.6-35B-A3B-4bit)` on the Mac Studio, with a key scoped to that model alone. The existing `gateway-personal` key is scoped to Claude models, and the gateway refuses it with a 403 (checked 2026-10-28). Mint a key per home-config `apps/litellm/README.md` "Create a key" with `models: ["reasoning (Qwen3.6-35B-A3B-4bit)"]`, write it to `~/.local/state/agentctl/fleet-review/key`, add a route file whose `ROUTE_KEY_SOURCE` points there, set `ROUTE=` to it in `fleet-review.conf`, then check with `AGENT_AUTHOR_FAMILY=anthropic ROUTE=<route> agentctl-run --explain review`.

## Cost

The sampler, the scorecard, the CI count and the ask digest call no model. They use no Claude subscription usage and no gateway allowance. The review runs on local hardware through the gateway, so it costs no allowance either; it is up to five local model runs a night, each capped at `BENCH_REVIEW_TIMEOUT_S` (900 s).

## Do NOT

- Read a score as a grade of the session. A long ratio usually means the plan's phases were uneven or the session waited on the human, which the samples' `bucket` field shows.
- Edit `progress.jsonl` to fix a number. Fix the sampler. The history is the source every number is rebuilt from.
- Add a model call to `sample`. Judgment belongs in a separate runner that reads these files.
- Point the review at a Claude model to get it running. A same-family review is recorded as independent while it is not; the `review` role refuses it on purpose.

## Related

- `fleet-overseer`: the shepherd. Its summary reads `fleet-bench eta`, and `fleet-sessions` (which it owns) is this skill's input.
- `agentctl-session-outcomes` (DREAMING.md "Session outcomes"): PRs, reverts, corrections and cost per ended session. The bench joins it by `session_id`; it does not count those again.
