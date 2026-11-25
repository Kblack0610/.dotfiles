//! `notes` — a single, profile-aware binary that owns all journal + zettelkasten
//! logic for the `~/.notes` vault. The git/MQTT sync layer lives elsewhere (shell);
//! this tool only reads and writes note files.
//!
//! Everything here is pure Rust (chrono for dates) so behaviour is identical on
//! macOS and Linux — no GNU-vs-BSD `date`/`sed`/`stat` divergence.

mod agent_sheet;
mod archive;
mod backfill;
mod backlog;
mod board;
mod clickup;
mod comms;
mod config;
mod daily;
mod doctor;
mod epics;
mod find;
mod focus;
mod focus_move;
mod focus_sweep;
mod gate;
mod improve;
mod inbox;
mod inbox_ack;
mod index;
mod ingest;
mod knowledge;
mod knowledge_gate;
mod knowledge_hubs;
mod knowledge_lint;
mod knowledge_mv;
mod knowledge_registry;
mod knowledge_repo;
mod knowledge_retired;
mod lab_refresh;
mod logging;
mod md;
mod meeting;
mod migrate_rows;
mod outbox;
mod playtest;
mod project_sweep;
mod project_tasks;
mod projects;
mod propose;
mod rank;
mod reasons;
mod report;
mod sheet;
mod shipped;
mod show;
mod standing;
mod status;
mod steps;
mod summarize;
mod sweep;
mod tags;
mod window;
mod zettel;

use agent_sheet::Lane;
use anyhow::{bail, Result};
use clap::{Parser, Subcommand};
use project_tasks::Pick;

#[derive(Parser)]
#[command(
    name = "notes",
    version,
    about = "Profile-aware journal + zettelkasten CLI"
)]
struct Cli {
    /// Echo log lines to stderr as well as the journal log file
    #[arg(short, long, global = true)]
    verbose: bool,

    /// Override the active profile (else $NOTES_PROFILE / hostname map / default)
    #[arg(long, global = true)]
    profile: Option<String>,

    #[command(subcommand)]
    cmd: Cmd,
}

