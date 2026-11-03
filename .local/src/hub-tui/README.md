# hub-tui

`hub`, the hub boards as terminal pages (ratatui). `hub infra` is the `hub:infra` window (tmux Prefix i, declared in `.config/tmux-servers/hub.conf`) and what the waybar load, CI and day chips open on click. It reads through `hub-core`, the same crate agent-web's Infra and Jobs tabs use, so the terminal and the browser cannot disagree. Read-only; actions stay in `fleet.sh` (Prefix C-g). Trends live in Grafana; `o` opens the dashboard for the tab you are on.

Install: the installer's `build_local_rust_tools` builds it and links `~/.local/bin/hub`. By hand: `cargo build --release` here, then `ln -sf "$PWD/target/release/hub" ~/.local/bin/hub`.

## Usage

```
hub infra                        the board, on the Overview tab
hub infra --tab jobs             start on another tab (overview, jobs, ci, machines)
hub infra --once                 print Overview, Machines and CI as plain text at $COLUMNS, then exit
hub infra --once --tab jobs      print one tab; exit 1 when Prometheus did not answer
```

## Tabs

| Tab | What it shows | Grafana (`o`) |
|---|---|---|
| 1 Overview | Header (overall status, CI busy/slots, waiting), POOLS, RUNNING (longest first, amber past an hour), the queue grouped by pool, repo, PR and branch (8 groups, then a "+N more" hint), DOWN (offline or missing runners, stuck runs, GitHub API failing), the finished headline and what is red now | `kb-command-center` |
| 2 Jobs | Every job `hub_core::jobs::collect` finds: agentctl runners (the run ledger), user timers (journald), night shift, Unity gates (the ledger plus running gates from `cc:host_local_gate`), CI and k8s from Prometheus. Queued, running and done with start, duration and result; Enter opens the log under the list | `kb-ci-runners` |
| 3 CI | Finished runs per workflow with failures, then the recent runs list | `kb-ci-runners` |
| 4 Machines | One row per machine: CPU now and over 6h, load per core, memory, temperature, slots per pool. Machines with no runner show when named in `CC_HOSTS` | `kb-fleet` |

Prometheus pages re-read every 60s (`PROM_REFRESH`; Prometheus has no push). The Jobs tab re-reads when a job file changes (inotify on the agentctl state dir, `~/.agent/night`, the Unity ledger), plus on that same 60s tick for CI and k8s.

## Keys

| Key | Does |
|---|---|
| `1`-`4`, Tab, Shift-Tab | Switch tab |
| `r` | Re-read now |
| `o` | Open this tab's Grafana dashboard (on Jobs: the selected row's URL) |
| `j`/`k`, PgUp/PgDn, space, `g`/`G` | Scroll a page; on Jobs, move the selection |
| `s` / `f` | Jobs: cycle the source / state filter |
| `/` | Jobs: search name, detail, result and source (Enter applies, Esc cancels) |
| `h` | Jobs: every run of the selected job, unfolded (again to go back) |
| Enter | Jobs: open the selected row's log (follows the tail) |
| `J`/`K`, PgUp/PgDn | Jobs, log open: scroll the log |
| Esc | Jobs: close the log, then history, then clear the filters |
| `q`, Ctrl-C | Quit |

## Environment

| Variable | Meaning |
|---|---|
| `CC_PROM_URL`, `CC_GRAFANA_URL`, `CC_HOSTS` | Read from `~/.config/command-center/env` (private overlay) unless set. `CC_GRAFANA_URL` is a dashboard link; the board links from its base. `CC_HOSTS` (default `workstation`) lists machines to show with no runner |
| `NO_COLOR` | Any non-empty value: no colour; bold and the reversed selection stay |
| `COLUMNS` | Width for `--once` (else the terminal's, else 80) |

## Tests

`cargo test` here: the board sections against a fixture Prometheus answer (ported from the old `command_center.bats`), the Jobs table, filters and log cleaning, and whole-screen `TestBackend` renders driven by keys. `tests/rust.sh` runs them in CI. Never drive the TUI on the live tmux server; use an isolated one (`tmux -L <name>`), or the container tier.

## Troubleshooting

| Symptom | Cause and fix |
|---|---|
| No CI job ever shows as running on Jobs | The exporter calls a busy runner `github_runner_state{state="running"}`, and hub-core `jobs/remote.rs` asks for `running` (fixed 2026-11-03) |
| Running Unity gates missing from Jobs, only finished ones | The ledger only gets a row when a gate ends; running gates come from `cc:host_local_gate` (fleet-assess textfile), merged in `jobs::collect` |
| Columns after an emoji row shift by one | A wide character takes two columns; `fit.rs` measures with `unicode-width`, never `chars().count()` |
| `o` opens a 404 like `.../d/kb-ci-runners/d/...` | `CC_GRAFANA_URL` is cut to its base in `hub_core::infra::gather`; an older binary does not. Rebuild |
| "QUERY FAILED" and no machines | Prometheus did not answer or `cc:overall_status` is missing. The board never shows the last numbers after a failed read; check `CC_PROM_URL` and the recording rules in home-config `apps/monitoring/prometheus-rules-command-center.yaml` |
| "unread: ..." under the Jobs status line | That source failed to read (named in the line); the other sources still show |
| "no log kept for this row" | That source keeps no log (Unity gates, k8s until phase 4) |
