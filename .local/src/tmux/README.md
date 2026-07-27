# Tmux Integration Scripts

Scripts for tmux session management, agent orchestration, and productivity workflows.

## Scripts

| Script | Keybinding | Description |
|--------|------------|-------------|
| `sessionizer.sh` | `Prefix+f` | Fast project directory switcher with fzf |
| `servers.sh` (`tmx`) | `Prefix+C-s` / `A` / `C-n` / `C-h` | Server layer: pick a world (compact) or every session everywhere (full); hop to hub / lab |
| `sesh` (Go, AUR `sesh-bin`) | `Prefix+S` | Session picker, scoped to the current server. Config: `../../.config/sesh/` |
| `agent-panel` (Rust) | `Prefix+g` / `Prefix+G` | View/select Claude agent windows (`G` = jump to next needing attention). Cross-platform binary; see `../agent-panel/`. |
| `favourites.sh` | `Prefix+s` / `Prefix+o` | Star a claude/opencode chat; reopen & resume it later |
| `tags.sh` | `Prefix+a` / `Prefix+w` / `Prefix+W` | Tag windows important/pinned/agent or group them; also on PATH as `tmux-tags` |
| `cockpit.sh` | `Prefix+C` | The one PERSISTENT surface: a session you attach to and leave up (windows: fleet, bridge, watch, prs, notes). Everything else here is a popup that vanishes on selection. `ensure` is also the repair path, so it is safe to call on every attach. Also `cockpit.sh stale` — see below. |
| `fleet.sh` | inside the cockpit | The headless layer `agent-panel` structurally cannot see: agentctl runners, sentinel watches, pending asks, and agents living in OTHER sessions (agent-panel only finds agents owning a pane in the current session). |
| `claude-status.sh` | Status bar | Shows Claude agent status in tmux status line |

## Usage

All scripts are bound to tmux keybindings via `~/.tmux.conf`.

### Quick Reference

- **Which world**: `Prefix+C-s` (or bare `tmx`) → the two worlds, sessions in the preview
- **Everything, everywhere**: `Prefix+A` → every session and window on every server
- **Resume a world**: `Prefix+C-n` hub · `Prefix+C-h` lab (back where you left off)
- **Root of a world**: `Prefix+N` hub · `Prefix+H` lab (daily / projects overview)
- **Switch session**: `Prefix+S` → sessions of the current world only
- **Switch projects**: `Prefix+f` → fuzzy find directories
- **View agents**: `Prefix+g` → choose active agent windows
- **Favourite a chat**: `Prefix+s` → star the agent in the current pane
- **Reopen a chat**: `Prefix+o` → pick a favourite, resume the conversation
- **Tag a window**: `Prefix+a` then `i`/`p`/`a`/`g` → important / pinned / agent / group
- **Find a tagged window**: `Prefix+w` (all, tag column) · `Prefix+C-w` (tagged only) · `Prefix+W` (fzf)

## Window Tags

`tags.sh` (on PATH as `tmux-tags`) marks windows so you, your scripts, and your
agents can tell them apart. A tag is a tmux **window user-option** (`@tag_*`),
not part of the window name: the `.zshrc` precmd hook rewrites window names to
the git branch on every prompt, so a name-based marker never survives.

- `Prefix+a` then `i` important · `p` pinned · `a` agent · `g` group:<name> ·
  `x` clear · `l` list. It is a native one-shot key table, so one key and you
  are back to normal.
- Status bar shows `*` for important and `+` for pinned.
- `Prefix+w` is the window chooser with a tag column; `Prefix+C-w` filters to
  tagged windows only.
- `Prefix+W` is an fzf picker over **every** window where you tag the row **under
  the cursor**: `C-i` important, `C-p` pinned, `C-a` agent, `C-x` clear, `Enter`
  jumps. The list reloads in place so the tag column updates as you go.
  This popup exists because tmux has no user-bindable key table for
  `choose-tree` - cursor-directed tagging cannot live in `Prefix+w`.

Scripts and agents query it:

```sh
tmux-tags ls --json                    # every tagged window, structured
tmux-tags targets --tag important      # bare @N ids, one per line
tmux-tags protected -t @66             # exit 0 if pinned/important
tmux-tags gather --tag group:work --into work   # a tag is a group
```

`wind-down.sh` refuses to kill a window, and `cockpit.sh stale` refuses to even list one,
tagged `pinned` or `important`.

