# notes

A single, profile-aware binary that owns all **journal + zettelkasten** logic for
the `~/.notes` vault. The git/MQTT **sync layer is separate** (shell + systemd/
launchd) and untouched — this tool only reads and writes note files.

Everything is pure Rust (chrono for dates), so behaviour is identical on macOS and
Linux: no GNU-vs-BSD `date`/`sed`/`stat` divergence, no Python-on-Mac drift.

## Why it exists

The old journal logic was split across `journal-create` (bash), two Python scripts,
and shell aliases — each with its **own hardcoded path**, so per-machine roots were
impossible and failures (a missing note, a mistyped heading) were silent. This binary
unifies all of it behind one config and adds a `doctor` command so problems are
visible instead of mysterious.

## Install

```sh
cargo build --release
ln -sf ../../.dotfiles/.local/src/notes-cli/target/release/notes ~/.local/bin/notes
```

`notes-bootstrap` does both automatically (and on every machine).

## Configuration

`~/.config/notes/config.toml` (symlinked from `~/.dotfiles/.config/notes/`). The
binary also falls back to `$NOTES_CONFIG` and `~/.dotfiles/.config/notes/config.toml`,
and to a built-in `personal` default if none exist.

Active profile resolves: `--profile` → `$NOTES_PROFILE` → `[hostname_map]` (by
`hostname -s`) → `default_profile`. This is what lets a corporate machine root its
daily notes inside `employment/jobs/<job>/` while a personal machine uses
`journal/daily` — same git repo, different active location.

**A job is one line.** Every path key defaults to the org convention (`daily/`, `refs/`,
`backlogs/fun.md`, `summaries/`, `daily_archive/`, `permanent/`, `meetings/`, `index/`,
`knowledge/`, `inbox/`, `projects/current`), so a new org is just its `root` plus whatever genuinely
differs. `personal` is the sole profile that overrides them all, because its root IS the
vault. An org that still holds a `log/` from before the directory was renamed is migrated
to `daily/` on the next `notes today`; a profile that explicitly pins `daily = "log"`
keeps it.

## Commands

