//! `notes` — a single, profile-aware binary that owns all journal + zettelkasten
//! logic for the `~/.notes` vault. The git/MQTT sync layer lives elsewhere (shell);
//! this tool only reads and writes note files.
//!
//! Everything here is pure Rust (chrono for dates) so behaviour is identical on
//! macOS and Linux — no GNU-vs-BSD `date`/`sed`/`stat` divergence.

mod agent_sheet;
mod archive;
mod backlog;
mod board;
mod clickup;
mod comms;
mod config;
mod daily;
mod doctor;
mod epics;
mod focus;
mod focus_move;
mod focus_sweep;
mod inbox;
mod inbox_ack;
mod index;
mod ingest;
mod knowledge;
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
mod registry;
mod sheet;
mod show;
mod status;
mod steps;
mod summarize;
mod sweep;
mod tags;
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
enum Cmd {
    /// Create today's daily note (idempotent), then link refs + backlogs
    Today {
        /// Create today's note for EVERY configured profile, not just the active one
        #[arg(long)]
        all: bool,
    },
    /// Print a resolved profile path for editor/shell integration.
    /// target: daily (default) | daily-dir | refs | refs-today | root | fun | scheduled | recurring | zettel | meetings | index | inbox | inbox-today
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
    /// Link today's ref files into today's note's `## Refs` section
    LinkRefs,
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
    /// Open + tidy a standing backlog file (`fun`, `scheduled`, or `recurring`); prints its path
    Backlog {
        /// Backlog name: fun | scheduled | recurring
        name: String,
    },
    /// One-time migration: lift Fun + Carry Over out of a daily note into backlogs
    SeedBacklogs {
        /// Source daily note (defaults to the latest one)
        #[arg(long)]
        from: Option<String>,
        /// Overwrite a backlog that already has Active items
        #[arg(long)]
        force: bool,
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
        /// subtasks and in-flight state live - instead of the queue on its own README.
        #[arg(long)]
        agent: bool,
        /// Act on the project's `playtest.md`: one row is one thing to play and check off.
        /// Takes `list`, `add` (with `--game`, `--pr`), `done` and `drop` only
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
        /// Print the agent-lane rows as `<project>\t<text>` instead of writing the board.
        /// READ-ONLY: this path never touches board.md. Exits 0 even with no rows —
        /// "nothing queued for the agent" is a valid answer, not an error, and the
        /// session preflight that calls this must never be able to lose a turn over it.
        #[arg(long)]
        agent: bool,
        /// Print the release view instead of writing the board: every row aimed at
        /// vX.Y.Z, open and closed, both lanes, with the closed rows' PRs. A row's release
        /// is its `#vX.Y.Z` tag, or its sheet's `Version:` when untagged; rows already frozen
        /// into `versions/vX.Y.Z.md` are included. READ-ONLY
        #[arg(long, value_name = "vX.Y.Z", conflicts_with_all = ["json", "agent"])]
        version: Option<String>,
        /// Limit to these projects (repeatable). Names are the LAB project names, which
        /// are not the same namespace as the agent-side project name: a session in
        /// ~/.dotfiles resolves to `dotfiles`, whose lab projects are `notes-cockpit` and
        /// `agent-runtime`. Callers join the two through project-map.json
        /// `trackers.<n>.repo` (see `project_lab_names` in project-name.sh) and pass the
        /// results here. Ignored without --agent or --version.
        #[arg(long = "project")]
        projects: Vec<String>,
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
    /// every tag with a count; `<name>` prints each matching line as `path<TAB>line<TAB>text`.
    Tags {
        /// Tag to show hits for (leading `#` optional). Omit to list all tags.
        name: Option<String>,
    },
    /// List the indexed projects behind the board and the daily note's footer link.
    /// No arg lists each as `name<TAB>summary-path<TAB>status`; `<name>` lists that
    /// project's note files as `path<TAB>label` (summary first).
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
        /// `Version:` moves to the next one. Refused for a project below beta
        #[arg(long, value_name = "NAME")]
        release: Option<String>,
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
        /// With --retire-ai-tag or --migrate-rows: report what would change and write nothing
        #[arg(long)]
        dry_run: bool,
        /// With --release: step the minor (v0.1.2 -> v0.2.0)
        #[arg(long)]
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
        /// Print a project's current version
        #[arg(long, value_name = "NAME")]
        version_of: Option<String>,
        /// Print a project's roadmap: the open version, then the releases rows are aimed at
        /// (TSV: `version<TAB>state<TAB>open<TAB>done<TAB>open_weight<TAB>done_weight<TAB>
        /// unsized_open`, both lanes' leaf rows; --json adds closes, scope growth and epics)
        #[arg(long, value_name = "NAME")]
        roadmap: Option<String>,
        /// Every profile's indexed projects with their open work, for the projects popup
        /// (TSV: `profile<TAB>name<TAB>stage<TAB>version<TAB>open<TAB>urgent<TAB>high<TAB>
        /// low<TAB>planned<TAB>agent<TAB>sheet`; the counts are the open version's, planned
        /// is the rows aimed at a later release, agent is the agent board's)
        #[arg(long)]
        stats: bool,
        /// With --stats or --roadmap: one JSON array instead. For --stats it adds each project's dir, done count, progress, epics, size weights, STATUS line and date, and summary path
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
        /// Print a project's index group; with --set, declare it. Unset means the
        /// project's own profile (bnb, personal); `tooling` is the tooling lane.
        #[arg(long, value_name = "NAME")]
        group: Option<String>,
        /// Print a project's priority; with --set, declare it. One of: focus, high, low,
        /// normal (clears it). fleet-dispatch ranks the project's board rows by it first.
        #[arg(long, value_name = "NAME")]
        prio: Option<String>,
        /// The value to write, for --stage / --group / --prio. Omit to read.
        #[arg(long, value_name = "VALUE")]
        set: Option<String>,
        /// Print (creating if absent) the path to a version's agent note,
        /// `agent/versions/<vX.Y.Z>.md`
        #[arg(long, value_name = "NAME")]
        agent_note: Option<String>,
        /// With --agent-note: which version (defaults to the open one)
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
    /// Mirror in-progress ClickUp tickets assigned to me into today's `## Focus`.
    /// Opt-in per profile via `clickup_list`; a no-op where it is unset.
    Clickup {
        #[command(subcommand)]
        sub: ClickupCmd,
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
        /// One JSON event per line (one object per step with --steps)
        #[arg(long)]
        json: bool,
    },
    /// Print the resolved profile + paths
    Config {
        /// List every configured profile name instead
        #[arg(long)]
        profiles: bool,
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
    /// write nothing when an open row with the same text is already on the sheet
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
        #[arg(long, value_name = "LINE")]
        detail: Vec<String>,
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
        #[arg(required = true, num_args = 1..)]
        query: Vec<String>,
    },
    /// Add or take hashtags off the first matching open task (before its marker). A release
    /// tag is refused: move, promote and demote own it
    Tag {
        /// A tag to add (`#` optional). Repeatable
        #[arg(long, value_name = "TAG")]
        add: Vec<String>,
        /// A tag to take off (`#` optional). Repeatable
        #[arg(long, value_name = "TAG")]
        remove: Vec<String>,
        #[arg(required = true, num_args = 1..)]
        query: Vec<String>,
    },
    /// Mark the matching task in progress (`[ ]` -> `[/]`); a started row is left as it is
    Start {
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
        /// It duplicates this row (its id, like ar-142)
        #[arg(long, value_name = "ID")]
        dup: Option<String>,
        #[arg(required = true, num_args = 1..)]
        query: Vec<String>,
    },
    /// Change the first matching open task's text in place: its place on the sheet,
    /// its checkbox state and its tags stay as they were
    Edit {
        /// The task's new text
        #[arg(
            long,
            conflicts_with = "append",
            required_unless_present_any = ["append", "detail"]
        )]
        text: Option<String>,
        /// Words to add to the end of the task's text
        #[arg(long)]
        append: Option<String>,
        /// A detail line to add under the row, after its existing ones. Repeatable
        #[arg(long, value_name = "LINE")]
        detail: Vec<String>,
        /// The triager's rewrite: --text must be `type(area): title`, the old words stay as a
        /// `was:` detail line, and the old row's own tags (#requested, #tier/N, #size/x) carry over
        #[arg(long, requires = "text")]
        was: bool,
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
    /// Sort the section by priority, done at the foot, and drop release tags the sheet
    /// has passed
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
    /// List the lines waiting in `## Inbox`, oldest first (TSV `path<TAB>line<TAB>text`)
    Inbox {
        /// One JSON array of `{line, raw, text, details}` instead
        #[arg(long)]
        json: bool,
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
        #[arg(long, value_name = "LINE")]
        detail: Vec<String>,
        #[arg(required = true, num_args = 1..)]
        query: Vec<String>,
    },
    /// With --agent: move the agent board's done rows into `agent/versions/<vX.Y.Z>.md`
    /// (the note their proof is in), under `## Done rows`
    Archive {
        /// Print how many rows would move and leave both files alone
        #[arg(long = "dry-run")]
        dry_run: bool,
    },
}