#[derive(Subcommand)]
#[expect(
    clippy::large_enum_variant,
    reason = "parsed once per process; boxing the Projects flags buys nothing"
)]
enum Cmd {
    /// Create today's daily note (idempotent), then link refs + backlogs
    Today {
        /// Create today's note for EVERY configured profile, not just the active one
        #[arg(long)]
        all: bool,
    },
    /// Print a resolved profile path for editor/shell integration.
    /// target: daily (default) | daily-dir | archive | refs | refs-today | root | backlog | scheduled | recurring | zettel | meetings | index | inbox | inbox-today
    Path {
        #[arg(default_value = "daily")]
        target: String,
    },
    /// One note for a viewer: daily (default), daily:YYYY-MM-DD, or a [[wikilink]] target,
    /// resolved like the editor's gf and kept inside the notes
    Show {
        #[arg(default_value = "daily")]
        target: String,
        /// One JSON object: path, rel, title, exists, date, prev, next, hash, markdown, links
        #[arg(long)]
        json: bool,
    },
    /// Replace a note with stdin when its hash (`show --json`'s `hash`) is still BASE; exit 3
    /// and write nothing when it changed since
    Put {
        target: String,
        #[arg(long, value_name = "BASE")]
        base: String,
    },
    /// Rebuild today's refs index and point today's note's `## Refs` at it
    LinkRefs,
    /// Agent reports for the human, one per file in the day's refs folder: add (or revise),
    /// list across days, mark read
    Report {
        #[command(subcommand)]
        sub: report::Cmd,
    },
    /// Summarize a day's note into the continuous monthly log (dedup-safe)
    Summarize {
        /// Date to summarize (YYYY-MM-DD); defaults to yesterday
        #[arg(long)]
        date: Option<String>,
        /// Append even if the date is already present in the log
        #[arg(long)]
        force: bool,
    },
    /// Roll up + archive a month's daily notes
    Archive {
        /// Month to process (YYYY-MM); defaults to the previous calendar month
        #[arg(long)]
        month: Option<String>,
        /// Show what would happen without writing or moving anything
        #[arg(long)]
        dry_run: bool,
        /// Process every past month that still has daily notes
        #[arg(long)]
        backfill: bool,
    },
    /// Open + tidy a standing list (`backlog`, `scheduled`, or `recurring`); prints its path
    Backlog {
        /// List name: backlog (default) | scheduled | recurring
        #[arg(default_value = "backlog")]
        name: String,
        /// File the task lines on stdin into the backlog, stamped with today (nvim `<leader>tb`)
        #[arg(long)]
        add: bool,
    },
    /// Today's cockpit: the daily note's `## Focus` active-task list (list / add / done).
    /// No subcommand = list. Same items the session-start hook surfaces.
    Focus {
        /// Aggregate open Focus across ALL configured profiles, for the cross-profile
        /// cockpit (TSV: `profile<TAB>file<TAB>line<TAB>key<TAB>text`). Read-only.
        #[arg(long)]
        all: bool,
        #[command(subcommand)]
        sub: Option<FocusCmd>,
    },
    /// Per-project task list - the `## Tasks` on a project's sheet (the project analog of
    /// `focus`, which is the daily note's `## Focus`). Project tasks live in the project .md.
    Ptask {
        /// Project name (case-insensitive)
        name: String,
        /// Act on the project's AGENT sheet (`agent/README.md`) - the working board where
        /// subtasks and in-flight state live - instead of the queue on its own README. Goes
        /// before or after the verb (`ptask <name> reopen --agent ...` parses too)
        #[arg(long, global = true)]
        agent: bool,
        /// Act on the project's `playtest.md`: one row is one thing to play and check off.
        /// Takes `list`, `add` (with `--game`, `--pr`), `done`, `drop` and `pass` only
        #[arg(long, conflicts_with = "agent")]
        playtest: bool,
        /// The query is one whole open task line, byte for byte (the `raw` field of
        /// `notes board --json`), not words from it. For a UI: a row edited since it was
        /// read matches nothing, so nothing is written and the exit is 1. Pass the line
        /// after `--`, since it starts with `-`
        #[arg(long)]
        exact: bool,
        #[command(subcommand)]
        sub: Option<PtaskCmd>,
    },
    /// Regenerate the project/agent board - every project's `## Tasks`, agent lane
    /// first, across every profile — and print its path. Also refreshed by `notes today`.
    /// The daily note LINKS this rather than rendering it: the note is the human's focus,
    /// the board is one click away.
    Board {
        /// Print every open row of every project as JSON instead of writing the board:
        /// the human and agent sheets' open-version rows and the playtest checks, across all
        /// profiles. READ-ONLY. The feed the board UIs read; the row shape is in the README
        #[arg(long, conflicts_with = "agent")]
        json: bool,
        /// With --json: the feed's `done` lists the rows closed in the last N days, the
        /// ones already rolled into `agent/versions/` included. Without it, `done` is each
        /// sheet's `### Done` as the sweep left it
        #[arg(long, value_name = "N", requires = "json")]
        done_days: Option<i64>,
        /// Print the agent-lane rows as `<project>\t<text>` instead of writing the board.
        /// READ-ONLY: this path never touches board.md. Exits 0 even with no rows —
        /// "nothing queued for the agent" is a valid answer, not an error, and the
        /// session preflight that calls this must never be able to lose a turn over it.
        #[arg(long)]
        agent: bool,
        /// Print the release view instead of writing the board: every row aimed at
        /// vX.Y.Z, open and closed, both lanes, with the closed rows' PRs. A row's release
        /// is its `#vX.Y.Z` tag, or its sheet's `Version:` when untagged; rows already frozen
        /// into `versions/vX.Y.Z.md` are included. With --json, the same rows as JSON (id,
        /// state, priority, PRs) with each project's window days. READ-ONLY
        #[arg(long, value_name = "vX.Y.Z", conflicts_with_all = ["agent", "done_days"])]
        version: Option<String>,
        /// Limit to these projects (repeatable). Names are the LAB project names, which
        /// are not the same namespace as the agent-side project name: a session in
        /// ~/.dotfiles resolves to `dotfiles`, whose lab projects are `notes-cockpit` and
        /// `agent-runtime`. Callers join the two through project-map.json
        /// `trackers.<n>.repo` (see `project_lab_names` in project-name.sh) and pass the
        /// results here. Ignored without --agent or --version.
        #[arg(long = "project")]
        projects: Vec<String>,
        /// With --json: print only the rows with this id (repeatable) as `{today, rows}`,
        /// wherever each sits: open in any version or closed (dropped and dup-closed too), on
        /// either lane's sheet or rolled into a version note. A dup-closed row's `dup` names
        /// the row it was folded into. READ-ONLY
        #[arg(long = "id", value_name = "ID", requires = "json", conflicts_with_all = ["agent", "version", "done_days"])]
        ids: Vec<String>,
        /// Read `git grep` lines of agent sheets on stdin (`[<rev>:]<path>/agent/README.md:<line>`)
        /// and print one JSON object per task row with an id: project, id, state (open, done,
        /// dropped) and weight by the rule every rollup uses. READ-ONLY: day-log weighs the board
        /// at a past notes commit through this, so the points rule has one home
        #[arg(long, conflicts_with_all = ["json", "agent", "version", "done_days"])]
        weigh: bool,
    },
    /// Triage the dated-capture inbox (list / add / archive), and mark inbox page rows
    /// reviewed (ack). No subcommand = list.
    Inbox {
        #[command(subcommand)]
        sub: Option<InboxCmd>,
    },
    /// The outbox (`<vault>/outbox.md`): drop work for any project; the inbox sweep routes
    /// each line to its project's inbox. No subcommand = list.
    Outbox {
        #[command(subcommand)]
        sub: Option<OutboxCmd>,
    },
    /// Keep an agent's nice-to-have in the project's `improvements.md`, never as a board row
    /// (the triager's `improvement` verdict). Writes only that file; `ideas.md` is the person's
    Improve(improve::Args),
    /// The ingest record (`<state>/ingest.jsonl`) that the inbox status page shows
    Ingest {
        #[command(subcommand)]
        sub: IngestCmd,
    },
    /// Compiled knowledge base under knowledge/ (written by the nightly engine)
    Knowledge {
        #[command(subcommand)]
        sub: KnowledgeCmd,
    },
    /// Zettelkasten operations
    Zettel {
        #[command(subcommand)]
        sub: ZettelCmd,
    },
    /// Meeting log operations
    Meeting {
        #[command(subcommand)]
        sub: MeetingCmd,
    },
    /// Scan `[[wikilinks]]`; report or rebuild the backlink + MOC index
    Index {
        /// Write the index/ MOC + backlink files (otherwise just report)
        #[arg(long)]
        rebuild: bool,
    },
    /// Scan the vault for tags (inline `#hashtag` + frontmatter `tags:`). No arg lists
    /// every tag with a count, topics before task tags; `<name>` prints each matching line as
    /// `path<TAB>line<TAB>text`. Every profile's project boards count too, task rows only.
    Tags {
        /// Tag to show hits for (leading `#` optional). Omit to list all tags.
        name: Option<String>,
        /// List only `task` tags (row state like `#high`, `#size/s`) or `topic` tags.
        #[arg(long, value_enum, conflicts_with = "name")]
        kind: Option<md::TagKind>,
    },
    /// Ranked lookup over the vault's knowledge: articles, zettels, refs, employment/ and lab/.
    /// Words are OR-ed and ranked (notes with every word first), `#tag` filters, `"a phrase"`
    /// boosts, `-word` excludes; typos and half-typed words still match. Prints
    /// `path<TAB>line<TAB>score<TAB>title<TAB>snippet`, best first.
    Find {
        /// The query, e.g. `ai oauth`, `#interview system design`, `"cert pinning" -android`.
        #[arg(num_args = 0.., trailing_var_arg = true, allow_hyphen_values = true)]
        query: Vec<String>,
        /// Most hits to print.
        #[arg(short = 'n', long, default_value_t = 30)]
        limit: usize,
        /// Print hits as JSON.
        #[arg(long)]
        json: bool,
        /// Score the engine against an eval file (`query<TAB>path[;path]`, `-` for none).
        #[arg(long, value_name = "FILE", conflicts_with_all = ["query", "json"])]
        eval: Option<std::path::PathBuf>,
    },
    /// List the indexed projects behind the board and the daily note's footer link.
    /// No arg lists each as `name<TAB>summary-path<TAB>status`; `<name>` lists that
    /// project's note files as `path<TAB>label` (summary first).
    #[command(group(clap::ArgGroup::new("hours_with").args(["commit", "prio"]).multiple(true)))]
    Projects {
        /// Project to list files for. Omit to list all indexed projects.
        name: Option<String>,
        /// Create a new project under `current/` + the index's `## Current` lane
        #[arg(long, value_name = "NAME")]
        new: Option<String>,
        /// Archive a project: move to `archived/` + the `## Archived` lane
        #[arg(long, value_name = "NAME")]
        archive: Option<String>,
        /// Restore an archived project back into `current/` + `## Current`
        #[arg(long, value_name = "NAME")]
        restore: Option<String>,
        /// List archived projects instead of the current ones
        #[arg(long)]
        archived: bool,
        /// Close a project's open version: its closed rows freeze into versions/ and
        /// `Version:` moves to the next one, at any stage. With no level the bump is derived:
        /// minor when a feature epic closed on proof in the version, else patch
        #[arg(long, value_name = "NAME")]
        release: Option<String>,
        /// Split the open version's closed record (its agent note) into one version per ISO
        /// week before this one, numbered by the release rule, and open the next patch. A
        /// project with no frozen version starts at a v0.1.0 baseline. Needs --weekly
        #[arg(long, value_name = "NAME", requires = "weekly")]
        backfill: Option<String>,
        /// With --backfill: one version per week (the only split there is)
        #[arg(long, requires = "backfill")]
        weekly: bool,
        /// With --backfill: a repo whose commits before the first week the baseline counts by
        /// system. Repeatable
        #[arg(long, value_name = "PATH", requires = "backfill")]
        repo: Vec<std::path::PathBuf>,
        /// Consolidate a project onto the one version layout: fold changelog/ and loose
        /// root vX.Y.Z.md notes into versions/ and backfill each version's agent note.
        /// Works on archived projects too. Never overwrites; idempotent.
        #[arg(long, value_name = "NAME")]
        migrate: Option<String>,
        /// Move a project to another profile (with --to-profile): same lifecycle dir
        /// (current/ or archived/) and same index lane on the other side. Links to the
        /// old path elsewhere are counted, not rewritten
        #[arg(long = "move", value_name = "NAME", requires = "to_profile")]
        move_project: Option<String>,
        /// With --move: the destination profile
        #[arg(long, value_name = "PROFILE", requires = "move_project")]
        to_profile: Option<String>,
        /// Remove the retired `#ai` tag from live project sheets (the lane is the agent
        /// sheet now). Bare = every project in the profile; with a NAME = just that one.
        /// Frozen versions/ notes keep their tags as history. Idempotent.
        #[arg(long, value_name = "NAME", num_args = 0..=1, default_missing_value = "")]
        retire_ai_tag: Option<String>,
        /// Migrate every project sheet and agent board, in every profile, onto `## Tasks`
        /// and the row grammar: ids, `#c` tags, no retired tags, done rows under `### Done`.
        /// Exact duplicates are reported, never removed. Idempotent
        #[arg(long)]
        migrate_rows: bool,
        /// Sweep every project sheet and agent board, in every profile, into Now / Next up /
        /// Board (agent boards) / Backlog / Done, rolling closed rows past the `[sheet]` window into versions notes
        #[arg(long)]
        sweep: bool,
        /// With --retire-ai-tag, --migrate-rows, --sweep or --backfill: report what would change and write nothing
        #[arg(long)]
        dry_run: bool,
        /// With --release: step the patch (v0.1.2 -> v0.1.3). With no level the bump is
        /// derived: minor when a feature epic closed on proof in the version, else patch
        #[arg(long, conflicts_with_all = ["minor", "major"])]
        patch: bool,
        /// With --release: step the minor (v0.1.2 -> v0.2.0)
        #[arg(long, conflicts_with = "major")]
        minor: bool,
        /// With --release: step the major (v0.1.2 -> v1.0.0)
        #[arg(long)]
        major: bool,
        /// With --release: close the version even though it still has open rows; they stay open
        #[arg(long)]
        force: bool,
        /// With --release: aim every open row at the next version (retagged, `carried:N`
        /// counted) before closing, and append to an existing versions/ note rather than
        /// refusing. What a release tag does to its sheet (`agentctl-wave-roll`)
        #[arg(long)]
        carry: bool,
        /// With --release: open exactly this version next (vX.Y.Z, above the current one)
        /// instead of stepping. For a sheet a release tag has already passed, so it lands
        /// after the tag in one release rather than creeping up a patch at a time
        #[arg(long, value_name = "VERSION")]
        next: Option<String>,
        /// With --release --next: allow a version BELOW the open one, to realign a sheet whose
        /// number ran ahead of the app's release tags (it could never be tagged, so tags
        /// would never close it). `notes-roll` checks the target is above the newest tag
        #[arg(long)]
        renumber: bool,
        /// With --release: the release tag closing the version (vX.Y.Z). The frozen note is
        /// named from it; a tag below the open version gets a note with no planned rows and
        /// leaves the sheet open (`agentctl-wave-roll`)
        #[arg(long, value_name = "VERSION")]
        tag: Option<String>,
        /// With --release --tag: the project's release tags, one `vX.Y.Z<TAB><tag name>` a
        /// line, so each closed row freezes under the first tag containing its `commit:`
        /// (`notes-roll` passes it with --checkout)
        #[arg(long, value_name = "FILE", requires_all = ["tag", "checkout"])]
        family: Option<std::path::PathBuf>,
        /// With --family: the checkout the tags are in
        #[arg(long, value_name = "PATH", requires = "family")]
        checkout: Option<std::path::PathBuf>,
        /// Print a project's current version
        #[arg(long, value_name = "NAME")]
        version_of: Option<String>,
        /// Print a project's roadmap: the open version, then the releases rows are aimed at
        /// (TSV: `version<TAB>state<TAB>open<TAB>done<TAB>open_weight<TAB>done_weight<TAB>
        /// unsized_open`, both lanes' leaf rows; --json adds closes, scope growth and epics)
        #[arg(long, value_name = "NAME")]
        roadmap: Option<String>,
        /// Print a project's past sprints, oldest cut first (TSV: `version<TAB>opened<TAB>cut<TAB>
        /// committed<TAB>delivered<TAB>carried<TAB>dropped<TAB>interrupted<TAB>timing`), one per
        /// scored `sprints/vX.Y.Z.md`; --json adds each score line. With --version vX.Y.Z (and
        /// --json): that one sprint's page instead, its head and every row with its outcome
        #[arg(long, value_name = "NAME")]
        sprints: Option<String>,
        /// Every profile's indexed projects with their open work, for the projects popup
        /// (TSV: `profile<TAB>name<TAB>stage<TAB>version<TAB>open<TAB>urgent<TAB>high<TAB>
        /// low<TAB>planned<TAB>agent<TAB>sheet`; the counts are the open version's, planned
        /// is the rows aimed at a later release, agent is the agent board's)
        #[arg(long)]
        stats: bool,
        /// With --stats, --roadmap or --sprints: one JSON array instead. For --stats it adds each project's dir, done count, progress, epics, size weights, STATUS line and date, and summary path
        #[arg(long)]
        json: bool,
        /// Print a project's maturity stage; with --set, declare it (a move up runs project-stage-check first).
        /// One of the ladder `--stages` prints (requirements: ~/.local/src/docs/stages.md)
        #[arg(long, value_name = "NAME")]
        stage: Option<String>,
        /// Print the maturity ladder, least to most real, on one line. Shell readers take
        /// the vocabulary from here instead of keeping a copy
        #[arg(long)]
        stages: bool,
        /// Print the file the project in DIR declares its stage and priority on: its working
        /// sheet, else, for a game its parent versions, its README, else its summary.md. The
        /// shell's head-tag readers (lab-feed.sh `lab_front_page`) take the path from here
        #[arg(long, value_name = "DIR")]
        front_page: Option<std::path::PathBuf>,
        /// Print a project's index group; with --set, declare it. Unset means the
        /// project's own profile (bnb, personal); `tooling` is the tooling lane.
        #[arg(long, value_name = "NAME")]
        group: Option<String>,
        /// Print `focus` while a project is on focus; with --set focus, put it on focus (its
        /// release windows run as sprints), --set normal takes it off. It ranks nothing: a row's
        /// own priority orders work. The retired high and low are refused
        #[arg(long, value_name = "NAME")]
        prio: Option<String>,
        /// Every profile's projects on a live focus, as `name<TAB>focus`
        #[arg(long)]
        prios: bool,
        /// Print the version a project promises and its day (`vX.Y.Z YYYY-MM-DD`, the sheet's
        /// `Target:` line); with --set 'vX.Y.Z YYYY-MM-DD', promise it; --set none clears it.
        /// The human's promise, beside the cadence cut; --stats --json emits it
        #[arg(long, value_name = "NAME")]
        target: Option<String>,
        /// Record the rows the open version commits to (its release window: the rows that fit its
        /// capacity), once, in the `## Committed` section of its `sprints/<version>.md`. A cut records the next
        /// window itself; this is for a window already open. On a focus project a later add then
        /// goes to the next window unless it is an interrupt (stages.md, "Release windows")
        #[arg(long, value_name = "NAME")]
        commit: Option<String>,
        /// With --commit: lock the window as a sprint of this many hours from now. It replaces an
        /// earlier snapshot with the rows that fit that many hours of the agent lane's shipped
        /// weight, #urgent and in-progress rows first, and records the cut (`cut=` in the head).
        /// With --prio --set focus: how long the focus lasts (default 4, at most 24); past its
        /// end the project is off focus
        #[arg(long, value_name = "H", requires = "hours_with")]
        hours: Option<f64>,
        /// With --commit --hours: queue a sprint behind the open one while it runs: the patch after
        /// the last sprint already queued, so any number chain, or the version named
        /// (`--queue v0.5.5` relocks that one). It takes the rows tagged #v<that version> and starts
        /// at the cut of the window before it. A roll opens the next one as it is
        #[arg(long, value_name = "VERSION", num_args = 0..=1, default_missing_value = "", requires = "hours")]
        queue: Option<String>,
        /// The value to write, for --stage / --group / --prio / --target. Omit to read.
        #[arg(long, value_name = "VALUE")]
        set: Option<String>,
        /// Print (creating if absent) the path to a version's agent note,
        /// `agent/versions/<vX.Y.Z>.md`
        #[arg(long, value_name = "NAME")]
        agent_note: Option<String>,
        /// With --agent-note: which version (defaults to the open one). With --sprints --json: print only
        /// this sprint's page; without it, list every scored window
        #[arg(long, value_name = "VERSION")]
        version: Option<String>,
    },
    /// Surface multi-account email triage into the daily note's `## Comms` section.
    /// No subcommand = list the currently-surfaced items for the active profile.
    /// The pull/label/classify work is done out-of-band by the triage poller.
    Comms {
        #[command(subcommand)]
        sub: Option<CommsCmd>,
    },
    /// The row grammar `type(area): title` (README "The task row"), for scripts and prompts
    /// that would otherwise keep their own copy
    Row {
        #[command(subcommand)]
        sub: RowCmd,
    },
    /// Mirror in-progress ClickUp tickets assigned to me into today's `## Focus`.
    /// Opt-in per profile via `clickup_list`; a no-op where it is unset.
    Clickup {
        #[command(subcommand)]
        sub: ClickupCmd,
    },
    /// Sweep one sheet file by path into Now / Next up / Board (an agent board) / Backlog / Done (the editor's save hook)
    SheetSweep {
        /// The sheet: a project README.md or its agent/README.md
        path: std::path::PathBuf,
        /// Read the buffer from stdin and print the swept buffer; the file is not written
        #[arg(long)]
        stdin: bool,
        /// With --stdin: only re-sort the sections, stamping and rolling off nothing
        #[arg(long, requires = "stdin")]
        layout_only: bool,
        /// Report what would change and write nothing
        #[arg(long)]
        dry_run: bool,
    },
    /// Diagnose the notes system (config, dirs, gaps, sync, dead links)
    Doctor {
        /// Instead: check every project in every profile against the project shape, one
        /// `<profile>/<project>: <finding>` line each
        #[arg(long)]
        projects: bool,
        /// With --projects: list instead each open agent-board row with no type and the row
        /// proposed for it, `<profile>/<project><TAB><id><TAB><row>`. Writes nothing
        #[arg(long, requires = "projects")]
        untyped: bool,
    },
    /// What was written to which row, and by whom: today, or `--day` / `--days`
    Log {
        /// One day, `YYYY-MM-DD`
        #[arg(long, conflicts_with = "days")]
        day: Option<String>,
        /// The last N days, today included
        #[arg(long)]
        days: Option<i64>,
        /// Only events from or to this project, or `focus` or `outbox`
        #[arg(long)]
        project: Option<String>,
        /// Only this row, like ucp-79
        #[arg(long)]
        id: Option<String>,
        /// Only this action, like `dropped`
        #[arg(long)]
        action: Option<String>,
        /// Only this writer: `human`, a queue item or a session's first 8 characters
        #[arg(long)]
        by: Option<String>,
        /// Only events of this agent-queue item, like fix-menu
        #[arg(long)]
        item: Option<String>,
        /// The whole record replayed into the chain's steps, inbox to done: per step what it
        /// holds, its oldest, in and out over 1h and 24h, and dwell p50/p90 in minutes
        #[arg(long, conflicts_with_all = ["day", "days", "project", "id", "action", "by", "item"])]
        steps: bool,
        /// One line's whole path, from the record's 30 days: the events whose words hold WORDS
        /// (or whose row is the id WORDS), then every event of the rows it was filed as and of
        /// the queue items they became, to the merge. For "where did my line go?"
        #[arg(long, value_name = "WORDS", conflicts_with_all = ["day", "days", "project", "id", "action", "by", "item", "steps"])]
        trace: Option<String>,
        /// One JSON event per line (one object per step with --steps)
        #[arg(long)]
        json: bool,
    },
    /// Print the resolved profile + paths
    Config {
        /// List every profile this machine lists instead (a work profile only on its own machine)
        #[arg(long)]
        profiles: bool,
        /// Print this machine's own profile: the one picked with no --profile flag
        #[arg(long, conflicts_with = "profiles")]
        machine_profile: bool,
    },
}

