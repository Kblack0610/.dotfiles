//! `notes` — a single, profile-aware binary that owns all journal + zettelkasten
//! logic for the `~/.notes` vault. The git/MQTT sync layer lives elsewhere (shell);
//! this tool only reads and writes note files.
//!
//! Everything here is pure Rust (chrono for dates) so behaviour is identical on
//! macOS and Linux — no GNU-vs-BSD `date`/`sed`/`stat` divergence.

mod archive;
mod backlog;
mod comms;
mod config;
mod daily;
mod doctor;
mod focus;
mod inbox;
mod index;
mod logging;
mod md;
mod meeting;
mod projects;
mod summarize;
mod tags;
mod zettel;

use anyhow::Result;
use clap::{Parser, Subcommand};

#[derive(Parser)]
#[command(name = "notes", version, about = "Profile-aware journal + zettelkasten CLI")]
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
    Today,
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
    },
    /// Surface multi-account email triage into the daily note's `## Comms` section.
    /// No subcommand = list the currently-surfaced items for the active profile.
    /// The pull/label/classify work is done out-of-band by the triage poller.
    Comms {
        #[command(subcommand)]
        sub: Option<CommsCmd>,
    },
    /// Diagnose the notes system (config, dirs, gaps, sync, dead links)
    Doctor,
    /// Print the resolved profile + paths
    Config,
}

#[derive(Subcommand)]
enum CommsCmd {
    /// List the currently-surfaced comms items for the active profile (the default)
    List,
    /// Re-render today's note's `## Comms` section from the triage surface file
    Refresh,
    /// Show configured accounts + whether each has a surface file (read-only)
    Status,
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
    /// Delete the first open item whose text matches (removes the line entirely)
    Rm {
        /// A word (or two) from the task to delete
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
        Cmd::Today => {
            daily::run(&prof, &log)?;
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
        Cmd::Archive { month, dry_run, backfill } => {
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
            if all {
                focus::list_all(&log)?;
            } else {
                match sub {
                    None | Some(FocusCmd::List) => focus::list(&prof, &log)?,
                    Some(FocusCmd::Add { text }) => focus::add(&prof, &log, &text.join(" "))?,
                    Some(FocusCmd::Done { query }) => focus::done(&prof, &log, &query.join(" "))?,
                    Some(FocusCmd::Rm { query }) => focus::rm(&prof, &log, &query.join(" "))?,
                }
            }
            0
        }
        Cmd::Inbox { sub } => {
            match sub {
                None | Some(InboxCmd::List) => inbox::list(&prof, &log)?,
                Some(InboxCmd::Add { text }) => inbox::add(&prof, &log, &text.join(" "))?,
                Some(InboxCmd::Archive { target, stale, before }) => {
                    inbox::archive(&prof, &log, target.as_deref(), stale, before.as_deref())?
                }
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
        Cmd::Projects { name } => {
            match name {
                Some(n) => projects::show(&prof, &n)?,
                None => projects::list(&prof)?,
            }
            0
        }
        Cmd::Comms { sub } => {
            match sub {
                None | Some(CommsCmd::List) => comms::list(&prof, &log)?,
                Some(CommsCmd::Refresh) => comms::refresh_cmd(&prof, &log)?,
                Some(CommsCmd::Status) => comms::status(&log)?,
            }
            0
        }
        Cmd::Doctor => doctor::run(&prof, &log)?,
        Cmd::Config => {
            config::print(&prof);
            if let Ok(c) = config::comms_config() {
                if !c.accounts.is_empty() {
                    config::print_comms(&c);
                }
            }
            0
        }
    };

    std::process::exit(code);
}
