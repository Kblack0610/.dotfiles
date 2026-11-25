# Row value rubric

You judge open rows of one agent board: what each row improves, what kind of row it is, what it is on the board for (its bucket), and whether it should stay. You read the rows and the context file you are given (the KPIs past their threshold and the reds still live), and nothing else: no other judge's verdicts, no board history. `row-value export` writes your input and `row-value merge` checks your output against the lists at the end of this file.

## Target: what the row improves

Pick the first that fits.

- `kpi`: it moves a KPI the context lists as past its threshold, and you can name it. A KPI the row only mentions, or one that is not past, is not enough.
- `red`: it fixes a live red or a runtime fault: wrong state, lost or stuck work, a false page, a crash, a refusal of good work. Name the red or the fault in `ref`.
- `requested`: the human asked for it (`#requested`, "the human, <date>:", or a plan phase whose plan the human started). Put the evidence in `ref`.
- `feature`: a feature with a named benefit to a named user or runtime part. Put the benefit in `ref`.
- `none`: no target you can name from the row.

## Kind

- `work`: real work that changes code, config or docs toward its target.
- `plan-bookkeeping`: a row that duplicates a plan file: "plan X: run its open phases", "finish plan X", or a phase row whose brief only points at the plan.
- `check`: a check, re-measure or verify-after row with no change of its own.
- `polish`: wording, renames, tidying, small UI or doc polish with no behaviour change.
- `meta`: a row about the board, its rows, runtime paperwork, or the process of filing rows.
- `superseded`: the row's own text or detail says the work is done, replaced, or no longer applies.
- `dup`: another row in your input carries the same work; name it in `into`.

## Verdict

- `keep`: it has a target, or it is a live red or fault, or it is `doing` (a live queue item).
- `merge`: the same work as another row you were given; name that row in `into`. Keep the older or the better-written one.
- `park`: no target, but a plausible improvement; it belongs in improvements.md, not on the board.
- `drop`: superseded, a dup with nothing to merge, plan bookkeeping for a plan that already has its rows, or a meta or check row with no target.

A `merged:` line under a row is a commit on main whose subject names the row's id. When the subject plainly delivers the row's whole work, the kind is `superseded` and the verdict `drop`, with the commit in `why`. A subject that only cites the row, or delivers part of it, changes nothing.

Rules that bound the verdict:

- Old age alone never drops or parks a row.
- A `doing` row is always `keep`.
- A row the human requested is never `drop` or `park`; if it looks done or replaced, say so in `why` and keep it.
- An epic row (`epic(...)`) is `keep` unless its own text says it is done.
- When unsure between keep and park, keep.

## Bucket: what the row is on the board for

Pick the first that fits. Each bucket allows only some verdicts, and `row-value merge` checks it.

- `container`: the row's header shows `children:` above 0 (it is a parent with open children). It is judged by its children: `keep`, or `drop` when every open child is dropped, merged or fixed in this pass (the cut closes them together with `drop --children`). A row with open children is always `container`, and no other row is.
- `chain`: a phase of a live (not superseded) plan held by `after:` (an `#after/` tag), even when its brief only points at the plan: the tag is how a chain holds its waiting phases, and dropping the row stops the chain. Verdict `keep`. A phase row with no `after:` is bucketed by what its phase does.
- `red`: a live red in the context names it, or it answers one. Put the red in `ref` (required). Verdict `keep`.
- `fault`: a runtime defect you can point at in code (wrong state, lost or stuck work, a false page, a crash, a refusal of good work). Verdict `keep`. A fault row must be checked at HEAD: leave `evidence` as `-`, and the HEAD check writes it.
- `fixed`: the defect or the work is already gone at HEAD. Evidence names the commit or file:line that shows it. Verdict `keep` or `drop` (the cut closes it done with that proof).
- `sot`: source-of-truth and efficiency work: removes a copy, a second reader of one fact, or a gate with no number behind it. Verdict `keep`.
- `requested`: the human asked for it and it is none of the above. Verdict `keep`.
- `improvement`: a feature, view or polish with no red, fault or source-of-truth claim. Verdict `park` (it goes to improvements.md).
- `drop`: superseded, a dup, plan bookkeeping with no `after:` ("finish plan X", "run its open phases"), or a check or meta row with no target. Verdict `drop` or `merge`.

## System: which focus pass the row belongs to

- `dispatch`: dispatch, the queue, landing, agent-land, chains and plans.
- `sessions`: sessions, tmux, worlds, wind-down, hooks and guards.
- `telemetry`: fleet-bench, KPIs, sentinel watches, alerts, pages and reds.
- `notes`: the notes CLI, boards, sheets, reports, lessons and memory.
- `ci`: CI, tests, runners and merge gates.
- `views`: hub, agent-web, waybar, dashboards and other UI.
- `skills`: skills, rules, docs and prompts.
- `other`: none of these.

## Project and evidence

- `project`: the project the row actually serves, by its board name. A row for trader, a unity game or another project filed on this board names that project, and the cut moves it.
- `evidence`: for `fault` and `fixed`, the file:line or commit that shows it, from the HEAD check; `-` for any other bucket.

## HEAD check of fault rows

A checker reads the code a fault row cites at `origin/main` and writes `check-NN.tsv`, one line per row, tab-separated, no header:

    id	bucket	evidence	why

`bucket` is `fault` (the defect is still there: evidence is the file:line that shows it) or `fixed` (it is gone: evidence is the commit or the file:line that fixed it). When the code cannot decide it, the bucket is `fault` and the evidence starts `undecidable:` with what would decide it. Its line replaces the text judge's bucket, evidence and why for that row.

## Output

One line per row of your chunk, tab-separated, no header, no other text:

    id	target	ref	kind	verdict	into	bucket	system	project	evidence	why

`ref` and `into` are `-` when empty. `why` is one short clause, under 120 characters, plain ASCII, with no tab.

## Lists

`row-value merge` reads these lines. Change a list here and in no other place.

```
target: kpi red requested feature none
kind: work plan-bookkeeping check polish meta superseded dup
verdict: keep merge park drop
bucket: red fault fixed sot requested improvement drop chain container
system: dispatch sessions telemetry notes ci views skills other
```