### Finding dead agent windows (`cockpit.sh stale`)

`fleet.sh` answers "what is running". The opposite question — which windows only
*look* like agents — has its own verb:

```sh
cockpit.sh stale                     # idle > 15m, the default
cockpit.sh stale --threshold 3600    # idle > 1h
```

A window is stale only when all three hold: the name matches an agent pattern, the
pane's command has fallen back to a plain shell (so the agent exited), and it has been
idle past the threshold. A long-running `claude` sitting at a prompt is never stale,
however long it has been quiet — its process is still there.

It **reports and never kills**, printing the `kill-window` command instead. Deciding a
window is dead is cheap and reversible; killing one that merely looked dead loses a
scrollback nobody can get back.

This replaced `stale-detector.sh` and `cleanup.sh`, which were unreachable — their only
callers were `launcher.sh` and `dashboard.sh`, both of which were themselves bound only
by commented-out lines in `.tmux.conf`.

Tags are **server-lifetime only** - they do not survive `tmux kill-server` or a
reboot. That is deliberate; for windows that should come back tagged, declare
them in the session manager's config and have the window tag itself on startup.

## Servers (`Prefix+A`, `tmx`)

The layer **above** sessions. tmux has four:

```
server   one per SOCKET   <- servers.sh / tmx
  session   hub, lab, ...
    window
      pane
```

Everything used to live in one server on the default socket, which made the
sessions siblings in a single process rather than separate systems - so one
`tmux kill-server` took out all of them at once. `hub` and `lab` now each own a
socket, and the blast radius of a kill is exactly one server.

| Keys / command | What |
|---|---|
| `Prefix+w` | **the sessions of the current world** - choose-tree, unchanged |
| `Prefix+A` | **everything, everywhere** - every session AND window across every server |
| `Prefix+C-n` / `C-h` | **resume** hub / lab - back on the exact window you left |
| `Prefix+N` / `H` | **root page** of hub / lab - today's daily, projects overview |
| `Prefix+C-s` | **compact**: just the worlds, sessions in the preview (also bare `tmx`) |
| `tmx ls` | every server + session counts |
| `tmx ensure hub` | build/repair the set without attaching |

One letter per world, so the only thing the Ctrl changes is resume-vs-root:
`n` = hub, `h` = lab. (lab was on `M`/`C-m` and moved - Ctrl-M is a carriage
return at the *terminal*, so a `bind C-m` can never fire.)

**Resume vs root** is the whole point of having two pairs of keys. `C-n`/`C-h`
attach to the most recently used session that is *not* the landing page, and a
session restores its own active window - you land back exactly where you were,
which makes flipping between two pieces of work cheap. `N`/`H` attach to the
manifest's first entry instead, for when you want to start from the top of a world.

**`Prefix+A` is the only view that crosses the server boundary.**
`Prefix+w` is server-scoped by construction, and `Prefix+S` (sesh) shells out to
plain `tmux` so it follows `$TMUX` into whichever single world you are in. Seeing hub
and lab *together* has to be assembled from outside both, which is what
`tmx pick-all` does. Three selectable levels in one list:

```
hub  3 session(s)
  dotfiles      ~/.dotfiles             8 win  claude x6, zsh, chromium  (attached)
       2  feat/tmux-cockp~ claude   kill-orphan-sessions-rebuild-views
       5* main             claude   Research best image viewing library options
  hub           ~/.notes                1 win  nvim
       1* master           nvim     2026-07-26.md (~/.notes/journal/daily)
lab  2 session(s)
  platform      ~/dev/bnb/platform      1 win  nvim
       1* fix/placemypare~ nvim     neo-tree filesystem
```

A **session** row explains itself - where it is and what is running in it, both
derived, so an ad-hoc session is described as well as a declared one and no manifest
has to be kept in sync. A **window** row carries the branch, the command, and the
pane title, which is where a program puts its context: claude windows read as their
task, nvim windows as their file. A **server** row hops the whole world, which is why
this list can also stand in for the compact picker when you want everything at once.

**Two views on purpose.** `Prefix+C-s` (and a bare `tmx`) is the COMPACT one - just the
worlds, two rows, with that world's sessions in the preview; use it when the question is
"which world". `Prefix+A` is the FULL one; use it when the question is "where is that
window". Neither replaces the other, so both are kept.

**The full view has no preview pane, deliberately.** A preview only describes the row
under the cursor, so with hundreds of windows you would arrow through the list to find
out what is in it - the list has to answer "what is this" itself. The compact view
keeps its preview precisely because it is the opposite case: two rows, and the preview
is the drill-down.

