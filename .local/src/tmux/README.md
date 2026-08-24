# Tmux Integration Scripts

Scripts for tmux session management, agent orchestration, and productivity workflows.

**Writing a new panel?** Copy `_skeleton.sh` (it runs as-is) and read `CONVENTIONS.md` for why
each rule is the way it is. The shared floor is `panel-lib.sh`; `tests/integ/panel_conformance.bats`
and `tests/unit/panel_lib.bats` enforce it, so a panel that skips the conventions fails
`make -C tests test-fast`. This README stays user-facing - which key opens what.

## Scripts

| Script | Keybinding | Description |
|--------|------------|-------------|
| `editor.sh` | `Prefix+Space` | ONE editor per session, at window 1, rooted where the session was born. Press it anywhere to go there, press it again to come back to the exact window you left. Created lazily on the first press, so a session you never edit in never pays for one. Space because its stock binding (next-layout) is the only one nothing here wanted — no existing key was moved. |
| `sessionizer.sh` | `Prefix+f` | Jump to a repo or a worktree. The list is git repos under the search roots, the directories the manifests declare, and everything in `~/.worktrees` - not every directory under the roots. |
| `worktree.sh` (`wt`) | `Prefix+F` / `Prefix+X` | One worktree per piece of work. `F` cuts a fresh worktree off the repo the current pane is in and lands you in a session named after it; `X` tears the current one down - kills the session and reaps the worktree, safe to press from inside it. No pickers. |
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

- **The editor**: `Prefix+Space` → this session's editor; again → back where you were
- **Which world**: `Prefix+C-s` (or bare `tmx`) → the worlds, sessions in the preview
- **Everything, everywhere**: `Prefix+A` → every session and window on every server
- **Resume a world**: `Prefix+C-n` hub · `Prefix+C-h` lab (back where you left off)
- **Root of a world**: `Prefix+N` hub · `Prefix+H` lab (daily / projects overview)
- **Switch session**: `Prefix+S` → sessions of the current world only
- **Switch projects**: `Prefix+f` → fuzzy find a repo or a worktree
- **Cut a worktree**: `Prefix+F` → a fresh worktree off this repo, in its own session
- **Tear it down**: `Prefix+X` → kill this session and reap its worktree, from inside it
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
| `tmx goto <world> <session>` | land on ONE named session in another world (what `Prefix+f` uses to route) |

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
containing a space cannot be expressed there (such a line is skipped).

### Worlds

| Server | Sessions | Lands on |
|---|---|---|
| `hub` - personal | **hub**, dotfiles, home-config | today's daily note |
| `lab` - building | **lab**, platform | `~/.notes/lab/projects/index.md` |
| `work` - client work | declared in the private overlay | that client's project index |

Declared in `../../.config/tmux-servers/<name>.conf`, one
`<name> <dir> [startup command...]` per line. **The first entry is the landing
session**: `tmx hop hub` attaches straight to it, so you arrive in today's note
rather than a bare shell.

Worlds are **discovered** from that directory rather than hardcoded, so dropping in a
`<name>.conf` creates a world with no code change - which is what makes a per-client
world a config edit. `hub` and `lab` are seeded first so the picker order stays stable,
and are offered even when their manifest is absent. `work.conf` lives in
`.dotfiles-private`, because client names and repo layouts do not belong on public
GitHub; `stow --no-folding` links files individually, so it lands in the same
`~/.config/tmux-servers/` directory.

**A manifest is identical on every machine.** An entry whose directory does not exist
is **skipped**, and the count is reported (`3 created, 0 already up, 1 skipped (no
dir)`), so each host materialises only the sessions it actually has: `home-config` and
`platform` are Linux-only, a client repo only exists on that client's machine. This
replaced a `$HOME`
fallback that created a junk session rooted at home on every machine lacking the repo
- which is why a `home-config` window used to open on the Mac. Skipping still never
costs you the rest of the manifest, and the reported count is what keeps a mistyped
path from vanishing silently.

#### Which world a directory belongs to

The manifests are also the **routing table**, and `Prefix+f` reads them. Pick a
directory some `*.conf` declares and you land in the world that declares it, under
the name that manifest gives it - hopping servers if that is where it lives:

| Picked | Goes to | Because |
|---|---|---|
| `~/.dotfiles` | `hub`, session `dotfiles` | hub.conf declares it |
| `~/dev/bnb/platform` | `lab`, session `platform` | lab.conf declares it |
| `~/.notes` | `hub`, session **`hub`** | the manifest's name wins over the basename |
| `~/dev/bnb/platform/apps/web` | wherever you are, session `web` | undeclared: **exact match only** |