#[derive(Subcommand)]
enum OutboxCmd {
    /// The lines waiting, oldest first (TSV `line<TAB>text`)
    List {
        /// One JSON array of `{line, raw, text, details, project}` instead
        #[arg(long)]
        json: bool,
    },
    /// The items as agent-web's Daily outbox edits them (`--json`: `{path, hash, text, waiting}`)
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
        #[arg(required = true, num_args = 1..)]
        raw: Vec<String>,
    },
}

#[derive(Subcommand)]
enum IngestCmd {
    /// Record one step the CLI did not make itself: a line the sweep `left` for the human, one
    /// whose write was `refused`, a row the planner `planned`, or a chain step a shell writer
    /// made (agent-queue's `item-*`, fleet-dispatch's `started`, `reaped`, `settled`,
    /// agent-land's `merged`, claude-acct's `parked` and `unparked`). An empty flag value is no value.
    Record(Box<RecordArgs>),
    /// Publish the inbox status page from the record and the outbox (the sweep runs it)
    Page,
}

/// `notes ingest record`: boxed, so the enum stays small.
#[derive(clap::Args)]
struct RecordArgs {
    #[arg(long, value_parser = [
        "left", "refused", "planned", "item-added", "item-moved", "item-set",
        "item-claimed", "item-cancelled", "started", "reaped", "settled", "merged",
        "parked", "unparked",
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
    /// Write knowledge/SCHEMA.md, the article contract, from the built-in template
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

/// The four verbs `ptask --playtest` takes. Everything else acts on releases, which playtest.md
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
            text,
        }) if detail.is_empty() => playtest::Op::Add {
            game,
            pr,
            text: text.join(" "),
        },
        Some(PtaskCmd::Done {
            proof,
            unverified,
            query,
        }) => playtest::Op::Done {
            proof,
            unverified,
            pick: Pick::new(&query.join(" "), exact)?,
        },
        Some(PtaskCmd::Drop { why, dup, query }) => playtest::Op::Drop {
            stamp: project_tasks::drop_stamp(why.as_deref(), dup.as_deref())?,
            pick: Pick::new(&query.join(" "), exact)?,
        },
        _ => bail!(
            "--playtest takes list, add, done and drop only (no releases or details: no --to, --version, --all or --detail)"
        ),
    })
}

