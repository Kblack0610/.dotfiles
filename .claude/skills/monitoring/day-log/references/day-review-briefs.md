# Day-review briefs

Fill `<D>` (or the week range), `<record>` (the path of `day-log json --date D` saved for the run) and `<baseline>` (the findings.md or report.md Review step 2 picked). Each brief is one Explore agent, "very thorough". Each returns findings with file:line or PR number, a severity, and whether it read the evidence first-hand; no file dumps.

## 1. Workstreams, churn and source-of-truth breaks (fleet repos)

Window <D>. The merged PRs are in <record> under `work`; do not count PRs with gh. For `~/.dotfiles` and `~/.dotfiles-private`:
- Group the merged PRs into workstreams (feature threads) and give each a one-line reading.
- Churn: files touched by 3 or more PRs in the window, and any PR that reverted or reworked one from the same window.
- Source-of-truth breaks: one fact with two homes (a knob with different values in code and conf, a doc copying a number its code or `rules.jsonl` row owns), one job with two live mechanisms, a knob no conf sets whose only reader is a test. For each, say which home is canonical and what to delete.
- Not drift: a code default plus a conf override that agree, a `rules.jsonl` row that names a knob by anchor.
- Compare against <baseline>: which of its findings are fixed, still open or gone.

## 2. Code drift and repo hygiene

Window <D>, the repos in <record>. For the files the window's PRs touched:
- Rename or back-compat shims still wired past their release, dead code, knobs no conf sets whose only reader is a test, TODO/HACK/"temporary" markers, stale paths or URL prefixes, debug output in prod paths.
- Junk stashes, `[gone]` or tmp branches, throwaway-titled commits, and any PR titled `docs` that changed code outside docs.
- Verify each high-severity item first-hand; say which you did not.

## 3. Other repos and the open-PR backlog

Window <D>. From <record>, every repo other than the two dotfiles repos:
- What merged, grouped by workstream, one line each.
- Open PRs (the record's `open`; `gh pr view` one PR for its checks): age, CI state, whether each blocks a release (`release` skill, lab `summary.md`), copied or empty PR bodies, PRs open on or before the window start with no push since.
- Collisions between open branches: migration numbers, generated files, version bumps.
- Scheduled CI that stopped firing (last `schedule` run per nightly workflow).

## 4. Process waste

Window <D>. From <record> (`agents`, `ci`, the week section) and `fleet-bench`:
- Cancelled queue items, sessions that ended with no PR, main reds and how long each lasted, CI pass rate per repo.
- Before calling any count bad, split it: one deliberate drain or bulk cancel, headless runners that never open PRs, board rows that left the sheet without a check, a level change against a rate change week on week.
- Plan phases whose PR merged but whose box is still open (`fleet-sessions`, the plan files).
- Lints or tests that first fail on main because the PR gate skips them.