| Command | What it does |
|---|---|
| `notes today` | Idempotent daily note. Carries unfinished **Focus** forward (day-stamped), surfaces anything the schedule fires, adds `## Projects`, links refs, regenerates the footer, publishes the status pages, and conforms a note an older build left behind. |
| `notes path` | Print today's note path (for `nvim "$(notes path)"`). |
| `notes link-refs` | Link today's `refs/<date>/*.md` into the note's `## Refs`. |
| `notes summarize [--date D] [--force]` | Append a day's summary to the continuous monthly log. **Dedup-safe**; WARNs on gaps/empty extraction. |
| `notes archive [--month M] [--dry-run] [--backfill]` | Roll a month into the monthly summary + move dailies to the archive tree. |
| `notes backlog <fun\|scheduled\|recurring>` | Open a standing backlog and print its path. `fun`/`scheduled` are tidied (sweep checked → `## Done`, restamp day counts); `recurring` is only ensured (never swept — its masters aren't checked off). |
| `notes focus [list]` | List today's open `## Focus` items — the daily cockpit's active-task list. Same items the session-start hook surfaces at turn 1. |
| `notes focus add "<text>"` | Append a new open task under today's `## Focus`, freshly day-stamped. Bootstraps today's note if absent. Keep it a couple words. |
| `notes focus done <word>` | Check off the first open `## Focus` item whose text matches `<word>` (case-insensitive). |
| `notes focus --all` | Cross-profile cockpit: aggregate every configured profile's open `## Focus` items as TSV `profile<TAB>file<TAB>line<TAB>key<TAB>text` (for editor/jump integration). Close a row with `notes --profile <p> focus done "<key>"`. |
| `notes inbox [list]` | Triage view of the dated-capture inbox — pending captures oldest-first with age + title, stale (≥14d) flagged. |
| `notes inbox add "<text>"` | Quick-capture: append a timestamped bullet to today's `inbox/<date>.md`. |
| `notes inbox archive <file>\|--stale\|--before D` | Drain triaged captures into `inbox/_archive/` (pick one selector). |
| `notes seed-backlogs [--from N] [--force]` | One-time migration: lift `## Fun` + `## Carry Over` out of a daily note into the backlog files. |
| `notes zettel new "<title>"` | Create `permanent/<id>-<slug>.md` (id = `YYYYMMDDThhmm`). |
| `notes index [--rebuild]` | Scan `[[wikilinks]]` across `permanent/` and `knowledge/`; report or rebuild `index/` backlinks + MOC (zettels by tag, then `## Knowledge` by subdir, each article with its title, summary and tags; `knowledge/_log/` is skipped). |
| `notes knowledge init [--force]` | Write `knowledge/SCHEMA.md`, the article contract (frontmatter, sections, links, tag vocabulary), from the template built into the binary (`src/knowledge_schema.md`). |
| `notes knowledge due [-n N]` | The N articles most due for a whole-article review, oldest `reviewed` first. |
| `notes knowledge apply <ops.json> [--started <unix>] [--dry-run]` | The only writer for the nightly knowledge engine: validates a batch of create/update ops (path under `knowledge/`, required frontmatter, shrink guard, loses to a human edit made after `--started`), snapshots a hand-written article to `_log/originals/` the first time it is rewritten, and writes the date's immutable log `knowledge/_log/YYYY/MM/YYYY-MM-DD.md`. The log is also the checkpoint: a date applies once. |
| `notes projects --move <name> --to-profile <dest>` | Move a project to another profile: same lifecycle dir (`current/` or `archived/`), same index lane on the other side. Refuses on an unknown or same profile, a name the destination already has, or a missing project, before writing anything. Links to the old path are counted, not rewritten. |
| `notes doctor` | Diagnose: config/profile, dirs, **summarize gaps**, heading validity, sync freshness, service status, dead links/orphans, **project layout** (loose `vX.Y.Z.md`/`changelog.md` at a project root, project dirs in no index lane, lane lines that are missing or point into another profile), and whether the **binary is stale** against its own source. |
| `notes config` | Print the resolved profile + all paths. |

`--verbose` echoes the structured log (also written to `~/.local/state/notes/journal.log`).

## Projects cheatsheet

This section is the one description of the lab. `~/.notes/lab/README.md`, the `lab-sync` skill and the `notes-system` skill link here instead of restating it.

### The lab tree

```
~/.notes/lab/
  README.md                                  pointer to this section
  ideas/                                     `_IDEAS.md` (`ideas` config key) and briefs for ideas with no project yet
  projects/{current,archived}/<name>/        the personal profile
  <org>/projects/{current,archived}/<name>/  an org profile, with its area files beside it (backlogs/, log/, schedule.md)
~/.notes/employment/jobs/<job>/projects/{current,archived}/<name>/   a client profile
```

Each profile's projects dir comes from `~/.config/notes/config.toml` (`notes config` prints it). The folder name is the project name, and it must be a key in `project-map.json` (`project-map-doctor` fails otherwise); `~/.agent/{plans,lessons,sessions,asks}/<name>` use the same name. A stage never moves a folder: the stage is the hashtag on the sheet's `Version:` line, and only `projects --archive` moves a folder, to `archived/`.

Each profile has a `projects/index.md`. lab-sync regenerates its `AUTO` overview; the CLI owns the `## Current` and `## Archived` lanes below it. A lane entry points at the project's `README.md`, never `summary.md`, and its path is relative to that profile's root. Do not hand-edit either half. `~/.notes/lab/projects/index.md` also rolls up every org, and `board.md` / `agent-board.md` beside it are every project's rows for its open version, read-only (`notes board`).

### A project directory

```
current/<name>/
  README.md                the working sheet: `Version: vX.Y.Z #<stage>`, then `## Inbox` and `## Tasks`
  summary.md               generated: a dated STATUS block (lab-status) and the AUTO release feed (lab-sync); no hand text
  agent/README.md          the agent board (`ptask --agent`): the same two sections, no `Version:` line (it follows the sheet)
  ideas.md                 unshaped ideas for this project (`#idea:<name>` in Focus lands here)
  playtest.md              type game only: things to play and check off, one per row (`ptask --playtest`)
  agent/versions/vX.Y.Z.md notes for a version, and the done rows `ptask --agent archive` or a release moves off the board
  versions/vX.Y.Z.md       frozen sheet of a closed version
  docs/                    every other note: the pitch, briefs, research, design docs, reviews, screenshots
```

Every project carries the same core: `README.md`, `summary.md`, `agent/README.md` and `ideas.md`, plus `versions/` and `docs/`. Anything else, including briefs and research, goes under `docs/`, and binaries (screenshots, renders) under `docs/assets/`; `notes doctor --projects` reports any other root entry. Version notes belong in `versions/` and nowhere else.

A project's `type` in `project-map.json` can add to the core through its `[project_type.<type>]` table, shipped in `notes-cli/templates/project_types.toml` (a table of the same type in `config.toml` replaces it on one machine): `files` lists extra root files the type carries (game carries `playtest.md`), and `requires` lists registry facts it needs (only `repo` is checked: `trackers.<name>.repo`, or the name registered in `paths`). A type with no table adds nothing. The root notes a project may hold are the core ones plus its type's `files`; a project with no type, or a machine with no registry, may hold any type's.

`projects --new <name>` writes the core and its type's files and never overwrites one, so on an existing project it fills the gaps. The name must already be registered in `project-map.json`, or it refuses and writes nothing (with no registry on the machine it does not check). `notes doctor` flags loose version notes and `projects --migrate` folds them in. `notes doctor --projects` checks the whole shape in every profile, one line per finding: missing files (core or type), a registry fact the type requires, loose root notes, an agent board over 32 KiB, and a row open twice. With no registry it prints one SKIP line, because type overlays cannot be checked.

### One home per fact

| Fact | Its one home | Written by |
|---|---|---|
| Name, lab profile, type, repo, path in the repo, branch, tracker, release epic, tag glob | `project-map.json` (private dotfiles) `trackers.<name>` | a PR there |
| Stage, version in progress, open rows and rows aimed at a later release | the sheet `README.md` | human, `notes ptask` / `projects` |
| Where we are | `summary.md` STATUS | `lab-status` |
| Shipped version | the git tag | the release |
| What shipped, for users | the repo's `CHANGELOG.md` | the release |
| What each closed version did | `versions/vX.Y.Z.md` | `projects --release` |
| How it works: stack, build, ship, runbooks, architecture decisions | the repo's `docs/` | docs-write |
| Pitch, product briefs, research, reviews | the project's `docs/` here | human, skills |
| Agent plans, lessons, sessions, asks, queue | `~/.agent/<kind>/<name>` | agents |
| Agent key facts at session start | `~/.agent/anchors/<name>.md` | project-index |

The session preflight reads the anchor and the agent board, not `summary.md`. The `## -> For the agents` section and the `<!-- canonical: -->`, `<!-- cockpit: -->` and `<!-- tagglob: -->` markers are retired (wiring is the registry entry); to ask an agent for something, add a row to the board.

After creating, staging, releasing or archiving a project, moving rows between projects, or editing a summary or index, run `lab-refresh`: it regenerates every feed, every index and both boards in about 12 s. The CLI runs it in the background after its own project verbs; failures land in `~/.local/log/lab-refresh.log`.

Every command takes `--profile <p>`. Without it, the active profile is used (`notes config`).

| I want to | Command |
|---|---|
| see projects | `notes projects`, `notes projects --archived`, `notes projects <name>` for its files |
| add a project | `project-map add <name> --type game\|app\|infra --lab <profile>`, plus `--repo <key> --path <dir>` for part of a repo or `--repo-dir <abs>` for a whole one; it writes the registry entry, scaffolds the folder, regenerates the anchor and runs `project-map-doctor`. Land the registry change with dotfiles-land |
| fill in a missing shape file | `notes --profile bnb projects --new <name>` |
| check every project's shape | `notes doctor --projects` |
| set where it shows in the Overview | `projects --stage <name> --set draft\|alpha\|beta\|prod` |
| show it under another group heading | `projects --group <name> --set <profile>\|dev` |
| move it to another profile | `notes --profile personal projects --move <name> --to-profile bnb` |
| retire it, or bring it back | `projects --archive <name>`, `projects --restore <name>` |
| close a version | `projects --release <name>` (`--minor`, `--major`, `--next vX.Y.Z`, `--carry`); refused for a `#draft` or `#alpha` project, which keeps one working list. The agent board follows the sheet: done rows go to `agent/versions/<old>.md`, open rows and done rows tagged for a later release stay. The frozen note ends in `## PRs`, every PR named on the closed rows of both lanes, dropped rows left out. `agentctl-wave-roll` runs it when a release tag reaches the sheet, and `project-map-doctor` fails a shipping app whose sheet is behind its newest tag |
| fix an old layout | `projects --migrate <name>`; also moves a playtest row's inline `(pr:N)` into its `<!-- pr:N -->` comment, and aligns a stale agent board to the sheet's version |
| see the roadmap | `projects --roadmap <name>`, `projects --version-of <name>` |
| every project's counts at once | `projects --stats` (TSV, what the projects popup reads); `--stats --json` adds each project's dir, open version, done count, goal, `progress` (the open version's open and done rows, their size weight #size/s 1, m 3, l 8, unsized 1, and the rows and weight closed in 7 and 28 days, by each row's `done:YYYY-MM-DD` stamp or for older rows the `## Proof` table) and dated STATUS line; `regen-anchor.sh` renders it as an anchor's `## Lab` section and the hub Projects tab draws its cards from it |
| add a task | `notes ptask <name> add "<text> #low"`, or `--to vX.Y.Z` to aim it at a later release; `--detail "<line>"` (repeatable) adds an indented detail line under it. On the human sheet, text that is not yet `type(area): title` goes to `## Inbox` for the triager (Intake, below) |
| send a Focus row to a project | put `#p:<name>` on it; `notes focus sweep` moves it, with its indented lines and without the tag, to that sheet's `## Inbox`. A name that is no project leaves the row in Focus |
| drop work for any project | `notes outbox add "<text>"`, or type a line under `## Outbox` in `<vault>/outbox.md` (linked first in the daily note's `## Morning`, beside the inbox page). The inbox sweep picks each line's project, moves it with `notes outbox move --project <p> -- "<raw>"` into that sheet's `## Inbox`, and files it there. `#p:<name>` forces the project and `#agent` the agent board. A missing outbox is made, with its heading, when the daily note links it. `notes outbox list [--json]` shows what waits |
| see what was ingested and where | `status/inbox.md`, linked under the outbox at the top of `## Morning`. One row per line, the same shape whatever the source: `HH:MM <verb> [<id>] in <project> (<lane>): <words>`, the project a link to its sheet, with sub-lines only when they say something. Under **Needs you**: `left` and `refused` (with `why:`), `waiting in the outbox`, `captured` (today's `notes inbox add` lines, with `(sess <id>)` when a session wrote them). Under **Handled today**: `filed` (the row as filed; `was:` when the words changed), `joined` (an open row already asked it), `planned` (with what the planner `added:`), and `moved` (in a project inbox, waiting to be filed). Last, **Waiting in project inboxes** links each sheet whose `## Inbox` holds lines, with the count. A line's source shows only as `from:`: `outbox`, `focus` (a `#p:` Focus row), or nothing for a line typed into its project's own inbox (by hand, `ptask add`, agent-web's Add). A guide line under the stat says what each verb means. Its source is the ingest record `<state_dir>/ingest.jsonl`, one event per move, filing, plan or line left (`notes ingest record --action left\|refused\|planned` for the runners' own). Its stat line ends with `triage kept N of M as filed (7d)`: a filing counts as kept while its row is in the project and lane it was filed to, not dropped or a dup, with its words (the row without its tags, as the record's `row` holds them) unchanged, so the human's edits score the triage and no model does. The machine that holds the record owns the page; `notes ingest page` republishes it |
| see what waits in an inbox | `ptask <name> inbox` (TSV `path, line, text`), `--json` for `{line, raw, text, details, typed}` |
| file an inbox line | `ptask <name> [--exact] file "<query>" --as "<type(area): title #tags>"` (repeat `--as` to split one line into several rows; no `--as` files a line that is typed already as written), with `--project <other>`, `--lane agent`, `--to vX.Y.Z` or `--detail "<line>"`; or `--dup <id>` to add it to the open row it repeats |
| work a task | `ptask <name> start "<query>"`, then `ptask <name> done "<query>" --proof pr:123` (or `--unverified "<why>"`) |
| aim a task at another release | `ptask <name> move "<query>" --to vX.Y.Z`, `ptask <name> promote\|demote "<query>"` |
| move a task to another project | `ptask <name> move "<query>" --project <other>`; its detail lines and child rows go with it |
| tag a task | `ptask <name> tag "<query>" --add=size/s --add=requested --remove=ai`; a row has one size, so a new `size/` replaces the old; a release is `move`'s |
| change a task's text | `ptask <name> edit "<query>" --append "<more>"` or `--text "<new text>"`; keeps its place, state and tags. `--detail "<line>"` adds a detail line after the row's existing ones, alone or with either. `--was` with `--text` is the triager's rewrite: the text must be `type(area): title` with a title of 80 chars or fewer, the old words become a `was:` detail line, and the old row's own tags (`#ask`, `#tier/N`, `#size/x`) carry over unless the new text sets one of the same name; a rewrite to the row's own words writes nothing |
| drop a task | `ptask <name> drop "<query>" --why "<why>"`, or `--dup <id>` for a duplicate; the row stays, ticked, with the reason in its marker |
| name a row exactly | any verb's `<query>` can be the row's id (`ar-142`) |
| tidy a sheet | `ptask <name> sweep` |
| agent work | the same `ptask` verbs with `--agent`, which write to `agent/README.md` |
| shrink the agent board | `ptask <name> --agent archive [--dry-run]` moves its done rows to `agent/versions/<current version>.md` under `## Done rows` |
| add a playtest check | `ptask <name> --playtest add [--game <name>] [--pr <n>] "<scene or mode: what to look for>"`; one short ASCII line per check, under `## <game>` (default `## General`) in `playtest.md` |
| work the playtest list | `ptask <name> --playtest list`, `ptask <name> --playtest done "<query>" --proof <ref>` (or `--unverified "<why>"`), `ptask <name> --playtest drop "<query>" --why "<why>"`; the board shows one `N playtest checks waiting -> playtest.md` line per project |
| regenerate the boards | `notes board` |
| see one release | `notes board --version vX.Y.Z [--project N]` (read-only): every row aimed at it across profiles and both lanes, open rows then closed ones with their PRs, plus rows already frozen into `versions/`. A row's release is its `#vX.Y.Z` tag, or its sheet's `Version:` when untagged, the same rule `--release` gates on and freezes by |
| feed a board UI | `notes board --json` (read-only, below); act on a row with `ptask <name> [--agent\|--playtest] --exact <verb> -- "<raw>"` |

The quick way in is the tmux popup: `Prefix+p`, or `<leader>np` from nvim. It lists every profile's projects, main ones first (drafts behind `d`), each with its stage and open count, and shows the selected project's card and open rows beside the list. `1`-`9` or Enter opens a project's tasks, where `a` adds, `m` moves a task to another project, `x` checks it off (asks for a proof), `+`/`-` move it a release sooner or later and `o` opens the sheet at that row. On the project list, `n` is new, `s` stage, `x` archive and `o` open. `/` searches; Esc steps out of the search, then the filter, then the view. Moving a project between profiles and changing its group stay CLI-only (the table above).

The human sheet (`README.md`) is the queue: what you asked for and what only you can do. Agents keep their own work on `--agent`. The full rules are in the `notes-system` skill, "Project board".

### The task row

Every project sheet, in every project and both lanes, uses one row format. Projects differ only by data in the registry, never by row format.

```
- [ ] fix(fleet-sessions): class a gh gate-wait shell as a gate wait #high #size/s #c1104 <!-- id:ar-142 -->
  Seen agent-10, run 41893820093: the row reads STALLED while its gate runs.
```

| Part | Required | Rule |
|---|---|---|
| `[ ]` `[/]` `[x]` | yes | open, doing (a queue item exists), closed |
| `type(area): title` | agent lane yes; human lane at triage | Types: `feat fix perf refactor docs test chore ci` for work, `run decide check` for what only the human can do. The area is one lowercase kebab word naming the component. The title is imperative, 80 chars or fewer, and becomes the PR title. |
| detail lines | no | indented two spaces under the row: evidence, file:line, the human's original words. They move with the row through sweep, move and archive. |
| priority | yes, exactly one | `#urgent`, `#high` or `#low`; a bare add gets `#high` |
| created | yes, stamped | `#cMMDD`, stamped by `ptask add` |
| id | yes, stamped | `id:<code>-<n>` in the marker, stamped by `ptask add`, or by `ptask start` on a row with none. `code` is the project's `trackers.<name>.code` in the registry (2-4 lowercase letters, unique; `project-map-doctor` checks it). `n` is one past the highest id anywhere under the project dir, both lanes, playtest and `versions/`, so an id is never reused. A project with no code gets no id, and `ptask add` says so. |
| size | no | `#size/s` (small single PR), `#size/m` (one PR), `#size/l` (needs a plan); there is no hour estimate |
| `#tier/N` `#worker/X` `#vX.Y.Z` `#dueMMDD` | no | as the feed above reads them |
| `#ask` | no | the human asked for this, and only the human drops it undelivered. A question for the human is an `agent-ask`, never a row. |
| marker | on close | `<!-- ... -->` at the end: `pr:N`, a run id or URL, `unverified: <why>`, `dropped: <why>`, `dup:<id>` |

No assignee field: the lane is the assignee. No comment thread: detail lines plus the PR. No per-project custom fields.

Intake: the human lane takes free text, and it waits in the sheet's `## Inbox` (from `ptask add`, a `#p:<name>` Focus row, agent-web's Add, or typed there by hand). `ptask file` is the one way out: it takes the line off the inbox and writes the typed rows in one write per sheet, stamped like an add plus `filed:<date>` in the marker, with the human's words as a `was: <words>` detail line (none when the line is filed as written) and the line's own indented lines after it. An `#agent` word in the line files its rows on the agent board, without the tag. It refuses an untyped row, a row `notes doctor` would flag (a retired priority such as `#medium`, two priorities, a retired tag) and a `--dup` id with no open row, before writing anything. The triager, `agentctl-inbox-triage`, runs it in one sweep over the outbox and every inbox. Its runner is `--watch` (`inbox-triage.conf`, KIND=persistent): a sweep at start, then one each time `outbox.md` or a project sheet is saved and `INBOX_SWEEP_QUIET` seconds (30) pass with no other save, so a line typed by hand is filed as fast as one a CLI wrote. An outbox line with `#p:<name>` is moved to that inbox and a line already typed is filed as written, both with no model; the rest of the sweep goes to one model call (the conf's MODEL, Opus: routing and the row are the plan of the work) that proposes the project, lane and rows, a duplicate or a skip, and flags work that needs planning before it starts, which files with `#plan`. The planner, `agentctl-inbox-plan` (`inbox-plan.conf`, Opus), takes every open row with `#plan`, the triager's or one a person typed: the sweep starts it with no wait when `agentctl-inbox-plan --waiting` says a row waits. Per row (`INBOX_PLAN_MAX` a pass, oldest first) one model call reads the row, its details, its board's open rows and, read-only, the project's code, and `ptask edit --exact` adds `goal:`, `approach:` and `check:` detail lines, sets the size and takes `#plan` off; work of more than one PR becomes rows added beside it, each with a `part of <id>` detail. A plan it cannot write is recorded as refused, so the row keeps its `#plan` and is not asked about again until its words change. An outbox line is moved with `notes outbox move` and then filed from its project's inbox. A write that lands during a sweep changes `<state_dir>/inbox.changed`, so the sweep repeats, at most `INBOX_TRIAGE_PASSES` times, and while the fleet is paused a save waits for the resume. A skipped or refused line stays where it was (outbox or inbox); nothing drops one. Its `left` or `refused` event in the ingest record keeps it out of later sweeps until its words change, and `status/inbox.md` shows it with the reason. `agentctl-inbox-triage --backlog [--project <name>]` puts the rows already on both boards through the same triage, the project with the most open rows first: per row the model proposes keep, a rewrite (`ptask edit --was`), a move to the project the row is about (`ptask move --project`, which the project-map's `repo` field informs: a game whose code lives in the playground repo owns its rows), a dup of another row or a drop with its reason (`ptask drop`, which keeps the row ticked), all `--exact`; a row in progress is only rewritten. Agent-lane rows are written in this form from the start.

Closing: every close says how. `ptask done --proof <ref>` for something checkable, `ptask done --unverified "<why>"` when there is nothing to check, `ptask drop --why "<why>"` or `--dup <id>` for one that will not be delivered. Nothing deletes a row: a dropped row stays as `[x]` with its reason, keeps its detail lines and child rows, and leaves with the done rows on the next archive or release. A board row that runs as a session goes row -> `fleet-dispatch promote` -> queue item (its slug and `from` are the row's id, its priority the row's, high on a bare row) -> session -> PR carrying `Task: <id>` -> `agent-land` closes the queue item and, by id, the row with `pr:N` -> `ptask sweep` moves it to `### Done` -> `ptask --agent archive` or `projects --release` into `versions/`. The proof lives on the row and travels with it.

`notes doctor --projects` checks this per sheet, one line per finding, and writes nothing: a priority word no reader knows (`#normal`, `#medium`, `#p0`-`#p3`), two priorities on one row, a retired tag (`#oneshot`, `#ci`, `#ai`, `#high-priority`), a `since:` stamp, a tier that is not `#tier/1`, `2` or `3`, and an agent-board done row with no proof marker (an `id:` alone is not proof). On the agent board it also counts the open rows not in `type(area): title` form, those with a title over 80 chars and those with no id, one line each. Human sheet rows are free text and closed by hand, so those checks skip them.

### The task feed

`notes board --json` prints one object, `{"today": "YYYY-MM-DD", "projects": [...], "rows": [...]}`, covering every project in every profile. It is the one shape the board UIs read. It is a view and nothing more: each call re-reads the sheets, and nothing gets written.

- A project is `{profile, project, dir, version, open, agent_open, playtest_open, inbox}`, `inbox` the lines waiting in the sheet's `## Inbox`. A project with no rows is still listed, so a UI can offer `add` on it.
- A row is one open task, from the sheet's open version (`lane: "human"`), the agent sheet's open version (`"agent"`), `playtest.md` (`"playtest"`), or the `## Focus` section of a profile's today note (`"focus"`). Its fields are `{profile, project, lane, version, game, state, priority, tier, worker, ask, id, type, area, size, text, tags, marker, since, filed, sheet, line, raw}`.
- A focus row has `project: null`: Focus belongs to the profile. The feed only reads it; `notes focus` stays its writer.
- `state` is `open` or `doing` (`[/]`).
- `priority` is `urgent`, `high` or `low`. An untagged row is `high`.
- `tier` is the `#tier/N` tag (1 to 3, as `fleet-dispatch` reads it), `worker` the `#worker/<name>` tag, `ask` true for an `#ask` row, and `version` the open version every row on the feed belongs to.
- `id` is the row's `id:<code>-<n>`, `type` and `area` the split `type(area):` prefix (null on a row without a well-formed one), and `size` the `#size/s|m|l` letter.
- `tags` holds the hashtags that no other field carries already: not the priority, tier, worker, ask, size, version or created tags.
- `marker` is the inner text of the row's `<!-- ... -->` comment: `pr:N`, `ask:ID`, a proof.
- `filed` is the `YYYY-MM-DD` of the row's `filed:` marker token, the day `ptask file` took it off an inbox (agent-web's Filed today section compares it to the feed's `today`, so the CLI's clock decides).
- `version` is null for a playtest row, and `game` is null for a sheet row.