#[derive(Subcommand)]
enum ClickupCmd {
    /// Fetch + reconcile: push status edits up, then pull in-progress tickets into `## Focus`.
    Sync,
    /// Push status edits (`[/]`/`[x]`) on cu-linked `## Focus` items up to ClickUp (no fetch;
    /// the fast on-save path).
    Push,
}

#[derive(Subcommand)]
enum RowCmd {
    /// One row or row text per stdin line -> one `type area title ok` TSV line each, `ok` 1
    /// when it parses; an empty field prints as `-`. Hashtags and stamps are not the title
    Parse,
    /// The types a filer may give a row, one space-separated line (`epic` is the human's)
    Types,
}

#[derive(Subcommand)]
enum CommsCmd {
    /// List the currently-surfaced comms items for the active profile (the default)
    List,
    /// Re-render today's note's `## Comms` section from the triage surface file
    Refresh,
    /// Show configured accounts + whether each has a surface file (read-only)
    Status,
    /// Cross-account email stats dashboard (cached snapshot; --fresh for live IMAP)
    Stats {
        /// Regenerate live from IMAP (runs comms.stats_bin) instead of the cached snapshot
        #[arg(long)]
        fresh: bool,
    },
}

#[derive(Subcommand)]
enum FocusCmd {
    /// List today's open focus items (the default)
    List,
    /// Add a focus item — keep it a couple words, plain, no fluff
    Add {
        /// Task text (free-form)
        #[arg(required = true, num_args = 1..)]
        text: Vec<String>,
    },
    /// Check off the first open item whose text matches
    Done {
        /// A word (or two) from the task to close
        #[arg(required = true, num_args = 1..)]
        query: Vec<String>,
    },
    /// Move a task to another profile and/or re-tag its project
    Mv {
        /// A word (or two) from the task to move
        #[arg(required = true, num_args = 1..)]
        query: Vec<String>,
        /// Destination profile (default: stay in the current one)
        #[arg(long)]
        to: Option<String>,
        /// Set the project tag (prefix), replacing any existing one
        #[arg(long)]
        tag: Option<String>,
        /// Remove the project tag
        #[arg(long)]
        untag: bool,
    },
    /// Delete the first open item whose text matches (removes the line entirely)
    Rm {
        /// A word (or two) from the task to delete
        #[arg(required = true, num_args = 1..)]
        query: Vec<String>,
    },
    /// Toggle the first matching task between todo and in-progress ([ ] <-> [/])
    Start {
        /// A word (or two) from the task
        #[arg(required = true, num_args = 1..)]
        query: Vec<String>,
    },
    /// Hand the first open item whose text matches, with its indented lines, to the outbox
    /// for the inbox sweep to file, and take it out of Focus. Nothing else ingests Focus.
    Ingest {
        /// A word (or two) from the task to ingest
        #[arg(required = true, num_args = 1..)]
        query: Vec<String>,
    },
    /// Reorganize today's `## Focus` by status (todo / in progress / done); moves nothing out
    Sweep,
}

/// The arguments of `ptask tag`.
#[derive(clap::Args)]
struct TagArgs {
    /// A tag to add (`#` optional). Repeatable
    #[arg(long, value_name = "TAG")]
    add: Vec<String>,
    /// A tag to take off (`#` optional). Repeatable
    #[arg(long, value_name = "TAG")]
    remove: Vec<String>,
    /// Why the row has its priority: a slug of `priority-reasons.tsv`. It writes `#why/<slug>`
    /// (replacing the row's reason) and the reason's priority, unless `--add` names one
    #[arg(long, value_name = "SLUG")]
    why: Option<String>,
    #[arg(required = true, num_args = 1..)]
    query: Vec<String>,
}

