# hub-tui

`hub`, every hub board as one terminal app (ratatui) with a tab per board. It runs in the `hub:board` window (declared in `.config/tmux-servers/hub.conf`); tmux Prefix i, o and O land on its Overview, Sessions and Today tabs, and the waybar load, CI and day chips open it on click. It reads through `hub-core`, the same crate agent-web's tabs use, so the terminal and the browser cannot disagree. Read-only; actions stay in `fleet.sh` (Prefix C-g). Trends live in Grafana; `o` opens the dashboard for the tab you are on.

Install: the installer's `build_local_rust_tools` builds it and links `~/.local/bin/hub`. By hand: `cargo build --release` here, then `ln -sf "$PWD/target/release/hub" ~/.local/bin/hub`.

## Usage

```
hub                              the board, on the Overview tab
hub --tab sessions               start on another tab (overview, jobs, ci, machines, sessions, today, history)
hub tab today                    ask the running hub to switch tab (the next hub to start takes it when none runs)
hub --once                       print Overview, Machines and CI as plain text at $COLUMNS, then exit
hub --once --tab jobs            print one tab; exit 1 when Prometheus did not answer
```

The tmux keys run `hub tab <name>; tmx goto hub hub:board`. The running hub listens on `~/.local/state/hub/tab.sock` and switches when the request arrives, with no file watch involved. When no hub is listening, the request is left in `~/.local/state/hub/tab`, `tmx goto` rebuilds the window, and the new hub starts on that tab. Only the first hub binds the socket; a second one still works by its keys.

## Tabs

| Tab | What it shows | Grafana (`o`) |
|---|---|---|
| 1 Overview | Header (overall status, CI busy/slots, waiting), POOLS, RUNNING (longest first, amber past an hour), the queue grouped by pool, repo, PR and branch (8 groups, then a "+N more" hint), DOWN (offline or missing runners, stuck runs, GitHub API failing), the finished headline and what is red now | `kb-command-center` |
| 2 Jobs | Every job `hub_core::jobs::collect` finds: agentctl runners (the run ledger), user timers (journald), night shift, Unity gates (the ledger plus running gates from `cc:host_local_gate`), CI and k8s from Prometheus. Queued, running and done with start, duration and result; Enter opens the log under the list | `kb-ci-runners` |
| 3 CI | Finished runs per workflow with failures, then the recent runs list | `kb-ci-runners` |
| 4 Machines | One row per machine: CPU now and over 6h, load per core, memory, temperature, slots per pool. Machines with no runner show when named in `CC_HOSTS` | `kb-fleet` |
| 5 Sessions | Every agent session's stages (sync, conflicts, tree, PR, CI, plan phases, ETA, bucket, idle, why) from `~/.local/state/fleet/state.json`, the open asks, and the newest changes from `~/.agent/shepherd/watch.log`. `fleet-state.timer` writes both every minute (`fleet-sessions tick`) | - |
| 6 Today | The day-log record (`~/.agent/daylog/<date>.json`, `day-log.timer` every 5 minutes): waiting on you, merged, still open, sessions bench, timeline, spend. `[`/`]` step a day, `t` back to today | - |
| 7 History | One row per recorded day: merges, repos, sessions, cost, areas. Enter opens that day on Today | - |

Prometheus pages re-read every 60s (`PROM_REFRESH`; Prometheus has no push). Everything else re-reads when its file is written (inotify; an open is not a write): Jobs on the agentctl state dir, `~/.agent/night` and the Unity ledger (CI and k8s on the 60s tick), Sessions on the fleet state and `watch.log`, Today and History on `~/.agent/daylog/`. When a watch cannot be set (inotify full), the tab bar says "no file watch" and the 60s tick reads those files instead.

## Keys

| Key | Does |
|---|---|
| `1`-`7`, Tab, Shift-Tab | Switch tab |
| `r` | Re-read now |
| `o` | Open this tab's Grafana dashboard (on Jobs: the selected row's URL) |
| `j`/`k`, PgUp/PgDn, space, `g`/`G` | Scroll a page; on Jobs, move the selection |
| `s` / `f` | Jobs: cycle the source / state filter |
| `/` | Jobs: search name, detail, result and source (Enter applies, Esc cancels) |
| `h` | Jobs: every run of the selected job, unfolded (again to go back) |
| Enter | Jobs: open the selected row's log (follows the tail) |
| `J`/`K`, PgUp/PgDn | Jobs, log open: scroll the log |
| Esc | Jobs: close the log, then history, then clear the filters |
| `[` / `]`, `t` | Today: the day before / after, back to today |
| `n` / `N` | Today: the next / previous section |
| `j`/`k`, Enter | History: pick a day, open it on Today |
| `q`, Ctrl-C | Quit |

## Environment

| Variable | Meaning |
|---|---|
| `CC_PROM_URL`, `CC_GRAFANA_URL`, `CC_HOSTS` | Read from `~/.config/command-center/env` (private overlay) unless set. `CC_GRAFANA_URL` is a dashboard link; the board links from its base. `CC_HOSTS` (default `workstation`) lists machines to show with no runner |
| `NO_COLOR` | Any non-empty value: no colour; bold and the reversed selection stay |
| `COLUMNS` | Width for `--once` (else the terminal's, else 80) |

## Tests

`cargo test` here: the board sections against a fixture Prometheus answer (ported from the old `command_center.bats`), the Jobs table, filters and log cleaning, the Sessions, Today and History pages from fixture records, `hub tab` over the socket and the request file (`tabreq.rs`), and whole-screen `TestBackend` renders driven by keys. `tests/rust.sh` runs them in CI. Never drive the TUI on the live tmux server; use an isolated one (`tmux -L <name>`), or the container tier.

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
| Sessions says no fleet state, or its changes stop moving | `fleet-state.timer` is not running: `systemctl --user enable --now fleet-state.timer`. The timer builds the log whether or not the tab is open |
| Today is a day behind or empty | `day-log.timer` is not running: `systemctl --user enable --now day-log.timer`; `day-log snapshot` writes one record by hand |
| Prefix o or O lands on the wrong tab | A hub older than the tab socket ignores the request. Rebuild, then `tmux kill-window -t hub:board` and press the key again |
| "hub tab cannot reach this hub (...)" in the tab bar | `tab.sock` would not bind; the reason is in the brackets. A socket path is limited to 108 bytes, so a long `XDG_STATE_HOME` cannot hold one |
| "no file watch (inotify full)" in the tab bar | Every inotify watch is taken. `grep -c '^inotify' /proc/[0-9]*/fdinfo/* 2>/dev/null \| awk -F'[/:]' '{n[$3]+=$NF} END{for(p in n) if(n[p]) print n[p], p}' \| sort -rn \| head -3` prints watches and pid, biggest first; an open Unity Editor's `Unity.ILPP.Runner` can hold nearly all of `fs.inotify.max_user_watches`. Closing it or raising the limit is the human's call. Until then the board re-reads its files every 60s, and agent-web will not start, so do not restart it |
| hub holds 100%+ CPU and a `journalctl --user ... MESSAGE_ID=...` child respawns non-stop | notify asks inotify for opens too, and each jobs read opens the files it watches, so every read woke the next. `is_write` in `app.rs` drops everything but create, modify and remove (fixed 2026-11-03). Rebuild and restart the hub |
| Status chips unreadable (yellow on yellow) | Chips are black text on the status colour, so a theme that maps red and green to light shades still reads; the word (OK, WARN, RED, NODATA) carries the state |
