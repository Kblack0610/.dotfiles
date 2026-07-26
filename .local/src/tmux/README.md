# Tmux Integration Scripts

Scripts for tmux session management, agent orchestration, and productivity workflows.

## Scripts

| Script | Keybinding | Description |
|--------|------------|-------------|
| `launcher.sh` | `Prefix+l` | Master menu for all tmux operations |
| `sessionizer.sh` | `Prefix+f` | Fast project directory switcher with fzf |
| `servers.sh` (`tmx`) | `Prefix+C-s` / `C-h` / `C-l` | Server layer: pick a world, or hop to hub / lab |
| `sesh` (Go, AUR `sesh-bin`) | `Prefix+S` | Session picker, scoped to the current server. Config: `../../.config/sesh/` |
| `agent-panel` (Rust) | `Prefix+g` / `Prefix+G` | View/select Claude agent windows (`G` = jump to next needing attention). Cross-platform binary; see `../agent-panel/`. |
| `agent-starter.sh` | `Prefix+e` | Spawn new Claude agent in a directory |
| `spawn-project.sh` | `Prefix+p` | Create new tmux session with nvim |
| `favourites.sh` | `Prefix+s` / `Prefix+o` | Star a claude/opencode chat; reopen & resume it later |
| `claude-status.sh` | Status bar | Shows Claude agent status in tmux status line |

## Usage

All scripts are bound to tmux keybindings via `~/.tmux.conf`.

### Quick Reference

- **Switch world**: `Prefix+C-h` hub · `Prefix+C-l` lab · `Prefix+C-s` picker
- **Switch session**: `Prefix+S` → sessions of the current world only
- **Switch projects**: `Prefix+f` → fuzzy find directories
- **Launch menu**: `Prefix+l` → unified launcher
- **Start agent**: `Prefix+e` → spawn Claude in directory
- **View agents**: `Prefix+g` → choose active agent windows
- **Favourite a chat**: `Prefix+s` → star the agent in the current pane
- **Reopen a chat**: `Prefix+o` → pick a favourite, resume the conversation

## Servers (`Prefix+C-s`, `tmx`)

The layer **above** sessions. tmux has four:

```
server   one per SOCKET   <- servers.sh / tmx
  session   daily, platform, ...
    window
      pane
```

Everything used to live in one server on the default socket, which made the
sessions siblings in a single process rather than separate systems - so one
`tmux kill-server` took out all of them at once. Each world now owns a socket, and
the blast radius of a kill is exactly one server.

Two worlds, deliberately:

| Server | Sessions | Lands on |
|---|---|---|
| `hub` - personal | **daily**, dotfiles, home-config | today's daily note |
| `lab` - building | **projects**, platform | `~/.notes/lab/projects/index.md` |

Declared in `../../.config/tmux-servers/<name>.conf`, one
`<name> <dir> [startup command...]` per line. **The first entry is the landing
session**, so hopping to hub puts you in today's note rather than a bare shell.

`tmx ensure` creates only what is **missing**, keyed on session name - never
renames, moves or kills - so it is both the boot path and the repair path.
`tmx ls` shows every server. An idempotent rebuild is the whole persistence
story here: tmux-resurrect/continuum would need TPM, and `.tmux.conf` runs zero
plugins by design.

Three things that are easy to get wrong, all found by testing:

- **`Prefix+w` needs no configuration.** `choose-tree` is server-scoped by
  construction and can only list the sessions of the server its client is attached
  to. That is the entire mechanism behind "each world has its own list".
- **`Prefix+S` does need help**, because two of sesh's three sources are global:
  the `[[session]]` entries come from one config and **zoxide is one shared
  database**. `tmx pick-session` derives the server from `#{socket_path}` and runs
  `sesh -C .config/sesh/<server>.toml picker -i -d -c -t` - that world's config
  plus its live sessions, and **no `-z`**. Dropping zoxide is what stops every
  list looking identical; `-d` collapses the config/live duplicate of one name.
  Note `-C` must precede the subcommand (`sesh -C f list` works, `sesh list -C f`
  errors).
- **A startup command is sent with `send-keys` targeting `"$name:"`.** Not as a
  `new-session <cmd>` argument, or quitting the editor would kill the session; and
  not `-t "=$name"`, because the `=` exact-match prefix is valid only for SESSION
  targets - against a pane target tmux fails with "can't find pane" and every
  startup command silently no-ops.

Reaching outside the current world is not lost, it just moves keys: `Prefix+f`
(`sessionizer.sh`) still fuzzy-finds every directory on the machine.

## Session Favourites

`favourites.sh` bookmarks a *specific* claude/opencode conversation so you can
resume it later — even after its window has closed or the agent exited
(`agent-chooser.sh` only lists **live** panes).

- `Prefix+s` — star the agent in the current pane. Claude sessions are read from
  `~/.claude/sessions/<pid>.json` (exact session id); opencode resolves the
  most-recent session for the pane's directory (read-only query of
  `~/.local/share/opencode/opencode.db`).
- `Prefix+o` — fzf picker over favourites with a live preview.
  - `Enter` restores: switches to (or creates) a tmux session at the chat's
    directory and resumes it (`claude --resume` / `opencode --session`).
  - `ctrl-x` removes a favourite · `ctrl-r` reloads · `ctrl-a` browses recent
    sessions to star one (handy for chats not currently open).

Registry: `~/.local/state/tmux-favourites/favourites.tsv` (runtime state, not in
the repo). Stale favourites fall back to a fresh agent in the directory.

## Status Line Integration

`claude-status.sh` runs every 3 seconds to display agent status:
- `!n` = needs attention (n agents)
- `~n` = working (n agents)
- `·n` = idle (n agents)
