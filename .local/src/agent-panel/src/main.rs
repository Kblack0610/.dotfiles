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
        /// Add a row per parked session (`claude-acct park`), the attached ones first: what
        /// hub-core `session_actions` acts on.
        #[arg(long)]
        parked: bool,
    },
    /// Exit 0 when the transcript's last word asks the human something (a question, a step for
    /// them to take, or an open dialog), else 1. The Stop check that makes a session file its ask.
    AsksHuman { transcript: PathBuf },
    /// Print a transcript's closed time by what it waited on, as one JSON object. The nightly
    /// session-outcomes run reads this, so the rule lives only in `time_use`.
    TimeUse { transcript: PathBuf },
    /// Jump to a `<server>/<session>:<window>` target from `list`.
    Jump { target: String },
    /// Type a message into a pane (`list --json`'s `pane`, `<server>/<pane>`) and submit it once
    /// the paste is drawn. Exits 3 when the pane never took the Enter: the text is still in its
    /// input box.
    Send {
        #[arg(long)]
        pane: String,
        /// Paste only; do not press Enter.
        #[arg(long)]
        no_submit: bool,
        text: String,
    },
    /// The turn of a transcript that posted an ask, as JSON {"first","prompt","said"}: the
    /// session's first typed prompt, the prompt that turn answered, and its text blocks, oldest
    /// first (the ask card's story). Exits 1 when no tool result in the transcript printed the id.
    Said {
        transcript: PathBuf,
        #[arg(long)]
        around: String,
    },
    /// Internal fzf reload callback: print the chooser rows again (not meant to be run by hand).
    #[command(hide = true)]
    Rows {
        #[arg(long)]
        map_file: PathBuf,
        /// Only the sessions waiting on the human: a pending ask or a prompt (ctrl-y).
        #[arg(long)]
        asking: bool,
    },
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
        Some(Cmd::List { json, parked }) => chooser::run_list(json, parked),
        Some(Cmd::AsksHuman { transcript }) => {
            std::process::exit(if agent_panel::jsonl::asks_human_at(&transcript) { 0 } else { 1 })
        }
        Some(Cmd::TimeUse { transcript }) => {
            println!("{}", serde_json::to_string(&agent_panel::jsonl::time_use_at(&transcript))?);
            Ok(())
        }
        Some(Cmd::Jump { target }) => chooser::run_jump(&target),
        Some(Cmd::Send { pane, no_submit, text }) => {
            if agent_panel::send::message(&pane, &text, !no_submit)? == agent_panel::send::Sent::NotSubmitted {
                eprintln!("agent-panel send: {pane} did not take the Enter; the text is still in its input box");
                std::process::exit(3);
            }
            Ok(())
        }
        Some(Cmd::Said { transcript, around }) => match agent_panel::jsonl::said_around_at(&transcript, &around) {
            Some(said) => {
                println!("{}", serde_json::to_string(&said)?);
                Ok(())
            }
            None => std::process::exit(1),
        },
        Some(Cmd::Rows { map_file, asking }) => chooser::run_rows(&map_file, asking),
        Some(Cmd::Preview { map_file, row }) => chooser::run_preview(&map_file, &row),
    }
}
