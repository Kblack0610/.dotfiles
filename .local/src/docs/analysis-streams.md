# Analysis streams

The method every analysis stream follows: tokens (`usage-cleanup`), pipeline time (`pipeline-eval`), CI (`ci-failures`, `ci-cost`, `ci-cleanup`), docs (`docs-cleanup`) and, for what to route where, runtime reds (last rule). A stream's skill names its sources, its metrics and where its report lives, and links here for the rest. A rule that a skill used to copy lives only here.

## A finding

One line: the claim, its number, the window, the command that printed it this session, the file or behaviour behind it, and its owner or route. A finding missing any of these is a guess and goes back to measuring.

## Rules

- In flight first: `agent-queue list`, `gh pr list` on the repos the stream touches, and the board rows for its area. A lever another session owns is theirs; send what you found with `fleet-comms`. Why: two sessions fixing one cause land two fixes and no measurement.
- The baseline comes from deterministic sources, saved with the window the skill names (an ISO time for anything under a day: a bare date means midnight). Why: a window that moves between passes makes the columns incomparable.
- Quote only a number the owning tool printed this session, or one read from the stream's own dated log. When the tool lacks one, extend it with a fixture test; never count by hand or score a transcript with a model. Why: a number only one session can reproduce cannot be re-measured.
- Put every unit (token, minute, red) in one bucket, name the file or behaviour behind it, and write down what you ruled out with its number. Why: the next pass starts from what is already excluded.
- Rank levers deletion first, then by saved per day: a lever that removes a mechanism, a wait or a repeat run beats one that adds a guard. Why: each added guard is paid on every later run.
- One lever per PR, with a test and a negative control for a script change. A pass with several PRs is one queue item: merge each earlier PR by hand once `gh pr checks <N>` is green (`gh pr merge <N> --squash --match-head-commit <sha>`), and `agent-land <N> --item <slug>` only the last. Why: a bundled PR measures nothing, and an early `agent-land` closes the item.
- A cause another stream owns goes to that stream as a proposal or board row, not fixed in place. Why: it is measured there and nowhere else.
- Re-measure the same way and over the same window length, after the merge is in the main checkout (stow serves `~/.dotfiles`). The report table holds one column per measured point, so a later pass adds a column and no table. If only the measuring waits on new data, queue it as an `at:` item naming the plan file and close the pass.
- The report names the causes with their numbers, what was fixed (PR and measured saving), what looks fine, and what is left. Why: a pass that cannot say what it saved did not change anything.
- Each lever left undone is one proposal: `agent-propose add --stream <skill> --project <p> --verb queue --arg "<the lever as one task>" --why "<its number>" --evidence <report path> "<the lever>"`. Accept queues it, reject does nothing. List the stream first (`agent-propose list --stream <skill> --status all`): a lever already proposed is not posted again and a rejected one is not worked on. An add refused at the cap goes in the report instead. Why: Home is where the human decides, and the store dedupes.
- Queue the next pass from the session that writes the report, when "left" names a lever with a number: `agent-queue add --priority low --tags "at:<date +7 days>T09:00" --slug <skill>-p<N+1> "<skill> pass <N+1>: run the <skill> skill; the baseline is <report path>"`, after `agent-queue show <slug>` finds nothing (it finds a finished item too). The `at:` rule is in `~/.config/agentctl/QUEUE.md`; the human ends a series with `agent-queue cancel <slug>`. Why: passes recur without a runner.
- A tripped watch or red runner reaches `triage-routes` (`~/.config/agentctl/triage-routes`) with one route: `agent` when its answer is a pass of one of these streams, `alert` when its answer is a decision (spend, pace, money). Why: pace and spend are the human's call, drift is a measured pass; `fleet-bench triage --coverage` fails a watch with no line, and `TRIAGE_FIX_CAP` bounds the sessions a day.
- Never restate this file or another skill in a stream's skill; name it. Why: a copy drifts, and `skill-drift --dups` lists it.