/// `notes ptask <name> ...` verbs - the project analog of `FocusCmd`, on the sheet's `## Tasks`.
#[derive(clap::Subcommand)]
enum PtaskCmd {
    /// List the open version's rows (TSV: `path<TAB>line<TAB>key<TAB>text`;
    /// with --version/--all a fifth `version` column is appended)
    List {
        /// Only the rows of this release (`vX.Y.Z`), open or later
        #[arg(long, value_name = "VERSION")]
        version: Option<String>,
        /// Every open row on the sheet, whichever release it is aimed at
        #[arg(long)]
        all: bool,
    },
    /// Add a task to the open version, or aim it at a later release with --to. Exit 3 and
    /// write nothing when an open row on the sheet has the same text, nearly the same text,
    /// or lands the same PR
    Add {
        /// Aim it at this release instead (`vX.Y.Z`)
        #[arg(long, value_name = "VERSION")]
        to: Option<String>,
        /// With --playtest: the `## <game>` heading the check goes under (default General)
        #[arg(long)]
        game: Option<String>,
        /// With --playtest: the PR the check is for, written as `<!-- pr:<n> -->`
        #[arg(long, value_name = "N")]
        pr: Option<u64>,
        /// A detail line under the row: evidence, file:line, the original words. Repeatable
        #[arg(long, value_name = "LINE", allow_hyphen_values = true)]
        detail: Vec<String>,
        /// The channel a human's want entered by (outbox, focus, voice, request, ask, meeting,
        /// human): the row gets `#requested` and the ingest event names the channel
        #[arg(long, value_name = "CHANNEL")]
        want: Option<String>,
        /// The writer this add is for: `plan` (a plan's phases) or a name on `agent_direct_filers`
        /// files its row now, when the process vouches for it. Otherwise a queue item's or
        /// runner's add goes to the outbox for inbox-triage (exit 4), and a hand session's runs
        /// triage's checks first
        #[arg(long, value_name = "NAME")]
        origin: Option<String>,
        /// The shortlist ids a hand session read and found to be other work (comma-separated or
        /// repeated). Its add exits 5 with the shortlist until every id shown is named here
        #[arg(long, value_name = "IDS", value_delimiter = ',')]
        checked: Vec<String>,
        /// Why the row has its priority: a slug of `priority-reasons.tsv`. It writes `#why/<slug>`
        /// and, when the text names no priority, the reason's own
        #[arg(long, value_name = "SLUG")]
        why: Option<String>,
        #[arg(required = true, num_args = 1..)]
        text: Vec<String>,
    },
    /// Aim the first matching open task at another release, or with --project move it onto
    /// another project's sheet (its open version, or the release --to names)
    Move {
        /// The release to aim it at (`vX.Y.Z`). Optional with --project
        #[arg(long, value_name = "VERSION", required_unless_present = "project")]
        to: Option<String>,
        /// Move the row to this project instead (any profile; with --agent, agent sheet to
        /// agent sheet). Its old release tag goes unless --to names one
        #[arg(long, value_name = "PROJECT")]
        project: Option<String>,
        #[arg(required = true, num_args = 1..)]
        query: Vec<String>,
    },
    /// Check off the first open task whose text matches. Needs evidence: pass
    /// --proof for something checkable, or --unverified to say out loud that there is none
    Done {
        /// Something checkable later: `pr:1142`, `run:<id>`, a URL
        #[arg(long, value_name = "REF")]
        proof: Option<String>,
        /// No checkable artifact exists, and this is why
        #[arg(long, value_name = "WHY")]
        unverified: Option<String>,
        /// The day it closed, YYYY-MM-DD, when that is not today (a backfill closes a row on the
        /// day its PR merged). Never a future day
        #[arg(long, value_name = "DAY")]
        on: Option<String>,
        /// What happens to its open children: `drop` closes each with this row's stamp, an id
        /// (like ar-142) moves them under that row. Without it, open children refuse the close
        #[arg(long, value_name = "drop|ID", value_parser = project_tasks::Children::parse)]
        children: Option<project_tasks::Children>,
        #[arg(required = true, num_args = 1..)]
        query: Vec<String>,
    },
    /// Re-date a closed row's `done:` day (a backfill that stamped the apply day). The row is
    /// picked by its id and must already be closed with a `done:` day
    Redate {
        /// The day it closed, YYYY-MM-DD; never a future day
        #[arg(long, value_name = "DAY")]
        on: String,
        /// Print `id<TAB>old<TAB>new` and write nothing
        #[arg(long)]
        dry_run: bool,
        /// The row's id, as `ar-142`
        id: String,
    },
    /// Undo a false close: the closed row with this id back to todo, its done or drop stamp
    /// off the marker. A row already archived moves back onto its sheet. The id finds the row in
    /// either lane, so `--agent` is not needed
    Reopen {
        /// What made the close false (the log keeps it)
        #[arg(long, value_name = "WHY")]
        why: String,
        /// The row's id, as `ar-142`
        id: String,
    },
    /// Add or take hashtags off the first matching open task (before its marker). A release
    /// tag is refused: move, promote and demote own it
    Tag(TagArgs),
    /// Mark the matching task in progress (`[ ]` -> `[/]`); a started row is left as it is
    Start {
        #[arg(required = true, num_args = 1..)]
        query: Vec<String>,
    },
    /// The matching task's queue item started: `[/]` plus `run:MMDD`, which puts it in Now
    /// (a started row without it is queued, in Next up); agent-queue writes it
    Run {
        #[arg(required = true, num_args = 1..)]
        query: Vec<String>,
    },
    /// Put the matching in-progress task back to todo (`[/]` -> `[ ]`); a todo row is left as it is
    Unstart {
        #[arg(required = true, num_args = 1..)]
        query: Vec<String>,
    },
    /// Close the first matching open task undelivered: the row stays, ticked, with the
    /// reason in its marker. Needs --why or --dup
    Drop {
        /// Why it will not be delivered: stale, superseded, or where it moved ("moved: ideas.md")
        #[arg(long, value_name = "WHY")]
        why: Option<String>,
        /// It duplicates this row (its id, like ar-142); its open children move under that row
        #[arg(long, value_name = "ID")]
        dup: Option<String>,
        /// What happens to its open children: `drop` closes each with this row's stamp, an id
        /// (like ar-142) moves them under that row. Without it, open children refuse the close
        #[arg(long, value_name = "drop|ID", value_parser = project_tasks::Children::parse)]
        children: Option<project_tasks::Children>,
        #[arg(required = true, num_args = 1..)]
        query: Vec<String>,
    },
    /// With --playtest: a build is cut, so file one `check(playtest): play build <build>, N
    /// checks` row on the human sheet, N the open checks, each stamped with the row's id so
    /// closing the row done closes them. The same build again is exit 3
    Pass {
        /// The build to play: a Steam build id, a branch, a tag
        #[arg(long)]
        build: String,
        /// Count only this `## <game>`'s checks, and name it in the row
        #[arg(long)]
        game: Option<String>,
    },
    /// Change the first matching open task's text in place: its place on the sheet,
    /// its checkbox state and its dates, priority, parent link (#of/) and sizing (#size, #pts)
    /// stay as they were, and a #c or #of/ tag typed in --text is dropped when the row has one;
    /// any other tag is what --text types
    Edit {
        /// The task's new text
        #[arg(
            long,
            conflicts_with = "append",
            required_unless_present_any = ["append", "detail", "brief"]
        )]
        text: Option<String>,
        /// Words to add to the end of the task's text
        #[arg(long)]
        append: Option<String>,
        /// A detail line to add under the row, after its existing ones. Repeatable
        #[arg(long, value_name = "LINE", allow_hyphen_values = true)]
        detail: Vec<String>,
        /// The row's whole brief, replacing its detail lines (its child rows stay): how
        /// `agent-queue retask` corrects a task, since the row is the task's record
        #[arg(long, value_name = "TEXT", allow_hyphen_values = true, conflicts_with_all = ["detail", "was", "text", "append"])]
        brief: Option<String>,
        /// The triager's rewrite: --text must be `type(area): title`, the old words stay as a
        /// `was:` detail line (a title over 80 chars is cut at a word, whole on a `full:` line), and the old row's own tags (#requested, #tier/N, #size/x) carry over
        #[arg(long, requires = "text")]
        was: bool,
        /// Link the new text as `add` would: a leaf with no `#of/` whose area is one of the
        /// project's systems goes under that system's standing epic, filed when missing; any
        /// other leaf with no `#of/` is refused and nothing is edited
        #[arg(long, requires = "text")]
        link: bool,
        #[arg(required = true, num_args = 1..)]
        query: Vec<String>,
    },
    /// Step the first matching task one release SOONER (toward the open version).
    /// Clamps there: nothing may sit before the version in flight
    Promote {
        #[arg(required = true, num_args = 1..)]
        query: Vec<String>,
    },
    /// Step the first matching task one release LATER, onto the next patch version
    /// when no later release is on the sheet
    Demote {
        #[arg(required = true, num_args = 1..)]
        query: Vec<String>,
    },
    /// Lay the sheet out in Epics, Now, Next up, Board (an agent board), Backlog and Done, roll closed rows past the
    /// Done window into versions/, and drop release tags the sheet has passed
    Sweep {
        /// Print what would change and leave the sheet alone
        #[arg(long = "dry-run")]
        dry_run: bool,
    },
    /// Print the `type(area): title` row proposed for this text, tags off and the title cut to
    /// the limit. Writes nothing
    Propose {
        /// The row's words
        #[arg(required = true, num_args = 1.., allow_hyphen_values = true)]
        text: Vec<String>,
    },
    /// Turn each list waiting in `## Inbox` into one line per ask. A triage sweep's first step
    Split,
    /// List the lines waiting in `## Inbox`, oldest first (TSV `path<TAB>line<TAB>text`)
    Inbox {
        /// One JSON array of `{line, raw, text, details}` instead
        #[arg(long)]
        json: bool,
    },
    /// The open rows closest to a text, best first (TSV `id<TAB>percent<TAB>text`), by the
    /// scoring a near-duplicate is refused by. Reads only. The triager's shortlist of the rows
    /// a line may repeat
    Similar {
        /// How many rows at most
        #[arg(long, default_value_t = 10)]
        top: usize,
        /// One JSON array of `{id, percent, text}` instead
        #[arg(long)]
        json: bool,
        #[arg(required = true, num_args = 1.., allow_hyphen_values = true)]
        text: Vec<String>,
    },
    /// Take the first inbox line matching the query off `## Inbox` and onto the board as
    /// typed rows (`--as`, repeatable to split a pile), or into an open row it duplicates
    /// (`--dup`). The human's words stay as a `was:` detail line. The triager's write path
    File {
        /// A typed row to file it as: `type(area): title`, with its priority and size tags.
        /// None files a line that is typed already as written
        #[arg(long = "as", value_name = "ROW")]
        rows: Vec<String>,
        /// It duplicates this open row (its id): its words join that row as a detail line
        #[arg(long, value_name = "ID", conflicts_with_all = ["rows", "to", "detail"])]
        dup: Option<String>,
        /// It asks for no row: the line leaves the inbox, recorded as `dropped` with `--why`
        #[arg(long, conflicts_with_all = ["rows", "dup", "to", "detail", "want"])]
        skip: bool,
        /// File it on this project's board instead (any profile)
        #[arg(long, value_name = "PROJECT")]
        project: Option<String>,
        /// The board lane it goes to: `human` (default) or `agent`
        #[arg(long, value_name = "LANE", default_value = "human")]
        lane: String,
        /// Aim the rows at this release (`vX.Y.Z`)
        #[arg(long, value_name = "VERSION")]
        to: Option<String>,
        /// Another detail line under each row, after the `was:` line. Repeatable
        #[arg(long, value_name = "LINE", allow_hyphen_values = true)]
        detail: Vec<String>,
        /// The channel the line came in by (as `add --want`): each row gets `#requested`
        #[arg(long, value_name = "CHANNEL", conflicts_with = "dup")]
        want: Option<String>,
        /// How the filing was decided, kept on its ingest event (`notes log` shows it)
        #[arg(long, value_name = "WHY")]
        why: Option<String>,
        #[arg(required = true, num_args = 1..)]
        query: Vec<String>,
    },
    /// With --agent: move the agent board's done rows into `agent/versions/<vX.Y.Z>.md`
    /// (the note their proof is in), under `## Done rows`
    Archive {
        /// Print how many rows would move and leave both files alone
        #[arg(long = "dry-run")]
        dry_run: bool,
        /// Instead move the done rows a roll-off filed under `versions/v0.0.1.md` since the open
        /// window opened into the open version's note, where the sprint count reads them
        #[arg(long)]
        rehome: bool,
    },
}