Before this the picker ran plain `tmux`, which follows `$TMUX`, so it created the
session on whatever socket happened to enclose it - `Prefix+f` on
`~/dev/bnb/platform` from `hub` built a **second** `platform` beside lab's. Same
directory, two worlds, and nothing looked wrong from either side.

The hop is handed to `tmx goto <world> <session>`, which is `hop`/`root`'s sibling:
"take me to THIS session, wherever it lives". It goes through `_enter` like every
other hop, so it records the back-crumb and `Prefix+L` returns from it. Crossing
worlds from inside a popup is not new - `Prefix+A` has always done it.

`sessionizer.sh --route <dir>` prints the decision (`hub dotfiles`, or `here <name>`
for anything undeclared) without touching a server, which is how it is tested.

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
(`sessionizer.sh`) sees every repo and worktree on the machine, whatever world
they belong to - and it **routes by manifest**: a directory some `*.conf` declares
lands in that world, under that manifest's name, hopping servers if that is where
it lives. Everything undeclared opens right where you are. See "Which world a
directory belongs to" below.

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

## Projects and worktrees (`Prefix+f`)

`sessionizer.sh` builds its rows from three sources, in this order, deduped:

| Source | What it contributes | Why it cannot be dropped |
|---|---|---|
| git repos under `SESSIONIZER_ROOTS` | every repo `SESSIONIZER_DEPTH` deep, **except** one its enclosing repo declares in `.gitmodules` | the actual projects. A declared submodule (`.local/src/gungan`) is a dependency pinned to somebody else's commit; an undeclared nested repo is a checkout parked there to work in |
| `.config/tmux-servers/*.conf` | every directory a manifest declares, if it exists here | a declared directory can sit *inside* a repo (`~/.notes/lab` is a subdirectory of the `~/.notes` repo), so no repo walk can produce it |
| `$WT_ROOT` (`~/.worktrees`) | directories whose `.git` is a **file** | a linked worktree's `.git` is a file where a main checkout's is a directory. That test both finds worktrees and rejects whatever else got parked there |

It used to be **every** directory to depth 4 under the roots: 1521 rows on the Mac, 1048 of
them inside `~/.dotfiles` alone, and not one worktree. The volume was the least of it. A
session name is the **basename** (`panel_session_name`), so 20+ names repeated - `src` x12,
`docs` x12, `dotfiles` x5 - and picking `~/.agent/plans/dotfiles` opened a session called
`dotfiles` that was not the dotfiles repo.

`~/.agent` is not a root at all: it is the agent runtime axis, one directory per project per
axis, so it contributed several colliding rows for every project it had ever seen.

An **arbitrary** directory belongs to `Prefix+S`, whose sesh sources are zoxide frecency and
the `[[session]]` entries in `../../.config/sesh/sesh.toml`. Passing one to `sessionizer.sh`
as an argument still works; it is only the *list* that is opinionated.

`SESSIONIZER_DEPTH` bounds how far below a root a repo may sit. The walk looks for `.git` one
level deeper than that, and the `.git` clause comes first in the `find` expression so that
`.git` being in `SESSIONIZER_PRUNE` - where it has to stay, to keep the descent out of it -
cannot swallow the very thing being searched for.

### Why a nested repo is a row

Nesting is not depth, it is **ownership**, and only `.gitmodules` records it.
`~/dev/bnb/games/engine` is a repo holding `unity-core`, `unity-core-harness` and
`unity-core-playground` as gitlinks with **no `.gitmodules` at all**, each sitting on its own
feature branch. Listing only the outermost repo hid all three behind `engine`, on every
machine, and the picker gave no sign it had done so.

Excluding them by *position* was never the intent - excluding **dependencies** was. So the
rule asks the enclosing repo whether it declares the thing, and everything vendored is
excluded one step earlier by `SESSIONIZER_PRUNE`, which is why `vendor` and `.claude` are in
that list beside `node_modules`: they hold real checkouts (`tests/vendor/bats-core`, the seven
hash-named worktrees under `platform/.claude/worktrees/`) that no one opens a session on.

A directory with **no** `.git` is still not a row, whatever it holds - `~/dev/adb-mcp` has to
be `git init`-ed, declared in a manifest, or reached with `Prefix+S`.

## Worktrees (`Prefix+F`, `Prefix+X`, `wt`)

**The worktree is the unit of work.** `Prefix+F` cuts a fresh worktree off the repo the
current pane is sitting in and drops you into a tmux session rooted there. A second agent
therefore never shares the first one's checkout, branch or dirty status - which is what one
session with seven windows all named `main` actually was.

