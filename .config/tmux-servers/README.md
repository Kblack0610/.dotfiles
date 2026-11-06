# tmux worlds

A world is a tmux server on its own socket. The `.conf` files here are the only routing table: `tmux-world` (`.local/src/tmux/worlds.sh`) reads them, and every opener asks it. A script that needs a server name calls `tmux-world`, it never writes one down.

## Which world gets what

| What | World | Why |
|---|---|---|
| The human's home and config repos on their base checkout: notes, dotfiles, home-config | hub | named in `hub.conf` |
| Any other repo nothing claims | hub | `@repos` in `hub.conf` |
| The shepherd's pass | hub | window `hub:shepherd`, owned by `fleet-shepherd run`, not declared in `hub.conf`: each pass replaces the last in that pane, so no run makes or closes a window there |
| Every agent worktree of every project, `<repo>-agent-N`, whoever started it | lab | `@agents` in `lab.conf` |
| Game checkouts, unity-core-playground first | lab | named in `lab.conf`, or `@repos ~/dev/bnb/games` |

The lab world has no landing page: every entry in `lab.conf` is on demand, so `tmx root lab` resumes the agent session you were last in.

The first matching rule wins:

1. A directory a manifest names: that world, under the manifest's session name.
2. Anywhere inside a linked worktree: the `@agents` world, under its own name, whichever repo it was cut from.
3. Any other directory: the deepest enclosing `@repos <dir>`, else the bare `@repos`.
4. Nothing matched: `here`, the caller's own world.

A repo's world never reaches its worktrees: `dotfiles` is on hub and `dotfiles-agent-3` is on lab.

## Add a repo

- Its own session in a world: add `<name> <dir>` to that world's `.conf`. Prefix `?` to keep it from booting with the world.
- A whole directory of repos: add `@repos <dir>` to the world that owns them.
- Nothing to do for a home or config repo, or for an agent worktree.

Check a directory with `tmux-world route <dir>`. It reads the manifests only, so the answer is the same whether the world is up or not.

The line format is at the top of `hub.conf`. A world listed in `hidden` on this machine declares nothing here, so what it names opens where you are. Work worlds live in the private repo beside these files.

## Who opens what

| Opener | How it routes |
|---|---|
| Prefix+f, `sessionizer.sh <dir>` | `world_route` |
| Prefix+F, `wt new`, `wt pick` | `@agents`, inside tmux or out; `--server` overrides |
| `tmx ensure <world> <session>`, `tmx goto <world> <session>` | the world that declares the session, whichever was named |
| `fleet-dispatch start` | `@agents`; `--server` is for `--resume` only, to put a session back where it was |
| `agent-queue add --running` | records its session only on the `@agents` world |
| `fleet-shepherd` | the world that declares its session |
| Prefix+R, `sessions resume --window` | `tmux-world route` on the session's directory |

An item's `session:` is always `<server>:<session>`. `agent-queue cancel` and the dispatch reap act on what it names, so a hand start from a hub window records nothing. Such an item closes with `agent-land <N> --item <slug>`. Automation closes through `tmux-close`, which never kills a session a manifest declares.

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `fleet-dispatch: start: no world declares @agents` | the `@agents` world is in `hidden`, or the line is gone | put it back or unhide that world; dispatch will not guess |
| `tmux-world: command not found` after a pull | the link in `~/.local/bin` is per file | `dotfiles-deploy --apply` |
| A work repo opens on hub | the catch-all took it | add `@repos <dir>` to the work world's manifest |
| A `shepherd` server or session still up | left from when passes had their own world (2026-11-04 to 2026-11-05) | `tmux -L shepherd kill-server` and `tmux -L hub kill-session -t =shepherd` once no pass there is talking to you; nothing reads them, and Prefix o goes to `hub:shepherd` |