#[derive(Subcommand)]
enum OutboxCmd {
    /// Turn each list waiting in the outbox into one line per ask. A triage sweep's first step
    Split,
    /// The lines waiting, oldest first (TSV `line<TAB>text`)
    List {
        /// One JSON array of `{line, raw, text, details, project, look, question}` instead
        #[arg(long)]
        json: bool,
    },
    /// The items as agent-web's Daily outbox edits them (`--json`: `{path, hash, text, waiting, tags}`)
    Show {
        #[arg(long)]
        json: bool,
    },
    /// Replace the items with stdin when the file's hash is still BASE; exit 3 and write
    /// nothing when it changed since
    Put {
        #[arg(long, value_name = "BASE")]
        base: String,
    },
    /// Append a line and wake the inbox sweep
    Add {
        #[arg(required = true, num_args = 1..)]
        text: Vec<String>,
    },
    /// Move the line that is RAW byte for byte into PROJECT's `## Inbox` (the sweep's write path)
    Move {
        #[arg(long, value_name = "PROJECT")]
        project: String,
        /// How the project was picked, kept on the `moved` event (`notes log` shows it)
        #[arg(long, value_name = "WHY")]
        why: Option<String>,
        #[arg(required = true, num_args = 1..)]
        raw: Vec<String>,
    },
    /// Take the `#ask` or `#investigate` line that is RAW byte for byte out of the outbox and write
    /// it, with the answer on stdin, to today's `inbox/<date>.md` (the sweep's write path for a look)
    Answer {
        #[arg(required = true, num_args = 1..)]
        raw: Vec<String>,
    },
    /// Take the line that is RAW byte for byte out of the outbox, filing nothing, because the
    /// person said it needs no row (the sweep's write path for a "drop" answer), or the triager
    /// skipped a session's follow-up
    Drop {
        /// Why it was dropped, kept on its `dropped` event
        #[arg(long, value_name = "WHY")]
        why: Option<String>,
        #[arg(required = true, num_args = 1..)]
        raw: Vec<String>,
    },
    /// The intake tags a line may carry and what each does (TSV `tag<TAB>does`, `--json`:
    /// `[{tag, does}]`), the table the outbox header and agent-web's legend print
    Tags {
        #[arg(long)]
        json: bool,
    },
}

#[derive(Subcommand)]
enum IngestCmd {
    /// Record one step the CLI did not make itself: a line the sweep `left` for the human, one
    /// it `asked` the human about (`--why` is the ask's id), one whose write was `refused`, a row the planner `planned`, or a chain step a shell writer
    /// made (agent-queue's `item-*`, fleet-dispatch's `started`, `reaped`, `settled`,
    /// agent-land's `merged`, claude-acct's `parked` and `unparked`). An empty flag value is no value.
    Record(Box<RecordArgs>),
    /// Append the queue-item events of a fleet worker's record (JSONL on stdin) this record lacks,
    /// word for word once, then print the newest instant the input carried (fleet-dispatch's
    /// next read of that worker starts there)
    Import,
    /// Publish the inbox status page from the record and the outbox (the sweep runs it)
    Page,
}

/// `notes ingest record`: one chain event a shell writer made, appended to the record.
fn ingest_record(prof: &config::Profile, r: RecordArgs) -> i32 {
    let RecordArgs {
        action,
        from,
        to,
        stage,
        why,
        id,
        item,
        by,
        pr,
        sha,
        near,
        text,
    } = r;
    let set = |v: Option<String>| ingest::set(v.as_deref());
    let mut ev = ingest::Event::new(&action, &from, to.as_deref().unwrap_or(""), &text.join(" "));
    ev.stage = Some(stage);
    ev.why = set(why);
    ev.id = set(id);
    ev.item = set(item).or(ev.item);
    if let Some(b) = set(by) {
        ev.by = b;
    }
    ev.pr = set(pr);
    ev.sha = set(sha);
    ev.near = set(near);
    ingest::record(prof, &ev);
    0
}

/// `notes ingest import`: a worker's record on stdin; prints where its next read starts.
fn ingest_import(prof: &config::Profile) -> anyhow::Result<i32> {
    let mut input = String::new();
    std::io::Read::read_to_string(&mut std::io::stdin(), &mut input)?;
    let (n, next) = ingest::import(prof, &input)?;
    eprintln!("ingest import: {n} line(s) taken");
    println!("{}", next.unwrap_or_default());
    Ok(0)
}

/// `notes ingest record`: boxed, so the enum stays small.
#[derive(clap::Args)]
struct RecordArgs {
    #[arg(long, value_parser = [
        "left", "asked", "refused", "planned", "item-added", "item-moved", "item-set",
        "item-claimed", "item-cancelled", "started", "reaped", "settled", "merged",
        "parked", "unparked", "land-failed", "sweep", "sweep-stopped",
    ])]
    action: String,
    /// `outbox`, or the project whose inbox holds the line (whose board holds the row)
    #[arg(long)]
    from: String,
    /// Where it went: the item's new state, the project a row moved to
    #[arg(long)]
    to: Option<String>,
    #[arg(long, default_value = "intake", value_parser = ["intake", "queue", "dispatch", "land"])]
    stage: String,
    #[arg(long)]
    why: Option<String>,
    /// The row's id, for `planned` or the item's row
    #[arg(long)]
    id: Option<String>,
    /// The queue item it is about, when not this session's own (`AGENT_QUEUE_ITEM`)
    #[arg(long)]
    item: Option<String>,
    /// The writer, when it is a runner with no queue item or session of its own (fleet-dispatch)
    #[arg(long)]
    by: Option<String>,
    #[arg(long)]
    pr: Option<String>,
    #[arg(long)]
    sha: Option<String>,
    /// For `left`: the projects the lines written beside it were filed to, comma-separated
    #[arg(long)]
    near: Option<String>,
    #[arg(required = true, num_args = 1..)]
    text: Vec<String>,
}

#[derive(Subcommand)]
enum InboxCmd {
    /// List pending captures, oldest-first (the triage view); this is the default
    List,
    /// Quick-capture: append a timestamped line to today's `inbox/<date>.md`
    Add {
        /// Capture text (free-form)
        #[arg(required = true, num_args = 1..)]
        text: Vec<String>,
    },
    /// Drain triaged captures into `inbox/_archive/` (pick one selector)
    Archive {
        /// A specific capture filename (or path) to archive
        target: Option<String>,
        /// Archive everything stale (age ≥ 14d)
        #[arg(long)]
        stale: bool,
        /// Archive every dated capture before YYYY-MM-DD
        #[arg(long)]
        before: Option<String>,
    },
    /// Mark a Handled-today row of the inbox page reviewed (it folds into `+N reviewed`), or
    /// take the mark back with --undo; republishes the page
    Ack {
        /// The row's key: the `ts` of its ingest event, as the page's `<!-- ack:... -->` holds it
        key: String,
        #[arg(long)]
        undo: bool,
    },
}

#[derive(Subcommand)]
enum KnowledgeCmd {
    /// Write knowledge/SCHEMA.md, the article contract, from the built-in template, and
    /// regenerate knowledge/README.md, the hub's front door
    Init {
        /// Overwrite an existing SCHEMA.md
        #[arg(long)]
        force: bool,
    },
    /// List the N articles most due for a whole-article review (oldest `reviewed` first)
    Due {
        #[arg(short, default_value_t = 3)]
        n: usize,
    },
    /// Validate and apply an ops batch (JSON) from the knowledge engine, then write its log
    Apply {
        /// The batch file: {"date", "sources": [..], "ops": [..]}
        file: std::path::PathBuf,
        /// Unix time the engine started; an update to a file modified after it is rejected
        #[arg(long)]
        started: Option<i64>,
        /// Validate and print the log, write nothing
        #[arg(long)]
        dry_run: bool,
        /// The day's gate JSON (`notes knowledge gate`): the log records every item's outcome
        /// under `## Dispositions`, and its todo items go to the outbox
        #[arg(long)]
        gate: Option<std::path::PathBuf>,
        /// The retired list (`knowledge-retired` TSV): an op that adds a line naming one as live is rejected
        #[arg(long)]
        retired: Option<std::path::PathBuf>,
    },
    /// Give each of a day's sources a kind and write what the model reads (stdin: one
    /// `<file>[TAB<label>]` per line; prints the gate JSON)
    Gate {
        /// The day being compiled, YYYY-MM-DD
        date: String,
        /// Where the stripped and split copies go
        #[arg(long)]
        out: std::path::PathBuf,
    },
    /// List the days still to compile: from the first nightly log through yesterday, each with no log
    Pending {
        #[arg(long)]
        json: bool,
        /// The days before the first nightly log instead, from the oldest source file on
        #[arg(long)]
        backfill: bool,
        /// The day the run counts from (default: today); the runner passes its own
        #[arg(long)]
        today: Option<chrono::NaiveDate>,
    },
    /// List the exported repo docs routed to a core or subject domain that the engine has not read
    /// at their current content, oldest export first, as absolute paths (the gate's source lines)
    RepoPending {
        /// At most this many (default: all)
        #[arg(long)]
        limit: Option<usize>,
    },
    /// Where a day's sources went, or one source: `<YYYY-MM-DD>` or a vault path
    Trace {
        target: String,
        #[arg(long)]
        json: bool,
    },
    /// Count drift from the schema and registry, per class (read-only)
    Lint {
        /// Print the counts and findings as JSON
        #[arg(long)]
        json: bool,
        /// The retired list (`knowledge-retired` TSV): count lines that name one as live
        #[arg(long)]
        retired: Option<std::path::PathBuf>,
    },
    /// Move a page (or retire one merged into another) and rewrite every link to it in the vault
    Mv {
        /// The page, vault-relative (knowledge/software/x.md)
        from: Option<String>,
        /// Where it goes: under knowledge/ or _archive/
        to: Option<String>,
        /// TO already holds FROM's facts: delete FROM and point its links at TO
        #[arg(long)]
        merged: bool,
        /// A batch, one `from<TAB>to[<TAB>merged]` per line, done in one walk of the vault
        #[arg(long, conflicts_with_all = ["from", "to", "merged"])]
        map: Option<std::path::PathBuf>,
        /// Print what would change, write nothing
        #[arg(long)]
        dry_run: bool,
    },
    /// The domain registry, knowledge/domains.toml
    Domain {
        #[command(subcommand)]
        sub: DomainCmd,
    },
}

#[derive(Subcommand)]
enum DomainCmd {
    /// Register a domain: its entry, its index page, and the regenerated SCHEMA.md
    Add {
        /// core/<x>, subjects/<x>, projects/<lab project> or references
        id: String,
        /// One line: what belongs there
        is: String,
        /// Another name for the domain (repeatable)
        #[arg(long = "alias")]
        aliases: Vec<String>,
        /// A doc this domain is a hub over (repeatable); a core page must link one
        #[arg(long)]
        canonical: Vec<String>,
    },
}

#[derive(Subcommand)]
enum ZettelCmd {
    /// Create a new permanent (zettel) note with a timestamp id
    New {
        /// Note title (free text)
        #[arg(required = true, num_args = 1..)]
        title: Vec<String>,
    },
}

#[derive(Subcommand)]
enum MeetingCmd {
    /// Create a new meeting log with a timestamp id + agenda scaffolding
    New {
        /// Meeting title (free text)
        #[arg(required = true, num_args = 1..)]
        title: Vec<String>,
    },
}

/// Restore default SIGPIPE handling so piping into `head`/`less` exits quietly
/// (like `cat`) instead of panicking with "Broken pipe". Rust ignores SIGPIPE
/// by default, which turns a closed pipe into a panic.
#[cfg(unix)]
fn reset_sigpipe() {
    unsafe {
        libc::signal(libc::SIGPIPE, libc::SIG_DFL);
    }
}
#[cfg(not(unix))]
fn reset_sigpipe() {}

