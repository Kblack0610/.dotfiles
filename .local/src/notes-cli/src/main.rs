//! `notes` — a single, profile-aware binary that owns all journal + zettelkasten
//! logic for the `~/.notes` vault. The git/MQTT sync layer lives elsewhere (shell);
//! this tool only reads and writes note files.
//!
//! Everything here is pure Rust (chrono for dates) so behaviour is identical on
//! macOS and Linux — no GNU-vs-BSD `date`/`sed`/`stat` divergence.

mod archive;
mod backlog;
mod clickup;
mod comms;
mod config;
mod daily;
mod doctor;
mod focus;
mod focus_move;
mod focus_sweep;
mod inbox;
mod index;
mod logging;
mod md;
mod meeting;
mod project_tasks;
mod projects;
mod summarize;
mod tags;
mod zettel;

use anyhow::{bail, Result};
use clap::{Parser, Subcommand};

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
    /// Per-project task list — the `## Wave` on a project's sheet (the project analog of
    /// `focus`, which is the daily note's `## Focus`). Project tasks live in the project .md.
    Ptask {
        /// Project name (case-insensitive)
        name: String,
        #[command(subcommand)]
        sub: Option<PtaskCmd>,
    },
    /// Triage the dated-capture inbox (list / add / archive). No subcommand = list.
    Inbox {
        #[command(subcommand)]
        sub: Option<InboxCmd>,
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
    /// List the indexed projects behind the daily note's `## Current Projects` block.
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
        /// Roll a project's working sheet to the next version: freeze it into versions/
        /// and reset to a fresh `## Wave: new` (the sheet-model rollover)
        #[arg(long, value_name = "NAME")]
        roll: Option<String>,
        /// Upgrade a legacy version-note project to the sheet model (highest note ->
        /// README sheet, older -> versions/); no-op if already a sheet
        #[arg(long, value_name = "NAME")]
        migrate: Option<String>,
        /// Start the next version's note for a legacy version-note project (seeds v0.0.1)
        #[arg(long, value_name = "NAME")]
        bump: Option<String>,
        /// With --roll/--bump: step the minor (v0.1.2 -> v0.2.0)
        #[arg(long)]
        minor: bool,
        /// With --roll/--bump: step the major (v0.1.2 -> v1.0.0)
        #[arg(long)]
        major: bool,
        /// Print a project's current version
        #[arg(long, value_name = "NAME")]
        version_of: Option<String>,
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
    Doctor,
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
    /// Reorganize today's `## Focus` by status (todo / in progress / done)
    Sweep,
}

/// `notes ptask <name> …` verbs — the project analog of `FocusCmd`, on the sheet's `## Wave`.
#[derive(clap::Subcommand)]
enum PtaskCmd {
    /// List the project's open wave tasks (TSV: `path<TAB>line<TAB>key<TAB>text`)
    List,
    /// Add a task to the project's current wave
    Add {
        #[arg(required = true, num_args = 1..)]
        text: Vec<String>,
    },
    /// Check off the first open wave task whose text matches
    Done {
        #[arg(required = true, num_args = 1..)]
        query: Vec<String>,
    },
    /// Toggle the first matching wave task between todo and in-progress (`[ ]` <-> `[/]`)
    Start {
        #[arg(required = true, num_args = 1..)]
        query: Vec<String>,
    },
    /// Delete the first open wave task whose text matches
    Rm {
        #[arg(required = true, num_args = 1..)]
        query: Vec<String>,
    },
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
        Cmd::Path { target } => match daily::resolve_path(&prof, &target) {
            Some(path) => {
                println!("{}", path.display());
                0
            }
            None => {
                eprintln!(
                    "unknown path target '{target}' (want: daily, daily-dir, refs, refs-today, root, fun, scheduled, recurring, zettel, meetings, index, inbox, inbox-today)"
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
        Cmd::Ptask { name, sub } => match sub {
            None | Some(PtaskCmd::List) => project_tasks::list(&prof, &name)?,
            Some(PtaskCmd::Add { text }) => {
                project_tasks::add(&prof, &log, &name, &text.join(" "))?
            }
            Some(PtaskCmd::Done { query }) => {
                project_tasks::done(&prof, &log, &name, &query.join(" "))?
            }
            Some(PtaskCmd::Start { query }) => {
                project_tasks::start(&prof, &log, &name, &query.join(" "))?
            }
            Some(PtaskCmd::Rm { query }) => {
                project_tasks::rm(&prof, &log, &name, &query.join(" "))?
            }
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
            }
            0
        }
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
            roll,
            migrate,
            bump,
            minor,
            major,
            version_of,
        } => {
            let level = if major {
                projects::Bump::Major
            } else if minor {
                projects::Bump::Minor
            } else {
                projects::Bump::Patch
            };
            // lifecycle/version flags take precedence over the read paths
            match (
                new, archive, restore, roll, migrate, bump, version_of, archived, name,
            ) {
                (Some(n), ..) => projects::new_project(&prof, &log, &n)?,
                (_, Some(n), ..) => projects::archive(&prof, &log, &n)?,
                (_, _, Some(n), ..) => projects::restore(&prof, &log, &n)?,
                (_, _, _, Some(n), ..) => projects::roll(&prof, &log, &n, level)?,
                (_, _, _, _, Some(n), ..) => projects::migrate(&prof, &log, &n)?,
                (_, _, _, _, _, Some(n), ..) => projects::bump(&prof, &log, &n, level)?,
                (_, _, _, _, _, _, Some(n), ..) => projects::show_version(&prof, &n)?,
                (_, _, _, _, _, _, _, true, _) => projects::list_archived(&prof)?,
                (_, _, _, _, _, _, _, _, Some(n)) => projects::show(&prof, &n)?,
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
        Cmd::Doctor => doctor::run(&prof, &log)?,
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
