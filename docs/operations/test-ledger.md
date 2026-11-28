# Per-case test ledger

One row per execution of a test case, read once from every finished run of a repo's declared test workflow, so the flake score counts executions and not a run's verdict. Code: `hub_core::cases` (`.local/src/hub-core/src/cases.rs`) and its bin `hub-cases`; the reader of the artifacts is `hub_core::junit`.

## What is where

| Fact | Home |
|---|---|
| The ledger | `~/.local/state/ci/cases/<owner>_<repo>/<run>-<attempt>.tsv.gz` (`$HUB_CASES_DIR` moves it). Columns: `hub_core::cases::COLUMNS`, a `#` header first |
| A run with no rows | a mark beside where its file would be: `.infra` (mass red), `.refused` (an artifact it will not read), `.none` (no results after 4 hours) |
| Which runs, which artifacts | the registry (`testWorkflows`, `testArtifacts` of the repo's tracker in the private `project-map.json`), the builds ledger for finished runs |
| What is left out as infra | the module doc of `cases.rs`; the mass-red share repeats the playground's `quarantine.py` `MAX_FAILED_SHARE` |
| Who runs it | `schedules-sync.service`: `ExecStartPost=hub-cases ingest` after each sync (the lease holder only) |
| Retention | rows and marks 90 days (`KEEP_DAYS`) |

## Use

- `hub-cases ingest` reads the last 3 days of runs not yet in the ledger, newest first, at most 40 fetched and 240 seconds of wall time. Each run is read once; a run is done when it has a file or a mark.
- Back-fill, once after deploy: `hub-cases ingest --backfill --days 30 --bundle 'test-runs-*'`. It reads main's nightly and `Tests (all)` runs and the same-SHA proof runs, and for a run from before `meta.json` falls back to the old `test-runs-*` bundles, whose rows say `bundle` in `source` and carry the run's head, since no tested commit exists. Run it again to drain a backlog the cap stopped.
- Reading it: `hub_core::cases::files` and `read_file`; there is no other reader of the artifacts for the flake score.
- GitHub reads go through the fleet `gh` wrapper and its REST reserve. When the wrapper defers ("REST calls left"), the pass stops and says so; the next timer pass continues.

## Troubleshooting

| Symptom | Cause and fix |
|---|---|
| `schedules-sync` unit shows failed after `hub-cases` | Read `journalctl --user -u schedules-sync`: each fetch or write error is a line. A missing binary means the link is absent: `cd ~/.dotfiles/.local/src/hub-core && cargo build --release && ln -sf "$PWD/target/release/hub-cases" ~/.local/bin/hub-cases` |
| A run says `refused: Unity results with no meta.json` | The artifact predates the playground's `meta.json` (phase 1). It is read only by a back-fill with `--bundle`; otherwise it stays marked `.refused` |
| A night has no rows and a `.infra` mark | Over 10% of at least 20 classes failed: one infra event, deliberately no failure for any case. The mark's text says the count |
| A run has a `.none` mark but results exist | The mark is written 4 hours after the start. Delete the mark; the next pass reads it |
| `still to read` stays above 0 | The cap or the time budget stopped the pass; the next passes drain it, newest first |
