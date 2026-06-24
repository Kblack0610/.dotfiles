//! agent-panel — cross-platform tmux chooser for Claude/AI agents.
//!
//! Lists every tmux window running a Claude agent, grouped by project, with a
//! live status glyph and an fzf preview. Replaces the old Linux-only bash
//! `agent-chooser.sh` + `agent-preview.sh`: process ancestry comes from
//! `ps -axo pid=,ppid=` (portable to macOS/BSD + Linux) instead of `/proc`.

use std::path::PathBuf;

use clap::{Parser, Subcommand};

mod chooser;
mod fzf;
mod jsonl;
mod procmap;
mod render;
mod session;
mod tmux;

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
        Some(Cmd::Preview { map_file, row }) => chooser::run_preview(&map_file, &row),
    }
}
