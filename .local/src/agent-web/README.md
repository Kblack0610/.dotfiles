# agent-web

A web view of the Claude agents running in tmux on this machine. From a phone or another computer you can read any session's transcript or live screen, type into it, press the keys a permission prompt needs, and answer the headless `agent-ask` queue. The board tabs show the tabs of the tmux hub board (`hub:board`) with charts: Watch is its Sessions tab (`Prefix+o`), Log its Today and History tabs (`Prefix+O`), Infra its Overview (`Prefix+i`), and Jobs lists every job that runs on its own, with its log.

It reuses agent-panel's library (the pane x `~/.claude/sessions` join, the tmux wrappers), so the web list and the `Prefix+g` chooser always agree on what an agent is.

## How it works

| Piece | Source |
|---|---|
| Queue tab (the front page) | agent-queue, the one intake for agent work (`~/.config/agentctl/QUEUE.md`), and the only writer of `~/.agent/queue`, so every route shells out to it with plain arguments (`src/queue.rs`): `GET /api/queue` is `agent-queue list --json --state all` (active items plus today's finished ones), `POST /api/queue` is `add --from human` with the task on stdin (a plan item starts its session at once, inside agent-queue), `/api/queue/cancel` and `/api/queue/bump` are `cancel` and `bump`, and `/api/queue/projects` is the names in `project-map.json`. agent-queue's stderr comes back as the 400 the page shows. Sections: Waiting for you, Running, Up next (with why an item waits), Done today; a running item's Open session button finds its pane by tmux session name |
| Agent list | hub-core `session_actions::gather`: `agent_panel::chooser::collect_all()` (the live agents plus a row per `claude-acct park` ledger in `~/.agent/parked`, the sessions you are attached to first), each with its account (the claude's `CLAUDE_CONFIG_DIR` named by `~/.config/claude-acct/accounts`), plan slug, pending ask, and the agent-queue item that started it (`agent-queue list --json`) |
| Session actions | `POST /api/session/<target>/<action>` (target URL-encoded, body `{"account": "..."}` for move) runs hub-core `session_actions`, which maps each action to the command that owns it: interrupt is Escape into the pane, park/unpark/move are `claude-acct park`/`unpark`/`move --to`, stop types `/exit` and then kills the window, cancel is `agent-queue cancel <slug>` (offered only for a session a queue item started). It refuses a target that is not a live or parked session and an account not in the accounts file; the command's stderr comes back as the 400. `GET /api/session-options` gives the page each action's confirm text and the account names. Every button arms a confirm in the page first; a parked row offers only unpark and reads only its transcript |
| Transcript | `~/.claude/projects/<cwd>/<session>.jsonl`, paged by byte offset from the end (`src/transcript.rs`), for a live or a parked session |
| Live screen | `tmux capture-pane` on the agent's own pane id |
| Typing | `load-buffer` + `paste-buffer -p` (bracketed paste, so a newline does not submit early), then `Enter` once the pane has drawn the paste, since Claude Code drops an Enter sent right behind one |
| Keys | a fixed list: Enter, Escape, arrows, Tab, Space, 1-9. No `C-c`/`C-d` |
| Waiting tab | each `waiting` or `idle` session's open question, read from the end of its transcript (`transcript::pending_question`): an AskUserQuestion dialog with its options, a tool waiting on permission, or its last message. Answers go through Typing/Keys into that session's pane, so they land in the conversation that asked; a typed reply to a dialog sends Escape first |
| Shepherd tab | `/api/shepherd` (`src/shepherd.rs`): the pane holding the shepherd lease (the agent tagged `shepherd`, set by agent-panel only while the lease is live) and the newest 60 records from `~/.agent/shepherd/rundowns/` (`hub_core::boards::rundowns`), one per rundown or chat answer the shepherd kept with `fleet-shepherd log --rundown`. The page lists them newest first beside a chat: that session's transcript, text only, and a box that types into its pane through `/api/send` |
| Asks | below the sessions on the same tab: `agent-ask list --all --pending` and `agent-ask answer`, for headless runs only (an attended session asks in its conversation) |
| Watch tab | `~/.local/state/fleet/state.json` (written by `fleet-sessions tick` from `fleet-state.timer`, and by `--write`) and the last 1500 lines of `~/.agent/shepherd/watch.log`, parsed in hub-core `src/boards.rs`, the same reader as the hub Sessions tab: bucket tiles, a 24h swimlane per session, a card per session (its task, last action, where its time went, the PRs it opened or merged), and the change feed. It judges nothing itself |
| Log tab | `day-log`'s records in `~/.agent/daylog/<date>.json` (or `$DAYLOG_DIR`): `/api/log?date=` returns a day's record as written, `/api/log/history?days=` one summary row per day (merged per area, repos, the `usage` TOTAL row), at most 120 days. Tiles, merged per day stacked by area, spend per day, merged by hour, spend by project, what waits on you, merged PRs by area and group with the session that landed each, open PRs, the bench sessions and the timeline. Click a bar or press `[` `]` to change day, `t` for today |
| Infra tab | `/api/infra` (`src/infra.rs`) runs hub-core's `infra::gather` (the same reader as `hub`) (`curl -m 10`) and caches the answer for 30s. The endpoints are `CC_PROM_URL` and `CC_GRAFANA_URL` from `~/.config/command-center/env`, which the unit loads as its EnvironmentFile. Claude accounts reads `claude_account_*`, which `claude-acct textfile` publishes every 15 minutes. Done today reads `github_runs_by_hour`, `github_run_failed` (home-config's github-runner-exporter) and `fleet_local_gate_by_hour`, `fleet_local_gate_failed` (`fleet-assess`, from the run ledger): tiles from local midnight and the failed runs with links. Recent runs is `github_actions_run_recent` and its `_duration_seconds`, the exporter's last runs per repo. Trends (runs per hour, the 24h status lanes, queue and busy over time) are Grafana's `kb-ci-runners` and `kb-command-center`, linked from the tab, not redrawn. Machines reads `cc:host_core_busy_ratio` for one bar per core, and lists what each machine carries: CI runners as running/online plus the ones the governor withholds (`github_runner_withheld`) as held, the workstation's local Unity gates as busy/slots; machines with runners sort first, and hovering the runners cell lists each runner's cores. Running shows the cores each job uses from `cc:runner_cores_busy` (home-config `roles/ci-runner-cpu`), out of its pinned CPUs or else the machine's, amber past half the machine. Pools counts withheld runners as held, not slots. A failed read shows the error, never the last numbers. The open tab re-reads every 60s, the board's cadence, because Prometheus has no push |
| Jobs tab | `/api/jobs` (`src/jobs.rs`) is hub-core's `jobs::collect` (`.local/src/hub-core`): agentctl runners from `~/.local/state/agentctl/runs.jsonl` (one line per run, written by `agentctl report --lifecycle stop`) plus the running units, other user timers from the journal's start/finish records, the Unity gate ledger, CI from the exporter (busy runners, waiting jobs, recent runs) and k8s CronJob Jobs from kube-state-metrics. A runner or timer that ran more than once in the window shows its latest run and every failure; `?name=` lists all of one job's runs, `?source=` one source, `?window=` seconds back (at most 7 days). The plain list is cached 15s. `/api/jobs/log?ref=` takes a row's own `log` object and returns its text: a runner's byte range of its stdout/stderr logs, a journald invocation, a finished GitHub run's failed steps (`gh run view --log-failed`, fetched once and kept under `~/.cache/hub/gh/`), or a k8s Job's pod lines from Loki (`hub_core::jobs::loki`). Every field of the reference is checked before it becomes a path or an argument: one that does not parse is a 400, one that fails a check or cannot be read a 502 |
| Live updates | inotify on `~/.claude/sessions`, `~/.claude/projects` and each project dir (not below it), `~/.agent/asks`, `~/.agent/queue` (recursive, created if missing), `~/.local/state/fleet`, `~/.agent/shepherd`, `~/.agent/shepherd/rundowns` (created if missing) and `~/.agent/daylog`, pushed over SSE. Nothing polls. A path it cannot watch is logged and retried (10 s, doubling to 5 min); until then the header says "live updates off" |

The board tabs are `static/*.js`, compiled in with `include_str!` and served at `/static/<name>` behind sign-in. Each registers `TABS.<name> = { show(), onEvent(ev) }`; the page calls `show` when the tab opens and passes every SSE message to `onEvent`. `static/charts.js` holds the shared pieces (swimlanes, column charts, the hover tooltip, meters, bucket and series colours). A tab can be opened directly with `#watch`, `#log`, `#infra` or `#jobs`.

Only a target that is a live agent right now accepts input, so the API cannot be aimed at an arbitrary pane.

## Auth

The page can type into live sessions, so a network allowlist is not enough. A signed-out visit shows one button, Sign in with Forgejo. It starts the OAuth2 authorization-code flow against your Forgejo; if the browser already has a Forgejo session there is nothing to type, otherwise Forgejo shows its own login form (which Bitwarden already fills).

On return agent-web exchanges the code for the user's Forgejo login and checks it against an allowlist (`AGENT_WEB_ALLOWED_USERS`, default `kblack0610`). A match gets an opaque session id in an HttpOnly cookie, valid 90 days. Sessions are stored in `~/.config/agent-web/sessions.json` (0600), so a restart signs nobody out. `POST /logout` revokes the session. `/healthz` is the only route that needs no session.

| Setting | Where | Default |
|---|---|---|
| OAuth client id and secret | `~/.config/agent-web/oauth.json` (0600), also kept in the Bitwarden vault | none, agent-web will not start without it |
| `AGENT_WEB_FORGEJO_URL` | env, Forgejo base URL | required |
| `AGENT_WEB_BASE_URL` | env, the URL agent-web is served at; the OAuth callback is `<base>/oauth/callback` | required |
| `AGENT_WEB_ALLOWED_USERS` | env, comma separated Forgejo logins | `kblack0610` |

To recreate the OAuth app: Forgejo -> Settings -> Applications -> OAuth2, confidential client, redirect URI `<base>/oauth/callback`, then write `{"client_id": ..., "client_secret": ...}` to `oauth.json`.

The two Forgejo calls (token exchange, `GET /api/v1/user`) run through `curl` with the secret on stdin, so no HTTP client library is linked in.

## Run

```sh
cargo build --release      # the dotfiles installer does this (build_local_rust_tools)
systemctl --user enable --now agent-web   # unit lives in the private overlay
```

`AGENT_WEB_ADDR` sets the listen address (default `0.0.0.0:8790`). The cluster ingress that fronts it is defined in home-config `apps/agents`.

## Test

```sh
cargo test && cargo clippy --all-targets -- -D warnings
```

To look at a change without touching the live service, run a second instance against a throwaway config dir with a hand-made session, then open `http://127.0.0.1:8799/#watch` with the cookie `agent_web=dev`:

```sh
d=$(mktemp -d); mkdir -p $d/agent-web
echo '{"client_id":"x","client_secret":"x"}' > $d/agent-web/oauth.json
echo '{"dev":{"user":"me","expires":4102444800}}' > $d/agent-web/sessions.json
XDG_CONFIG_HOME=$d AGENT_WEB_ADDR=127.0.0.1:8799 AGENT_WEB_FORGEJO_URL=http://x AGENT_WEB_BASE_URL=http://127.0.0.1:8799 ./target/debug/agent-web
curl -s -b agent_web=dev 127.0.0.1:8799/api/watch | jq '.state.sessions | length'
```

To render the Watch tab from a chosen `state.json`, also set `HOME=$d` and put the file at `$d/.local/state/fleet/state.json`. agent-web then watches under that home; without `$d/.claude/sessions` and `$d/.claude/projects` it logs "cannot watch" and the header says live updates are off.

The static files are compiled in, so restart the instance after editing one.

## Troubleshooting

| Symptom | Cause | Fix |
| --- | --- | --- |
| Header says "live updates off"; the log has `cannot watch ...: OS file watch limit reached` | The user's inotify watches (`fs.inotify.max_user_watches`) are used up by another program. On 2026-11-03 it was Unity's ILPP runner watching a Unity project checkout whose `.git` held 1.5M empty LFS dirs. Raising the limit does not help: a recursive watcher takes the new room too | Find the holder: for each pid, count the `inotify` lines in `/proc/<pid>/fdinfo/<fd>` of its `anon_inode:inotify` fds. Free watches at the source; agent-web picks them up on its next retry, no restart |
