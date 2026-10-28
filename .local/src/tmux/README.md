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
| `servers.sh` (`tmx`) | `Prefix+C-s` / `A` / `C-h` / `C-n` | Server layer: pick a world (compact) or every session everywhere (full); hop to lab / hub |
| `sesh` (Go, AUR `sesh-bin`) | `Prefix+S` | Session picker, scoped to the current server. Config: `../../.config/sesh/` |
| `agent-panel` (Rust) | `Prefix+g` / `Prefix+G` | View/select Claude agent windows (`G` = jump to next needing attention). Cross-platform binary; see `../agent-panel/`. |
| `tags.sh` | `Prefix+a` / `Prefix+w` / `Prefix+W` | Tag windows important/pinned/agent or group them; also on PATH as `tmux-tags` |
| `projects.sh` | `Prefix+P` | Every profile's projects, main ones first (drafts behind `d`), each with its open count by priority and wave. `1`-`9` or Enter opens a project's tasks: `a` add, `m` move to another project, `x` done, `+`/`-` change wave, `o` open the sheet. `/` searches. Also nvim `<leader>np`. |
| `fleet-sessions watch` | `Prefix+o` | The fleet watch, in the `hub:watch` window beside infra: one row per agent session with its stages (behind main, conflicts, tree, PR, CI, plan phases, bucket, labels, idle) and a log of every change since the last tick, one line per session fitted to the window (columns at their content's width, all-default ones hidden, the least important dropped first when narrow, WHY taking the rest). A declared window, so it is always running and its log keeps building while you are elsewhere. `Prefix+o` goes there from any world (`tmx goto hub hub:watch`, which rebuilds it if it was killed); `Prefix+L` comes back, and never returns TO a board: when the last session is sitting on one, L goes to the session you worked in before it. `n` refreshes now, `q` quits the board itself. |
| `day-log watch` | `Prefix+O` | The day log, in the `hub:log` window beside watch: everything merged today in every repo grouped by area and conventional-commit scope (`.config/day-log/groups`), the PRs still open with their CI and session, what waits on you (MAIN reds, NEEDS sessions, pending asks), the `fleet-bench` scorecard headline and its top sessions, spend and tokens from `agent-usage`, merges per hour, and the last watch-log transitions. Deterministic: gh search, the fleet state document and the tools above, no model. Each pass (every 5 min) writes `~/.agent/daylog/<date>.json`, so `[` and `]` step through past days and `t` returns; `l` pages every PR as markdown; `n` refreshes, `q` quits. The briefing files each day as `refs/<date>/shipped.md` with `day-log finalize`. The `day-log` skill reads the same records. |
| `fleet.sh` | `Prefix+C-g` | The headless layer `agent-panel` structurally cannot see: agentctl runners, sentinel watches, pending asks, and agents living in OTHER sessions (agent-panel only finds agents owning a pane in the current session). |
| `night-shift.sh` | `Prefix+C` | The overnight agent queue (`night-shift`): a `night-shift` session with the board on top (queued, running, last night's results with PRs and pending asks) and the running task's live log below. Both redraw on inotify events. Queue work with `night-shift queue <repo> <task>`. |
| `command-center.sh` | window `hub:infra` | The CI-first infra board. One row per machine (CPU, load/cores, memory, temperature, runners busy), then one row per busy runner under its machine with the repo, PR, job, time in job, and branch plus the run title; the queue grouped by pool, repo, PR and branch with count and oldest wait; DOWN (offline or missing runners, GitHub API failing); the last five finished runs; and a one-line domain strip from the `cc:*` rules. It reads Prometheus only (`cc:host_*`, `github_runner_state`, `github_actions_job_waiting`, `github_actions_run_recent`, from home-config `apps/monitoring/prometheus-rules-command-center.yaml` and `apps/github-runner-exporter`), so it cannot disagree with Grafana, and any failed query blanks the board. A machine with no exporter reads `-`. The workstation is not a runner, so its row lists the headless Unity gates running here (pool `local`, from `fleet-assess --textfile`, published every minute by `fleet-local-gates.timer` through node_exporter). Columns fit the window through `.local/lib/table-fit.sh`, shared with `fleet-sessions watch`. Read-only; actions stay in `fleet.sh`. |
| `claude-status.sh` | Status bar | Shows Claude agent status in tmux status line |

## Usage

All scripts are bound to tmux keybindings via `~/.tmux.conf`.

### Quick Reference

- **The editor**: `Prefix+Space` → this session's editor; again → back where you were
- **Which world**: `Prefix+C-s` (or bare `tmx`) → the worlds, sessions in the preview
- **Everything, everywhere**: `Prefix+A` → every session and window on every server
- **Resume a world**: `Prefix+C-h` lab · `Prefix+C-n` hub (back where you left off)
- **Root of a world**: `Prefix+H` lab · `Prefix+N` hub (projects overview / daily)
- **Switch session**: `Prefix+S` → sessions of the current world only
- **Switch projects**: `Prefix+f` → fuzzy find a repo or a worktree
- **Project work**: `Prefix+P` → projects with their open counts; Enter for the tasks
- **Cut a worktree**: `Prefix+F` → a fresh worktree off this repo, in its own session
- **Tear it down**: `Prefix+X` → kill this session and reap its worktree, from inside it
- **View agents**: `Prefix+g` → choose active agent windows
- **Fleet watch**: `Prefix+o` → every session's stages and what just changed (popup over the hub `watch` session; `Prefix+o` again closes it)
- **Resume a past chat**: `Prefix+R` → search every Claude session ever run, Enter resumes it
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

`wind-down.sh` refuses to kill a window tagged `pinned` or `important`.

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
| `Prefix+C-h` / `C-n` | **resume** lab / hub - back on the exact window you left |
| `Prefix+H` / `N` | **root page** of lab / hub - projects overview, today's daily |
| `Prefix+C-s` | **compact**: just the worlds, sessions in the preview (also bare `tmx`) |
| `tmx ls` | every server + session counts |
| `tmx ensure hub` | build/repair the set without attaching |
| `tmx goto <world> <session>` | land on ONE named session in another world (what `Prefix+f` uses to route) |

One letter per world, so the only thing the Ctrl changes is resume-vs-root:
`h` = lab, `n` = hub, set by `WORLD_H` / `WORLD_N` near the top of `~/.tmux.conf` - swap those two lines to swap every world key. (lab was on `M`/`C-m` and moved - Ctrl-M is a carriage
return at the *terminal*, so a `bind C-m` can never fire.)

**Resume vs root** is the whole point of having two pairs of keys. `C-h`/`C-n`
attach to the most recently used session that is *not* the landing page, and a
session restores its own active window - you land back exactly where you were,
which makes flipping between two pieces of work cheap. `H`/`N` attach to the
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
| `hub` - personal | **hub** (+ window `infra`: command-center.sh), dotfiles, watch (fleet-sessions watch), home-config (on demand) | today's daily note |
| `lab` - building | **lab**, platform | `~/.notes/lab/projects/index.md` |
| `work` - client work | declared in the private overlay | that client's project index |

Declared in `../../.config/tmux-servers/<name>.conf`, one
`<name> <dir> [startup command...]` per line. **The first entry is the landing
session**: `tmx hop hub` attaches straight to it, so you arrive in today's note
rather than a bare shell.

A name written `?name` is **on demand**: `ensure` does not boot it, so closing it sticks
instead of coming back on the next hop in. It is still declared, so `Prefix+f` on its
directory still routes to this world, and `Prefix+f`, `tmx goto <world> <name>` or the
world's `Prefix+S` list (`sesh/<world>.toml`) start it. `ensure` reports it as
`N on demand`. Never mark the landing entry.

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
| `~/dev/bnb/games/engine/unity-core-playground` | `lab`, session `unity-core-playground` | lab.conf declares it (`?`, on demand) |
| `~/.worktrees/unity-core-playground-agent-3` | `lab`, session `unity-core-playground-agent-3` | a linked worktree takes its main repo's world, under its own name |
| `~/.notes` | `hub`, session **`hub`** | the manifest's name wins over the basename |
| `~/dev/bnb/games/engine/unity-core-playground/Assets` | wherever you are, session `Assets` | undeclared: **exact match only** |

Before this the picker ran plain `tmux`, which follows `$TMUX`, so it created the
session on whatever socket happened to enclose it - `Prefix+f` on
`~/dev/bnb/platform` from `hub` built a **second** `platform` beside lab's. Same
directory, two worlds, and nothing looked wrong from either side.

`wt new` (`Prefix+F`) asks the same route (`sessionizer.sh --route <main repo>`), so a declared repo's new agent session is created on its world and you hop there. 2026-10-28: the playground was undeclared, `Prefix+F` pressed from `hub` built three agent sessions on hub's socket while 23 siblings sat on lab. A worktree is in no manifest, so when the picker hops to one that has no session yet it creates the session on that world first; `tmx land` would otherwise fall back to the world's last session.

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
renames, moves or kills - so it is both the boot path and the repair path.

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
| git repos under `SESSIONIZER_ROOTS` | every repo `SESSIONIZER_DEPTH` deep, **except** one its enclosing repo declares in `.gitmodules`, unless that section sets `tmux-picker = true` | the actual projects. A declared submodule (`.local/src/gungan`) is a dependency pinned to somebody else's commit; an undeclared nested repo is a checkout parked there to work in. `tmux-picker = true` is for a submodule that is its own project (`.local/src/android-suite`); a manifest line would list it too, but `ensure` recreates manifest sessions on every hop |
| `.config/tmux-servers/*.conf` | every directory a manifest declares, if it exists here | a declared directory can sit *inside* a repo (`~/.notes/lab` is a subdirectory of the `~/.notes` repo), so no repo walk can produce it |
| `$WT_ROOT` (`~/.worktrees`) | directories whose `.git` is a **file** | a linked worktree's `.git` is a file where a main checkout's is a directory. That test both finds worktrees and rejects whatever else got parked there |

The picker runs fzf with `--tiebreak=index`, so that order survives a search: on an equal match a repo ranks ahead of its own worktrees (`unity-core-playground` above its 27 `~/.worktrees/unity-core-playground-*`), and a query that names the worktree still scores it higher.

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
the current pane is in, and the slot is the lowest one that is free or idle. Idle means the
same thing `reap` means by eligible - clean, landed, no session and no pane inside it - so a
worktree whose session was killed without `wt done` is reset onto the trunk in place (its
ignored build caches kept) instead of pushing the next agent one number higher. A leftover
`agent-N` branch with no directory frees its slot too, once it is merged and checked out
nowhere.

`Prefix+f` **does** list worktrees, which reverses the original call that "a worktree is
somewhere you are sent, not somewhere you go looking". Being sent covers the first minute of
a worktree's life; coming back to one an hour later, from another session, needs a list, and
the only way to get there was to remember the path. `$WT_ROOT` only - a worktree parked
somewhere else is not something to advertise as a session.

`agent-N` is **not** a persistent workspace slot. It is the Nth worktree alive right now:
allocated by `new`, freed by `reap` or by going idle, and the number is reused once it is free. Nothing else
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
| `wt new [-c <dir>]` | take the next agent-N of `<dir>`'s repo and land in its session at once; the fetch and checkout run visibly in that session's first pane |
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

### What `Prefix+F` does, and what each step costs

Measured on unity-core-playground (5k files in the main tree; `External/asset-library` is 150,185 files, 28,242 of them LFS; `External/unity-core` has no LFS), 2026-10-21 to 2026-10-24. The binding runs `wt new` with `run-shell -b` and discards its output, so until step 4 the status line is the only feedback.

| # | step | where | cost |
|---|---|---|---|
| 1 | resolve the repo, take `~/.local/state/wt/new-<repo>.lock` | background | instant |
| 2 | `wt: finding a free <repo> slot...` | status line | instant |
| 3 | `wt_next_slot`: walk agent-1, 2, ... and take the first idle one | background | 0.7s (was 4.5 to 9s, #463) |
| 4 | `wt: recycle\|fresh <name>, opening it`, create the session, switch to it | status line, then the new session | instant |
| 5 | `git fetch origin` on the main checkout | the new session's first pane | 2.8s, network |
| 6 | `git switch -C agent-N origin/<trunk>` in the worktree | pane | 0.2s |
| 7 | copy each moved submodule's new commit from the main checkout into `refs/wt/main` | pane | 8 to 54ms (unity-core over the network was 1079ms, #474) |
| 8 | `GIT_LFS_SKIP_SMUDGE=1 git submodule update --recursive` | pane | no network when step 7 found the commit |
| 9 | `git lfs checkout -- <changed files>` in submodules that moved | pane | 0.07s for a real LFS file (a bare `lfs checkout` scanned the whole tree: 20s+, #456 #460) |
| 10 | delete the old merged branch, `wt: ready.` | pane | instant |

Steps 5 to 10 are `wt_prepare`/`wt_recycle`; a fresh slot replaces 6 to 9 with `git worktree add`. Before these fixes a recycle took 30s or more, nearly all of it step 9; the last full trace measured 7.6s with step 8 at 3.1s, which #474 then removed.

The git and git-lfs behaviour these steps are built around, none of it obvious:

- `git lfs checkout` with no paths walks every file in the tree, even when nothing changed. Given paths, it touches only those. Which files to pass comes from `git diff --name-only <old> HEAD` in each submodule, with the HEADs snapshotted before `submodule update`.
- `git submodule update` counts a commit as present only when a ref reaches it (`rev-list <commit> --not --all`); having the object in the store is not enough. A local fetch into `FETCH_HEAD` changes nothing; it has to land on a ref.
- That ref is `refs/wt/main` and never `refs/remotes/*`, because `wt_submodule_pushed` reads "on a remote ref" as "pushed", and a commit borrowed from the main checkout is not known to be pushed.
- Every worktree has its own submodule object store (agent-1: 88 MB unity-core, 48 MB asset-library). Sharing one through `objects/info/alternates` would be faster still, but a `gc` in the main checkout could then delete objects the worktrees depend on, so step 7 copies instead.
- In step 3 a slot with a live tmux session is skipped by asking tmux (45ms) before the git work check (~1s a slot, `git status` across the 150k-file submodule). With agent-1 to 9 live, that ordering was the whole silent wait.

#### Troubleshooting

| symptom | cause | fix |
|---|---|---|
| Nothing on screen for seconds after `Prefix+F` | step 3 doing git work on busy slots | fixed in #463; if it comes back, time `wt_next_slot` (below) |
| Pane sits on `fetching and checking out...` for 20s or more | bare `git lfs checkout` over asset-library | fixed in #456 and #460 |
| `git: 'credential-osxkeychain' is not a git command` (4 times) | the macOS keychain helper set for every OS in `.gitconfig`, and again per host in the private `private.inc` | fixed in #465 and the private repo's #222; the helper is now a no-op off macOS |
| `Pseudo-terminal will not be allocated because stdin is not a terminal.` | `RequestTTY yes` under `Host *` in `~/.ssh/config`; printed once per git-over-ssh connection | harmless and adds no time; still open |
| A wt LFS test passes locally but fails in CI | GitHub runners ship `/etc/gitconfig` with `filter.lfs.process`, which outranks a test's stubbed `filter.lfs.smudge` | the test sandbox sets `GIT_CONFIG_NOSYSTEM=1` (`tests/helpers/sandbox.bash`) |

#### Measuring it again

Run these from the repo's main checkout. The slot search is read-only:

```bash
bash -c 'source ~/.dotfiles/.local/src/tmux/worktree.sh
main=$(wt_main_repo .); base=$(wt_base_ref "$main" "$(wt_default_branch "$main")")
s=$(date +%s%3N); wt_next_slot "$(wt_repo_name "$main")" "$main" "$base"; echo "$(( $(date +%s%3N)-s ))ms"'
```

The slow half, with a timestamp on every command. This really recycles the slot you name, so pick an idle one (`wt_next_slot` says which):

```bash
bash -c 'source ~/.dotfiles/.local/src/tmux/worktree.sh
exec 9>/tmp/prepare.log; BASH_XTRACEFD=9; PS4="+\${EPOCHREALTIME} "; set -x
wt_prepare "$PWD" ~/.worktrees/<repo>-agent-N N recycle'
awk '{t=substr($1,2); if (p!="") printf "%7.2fs  %s\n", t-pt, p; pt=t; $1=""; p=substr($0,1,120)}' /tmp/prepare.log | sort -rn | head
```

Under zsh, write `${c}` rather than `$c` before a colon in a refspec: `$c:r` is a zsh filename modifier and silently mangles `"+$c:refs/..."`.

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
| `hub` - personal | **hub** (+ window `infra`: command-center.sh), dotfiles, watch (fleet-sessions watch), home-config (on demand) | today's daily note |
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

## Status Line Integration

`claude-status.sh` runs every 3 seconds to display agent status:
- `!n` = needs attention (n agents)
- `~n` = working (n agents)
- `✓n` = idle between turns (n agents). This is the live `activity`, not the delivery `bucket`: a session that is idle here can still be NEEDS or STALLED in `fleet-sessions` (vocabulary: `.local/src/docs/fleet-states.md`)
- `·n` = Claude panes found but none classified