/// `--game` and `--pr` belong to the playtest sheet's add; anywhere else they are refused.
fn refuse_playtest_flags(game: Option<&String>, pr: Option<&u64>) -> Result<()> {
    if game.is_some() || pr.is_some() {
        bail!("--game and --pr only apply with --playtest");
    }
    Ok(())
}

/// The five verbs `ptask --playtest` takes. Everything else acts on releases, which playtest.md
/// does not have, so it is refused rather than run against the sheet.
fn playtest_op(sub: Option<PtaskCmd>, exact: bool) -> Result<playtest::Op> {
    Ok(match sub {
        None
        | Some(PtaskCmd::List {
            version: None,
            all: false,
        }) => playtest::Op::List,
        Some(PtaskCmd::Add {
            to: None,
            game,
            pr,
            detail,
            want: None,
            origin: None,
            checked,
            why: None,
            text,
        }) if detail.is_empty() && checked.is_empty() => playtest::Op::Add {
            game,
            pr,
            text: text.join(" "),
        },
        Some(PtaskCmd::Done {
            children: Some(_), ..
        })
        | Some(PtaskCmd::Drop {
            children: Some(_), ..
        }) => bail!("--playtest rows have no children: drop --children"),
        Some(PtaskCmd::Done { on: Some(_), .. }) => {
            bail!("--playtest done takes no --on: a playtest row closes today")
        }
        Some(PtaskCmd::Done {
            proof,
            unverified,
            query,
            ..
        }) => playtest::Op::Done {
            proof,
            unverified,
            pick: Pick::new(&query.join(" "), exact)?,
        },
        Some(PtaskCmd::Drop {
            why, dup, query, ..
        }) => playtest::Op::Drop {
            stamp: project_tasks::drop_stamp(why.as_deref(), dup.as_deref())?,
            pick: Pick::new(&query.join(" "), exact)?,
        },
        Some(PtaskCmd::Pass { build, game }) => playtest::Op::Pass { build, game },
        _ => bail!(
            "--playtest takes list, add, done, drop and pass only (no releases or details: no --to, --version, --all or --detail)"
        ),
    })
}

/// `notes row parse|types`. Parse reads bytes, so one line that is not UTF-8 still gets its
/// own output line instead of failing the rest.
/// The commands that need no profile, run before one is resolved: the row grammar (agent-queue
/// and the triage prompts call it where none may resolve) and weighing rows from stdin (day-log
/// runs it over the notes history).
fn profile_free(cmd: &Cmd) -> Option<Result<()>> {
    match cmd {
        Cmd::Row { sub } => Some(row_cmd(sub)),
        Cmd::Board { weigh: true, .. } => Some(read_stdin().and_then(|s| board::print_weigh(&s))),
        _ => None,
    }
}

fn row_cmd(sub: &RowCmd) -> Result<()> {
    use std::io::{BufRead, Write};
    let mut out = std::io::stdout().lock();
    match sub {
        RowCmd::Parse => {
            let mut stdin = std::io::stdin().lock();
            let mut buf = Vec::new();
            while stdin.read_until(b'\n', &mut buf)? > 0 {
                let line = String::from_utf8_lossy(&buf);
                let line = line.strip_suffix('\n').unwrap_or(&line);
                writeln!(out, "{}", projects::row_parse_tsv(line))?;
                buf.clear();
            }
        }
        RowCmd::Types => writeln!(
            out,
            "{}",
            projects::filer_types().collect::<Vec<_>>().join(" ")
        )?,
    }
    Ok(())
}

/// `notes knowledge ...`.
fn knowledge_cmd(prof: &config::Profile, log: &logging::Logger, sub: KnowledgeCmd) -> Result<i32> {
    Ok(match sub {
        KnowledgeCmd::Init { force } => {
            knowledge::init(prof, log, force)?;
            0
        }
        KnowledgeCmd::Due { n } => {
            for path in knowledge::due(prof, n) {
                println!("{path}");
            }
            0
        }
        KnowledgeCmd::Apply {
            file,
            started,
            dry_run,
            gate,
            retired,
        } => {
            let gate = gate.as_deref().map(knowledge_gate::load).transpose()?;
            let gone = knowledge_retired::load(retired.as_deref())?;
            knowledge::apply(prof, log, &file, started, dry_run, gate.as_ref(), &gone)?;
            0
        }
        KnowledgeCmd::Gate { date, out } => {
            knowledge_gate::run(prof, &date, &out, &read_stdin()?)?;
            0
        }
        KnowledgeCmd::Pending {
            json,
            backfill,
            today,
        } => {
            let today = today.unwrap_or_else(|| chrono::Local::now().date_naive());
            let days = if backfill {
                knowledge::backfill(prof)
            } else {
                knowledge::pending(prof, today)
            };
            if json {
                let days: Vec<String> = days.iter().map(|d| d.to_string()).collect();
                println!("{}", serde_json::to_string(&days)?);
            } else {
                for d in days {
                    println!("{d}");
                }
            }
            0
        }
        KnowledgeCmd::RepoPending { limit } => {
            knowledge_repo::run(prof, limit)?;
            0
        }
        KnowledgeCmd::Trace { target, json } => {
            knowledge::trace(prof, &target, chrono::Local::now().date_naive(), json)?
        }
        KnowledgeCmd::Lint { json, retired } => {
            knowledge_lint::run(prof, json, &knowledge_retired::load(retired.as_deref())?)?;
            0
        }
        KnowledgeCmd::Mv {
            from,
            to,
            merged,
            map,
            dry_run,
        } => {
            let moves = match (map, from, to) {
                (Some(f), _, _) => knowledge_mv::parse_map(&std::fs::read_to_string(&f)?)?,
                (None, Some(a), Some(b)) => vec![knowledge_mv::single(&a, &b, merged)?],
                _ => anyhow::bail!("give FROM TO, or --map FILE"),
            };
            let o = knowledge_mv::run(prof, log, &moves, dry_run)?;
            knowledge_mv::print(&o, dry_run);
            0
        }
        KnowledgeCmd::Domain {
            sub:
                DomainCmd::Add {
                    id,
                    is,
                    aliases,
                    canonical,
                },
        } => {
            let d = knowledge_registry::Domain {
                id,
                is,
                aliases,
                canonical,
                repo_docs: Vec::new(),
            };
            let today = chrono::Local::now().date_naive();
            for f in knowledge_registry::add(prof, log, d, today)? {
                println!("{}", f.display());
            }
            0
        }
    })
}

/// `ptask done` and `ptask drop`: close the row the query names, settling its open children
/// (`--children`, and a dup's children move under the row it duplicates).
fn ptask_close(
    prof: &config::Profile,
    log: &logging::Logger,
    name: &str,
    pick: &dyn Fn(&[String]) -> Result<Pick>,
    cmd: PtaskCmd,
    lane: Lane,
) -> Result<i32> {
    match cmd {
        PtaskCmd::Done {
            proof,
            unverified,
            on,
            children,
            query,
        } => project_tasks::done(
            prof,
            log,
            name,
            &pick(&query)?,
            proof.as_deref(),
            unverified.as_deref(),
            on.as_deref(),
            lane,
            children.as_ref(),
        ),
        PtaskCmd::Drop {
            why,
            dup,
            children,
            query,
        } => project_tasks::drop(
            prof,
            log,
            name,
            &pick(&query)?,
            why.as_deref(),
            dup.as_deref(),
            lane,
            children.as_ref(),
        ),
        _ => bail!("ptask_close takes done and drop only"),
    }
}

#[allow(clippy::too_many_arguments)]
/// `ptask tag`: its `--add` tags plus `--why`'s reason and priority, then the retag.
fn ptask_tag(
    prof: &config::Profile,
    log: &logging::Logger,
    name: &str,
    pick: &Pick,
    t: TagArgs,
    lane: Lane,
    writer: &project_tasks::Writer,
) -> Result<i32> {
    let add = reasons::tag_adds(t.add, t.why.as_deref())?;
    project_tasks::tag(prof, log, name, pick, &add, &t.remove, lane, writer)
}

/// All of stdin as text, for the commands that take their body there.
/// `notes ptask <name> move <query> (--to vX.Y.Z | --project <dest> [--to vX.Y.Z])`.
#[allow(clippy::too_many_arguments)]
fn ptask_move(
    prof: &config::Profile,
    log: &logging::Logger,
    name: &str,
    pick: &Pick,
    to: Option<String>,
    project: Option<String>,
    lane: Lane,
    writer: &project_tasks::Writer,
) -> Result<i32> {
    match (project, to) {
        (Some(dest), to) => {
            let rc = project_tasks::move_to_project(
                prof,
                log,
                name,
                &dest,
                pick,
                to.as_deref(),
                lane,
                writer,
            )?;
            if rc == 0 {
                lab_refresh::kick();
            }
            Ok(rc)
        }
        // clap's `required_unless_present` guarantees --to here.
        (None, Some(to)) => project_tasks::move_task(prof, log, name, pick, &to, lane, writer),
        (None, None) => unreachable!("clap requires --to without --project"),
    }
}

fn read_stdin() -> Result<String> {
    let mut text = String::new();
    std::io::Read::read_to_string(&mut std::io::stdin(), &mut text)?;
    Ok(text)
}