`tmx rows` is the data behind it, split out from the fzf call so it is assertable
without a terminal; `tests/ui/servers_isolation.bats` covers it.

One limit worth knowing: the manifest is whitespace-delimited, so a session directory
containing a space cannot be expressed there (it falls back to `$HOME`).

### Worlds

Two, deliberately. A third `work` server was tried and dropped as noise.

| Server | Sessions | Lands on |
|---|---|---|
| `hub` - personal | **hub**, dotfiles, home-config | today's daily note |
| `lab` - building | **lab**, platform | `~/.notes/lab/projects/index.md` |

Declared in `../../.config/tmux-servers/<name>.conf`, one
`<name> <dir> [startup command...]` per line. **The first entry is the landing
session**: `tmx hop hub` attaches straight to it, so you arrive in today's note
rather than a bare shell.

The startup command is delivered with `send-keys` rather than as a
`new-session <cmd>` argument, so quitting the editor drops you into a normal shell
instead of destroying the session. Its target must be `"$name:"` - the `=` exact-
match prefix is valid only for SESSION targets, and against a pane target tmux
fails with "can't find pane", which silently no-ops every startup command.

`tmx ensure` creates only what is **missing**, keyed on session name - never
renames, moves or kills - so it is both the boot path and the repair path, the
same contract `cockpit.sh ensure` uses.

`Prefix+w` needs no configuration to respect this: `choose-tree` is server-scoped
by construction and can only ever list the sessions of the server its client is
attached to. That is the entire mechanism behind "completely different lists".

`Prefix+S` needs help, though, because two of sesh's three sources are global: the
`[[session]]` entries come from one config and **zoxide is one shared database**.
So `tmx pick-session` derives the server from `#{socket_path}` and runs
`sesh -C .config/sesh/<server>.toml picker -i -d -c -t` - that world's own config,
plus its live sessions, and **no `-z`**. Dropping zoxide is what stops every
server's list looking identical; `-d` collapses the config/live duplicate of the
same name. Note `-C` must precede the subcommand (`sesh -C f list` works,
`sesh list -C f` errors).

Reaching outside the current world is not lost, it just moves keys: `Prefix+f`
(`sessionizer.sh`) still fuzzy-finds every directory on the machine.

Two things verified, both load-bearing:

- Inside a `-L foo` session `$TMUX` is set, so a bare `tmux ls` reports **foo's**
  sessions. `sesh` shells out to plain `tmux`, so it follows the enclosing server
  automatically - one `sesh.toml` is correct inside every server, no
  `tmux_command` needed.
- tmux has **no** cross-server `switch-client` (it is session-scoped). The hop is
  `detach-client -E`, which runs a command after the client detaches so the
  detach+attach reads as one motion. `new-session -A` makes each binding double as
  the boot path.

**tmux cannot move a live session between servers** - there is no `move-session -L`.
Putting an existing session on another server means recreating it there.

The bare `tmux` command is a zsh **function** (not an alias) that redirects to the
`hub` server only when called with no args from outside tmux - see `.zshrc`. An
alias would append `-L hub` to every call, including from inside `lab`, where
`-L` overrides `$TMUX`.

## Sessions (`Prefix+S`)

`sesh` merges three sources into one picker: **live tmux sessions**, **zoxide**
frecency, and the named `[[session]]` entries in `../../.config/sesh/sesh.toml`.
Picking a live session switches to it; picking a directory creates a session
there. This is what `Prefix+w`/`Prefix+C-w` are for windows.

Additive to `Prefix+f` (`sessionizer.sh`), which only ever saw *directories* and
had no preview. Keep that list short - zoxide already covers every project repo,
so a `[[session]]` entry for one just prints a duplicate row.

**Do not** try to drive a layout tool from `startup_command`: `smug start X` is a
silent no-op there (exit 0, builds nothing) because sesh creates the session
first. sesh's own `[[window]]` has no panes; its native layout hooks are the
`tmuxinator` / `tmuxp` session fields. `smug` itself has been unused since
2026-01 and is no longer installed by the Arch provisioner.

## Servers (`Prefix+A`, `tmx`)

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
| `hub` - personal | **hub**, dotfiles, home-config | today's daily note |
| `lab` - building | **lab**, platform | `~/.notes/lab/projects/index.md` |

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
