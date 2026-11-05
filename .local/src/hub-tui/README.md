# hub-tui

`hub`, every hub board as one terminal app (ratatui) with a tab per board. It runs in the `hub:board` window (declared in `.config/tmux-servers/hub.conf`); tmux Prefix i and O land on its Home and Today tabs, and the waybar load, CI and day chips open it on click. It reads through `hub-core`, the same crate agent-web's tabs use, so the terminal and the browser cannot disagree. It reads only, except the Fleet tab's session controls, which act on a session through `hub_core::session_actions` (the same actions as agent-web's session buttons), the Queue tab's cancel and priority keys, which run `agent-queue` through `hub_core::queue` (the same calls as agent-web's queue buttons), and the Board tab's add, start, done, drop, move, edit, release and open-sheet keys, which run `notes ptask --exact` through `hub_core::tasks` (the same calls as agent-web's Board tab). Trends live in Grafana; `o` opens the dashboard for the tab you are on.

Install: the installer's `build_local_rust_tools` builds it and links `~/.local/bin/hub`. By hand: `cargo build --release` here, then `ln -sf "$PWD/target/release/hub" ~/.local/bin/hub`.

## Usage

```
hub                              the board, on the Home tab
hub --tab fleet                  start on another tab (home, queue, jobs, ci, machines, forecast, today, history, fleet, board; a retired name such as overview lands on its new tab)
hub tab today                    ask the running hub to switch tab (the next hub to start takes it when none runs)
hub tab board bnb/demo           the same, with a Board search: one project's rows (what Prefix+P Enter sends)
hub --once                       print Home, Machines and CI as plain text at $COLUMNS, then exit
hub --once --tab jobs            print one tab; exit 1 when Prometheus did not answer
```

The tmux keys run `hub tab <name>; tmx goto hub hub:board`. The running hub listens on `~/.local/state/hub/tab.sock` and switches when the request arrives, with no file watch involved. When no hub is listening, the request is left in `~/.local/state/hub/tab`, `tmx goto` rebuilds the window, and the new hub starts on that tab. Only the first hub binds the socket; a second one still works by its keys.

## Tabs

A new tab or section follows `../docs/dashboards.md` (the dashboard standards, and the layout both hub surfaces are moving to).

| Tab | What it shows | Grafana (`o`) |
|---|---|---|
| 1 Home | `hub_core::home`, the reader agent-web's Home uses too. NEEDS YOU: pending asks, sessions waiting on a dialog, queue items waiting on you, a red nightly on main and what `cc:red_now` lists, one row per tmux session (an ask stands for its session and its queue item), oldest first. RUNNING: the queue's running items with plan phase done/total, next phase and ETA (amber `late` once past it). NUMBERS: the queue (running, up next, held), done today, sessions by bucket, Claude spend in 24h. HEALTH: one chip per domain from `cc:domain_status`; all green is one line, otherwise only the chips that are not green. Under them, until the Infra tab takes them: CI busy/slots, POOLS, RUNNING jobs, the queue by pool, DOWN and the finished headline | `kb-command-center` |
| 2 Queue | `hub_core::queue`, the same reader as agent-web's Queue tab: `agent-queue list --json --state all` and `agent-queue stats --json`, never the store's files. The week's line (done by outcome, with a PR, the wait median and p90 over items that waited plus how many started at once, the time-to-PR median) and the sitting line (how many queued items could start now, the oldest with its slug and the median age, and how many are held by kind), both worded by `hub_core::queue::Stats` so agent-web prints the same text, then Waiting for you, Running, Up next and Done today, each item with its priority, project, mode, when it was queued, started or finished, its session, hold, or outcome and PR, and the task's first line. `j`/`k` pick an active item, `c` cancels it (`agent-queue cancel`, after `y`), `+`/`-` move its priority a step (`agent-queue bump`). Read on start (the Overview counts it), on entering, on `r`, after an action, and when an item file under `$AGENT_QUEUE_DIR` (default `~/.agent/queue`) is written | - |
| 3 Jobs | Every job `hub_core::jobs::collect` finds: agentctl runners (the run ledger), user timers (journald), Unity gates (the ledger plus running gates from `cc:host_local_gate`), CI and k8s from Prometheus. Queued, running and done with start, duration and result; Enter opens the log under the list. A k8s Job's log is its pods' lines in Loki, read through the API server's service proxy (`kubectl get --raw`, cluster `CC_KUBE_CONTEXT`, service `CC_LOKI_SERVICE`), so Loki needs no ingress and no token | `kb-ci-runners` |
| 4 CI | Finished runs per workflow with failures, then the recent runs list | `kb-ci-runners` |
| 5 Machines | One row per machine: CPU now and over 6h, load per core, memory, temperature, slots per pool. Machines with no runner show when named in `CC_HOSTS` | `kb-fleet` |
| 6 Forecast | `fleet-bench forecast`, `vs` and `flow` (`--json`): the all-done-by band (median, p90, last at p50 and slow), the drain (highlighted when not draining), the queue and the unscheduled count, a phase timeline per session out to the last slow finish (late ones marked), the burn-up of scope against done per hour, and the frozen baseline against what happened since. Read on the 60s tick while the tab is shown | - |
| 7 Today | The day-log record (`~/.agent/daylog/<date>.json`, `day-log.timer` every 5 minutes): waiting on you, merged, still open, sessions bench, timeline, spend. `[`/`]` step a day, `t` back to today | - |
| 8 History | One row per recorded day: merges, repos, sessions, cost, areas. Enter opens that day on Today | - |
| 9 Fleet | The agent sessions, then the machinery that runs them. First the session controls: every live agent session and every `claude-acct park` ledger whose session has no live claude (`hub_core::session_actions::gather`), the ones you are attached to first, with the account, plan, pending ask and the agent-queue item that started it. A key arms an action and a confirm line says what it will do; nothing runs until `y`. Each action is the command that owns it: interrupt is Escape into the pane, park, unpark and move are `claude-acct`, stop types `/exit` then closes the window, cancel is `agent-queue cancel` (only for a session a queue item started), approve-plan presses the plan dialog's "Yes, auto-accept edits" digit (only while the pane shows that dialog; STATE then reads `plan ready`). A parked row offers only unpark. The list is read on entering the tab, on `r`, after an action and on the 60s tick while it is shown. Below it, every agent session's stages (sync, conflicts, tree, PR, CI, plan phases, ETA, bucket, idle, why) from `~/.local/state/fleet/state.json`, the open asks, and the newest changes from `~/.agent/shepherd/watch.log`. `fleet-state.timer` writes both every minute (`fleet-sessions tick`). Below the sessions, `hub_core::fleet::collect`, the same reader as agent-web's Fleet tab: the Claude accounts (claude-acct's textfile in Prometheus), one row per agentctl runner in `~/.config/agentctl/agents/*.conf` (last outcome and when, runs and failures in 24h from the run ledger, the last "why" from `activity.log`, the next timer fire, dollars in 24h by the `agentctl_runner` OTel label), the dispatch judge (`~/.agent/dispatch/verdicts.jsonl` newest 30, counts by verdict for 24h and 7d, starts and reaps from `log.md`) and the answer judge (agree, disagree, deferred, pending and the newest disagreements from the asks). Read on entering, on `r`, on an agentctl ledger write and on the 60s tick while it is shown | - |
| 0 Board | `hub_core::tasks`, the same feed as agent-web's Board tab: `notes board --json`, never the sheets. Every project's open rows (human sheet, agent board, playtest checks) grouped by profile and project, each with its priority, lane, version (the game heading on a playtest check), state and text; each profile's open Focus rows are their own group, read-only (`notes focus` owns the daily note). `/` searches, `l` steps the lane filter, and `a`, `s`, `d`/`D`, `x`/`X`, `m`, `e`, `+`/`-` and `o` add to the selected row's project and lane, start, finish (with a proof, or unverified with why), drop (with why, or the id of the row it duplicates; the row stays on the sheet, ticked, with the reason), move to another project or version, edit the text (tags stay), move a release sooner or later, and open the sheet at the row in a new tmux window. A playtest check takes only add, done and drop. A write passes the row's raw line to `notes ptask --exact`, or for `s` to `fleet-dispatch promote`, which queues the row as an item that waits for the human to be away, so a row edited since the read matches nothing, nothing is written, and the status line shows notes' error. Read on entering, on `r`, after a write and on the 60s tick while shown; the vault has no watch here. `0`, Tab, Shift-Tab or `hub --tab board` | - |

Prometheus pages re-read every 60s (`PROM_REFRESH`; Prometheus has no push). Everything else re-reads when its file is written (inotify; an open is not a write): Jobs on the agentctl state dir and the Unity ledger (CI and k8s on the 60s tick), Fleet's sessions on the fleet state and `watch.log`, Today and History on `~/.agent/daylog/`, Queue and Home's running list and numbers on any `.md` under the queue dir. Forecast has no file to watch: it runs fleet-bench on entering the tab, on `r`, and on the 60s tick while it is shown. Fleet's accounts, runners and judges read the same way, and also when the agentctl ledger is written; the dispatch and ask files have no watch here, so they show on the next tick. When a watch cannot be set (inotify full), the tab bar says "no file watch" and the 60s tick reads those files instead.

## Keys

| Key | Does |
|---|---|
| `1`-`9`, `0`, Tab, Shift-Tab | Switch tab (`0` is the tenth, Board) |
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
| `j`/`k` | Fleet: pick a session (PgUp/PgDn, space and `g`/`G` scroll the page) |
| `i` `p` `u` `m` `x` `c` `a` | Fleet: interrupt, park, unpark, move, stop, cancel, approve the plan of the selected session; each asks first |
| `y`/Enter, `n`/Esc, Left/Right | Fleet, confirm armed: run it, drop it, pick the account a move goes to |
| `j`/`k`, `c`, `+`/`-` | Queue: pick an active item, cancel it (asks first), raise or lower its priority |
| `y`/Enter, `n`/Esc | Queue, cancel armed: run it, drop it |
| `j`/`k`, PgUp/PgDn, space, `g`/`G` | Board: move the selection (the page follows it) |
| `/`, `l`, Esc | Board: search project and text (Enter applies, Esc clears), step the lane filter, clear both |
| `a` | Board: add a row to the selected row's project and lane; `#urgent` or `#low` in the text sets its priority |
| `s`, `d`, `D`, `x`, `X` | Board: queue the selected row, mark it done with a proof (pr:N, a URL), done unverified with why, drop it with why, drop it as a duplicate of an id; not on a Focus row |
| `m`, `e`, `+`, `-` | Board: move the row (a project, a version `vX.Y.Z`, or both, space-separated), edit its text (tags kept), one release sooner, one release later; not on a playtest check or a Focus row |
| `o` | Board: open the row's sheet at its line in `$EDITOR` (one word, else nvim) in a new tmux window |
| `q`, Ctrl-C | Quit |

## Environment

| Variable | Meaning |
|---|---|
| `CC_PROM_URL`, `CC_GRAFANA_URL`, `CC_HOSTS` | Read from `~/.config/command-center/env` (private overlay) unless set. `CC_GRAFANA_URL` is a dashboard link; the board links from its base. `CC_HOSTS` (default `workstation`) lists machines to show with no runner |
| `NO_COLOR` | Any non-empty value: no colour; bold and the reversed selection stay |
| `COLUMNS` | Width for `--once` (else the terminal's, else 80) |
| `AGENT_QUEUE_DIR` | The queue dir to watch, as agent-queue reads it (default `~/.agent/queue`); the items themselves always come from `agent-queue` on PATH |

## Tests

`cargo test` here: the board sections against a fixture Prometheus answer (ported from the old `command_center.bats`), the Jobs table, filters and log cleaning, the Fleet sessions, Today and History pages from fixture records, the Forecast page from real `fleet-bench` answers in `tests/fixtures/`, the Fleet machinery from a fixture `hub_core::fleet::Fleet` (`fleettab.rs`), the Queue page, its keys and the Overview's counts from a fixture `hub_core::queue::Queue` (`queuetab.rs`), the Board page, its filters and the argv of each write from a fixture `hub_core::tasks::Feed` (`tasktab.rs`), `hub tab` over the socket and the request file (`tabreq.rs`), and whole-screen `TestBackend` renders driven by keys. The session controls and the queue's cancel run against a fixture and a fake runner (`controls.rs`, `queuetab.rs`, `app.rs`), so no test reaches tmux, claude-acct, agent-queue or notes. `tests/rust.sh` runs them in CI. Never drive the TUI on the live tmux server; use an isolated one (`tmux -L <name>`), or the container tier.

## Troubleshooting

| Symptom | Cause and fix |
|---|---|
| No CI job ever shows as running on Jobs | The exporter calls a busy runner `github_runner_state{state="running"}`, and hub-core `jobs/remote.rs` asks for `running` (fixed 2026-11-03) |
| Running Unity gates missing from Jobs, only finished ones | The ledger only gets a row when a gate ends; running gates come from `cc:host_local_gate` (fleet-assess textfile), merged in `jobs::collect` |
| Columns after an emoji row shift by one | A wide character takes two columns; `fit.rs` measures with `unicode-width`, never `chars().count()` |
| `o` opens a 404 like `.../d/kb-ci-runners/d/...` | `CC_GRAFANA_URL` is cut to its base in `hub_core::infra::gather`; an older binary does not. Rebuild |
| "QUERY FAILED" and no machines | Prometheus did not answer or `cc:overall_status` is missing. The board never shows the last numbers after a failed read; check `CC_PROM_URL` and the recording rules in home-config `apps/monitoring/prometheus-rules-command-center.yaml` |
| "unread: ..." under the Jobs status line | That source failed to read (named in the line); the other sources still show |
| "no log kept for this row" | That source keeps no log (Unity gates) |
| "CC_KUBE_CONTEXT is not set" or "CC_LOKI_SERVICE is not set" on a k8s log | The cluster and the Loki service come from `~/.config/command-center/env` (private repo): `CC_KUBE_CONTEXT=home-k3s`, `CC_LOKI_SERVICE=monitoring/loki:3100` |
| A k8s log says "kubectl: ..." | The API server refused or timed out (10s guard). `kubectl --context home-k3s get --raw /api/v1/namespaces/monitoring/services/loki:3100/proxy/ready` shows whether Loki answers |
| "Loki has no lines from this Job's pods" | The pod wrote nothing, or Alloy (home-config `apps/alloy`) did not ship it. Loki keeps a year |
| Forecast says "No forecast: ... exit 2, usage" | The `fleet-bench` on PATH has no `forecast`, `vs` or `flow` verb (exit 2 is its usage). Pull the checkout `~/.local/bin/fleet-bench` links to |
| Forecast says "no baseline yet" | `fleet-bench vs` found no frozen forecast: `fleet-bench forecast --baseline <label>` freezes one |
| Fleet says no fleet state, or its changes stop moving | `fleet-state.timer` is not running: `systemctl --user enable --now fleet-state.timer`. The timer builds the log whether or not the tab is open |
| Today is a day behind or empty | `day-log.timer` is not running: `systemctl --user enable --now day-log.timer`; `day-log snapshot` writes one record by hand |
| Prefix o or O lands on the wrong tab | A hub older than the tab socket ignores the request. Rebuild, then `tmux kill-window -t hub:board` and press the key again |
| "hub tab cannot reach this hub (...)" in the tab bar | `tab.sock` would not bind; the reason is in the brackets. A socket path is limited to 108 bytes, so a long `XDG_STATE_HOME` cannot hold one |
| "no file watch (inotify full)" in the tab bar | Every inotify watch is taken. `grep -c '^inotify' /proc/[0-9]*/fdinfo/* 2>/dev/null \| awk -F'[/:]' '{n[$3]+=$NF} END{for(p in n) if(n[p]) print n[p], p}' \| sort -rn \| head -3` prints watches and pid, biggest first; an open Unity Editor's `Unity.ILPP.Runner` can hold nearly all of `fs.inotify.max_user_watches`. Closing it or raising the limit is the human's call. Until then the board re-reads its files every 60s, and agent-web will not start, so do not restart it |
| hub holds 100%+ CPU and a `journalctl --user ... MESSAGE_ID=...` child respawns non-stop | notify asks inotify for opens too, and each jobs read opens the files it watches, so every read woke the next. `is_write` in `app.rs` drops everything but create, modify and remove (fixed 2026-11-03). Rebuild and restart the hub |
| Status chips unreadable (yellow on yellow) | Chips are black text on the status colour, so a theme that maps red and green to light shades still reads; the word (OK, WARN, RED, NODATA) carries the state |
| Queue or Home shows a yellow `agent-queue ...` line | `agent-queue` failed or is not on PATH; the line is its error. The page shows what still read (items without the week line, or the reverse). Run the same `agent-queue list --json --state all` by hand to see it |
| Queue does not move when an item changes | The queue dir did not exist when hub started, so it has no watch on it. `r` reads it; restart hub to watch it |
