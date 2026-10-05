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

The page can type into live sessions, so a network allowlist is not enough. On first start it writes a random token to `~/.config/agent-web/token` (0600).

Opening the page without a session shows a sign-in form. The form is a normal password login, so a browser or Bitwarden can save the token and fill it in on the next visit. The token is also kept in the Bitwarden vault (rbw), under the hostname the ingress serves. A correct token sets an HttpOnly, SameSite=Strict cookie that lasts a year. `/?token=<token>` does the same in one step, which is handy for a link or QR code. Scripts can send `Authorization: Bearer <token>`. `/healthz` is the only route that needs no token.

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
