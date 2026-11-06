# Judge standard

A judge is a model call that decides something a human would otherwise decide: the answer judge (`ask-judge`, in `agent-ask`), the dispatch judge (`dispatch-judge`, in `fleet-dispatch`) and the ask sweep (`ask-sweep`). Each is an agent with its own conf in `~/.config/agentctl/agents/` (what an agent is: `~/.config/agentctl/README.md`). `judge-eval` is the one scorer; this file is what it holds a judge to. The fleet's other invariants are in `standards.md` beside this file.

## Ground truth per lane

| lane | a verdict | right when | wrong when | not scored |
|---|---|---|---|---|
| ask-judge | `judge` on the ask file, its rule and its `judge_call` | the human's answer is the option the judge would have given, or the human's review of a live answer is `judge_override: none` | the human answered another option, or overrode the live answer | gate asks, free text that names no option, `unclear-ask` deferrals, asks still pending |
| dispatch-judge | the newest `dispatch` or `skip` line per row in `~/.agent/dispatch/verdicts.jsonl` | the started row's queue item ended `done ok` | its item ended failed or cancelled, or a later `failed` line names the row | `skip` (nothing started, so nothing shows whether it should have), rows still running |
| ask-sweep | not recorded | - | - | everything: ask-sweep keeps only a signature of each quote it filed in `~/.agent/ask-sweep/asks-filed`, so `judge-eval` reports its calls alone until it records the row and whether the human kept it |

## Rules

- Judges are scored only by `judge-eval`. A dashboard or report shows its numbers and never counts again. Why: `agent-ask judge-report` and hub-core's own count both scored the answer judge, and they disagreed on in-session answers. Tests: `tests/unit/judge_eval.bats`, hub-core `fleet::tests::the_answer_judge_tiles_are_judge_evals_numbers`.
- A verdict is scored against its lane's ground truth above, never against a model's opinion of it. Why: a model grading a model scored 78% of turns 10/10 (the per-Stop judge retired 2026-10-28). Test: `judge_eval.bats` "the confusion matrix" and "dispatch-judge: the newest verdict per row".
- Scores count only verdicts made under the judge's current prompt (the git blob of its conf's `PROMPT`, the `prompt_sha` agentctl-run writes on the call). A changed policy starts the count again, and `--any-prompt` reads the history. Why: a score earned under an older policy says nothing about the one running now. Test: `judge_eval.bats` "--any-prompt also counts".
- A deferral the human answered with the recommendation is a false-defer, and it is reported beside precision. Why: precision alone rewards a judge that defers everything. On 2026-11-05 the answer judge had 8 scored answers and 47 false-defers. Test: `judge_eval.bats` "the confusion matrix".
- A live answer is labelled by the human's review: `none` is right, an override is wrong, and no review yet is pending. Why: the human never answers a live ask, so the review is its only label. Test: `judge_eval.bats` "the confusion matrix"; how a review is recorded: `tests/integ/agent_ask.bats` "override: ...".
- An answer typed in a session is scored when it names exactly one of the ask's options (agent-ask's `named_option`). The rest is counted as unscorable and never guessed. Why: a guessed label is an invented one. Test: `judge_eval.bats` "the confusion matrix".
- A gate ask (rule `gate`, no call) is not a verdict, and an `unclear-ask` deferral is the asker's fault. It is counted in `ask_unclear_pct`, never as the judge's false-defer. Why: the policy sends both to the human whatever the judge thinks. Tests: `judge_eval.bats` "the confusion matrix", `agent_ask.bats` "judge never sends a gate to the model".
- A failed call is an error: it is counted, left out of coverage's denominator, and never read as a deferral. Why: a timeout is not a judgement, and counting it as one would hide a broken judge behind a careful-looking one. Tests: `judge_eval.bats` "the confusion matrix", the `judge_errors` KPI.
- A shadow class goes live only past one bar for every lane: `AGENT_ASK_LIVE_BAR` (30) scored answers at `AGENT_ASK_LIVE_PRECISION` (90%) precision, read from agent-ask. `judge-eval` shows the 95% interval beside it. Why: at 30 answers a 90% estimate still has a lower bound near 74%, and the interval says how sure the bar is. Test: `judge_eval.bats` "precision carries its 95% Wilson interval".
- An override among a live class's first 30 answers demotes the class, and so does precision falling under the bar after them. Why: a class that goes live on a lucky streak must come back the first time the human disagrees. Tests: `agent_ask.bats` "override: the human's next message ..." and "override: past the first 30 live answers ...".
- Each verdict names its call (`judge_call`, one `calls.jsonl` line), so latency and cost per verdict are the call's, shared across the rows one call judged. Why: estimated costs drift, and a dispatch call judges many rows at once. Test: `judge_eval.bats` "dispatch-judge: the newest verdict per row" (cost per verdict).
- The judge KPIs (`judge_errors`, `judge_precision`, `ask_false_defer_pct`, `ask_unclear_pct`) are fleet-bench KPIs with thresholds in `~/.config/agentctl/kpi-thresholds`, so `fleet-bench retro` files a row when one trips. `judge_precision` is the lowest precision among rules with 10 or more scored answers. Why: a judge drifting wrong was visible only to someone who went looking. Test: `tests/unit/fleet_bench.bats` "kpi: the judge KPIs come from judge-eval kpi".

## Replay

`judge-eval replay` scores a changed policy before it earns live labels: the real `agent-ask judge` over blind copies of the asks the human answered with an option, as the agent `ask-judge-replay`, whose own budget keeps it off `ask-judge`'s. The copies are then scored like any other verdicts, so its numbers are a replay's, never counted into the KPIs, and a run that would leak an answer sends nothing. Test: `judge_eval.bats` "replay".

## How the numbers are computed

Each verdict is one of: TP (answered, right), FP (answered, wrong), FN (deferred, but the human took the recommendation), TN (deferred, rightly), pending, unscorable, or an error.

| number | formula |
|---|---|
| coverage | answered / (verdicts - errors) |
| precision | TP / (TP + FP), with its Wilson 95% interval |
| false-defer % | FN / (FN + TN) |
| kappa | Cohen's kappa over the TP, FP, FN, TN table |
| p50, p95 | each scored verdict's call `duration_ms` |
| cost per verdict | each call's `cost_usd` divided by the verdicts it made, averaged |
| `ask_unclear_pct` | `unclear-ask` verdicts / (ask verdicts - errors) |