To write, a UI passes the row's `raw` back to `ptask --exact`, which acts only on the open row whose line is exactly that, byte for byte. If someone else has edited, ticked or dropped the row since the UI read it, nothing matches, nothing is written, and the exit code is 1, so the UI refreshes. That is the concurrency control, which is why a UI writes by `raw` and not by `id`: the id names the row, not the version of it the UI showed. Two identical open lines on one sheet are refused too: the text cannot say which one the UI meant.

## Daily-note model

Lean by design: **ONE** task list, `## Focus`, swept into `### Urgent` / `### High` /
`### Low` / `### Done` lanes. There is no second inline list. `## Due` (and its `## Priority`
ancestor) was removed because two lists in one note make every glance a merge, and anything a
schedule surfaces IS today's work; a note left over from an older build has its Due items
folded into Focus on the next run. A row tagged `#idea` leaves Focus for `lab/ideas/_IDEAS.md`, and one tagged `#idea:<project>` for that project's `ideas.md` (the CLI sweep only; the nvim sweep leaves them). **Fun** is a standing backlog file linked in the footer.
Completed items move to a `## Done` section in the same file (history via git +
`daily_archive/`), so there's no separate done log.

**Time-triggered tasks** all live in one `schedule.md` (its `scheduled.md` + `recurring.md`
ancestors were merged and renamed aside). What a line does is decided by its TOKEN, not by
which file it sits in: `[YYYY-MM-DD]` fires ONCE within the lead window and the master line is
consumed; `(every:…)` fires each matching day and the master is kept, so the habit returns
every cycle and missed days are simply skipped. Cadences: `every:fri`, comma lists
`every:mon,thu`, `every:weekday` (Mon-Fri), `every:day`, and day-of-month `every:1st` /
`every:15th` / `every:last`. Tagging a surfaced task with a far-future date pushes it back out
to the schedule, which is what makes the date a two-way verb.

