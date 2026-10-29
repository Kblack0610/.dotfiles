# agent-web

A web view of the Claude agents running in tmux on this machine. From a phone or another computer you can read any session's transcript or live screen, type into it, press the keys a permission prompt needs, and answer the headless `agent-ask` queue. The board tabs show the tmux hub boards with charts: Watch is `hub:watch` (`Prefix+o`) and Log is `hub:log` (`Prefix+O`).

It reuses agent-panel's library (the pane x `~/.claude/sessions` join, the tmux wrappers), so the web list and the `Prefix+g` chooser always agree on what an agent is.

## How it works

| Piece | Source |
|---|---|
| Agent list | `agent_panel::chooser::collect()` |
| Transcript | `~/.claude/projects/<cwd>/<session>.jsonl`, paged by byte offset from the end (`src/transcript.rs`) |
| Live screen | `tmux capture-pane` on the agent's own pane id |
| Typing | `load-buffer` + `paste-buffer -p` (bracketed paste, so a newline does not submit early), then `Enter` |
| Keys | a fixed list: Enter, Escape, arrows, Tab, Space, 1-9. No `C-c`/`C-d` |
| Waiting tab | each `waiting` or `idle` session's open question, read from the end of its transcript (`transcript::pending_question`): an AskUserQuestion dialog with its options, a tool waiting on permission, or its last message. Answers go through Typing/Keys into that session's pane, so they land in the conversation that asked; a typed reply to a dialog sends Escape first |
| Asks | below the sessions on the same tab: `agent-ask list --all --pending` and `agent-ask answer`, for headless runs only (an attended session asks in its conversation) |
| Watch tab | `~/.local/state/fleet/state.json` (written by `fleet-sessions --write`) and the last 1500 lines of `~/.agent/shepherd/watch.log`, parsed in `src/boards.rs`: bucket tiles, a 24h swimlane per session, a card per session, and the change feed. It reads what the `hub:watch` board writes and judges nothing itself |
| Log tab | `day-log`'s records in `~/.agent/daylog/<date>.json` (or `$DAYLOG_DIR`): `/api/log?date=` returns a day's record as written, `/api/log/history?days=` one summary row per day (merged per area, repos, the `usage` TOTAL row), at most 120 days. Tiles, merged per day stacked by area, spend per day, merged by hour, spend by project, what waits on you, merged PRs by area and group with the session that landed each, open PRs, the bench sessions and the timeline. Click a bar or press `[` `]` to change day, `t` for today |
| Live updates | inotify on `~/.claude/sessions`, `~/.claude/projects`, `~/.agent/asks`, `~/.local/state/fleet`, `~/.agent/shepherd` and `~/.agent/daylog`, pushed over SSE. Nothing polls |

The board tabs are `static/*.js`, compiled in with `include_str!` and served at `/static/<name>` behind sign-in. Each registers `TABS.<name> = { show(), onEvent(ev) }`; the page calls `show` when the tab opens and passes every SSE message to `onEvent`. `static/charts.js` holds the shared pieces (swimlanes, column charts, the hover tooltip, meters, bucket and series colours). A tab can be opened directly with `#watch` or `#log`.

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

The static files are compiled in, so restart the instance after editing one.