**One key, one action.** `Prefix+F` opens no picker and asks nothing: the repo is the one
the current pane is in, and the slot is the next free one.

`Prefix+f` **does** list worktrees, which reverses the original call that "a worktree is
somewhere you are sent, not somewhere you go looking". Being sent covers the first minute of
a worktree's life; coming back to one an hour later, from another session, needs a list, and
the only way to get there was to remember the path. `$WT_ROOT` only - a worktree parked
somewhere else is not something to advertise as a session.

`agent-N` is **not** a persistent workspace slot. It is the Nth worktree alive right now:
allocated by `new`, freed by `reap`, and the number is reused once it is free. Nothing else
had to learn a new concept for this, because the layout keeps the basename as the identity:

```
~/.worktrees/<repo>-agent-N     directory basename
           == <repo>-agent-N    tmux session name       panel-lib.sh:panel_session_name
           -> project <repo>    agent-panel             render.rs:project_from_path
           -> label   N:<win>   agent-panel row label   render.rs:short_target
```

So `Prefix+g`, `Prefix+w` and `sesh` all show live worktrees the moment they exist. Nesting
them under `~/.worktrees/<repo>/` would make the basename `agent-N`, losing the repo and
breaking all three at once.

| verb | what |
|---|---|
| `wt new [-c <dir>]` | cut a worktree off `<dir>`'s repo, open its session, land there |
| `wt done [<name>]` | **the cleanup**: kill the session and reap the worktree, in one go |
| `wt reap [<path>]` | remove ONE worktree - only if clean, landed and with no live session |
| `wt gc [<repo>] [-n]` | reap everything eligible and **name** what it kept, with the reason |
| `wt --list` | every worktree on the machine, TSV |
| `wt` (no verb) | an fzf picker over that list. Typed, not bound to a key. |

**Reaping is the load-bearing half.** Cheap creation with no reaper is how
`~/dev/bnb/platform` reached 35 worktrees. `reap` refuses - with the reason, and there is no
`--force` - when the tree is dirty, when commits are unpushed, when the path is a main
checkout, or when a tmux session for it is still live. "Clean and pushed" is a snapshot, not
a promise: an agent working detached is clean-and-pushed for a moment after every push, so
the live-session rule is what stops a `gc` deleting a worktree mid-turn.

**Tearing one down is `Prefix+X`, and it works from inside the session it is killing.** That
sounds impossible - `tmux kill-session` takes your own shell with it, so any `wt reap` you
chain after it never runs. The trick is to hand the job to something that outlives you: the
tmux SERVER is a persistent daemon, and `run-shell -b` is its queue. `wt done` schedules
`kill-session; wt reap` there and returns immediately.

The refusal happens FIRST, in your terminal, while there is still a terminal to print it to.
A worktree holding uncommitted or unpushed work is refused before anything is killed. The
deferred reap then re-runs the FULL policy, live-session rule included - which passes
honestly, because the session it would have objected to is the one just killed. Nothing is
waived. Its outcome lands in `~/.agent/wt/done.log`, since by then there is nowhere else to
print it.

`wind-down` closes the loop: `arm` records the worktree in its sentinel, and `fire` runs
`wt reap` **after** the kill, in the same backgrounded chain. Before the kill it would always
refuse, correctly.

> **Caveat, dotfiles only.** Stow symlinks point at `~/.dotfiles`
> (`~/.local/src/tmux -> ../../.dotfiles/.local/src/tmux`), so edits made in a *dotfiles*
> worktree are **not deployed**. You are exercising the repo copy, not the live one. Run
> scripts by their path inside the worktree; `wt` on `PATH` is not the one you just edited.

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

The worlds, discovered from `../../.config/tmux-servers/*.conf`:

| Server | Sessions | Lands on |
|---|---|---|
| `hub` - personal | **hub**, dotfiles, home-config | today's daily note |
| `lab` - building | **lab**, platform | `~/.notes/lab/projects/index.md` |
| `work` - client work | declared in the private overlay | that client's project index |

Declared one `<name> <dir> [startup command...]` per line. **The first entry is the
landing session**, so hopping to hub puts you in today's note rather than a bare shell.

`tmx ensure` creates only what is **missing**, keyed on session name - never
renames, moves or kills - so it is both the boot path and the repair path. An entry
whose directory does not exist is skipped and counted, so one manifest serves every
machine: see [Worlds](#worlds) above.
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
(`sessionizer.sh`) sees every repo and worktree on the machine, whatever world
they belong to - and it **routes by manifest**: a directory some `*.conf` declares
lands in that world, under that manifest's name, hopping servers if that is where
it lives. Everything undeclared opens right where you are. See "Which world a
directory belongs to" below.

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