Which backlogs the footer links is config-driven via `footer_links` (names: `backlog`/`fun` |
`schedule`, or a vault-relative path; default `["backlog", "schedule"]`) - edit that list in
`config.toml`, no recompile. `footer_backlogs` is the old key name, still read as an alias.

**The note is written once a day.** `notes today` builds the note when it creates it, and after that only you write to it. Everything that changes during the day lives on a status page beside the note under `<root>/status/`, reached from the footer (the inbox page from Morning):

- `status/watches.md` - Sentinel watches (set `watches = "~/.agent/watches"`; state read from `~/.local/state/watch-companion/<name>.state`). Read-only against the Sentinel runtime.
- `status/comms.md` - the mail triage poller's surface file plus its stats line. Skipped on a machine without comms config, so it never overwrites the page another machine publishes.
- `status/inbox.md` - what the intake sweep did with each line today, what waits on you, and today's quick-captures; its row shape is in the Intake table above.

A note written by an older build has its `## Watches`, `## Comms`, `## Inbox` and `## Work` sections removed once each page is on disk.

**Projects** - the note's one generated section, rendered at creation: quick links to every project tagged `#beta` or `#alpha` (see `notes projects --stage`) in this org and in each org listed in `rollup`, one small `### <org>` block per org that has any. Prod and draft projects are left out. Links are vault-relative, so they resolve from any org.