fn main() -> Result<()> {
    reset_sigpipe();
    let cli = Cli::parse();
    if let Some(done) = profile_free(&cli.cmd) {
        return done;
    }
    let prof = config::resolve(cli.profile.as_deref())?;
    let log = logging::Logger::new(prof.log_file.clone(), cli.verbose);

    let code = match cli.cmd {
        Cmd::Today { all } => {
            if all {
                // The daily note is per-profile and `focus --all` only reads notes that
                // already EXIST, so on a fresh day an uncreated profile silently reads
                // as zero in a cross-profile cockpit. Bootstrap every profile so each
                // lane's Focus carries forward. One bad profile warns, never aborts.
                for name in config::all_profile_names()? {
                    match config::resolve(Some(&name)) {
                        Ok(p) => {
                            if let Err(e) = daily::run(&p, &log) {
                                log.warn("today", &format!("{name}: {e}"));
                            }
                        }
                        Err(e) => log.warn("today", &format!("{name}: {e}")),
                    }
                }
            } else {
                daily::run(&prof, &log)?;
            }
            0
        }
        Cmd::Show { target, json } => show::run(&prof, &target, json)?,
        Cmd::Put { target, base } => show::put(&prof, &log, &target, &base, &read_stdin()?)?,
        Cmd::Path { target } => match daily::resolve_path(&prof, &target) {
            Some(path) => {
                println!("{}", path.display());
                0
            }
            None => {
                eprintln!(
                    "unknown path target '{target}' (want: daily, daily-dir, refs, refs-today, root, backlog, scheduled, recurring, zettel, meetings, archive, index, projects, inbox, inbox-today)"
                );
                2
            }
        },
        Cmd::LinkRefs => {
            daily::link_refs(&prof, &log)?;
            0
        }
        Cmd::Report { sub } => report::run(&prof, &log, sub)?,
        Cmd::Summarize { date, force } => {
            summarize::run(&prof, &log, date.as_deref(), force)?;
            0
        }
        Cmd::Archive {
            month,
            dry_run,
            backfill,
        } => {
            archive::run(&prof, &log, month.as_deref(), dry_run, backfill)?;
            0
        }
        Cmd::Backlog { name, add } => {
            backlog::run(&prof, &log, &name, add)?;
            0
        }
        Cmd::Focus { all, sub } => {
            // `--all` is a read-only cross-profile dump; pairing it with a write verb is
            // always a mistake. Reject it rather than silently discarding the write.
            // (Clap's `conflicts_with` takes an arg id and cannot reference a subcommand,
            // so the check lives here.)
            if all && !matches!(sub, None | Some(FocusCmd::List)) {
                bail!("`--all` is read-only and cannot be combined with a write subcommand");
            }
            if all {
                focus::list_all(&log)?
            } else {
                match sub {
                    None | Some(FocusCmd::List) => focus::list(&prof, &log)?,
                    Some(FocusCmd::Add { text }) => focus::add(&prof, &log, &text.join(" "))?,
                    Some(FocusCmd::Done { query }) => focus::done(&prof, &log, &query.join(" "))?,
                    Some(FocusCmd::Rm { query }) => focus::rm(&prof, &log, &query.join(" "))?,
                    Some(FocusCmd::Ingest { query }) => {
                        focus::ingest(&prof, &log, &query.join(" "))?
                    }
                    Some(FocusCmd::Mv {
                        query,
                        to,
                        tag,
                        untag,
                    }) => focus_move::mv(
                        &prof,
                        &log,
                        &query.join(" "),
                        to.as_deref(),
                        tag.as_deref(),
                        untag,
                    )?,
                    Some(FocusCmd::Start { query }) => {
                        focus_sweep::start(&prof, &log, &query.join(" "))?
                    }
                    Some(FocusCmd::Sweep) => focus_sweep::sweep(&prof, &log)?,
                }
            }
        }
        Cmd::Ptask {
            name,
            playtest: true,
            exact,
            sub,
            ..
        } => {
            let name = project_map::canonical(&name);
            let op = playtest_op(sub, exact)?;
            let _lock = match op {
                playtest::Op::List => None,
                _ => Some(project_tasks::lock(&prof)?),
            };
            if let playtest::Op::Done { pick, .. } | playtest::Op::Drop { pick, .. } = &op {
                pick.sole_in(&playtest::path(&projects::project_dir(&prof, &name)?))?;
            }
            playtest::run(&prof, &log, &name, op)?
        }
        Cmd::Ptask {
            name,
            agent,
            exact,
            sub,
            ..
        } => {
            let name = project_map::canonical(&name);
            let lane = if agent { Lane::Agent } else { Lane::Human };
            let sheet = project_tasks::sheet_of(&prof, &name, lane)?;
            let pick = |query: &[String]| -> anyhow::Result<Pick> {
                let pick = Pick::new(&query.join(" "), exact)?;
                match &sheet {
                    Some(sheet) => pick.resolve_in(sheet),
                    None => Ok(pick),
                }
            };
            // Every verb that writes holds the ptask lock across its read-modify-write and id
            // minting, so two writers never lose a row or mint one id twice.
            let _lock = match &sub {
                None
                | Some(
                    PtaskCmd::List { .. }
                    | PtaskCmd::Inbox { .. }
                    | PtaskCmd::Similar { .. }
                    | PtaskCmd::Propose { .. }
                    | PtaskCmd::Redate { dry_run: true, .. },
                ) => None,
                Some(_) => Some(project_tasks::lock(&prof)?),
            };
            let writer = project_tasks::Writer::from_env(None, Vec::new());
            match sub {
                None => project_tasks::list(&prof, &name, None, false, lane)?,
                Some(PtaskCmd::List { version, all }) => {
                    project_tasks::list(&prof, &name, version.as_deref(), all, lane)?
                }
                Some(PtaskCmd::Add {
                    to,
                    game,
                    pr,
                    detail,
                    want,
                    origin,
                    checked,
                    why,
                    text,
                }) => {
                    refuse_playtest_flags(game.as_ref(), pr.as_ref())?;
                    project_tasks::add(
                        &prof,
                        &log,
                        &name,
                        &reasons::add_text(&text, why.as_deref())?,
                        &detail,
                        to.as_deref(),
                        want.as_deref(),
                        lane,
                        &project_tasks::Writer::from_env(origin.as_deref(), checked),
                    )?
                }
                Some(PtaskCmd::Move { to, project, query }) => ptask_move(
                    &prof,
                    &log,
                    &name,
                    &pick(&query)?,
                    to,
                    project,
                    lane,
                    &writer,
                )?,
                Some(cmd @ (PtaskCmd::Done { .. } | PtaskCmd::Drop { .. })) => {
                    ptask_close(&prof, &log, &name, &pick, cmd, lane)?
                }
                Some(PtaskCmd::Redate { on, dry_run, id }) => {
                    project_tasks::redate(&prof, &log, &name, &id, &on, dry_run, lane)?
                }
                Some(PtaskCmd::Reopen { why, id }) => {
                    project_tasks::reopen(&prof, &log, &name, &id, &why, lane)?
                }
                Some(PtaskCmd::Start { query }) => {
                    project_tasks::start(&prof, &log, &name, &pick(&query)?, lane)?
                }
                Some(PtaskCmd::Run { query }) => {
                    project_tasks::run(&prof, &log, &name, &pick(&query)?, lane)?
                }
                Some(PtaskCmd::Unstart { query }) => {
                    project_tasks::unstart(&prof, &log, &name, &pick(&query)?, lane)?
                }
                Some(PtaskCmd::Inbox { json }) => project_tasks::inbox(&prof, &name, json, lane)?,
                Some(PtaskCmd::Split) => project_tasks::inbox_split(&prof, &name, lane)?,
                Some(PtaskCmd::Propose { text }) => {
                    println!("{}", propose::proposed_row(&text.join(" "), &name));
                    0
                }
                Some(PtaskCmd::Similar { top, json, text }) => {
                    project_tasks::similar_rows(&prof, &name, &text.join(" "), top, json, lane)?
                }
                Some(PtaskCmd::File {
                    rows,
                    dup,
                    skip,
                    project,
                    lane: to_lane,
                    to,
                    detail,
                    want,
                    why,
                    query,
                }) => {
                    let to_lane = match to_lane.as_str() {
                        "human" => Lane::Human,
                        "agent" => Lane::Agent,
                        other => bail!("--lane is human or agent, not '{other}'"),
                    };
                    let how = project_tasks::Filing {
                        project,
                        lane: to_lane,
                        want: want.as_deref().map(projects::want_channel).transpose()?,
                        why,
                        how: match dup {
                            _ if skip => project_tasks::How::Skip,
                            Some(id) => project_tasks::How::Dup(id),
                            None => project_tasks::How::Rows {
                                texts: rows,
                                to,
                                details: detail,
                            },
                        },
                    };
                    let q = query.join(" ");
                    let pick = if exact {
                        Pick::Exact(q.trim_end().to_string())
                    } else {
                        Pick::new(&q, false)?
                    };
                    project_tasks::file(&prof, &log, &name, &pick, &how, lane)?
                }
                Some(PtaskCmd::Tag(t)) => {
                    ptask_tag(&prof, &log, &name, &pick(&t.query)?, t, lane, &writer)?
                }
                Some(PtaskCmd::Pass { .. }) => bail!("pass applies only with --playtest"),
                Some(PtaskCmd::Edit {
                    text,
                    append,
                    detail,
                    brief,
                    was,
                    link,
                    query,
                }) => match brief {
                    Some(b) => {
                        project_tasks::rebrief(&prof, &log, &name, &pick(&query)?, &b, lane)?
                    }
                    None => project_tasks::retext(
                        &prof,
                        &log,
                        &name,
                        &pick(&query)?,
                        text.as_deref(),
                        append.as_deref(),
                        &detail,
                        was,
                        link.then_some(standing::SYSTEMS_BIN),
                        lane,
                        &writer,
                    )?,
                },
                Some(PtaskCmd::Promote { query }) => {
                    project_tasks::step(&prof, &log, &name, &pick(&query)?, -1, lane, &writer)?
                }
                Some(PtaskCmd::Demote { query }) => {
                    project_tasks::step(&prof, &log, &name, &pick(&query)?, 1, lane, &writer)?
                }
                Some(PtaskCmd::Sweep { dry_run }) => {
                    project_tasks::sweep(&prof, &log, &name, dry_run, lane)?
                }
                Some(PtaskCmd::Archive { dry_run, rehome }) => {
                    project_tasks::archive_verb(&prof, &log, &name, dry_run, rehome, lane)?
                }
            }
        }
        Cmd::Board {
            json,
            done_days,
            agent,
            version,
            projects,
            ids,
            weigh: _,
        } => {
            if let Some(v) = version {
                board::print_version(&v, &projects, json)?
            } else if !ids.is_empty() {
                board::print_ids(&ids)?
            } else if json {
                board::print_json(done_days)?
            } else if agent {
                board::print_agent(&projects)?
            } else {
                board::run(&log)?
            }
        }
        Cmd::Outbox { sub } => match sub {
            None => outbox::list(&prof, false)?,
            Some(OutboxCmd::List { json }) => outbox::list(&prof, json)?,
            Some(OutboxCmd::Split) => outbox::split(&prof)?,
            Some(OutboxCmd::Show { json }) => outbox::show(&prof, json)?,
            Some(OutboxCmd::Put { base }) => outbox::put(&prof, &log, &base, &read_stdin()?)?,
            Some(OutboxCmd::Add { text }) => outbox::add(&prof, &log, &text.join(" "))?,
            Some(OutboxCmd::Move { project, why, raw }) => {
                outbox::move_line(&prof, &log, &project, why.as_deref(), &raw.join(" "))?
            }
            Some(OutboxCmd::Answer { raw }) => {
                outbox::answer(&prof, &log, &raw.join(" "), &read_stdin()?)?
            }
            Some(OutboxCmd::Drop { why, raw }) => {
                outbox::drop_line(&prof, &log, &raw.join(" "), why.as_deref())?
            }
            Some(OutboxCmd::Tags { json }) => outbox::tags(json)?,
        },
        Cmd::Log {
            steps: true, json, ..
        } => steps::print(&prof, json)?,
        Cmd::Log {
            trace: Some(words),
            json,
            ..
        } => ingest::trace(&prof, &words, json)?,
        Cmd::Log {
            day,
            days,
            project,
            id,
            action,
            by,
            item,
            json,
            ..
        } => {
            let filter = ingest::Filter::new(project, id, action, by, item);
            ingest::log(&prof, day.as_deref(), days, &filter, json)?
        }
        Cmd::Improve(a) => improve::run(&prof, &log, a)?,
        Cmd::Ingest { sub } => match sub {
            IngestCmd::Record(r) => ingest_record(&prof, *r),
            IngestCmd::Import => ingest_import(&prof)?,
            IngestCmd::Page => daily::publish_inbox_page(&prof, &log)?,
        },
        Cmd::Inbox { sub } => {
            match sub {
                None | Some(InboxCmd::List) => inbox::list(&prof, &log)?,
                Some(InboxCmd::Add { text }) => inbox::add(&prof, &log, &text.join(" "))?,
                Some(InboxCmd::Archive {
                    target,
                    stale,
                    before,
                }) => inbox::archive(&prof, &log, target.as_deref(), stale, before.as_deref())?,
                Some(InboxCmd::Ack { key, undo }) => {
                    inbox_ack::mark(&prof, &key, !undo)?;
                    daily::publish_inbox_page(&prof, &log)?;
                }
            }
            0
        }
        Cmd::Knowledge { sub } => knowledge_cmd(&prof, &log, sub)?,
        Cmd::Zettel { sub } => match sub {
            ZettelCmd::New { title } => {
                zettel::new_note(&prof, &log, &title.join(" "))?;
                0
            }
        },
        Cmd::Meeting { sub } => match sub {
            MeetingCmd::New { title } => {
                meeting::new_note(&prof, &log, &title.join(" "))?;
                0
            }
        },
        Cmd::Index { rebuild } => {
            index::run(&prof, &log, rebuild)?;
            0
        }
        Cmd::Tags { name, kind } => {
            match name {
                Some(n) => tags::show(&prof, &n)?,
                None => tags::list(&prof, kind)?,
            }
            0
        }
        Cmd::Find {
            query,
            limit,
            json,
            eval,
        } => {
            match eval {
                Some(f) => find::run_eval(&prof, &f)?,
                None => find::run(&prof, &query.join(" "), limit, json)?,
            }
            0
        }
        Cmd::Projects {
            name,
            new,
            archive,
            restore,
            archived,
            release,
            backfill,
            weekly: _,
            repo,
            migrate,
            move_project,
            to_profile,
            retire_ai_tag,
            migrate_rows,
            sweep,
            dry_run,
            patch,
            minor,
            major,
            force,
            carry,
            next,
            renumber,
            tag,
            family,
            checkout,
            version_of,
            roadmap,
            sprints,
            stats,
            json,
            agent_note,
            version,
            stage,
            stages,
            front_page,
            group,
            prio,
            prios,
            target,
            commit,
            hours,
            queue,
            set,
        } => {
            let level = if major {
                Some(projects::Bump::Major)
            } else if minor {
                Some(projects::Bump::Minor)
            } else if patch {
                Some(projects::Bump::Patch)
            } else {
                None
            };
            // A whole-vault sweep, so it is handled before the name-keyed match below:
            // an empty NAME means "every project" and must not fall through as a lookup.
            if let Some(n) = retire_ai_tag {
                let which = if n.is_empty() { None } else { Some(n.as_str()) };
                projects::retire_ai_tag(&prof, &log, which, dry_run)?;
                std::process::exit(0);
            }
            if let Some(n) = backfill {
                if backfill::backfill(&prof, &log, &n, &repo, dry_run)? {
                    lab_refresh::kick();
                }
                std::process::exit(0);
            }
            if sweep {
                // Exits 1 when a sheet failed, so the nightly runner reads the failure.
                let rc = project_tasks::sweep_all(&log, dry_run)?;
                if !dry_run {
                    lab_refresh::kick();
                }
                std::process::exit(rc);
            }
            if migrate_rows {
                migrate_rows::run(&log, dry_run)?;
                if !dry_run {
                    lab_refresh::kick();
                }
                std::process::exit(0);
            }
            // Handled before the match below because both take a VALUE (`--set`), which the
            // name-keyed tuple has no room for.
            if projects::ladder_read(stages, front_page.as_deref())? {
                std::process::exit(0);
            }
            if let Some(n) = stage {
                projects::stage(&prof, &log, &n, set.as_deref())?;
                if set.is_some() {
                    lab_refresh::kick();
                }
                std::process::exit(0);
            }
            if let Some(n) = group {
                projects::group(&prof, &log, &n, set.as_deref())?;
                if set.is_some() {
                    lab_refresh::kick();
                }
                std::process::exit(0);
            }
            if prios {
                projects::prios()?;
                std::process::exit(0);
            }
            if let Some(n) = prio {
                projects::prio(&prof, &log, &n, set.as_deref(), hours)?;
                if set.is_some() {
                    lab_refresh::kick();
                }
                std::process::exit(0);
            }
            if let Some(n) = target {
                projects::target(&prof, &log, &n, set.as_deref())?;
                if set.is_some() {
                    lab_refresh::kick();
                }
                std::process::exit(0);
            }
            if let Some(n) = commit {
                let writer = project_tasks::Writer::from_env(None, Vec::new());
                projects::commit_window(&prof, &log, &n, hours, queue.as_deref(), &writer)?;
                std::process::exit(0);
            }
            // Two values (name + destination), so it sits beside --stage, not in the tuple.
            if let (Some(n), Some(dest)) = (move_project, to_profile) {
                projects::move_to_profile(&prof, &log, &n, &dest)?;
                lab_refresh::kick();
                std::process::exit(0);
            }
            if json && !stats && roadmap.is_none() && sprints.is_none() {
                anyhow::bail!("--json goes with --stats, --roadmap or --sprints");
            }
            if projects::print_view(&prof, stats, sprints.as_deref(), version.as_deref(), json)? {
                std::process::exit(0);
            }
            // lifecycle/version flags take precedence over the read paths
            match (
                new, archive, restore, release, migrate, version_of, roadmap, agent_note, archived,
                name,
            ) {
                (Some(n), ..) => {
                    projects::new_project(&prof, &log, &n, &projects::Overlays::load()?)?;
                    lab_refresh::kick();
                }
                (_, Some(n), ..) => {
                    projects::archive(&prof, &log, &n)?;
                    lab_refresh::kick();
                }
                (_, _, Some(n), ..) => {
                    projects::restore(&prof, &log, &n)?;
                    lab_refresh::kick();
                }
                (_, _, _, Some(n), ..) => {
                    let family = match (&checkout, &family) {
                        (Some(c), Some(f)) => Some(shipped::Family::load(c, f)?),
                        _ => None,
                    };
                    projects::release(
                        &prof,
                        &log,
                        &n,
                        level,
                        force,
                        carry,
                        next.as_deref(),
                        renumber,
                        tag.as_deref(),
                        family.as_ref(),
                    )?;
                    lab_refresh::kick();
                }
                (_, _, _, _, Some(n), ..) => {
                    projects::migrate(&prof, &log, &n)?;
                    lab_refresh::kick();
                }
                (_, _, _, _, _, Some(n), ..) => projects::show_version(&prof, &n)?,
                (_, _, _, _, _, _, Some(n), ..) => projects::show_roadmap(&prof, &n, json)?,
                (_, _, _, _, _, _, _, Some(n), ..) => {
                    projects::show_agent_note(&prof, &n, version.as_deref())?
                }
                (_, _, _, _, _, _, _, _, true, _) => projects::list_archived(&prof)?,
                (_, _, _, _, _, _, _, _, _, Some(n)) => projects::show(&prof, &n)?,
                _ => projects::list(&prof)?,
            }
            0
        }
        Cmd::Comms { sub } => {
            match sub {
                None | Some(CommsCmd::List) => comms::list(&prof, &log)?,
                Some(CommsCmd::Refresh) => comms::refresh_cmd(&prof, &log)?,
                Some(CommsCmd::Status) => comms::status(&log)?,
                Some(CommsCmd::Stats { fresh }) => comms::stats(fresh, &log)?,
            }
            0
        }
        Cmd::Row { .. } => unreachable!("handled before the profile resolves"),
        Cmd::Clickup { sub } => match sub {
            ClickupCmd::Sync => clickup::sync(&prof, &log)?,
            ClickupCmd::Push => clickup::push(&prof, &log)?,
        },
        Cmd::SheetSweep {
            path,
            stdin,
            layout_only,
            dry_run,
        } => std::process::exit(project_tasks::sheet_sweep(
            &path,
            stdin,
            layout_only,
            dry_run,
        )?),
        Cmd::Doctor { untyped: true, .. } => doctor::untyped()?,
        Cmd::Doctor { projects: true, .. } => doctor::projects()?,
        Cmd::Doctor {
            projects: false, ..
        } => doctor::run(&prof, &log)?,
        Cmd::Config {
            profiles,
            machine_profile,
        } => {
            if machine_profile {
                println!("{}", config::machine_profile()?);
            } else if profiles {
                for name in config::all_profile_names()? {
                    println!("{name}");
                }
            } else {
                config::print(&prof);
                if let Ok(c) = config::comms_config() {
                    if !c.accounts.is_empty() {
                        config::print_comms(&c);
                    }
                }
            }
            0
        }
    };

    std::process::exit(code);
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ptask(args: &[&str]) -> Result<playtest::Op> {
        let argv = ["notes", "ptask", "demo", "--playtest"].iter().chain(args);
        match Cli::try_parse_from(argv).expect("parses").cmd {
            Cmd::Ptask { sub, exact, .. } => playtest_op(sub, exact),
            _ => unreachable!(),
        }
    }

    #[test]
    fn playtest_takes_five_verbs_and_refuses_the_rest() {
        assert!(matches!(ptask(&[]), Ok(playtest::Op::List)));
        assert!(matches!(ptask(&["list"]), Ok(playtest::Op::List)));
        assert!(matches!(
            ptask(&["add", "--game", "Dodgeball", "--pr", "7", "arena"]),
            Ok(playtest::Op::Add { pr: Some(7), .. })
        ));
        assert!(matches!(
            ptask(&["done", "--proof", "pr:7", "arena"]),
            Ok(playtest::Op::Done { .. })
        ));
        assert!(matches!(
            ptask(&["drop", "--why", "cut", "arena"]),
            Ok(playtest::Op::Drop { .. })
        ));
        assert!(matches!(
            ptask(&["pass", "--build", "b7", "--game", "Dodgeball"]),
            Ok(playtest::Op::Pass { game: Some(_), .. })
        ));
        for bad in [
            &["start", "arena"][..],
            &["sweep"],
            &["promote", "arena"],
            &["edit", "arena", "--text", "x"],
            &["list", "--all"],
            &["add", "--to", "v1.0.0", "arena"],
            &["add", "--detail", "why", "arena"],
        ] {
            let e = ptask(bad).err().expect("refused").to_string();
            assert!(
                e.contains("--playtest takes list, add, done, drop and pass only"),
                "{bad:?}: {e}"
            );
        }
    }

    #[test]
    fn playtest_and_agent_are_exclusive() {
        assert!(
            Cli::try_parse_from(["notes", "ptask", "demo", "--playtest", "--agent", "list"])
                .is_err()
        );
    }

    #[test]
    fn agent_parses_after_the_verb() {
        let after = [
            "notes", "ptask", "demo", "reopen", "--agent", "--why", "x", "dm-1",
        ];
        assert!(Cli::try_parse_from(after).is_ok());
    }
}
