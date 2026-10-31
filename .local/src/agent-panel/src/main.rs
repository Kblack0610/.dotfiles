//! agent-panel — cross-platform tmux chooser for Claude/AI agents.
//!
//! Lists every tmux window running a Claude agent, grouped by project, with a
//! live status glyph and an fzf preview. Replaces the old Linux-only bash
//! `agent-chooser.sh` + `agent-preview.sh`: process ancestry comes from
//! `ps -axo pid=,ppid=` (portable to macOS/BSD + Linux) instead of `/proc`.

use std::path::PathBuf;

use agent_panel::chooser;
use clap::{Parser, Subcommand};

#[derive(Parser)]
#[command(
    name = "agent-panel",
    about = "Cross-platform tmux chooser for Claude/AI agents (fzf + tmux UI)"
)]
struct Cli {
    #[command(subcommand)]
    cmd: Option<Cmd>,
}

#[derive(Subcommand)]
enum Cmd {
    /// Cycle to the next attention-needed agent (else next in list).
    Next,
    /// Print one plain TSV row per live agent, for other surfaces to consume.
    List {
        /// One JSON object per line with session and transcript facts (fleet-sessions).
        #[arg(long)]
        json: bool,
    },
    /// Exit 0 when the transcript's last word asks the human something (a question, a step for
    /// them to take, or an open dialog), else 1. The Stop check that makes a session file its ask.
    AsksHuman { transcript: PathBuf },
    /// Print a transcript's closed time by what it waited on, as one JSON object. The nightly
    /// session-outcomes run reads this, so the rule lives only in `time_use`.
    TimeUse { transcript: PathBuf },
    /// Jump to a `<server>/<session>:<window>` target from `list`.
    Jump { target: String },
    /// Internal fzf preview callback (not meant to be run by hand).
    Preview {
        #[arg(long)]
        map_file: PathBuf,
        /// The selected fzf row text.
        row: String,
    },
}

fn main() -> anyhow::Result<()> {
    let cli = Cli::parse();
    match cli.cmd {
        None => chooser::run_interactive(),
        Some(Cmd::Next) => chooser::run_next(),
        Some(Cmd::List { json }) => chooser::run_list(json),
        Some(Cmd::AsksHuman { transcript }) => {
            std::process::exit(if agent_panel::jsonl::asks_human_at(&transcript) { 0 } else { 1 })
        }
        Some(Cmd::TimeUse { transcript }) => {
            println!("{}", serde_json::to_string(&agent_panel::jsonl::time_use_at(&transcript))?);
            Ok(())
        }
        Some(Cmd::Jump { target }) => chooser::run_jump(&target),
        Some(Cmd::Preview { map_file, row }) => chooser::run_preview(&map_file, &row),
    }
}