**Morning** - below Notes and Focus (above Projects and Refs), re-rendered only when it changes: first the Outbox and Inbox links (no counts, for the footer's reason), then the morning briefing (`journal/refs/<date>/briefing.md`: its headline, which carries Lazer month-to-date spend, and its "Needs you" items; it is not repeated under Refs) and every knowledge-engine log from the last week that the previous note did not already list, with the articles it created or updated. With nothing new it names the last compile date, so a stalled engine shows.

**Footer** - one `- Label: [[target]]` per line below a `---`: the `footer_links` files, the project board and agent board, this org's project index, the knowledge MOC, and the Watches and Comms pages. It carries no counts, so it only changes when the set of links does.

## What runs, and when

Everything that reads or writes the vault on its own, and what sets it off. Change a trigger and this table in the same PR.

| When | What runs | What it changes |
|---|---|---|
| You open today's note from notes.nvim, or run `today` / `notes today` | `notes today` | Creates the note if it is missing, refreshes Morning and the footer, writes `status/watches.md`, `status/comms.md`, `status/inbox.md` and the board file, then runs the Focus sweep (next row) |
| `notes today`, `notes focus sweep`, `notes clickup sync` | the Focus sweep | Regroups `## Focus` into its lanes, moves `#idea` rows to their ideas file and each `#p:<name>` row to that project's `## Inbox` (recorded as `moved`, `from: focus`) |
| You save a note in nvim | `markdown.lua` save hooks | Stamps new tasks with a date and regroups the Focus lanes, with no moves; on a daily note, `notes clickup push` sends the status of ClickUp-linked rows |
| You save `outbox.md`, a project `README.md` or its `agent/README.md` | `agentctl@inbox-triage` (`--watch`, always on), once 30s pass with no other save | Moves outbox lines to their project, files inbox lines as rows (one Opus call for the untyped ones), republishes `status/inbox.md`, and starts the planner when a `#plan` row waits |
| The triage sweep, when a `#plan` row waits | `agentctl@inbox-plan` | Adds `goal:`, `approach:` and `check:` lines to the row, sets its size, splits it when it is more than one PR |
| Any file under `~/.notes` changes | `notes-watch`, 3s after the last change, then `notes-sync`; `git-sync-notes.timer` runs the same sync every 30s | Commits, pulls and pushes the vault. `notes-mqtt` and `notes-ntfy` start a pull when another machine pushes |
| :00 and :30 every hour | `agentctl@comms` | Mail triage; its surface file feeds `status/comms.md` |
| 06:45 and 18:45 | `agentctl@briefing` | `journal/refs/<date>/briefing.md`, which Morning shows; the evening asks page |
| 23:00 | `agentctl@nightly-sync` | Reads recent notes into mem0; writes nothing in the vault |
| 00:30 | `agentctl@knowledge-engine` | Compiles the daily notes into `~/.notes/knowledge/` |
| 01:00 | `journal-daily-summarize` | `notes summarize`: yesterday's note gets its summary |
| 01:15 | `journal-index-rebuild` | `notes index --rebuild`: backlinks and the Map of Content |
| The 2nd of the month, 01:30 and 01:45 | `journal-monthly-archive`, `journal-refs-archive` | `notes archive` moves old daily notes to `daily_archive/`; `archive-refs` moves old ref folders |

To see them live: `agentctl list` for the agentctl runners, `systemctl --user list-timers` for the clock rows, and `status/inbox.md` for what the Focus sweep and the triager did with each line today. The shell aliases (`.commonrc`) `today`, `fun`, `co`, `zk` and `ndoctor` call the binary; the legacy `journal-create` and its two Python scripts are deprecated fallbacks.

## Tests

`cargo test` — covers the historically fragile bits: date/day-count stamping,
carry-forward filtering, section extraction, profile + hostname resolution,
backlog sweep, link extraction.
