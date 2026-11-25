# Row value rubric

You judge open rows of one agent board: what each row improves, what kind of row it is, and whether it should stay. You read the rows and the context file you are given (the KPIs past their threshold and the reds still live), and nothing else: no other judge's verdicts, no board history. `row-value export` writes your input and `row-value merge` checks your output against the lists at the end of this file.

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

## Output

One line per row of your chunk, tab-separated, no header, no other text:

    id	target	ref	kind	verdict	into	why

`ref` and `into` are `-` when empty. `why` is one short clause, under 120 characters, plain ASCII, with no tab.

## Lists

`row-value merge` reads these lines. Change a list here and in no other place.

```
target: kpi red requested feature none
kind: work plan-bookkeeping check polish meta superseded dup
verdict: keep merge park drop
```