fn main() -> Result<()> {
    reset_sigpipe();
    let cli = Cli::parse();
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
        Cmd::Put { target, base } => {
            let mut text = String::new();
            std::io::Read::read_to_string(&mut std::io::stdin(), &mut text)?;
            show::put(&prof, &log, &target, &base, &text)?
        }
        Cmd::Path { target } => match daily::resolve_path(&prof, &target) {
            Some(path) => {
                println!("{}", path.display());
                0
            }
            None => {
                eprintln!(
                    "unknown path target '{target}' (want: daily, daily-dir, refs, refs-today, root, fun, scheduled, recurring, zettel, meetings, index, projects, inbox, inbox-today)"
                );
                2
            }
        },
        Cmd::LinkRefs => {
            daily::link_refs(&prof, &log)?;
            0
        }
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
        Cmd::Backlog { name } => {
            backlog::run(&prof, &log, &name)?;
            0
        }
        Cmd::SeedBacklogs { from, force } => {
            backlog::seed(&prof, &log, from.as_deref(), force)?;
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
            let name = registry::canonical(&name);
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
            let name = registry::canonical(&name);
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
                | Some(PtaskCmd::List { .. } | PtaskCmd::Inbox { .. } | PtaskCmd::Propose { .. }) => {
                    None
                }
                Some(_) => Some(project_tasks::lock(&prof)?),
            };
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
                    text,
                }) => {
                    if game.is_some() || pr.is_some() {
                        bail!("--game and --pr only apply with --playtest");
                    }
                    project_tasks::add(
                        &prof,
                        &log,
                        &name,
                        &text.join(" "),
                        &detail,
                        to.as_deref(),
                        lane,
                    )?
                }
                Some(PtaskCmd::Move { to, project, query }) => match (project, to) {
                    (Some(dest), to) => {
                        let rc = project_tasks::move_to_project(
                            &prof,
                            &log,
                            &name,
                            &dest,
                            &pick(&query)?,
                            to.as_deref(),
                            lane,
                        )?;
                        if rc == 0 {
                            lab_refresh::kick();
                        }
                        rc
                    }
                    // clap's `required_unless_present` guarantees --to here.
                    (None, Some(to)) => {
                        project_tasks::move_task(&prof, &log, &name, &pick(&query)?, &to, lane)?
                    }
                    (None, None) => unreachable!("clap requires --to without --project"),
                },
                Some(PtaskCmd::Done {
                    proof,
                    unverified,
                    query,
                }) => project_tasks::done(
                    &prof,
                    &log,
                    &name,
                    &pick(&query)?,
                    proof.as_deref(),
                    unverified.as_deref(),
                    lane,
                )?,
                Some(PtaskCmd::Start { query }) => {
                    project_tasks::start(&prof, &log, &name, &pick(&query)?, lane)?
                }
                Some(PtaskCmd::Unstart { query }) => {
                    project_tasks::unstart(&prof, &log, &name, &pick(&query)?, lane)?
                }
                Some(PtaskCmd::Inbox { json }) => project_tasks::inbox(&prof, &name, json, lane)?,
                Some(PtaskCmd::Propose { text }) => {
                    println!("{}", propose::proposed_row(&text.join(" "), &name));
                    0
                }
                Some(PtaskCmd::File {
                    rows,
                    dup,
                    project,
                    lane: to_lane,
                    to,
                    detail,
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
                        how: match dup {
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
                Some(PtaskCmd::Tag { add, remove, query }) => {
                    project_tasks::tag(&prof, &log, &name, &pick(&query)?, &add, &remove, lane)?
                }
                Some(PtaskCmd::Drop { why, dup, query }) => project_tasks::drop(
                    &prof,
                    &log,
                    &name,
                    &pick(&query)?,
                    why.as_deref(),
                    dup.as_deref(),
                    lane,
                )?,
                Some(PtaskCmd::Edit {
                    text,
                    append,
                    detail,
                    was,
                    query,
                }) => project_tasks::retext(
                    &prof,
                    &log,
                    &name,
                    &pick(&query)?,
                    text.as_deref(),
                    append.as_deref(),
                    &detail,
                    was,
                    lane,
                )?,
                Some(PtaskCmd::Promote { query }) => {
                    project_tasks::step(&prof, &log, &name, &pick(&query)?, -1, lane)?
                }
                Some(PtaskCmd::Demote { query }) => {
                    project_tasks::step(&prof, &log, &name, &pick(&query)?, 1, lane)?
                }
                Some(PtaskCmd::Sweep { dry_run }) => {
                    project_tasks::sweep(&prof, &log, &name, dry_run, lane)?
                }
                Some(PtaskCmd::Archive { dry_run }) => {
                    project_tasks::archive(&prof, &log, &name, dry_run, lane)?
                }
            }
        }
        Cmd::Board {
            json,
            agent,
            version,
            projects,
        } => {
            if let Some(v) = version {
                board::print_version(&v, &projects)?
            } else if json {
                board::print_json()?
            } else if agent {
                board::print_agent(&projects)?
            } else {
                board::run(&log)?
            }
        }
        Cmd::Outbox { sub } => match sub {
            None => outbox::list(&prof, false)?,
            Some(OutboxCmd::List { json }) => outbox::list(&prof, json)?,
            Some(OutboxCmd::Show { json }) => outbox::show(&prof, json)?,
            Some(OutboxCmd::Put { base }) => {
                let mut text = String::new();
                std::io::Read::read_to_string(&mut std::io::stdin(), &mut text)?;
                outbox::put(&prof, &log, &base, &text)?
            }
            Some(OutboxCmd::Add { text }) => outbox::add(&prof, &log, &text.join(" "))?,
            Some(OutboxCmd::Move { project, raw }) => {
                outbox::move_line(&prof, &log, &project, &raw.join(" "))?
            }
        },
        Cmd::Log {
            steps: true, json, ..
        } => steps::print(&prof, json)?,
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
            let filter = ingest::Filter {
                project: project.map(|n| registry::canonical(&n)),
                id,
                action,
                by,
                item,
            };
            ingest::log(&prof, day.as_deref(), days, &filter, json)?
        }
        Cmd::Ingest { sub } => match sub {
            IngestCmd::Record(r) => {
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
                    text,
                } = *r;
                let set = |v: Option<String>| ingest::set(v.as_deref());
                let mut ev = ingest::Event::new(
                    &action,
                    &from,
                    to.as_deref().unwrap_or(""),
                    &text.join(" "),
                );
                ev.stage = Some(stage);
                ev.why = set(why);
                ev.id = set(id);
                ev.item = set(item).or(ev.item);
                if let Some(b) = set(by) {
                    ev.by = b;
                }
                ev.pr = set(pr);
                ev.sha = set(sha);
                ingest::record(&prof, &ev);
                0
            }
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
        Cmd::Knowledge { sub } => match sub {
            KnowledgeCmd::Init { force } => {
                knowledge::init(&prof, &log, force)?;
                0
            }
            KnowledgeCmd::Due { n } => {
                for path in knowledge::due(&prof, n) {
                    println!("{path}");
                }
                0
            }
            KnowledgeCmd::Apply {
                file,
                started,
                dry_run,
            } => {
                knowledge::apply(&prof, &log, &file, started, dry_run)?;
                0
            }
        },
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
        Cmd::Tags { name } => {
            match name {
                Some(n) => tags::show(&prof, &n)?,
                None => tags::list(&prof)?,
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
            migrate,
            move_project,
            to_profile,
            retire_ai_tag,
            migrate_rows,
            dry_run,
            minor,
            major,
            force,
            carry,
            next,
            renumber,
            version_of,
            roadmap,
            stats,
            json,
            agent_note,
            version,
            stage,
            stages,
            group,
            prio,
            set,
        } => {
            let level = if major {
                projects::Bump::Major
            } else if minor {
                projects::Bump::Minor
            } else {
                projects::Bump::Patch
            };
            // A whole-vault sweep, so it is handled before the name-keyed match below:
            // an empty NAME means "every project" and must not fall through as a lookup.
            if let Some(n) = retire_ai_tag {
                let which = if n.is_empty() { None } else { Some(n.as_str()) };
                projects::retire_ai_tag(&prof, &log, which, dry_run)?;
                std::process::exit(0);
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
            if stages {
                projects::stages();
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
            if let Some(n) = prio {
                projects::prio(&prof, &log, &n, set.as_deref())?;
                if set.is_some() {
                    lab_refresh::kick();
                }
                std::process::exit(0);
            }
            // Two values (name + destination), so it sits beside --stage, not in the tuple.
            if let (Some(n), Some(dest)) = (move_project, to_profile) {
                projects::move_to_profile(&prof, &log, &n, &dest)?;
                lab_refresh::kick();
                std::process::exit(0);
            }
            if json && !stats && roadmap.is_none() {
                anyhow::bail!("--json goes with --stats or --roadmap");
            }
            if stats {
                projects::stats(json)?;
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
                    projects::release(
                        &prof,
                        &log,
                        &n,
                        level,
                        force,
                        carry,
                        next.as_deref(),
                        renumber,
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
        Cmd::Clickup { sub } => match sub {
            ClickupCmd::Sync => clickup::sync(&prof, &log)?,
            ClickupCmd::Push => clickup::push(&prof, &log)?,
        },
        Cmd::Doctor { untyped: true, .. } => doctor::untyped()?,
        Cmd::Doctor { projects: true, .. } => doctor::projects()?,
        Cmd::Doctor {
            projects: false, ..
        } => doctor::run(&prof, &log)?,
        Cmd::Config { profiles } => {
            if profiles {
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
    fn playtest_takes_four_verbs_and_refuses_the_rest() {
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
                e.contains("--playtest takes list, add, done and drop"),
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
}
