# tmux worlds

A world is a tmux server on its own socket. The `.conf` files here are the only routing table: `tmux-world` (`.local/src/tmux/worlds.sh`) reads them, and every opener asks it. A script that needs a server name calls `tmux-world`, it never writes one down.

## Which world gets what

| What | World | Why |
|---|---|---|
| The human's home and config repos on their base checkout: notes, dotfiles, home-config | hub | named in `hub.conf` |
| Any other repo nothing claims | hub | `@repos` in `hub.conf` |
| The shepherd's pass | hub | window `hub:shepherd`, owned by `fleet-shepherd run`, not declared in `hub.conf`: each pass replaces the last in that pane, so a run makes no window there; it closes any other pane a pass ran in and renames any other `shepherd` window, so there is never a second one |
| Game checkouts, unity-core-playground first | hub | named in `hub.conf`, or the bare `@repos` |
| Every worktree session, `<repo>-agent-N`: Prefix+F, `wt new`, `wt pick`, and `fleet-dispatch` | lab | `@agents` in `lab.conf`; only main checkouts sit in hub (2026-11-12, the human: "all agent sessions go to lab, just main dirs go to hub") |

Lab declares no repo and has no landing page, so `tmx root lab` resumes the worktree session you were last in.

The first matching rule wins:

1. A directory a manifest names: that world, under the manifest's session name.
2. Anywhere inside a linked worktree: the `@agents` world, whichever repo it was cut from, under the worktree's own name.
3. Any other directory: the deepest enclosing `@repos <dir>`, else the bare `@repos`.
4. Nothing matched: `here`, the caller's own world.

A repo's world does not reach its worktrees: `dotfiles` is on hub, and every `dotfiles-agent-N`, started by hand or dispatched, is on lab.

## Add a repo

- Its own session in a world: add `<name> <dir>` to that world's `.conf`. Prefix `?` to keep it from booting with the world.
- A whole directory of repos: add `@repos <dir>` to the world that owns them.
- Nothing to do for a home, config or game repo (the bare `@repos` takes it), or for a worktree (lab).

Check a directory with `tmux-world route <dir>`. It reads the manifests only, so the answer is the same whether the world is up or not.

The line format is at the top of `hub.conf`. A world listed in `hidden` on this machine declares nothing here, so what it names opens where you are. Work worlds live in the private repo beside these files.

## Who opens what

| Opener | How it routes |
|---|---|
| Prefix+f, `sessionizer.sh <dir>` | `world_route` |
| Prefix+F, `wt new`, `wt pick` | `@agents` (lab), inside tmux or out; a session already live on another server stays there; `--server` overrides |
| `tmx ensure <world> <session>`, `tmx goto <world> <session>` | the world that declares the session, whichever was named |
| `fleet-dispatch start` | `@agents` (lab); `--server` is for `--resume` only, to put a session back where it was |
| `agent-queue add --running` | records its session on any world when it is a worktree session (`<repo>-agent-N`); a checkout session such as hub:dotfiles holds many conversations and records none |
| `fleet-shepherd` | the world that declares its session |
| Prefix+R, `sessions resume --window` | `tmux-world route` on the session's directory |

An item's `session:` is always `<server>:<session>`. `agent-queue cancel` and the dispatch reap act on what it names, so a hand start from a declared session such as `hub:dotfiles` records nothing. Such an item closes with `agent-land <N> --item <slug>`. Automation closes through `tmux-close`, which never kills a session a manifest declares.

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `fleet-dispatch: start: no world declares @agents` | the `@agents` world is in `hidden`, or the line is gone | put it back or unhide that world; dispatch will not guess |
| `tmux-world: command not found` after a pull | the link in `~/.local/bin` is per file | `dotfiles-deploy --apply` |
| A work repo opens on hub | the catch-all took it | add `@repos <dir>` to the work world's manifest |
| A `shepherd` server or session still up | left from when passes had their own world (2026-11-04 to 2026-11-05) | `tmux -L shepherd kill-server` and `tmux -L hub kill-session -t =shepherd` once no pass there is talking to you; nothing reads them, and Prefix o goes to `hub:shepherd` |
| A playground or platform main-checkout session still up on lab after the 2026-11-11 world split | those repos are declared on hub now, so `tmx ensure` or Prefix+f makes a second one there | close the lab one (`tmux -L lab kill-session -t =<name>`) once nothing in it is live |
| A `<repo>-agent-N` you started by hand still on hub | started between 2026-11-11 and 2026-11-12, when hand-started worktrees followed their repo | finish it there and `wt done`; reach it with `wt pick`, which keeps a live session where it is. Prefix+f or an ask reopen would make a second session for it on lab |
