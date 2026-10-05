# agent-web

A web view of the Claude agents running in tmux on this machine. From a phone or another computer you can read any session's transcript or live screen, type into it, press the keys a permission prompt needs, and answer the headless `agent-ask` queue.

It reuses agent-panel's library (the pane x `~/.claude/sessions` join, the tmux wrappers), so the web list and the `Prefix+g` chooser always agree on what an agent is.

## How it works

| Piece | Source |
|---|---|
| Agent list | `agent_panel::chooser::collect()` |
| Transcript | `~/.claude/projects/<cwd>/<session>.jsonl`, paged by byte offset from the end (`src/transcript.rs`) |
| Live screen | `tmux capture-pane` on the agent's own pane id |
| Typing | `load-buffer` + `paste-buffer -p` (bracketed paste, so a newline does not submit early), then `Enter` |
| Keys | a fixed list: Enter, Escape, arrows, Tab, Space, 1-9. No `C-c`/`C-d` |
| Asks | `agent-ask list --all --pending` and `agent-ask answer` |
| Live updates | inotify on `~/.claude/sessions`, `~/.claude/projects` and `~/.agent/asks`, pushed over SSE. Nothing polls |

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
