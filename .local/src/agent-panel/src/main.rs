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
    /// Open the chooser with this search already typed, e.g. `'dotfiles` for one project's
    /// agents (Prefix+p a).
    #[arg(long)]
    query: Option<String>,
}

#[derive(Subcommand)]
enum Cmd {
    /// Jump to the next agent that needs you; with none, say so and stay put.
    Next,
    /// Print one plain TSV row per live agent, for other surfaces to consume. Exits 3, after
    /// the rows it could read, when a source failed (named on stderr): the list may miss a
    /// live session.
    List {
        /// One JSON object per line with session and transcript facts (fleet-sessions).
        #[arg(long)]
        json: bool,
        /// Add a row per parked session (`claude-acct park`), the attached ones first: what
        /// hub-core `session_actions` acts on.
        #[arg(long)]
        parked: bool,
        /// Add a row per Codex run in a pane (`"harness": "codex"`, always busy): fleet-sessions.
        /// Left out by default, since the other readers take every row for a Claude conversation.
        /// fleet-sessions sets the env form, which a binary older than the flag ignores.
        #[arg(long, env = "AGENT_PANEL_CODEX", value_parser = clap::builder::FalseyValueParser::new())]
        codex: bool,
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
    /// The plan or question dialog open in a session (`<server>/<session>:<window>`), as the
    /// questions panel's card; exits 1 when its pane shows none.
    Dialog {
        target: String,
        /// Its options as `<key>\t<free 0|1>\t<text>` lines instead of the card.
        #[arg(long)]
        options: bool,
    },
    /// Choose option <key> in the dialog open in a session, after checking it still reads
    /// --expect; a free-text option types [text] into the field it opens. Exits 3 when the
    /// dialog did not take it, 4 when it is gone or changed.
    Answer {
        target: String,
        key: char,
        #[arg(long, default_value = "")]
        expect: String,
        #[arg(default_value = "")]
        text: String,
    },
    /// Markdown on stdin as plain text: no heading, bold or backtick marks, no fences, a table as
    /// `header: value` lines, folded at --width (default the fzf preview's or terminal's width,
    /// at most 110; 0 folds nothing). The one cleaner the panels' previews and cards use.
    Plain {
        #[arg(long)]
        width: Option<usize>,
    },
    /// Internal fzf reload callback: print the chooser rows again (not meant to be run by hand).
    #[command(hide = true)]
    Rows {
        #[arg(long)]
        map_file: PathBuf,
        /// Only the sessions waiting on the human: a pending ask or a prompt (ctrl-y).
        #[arg(long)]
        asking: bool,
        /// Move the saved sort first: `next` key (C-o) or `reverse` direction (A-o).
        #[arg(long, value_enum)]
        sort: Option<agent_panel::sort::Step>,
        /// The search box text; only the matching rows print.
        #[arg(long, default_value = "", allow_hyphen_values = true)]
        query: String,
    },
    /// Internal fzf change callback: the saved rows matching the search box (not meant to be run by hand).
    #[command(hide = true)]
    Match {
        #[arg(long)]
        map_file: PathBuf,
        #[arg(long, default_value = "", allow_hyphen_values = true)]
        query: String,
    },
    /// Internal ctrl-n callback: a new Claude in a fresh worktree of the repo the agent at
    /// `target` works in (not meant to be run by hand).
    #[command(hide = true)]
    NewAgent { target: String },
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
        None => chooser::run_interactive(cli.query.as_deref()),
        Some(Cmd::Next) => chooser::run_next(),
        Some(Cmd::List {
            json,
            parked,
            codex,
        }) => chooser::run_list(json, parked, codex),
        Some(Cmd::AsksHuman { transcript }) => {
            std::process::exit(if agent_panel::jsonl::asks_human_at(&transcript) {
                0
            } else {
                1
            })
        }
        Some(Cmd::TimeUse { transcript }) => {
            println!(
                "{}",
                serde_json::to_string(&agent_panel::jsonl::time_use_at(&transcript))?
            );
            Ok(())
        }
        Some(Cmd::Jump { target }) => chooser::run_jump(&target),
        Some(Cmd::Send {
            pane,
            no_submit,
            text,
        }) => {
            if agent_panel::send::message(&pane, &text, !no_submit)?
                == agent_panel::send::Sent::NotSubmitted
            {
                eprintln!("agent-panel send: {pane} did not take the Enter; the text is still in its input box");
                std::process::exit(3);
            }
            Ok(())
        }
        Some(Cmd::Said { transcript, around }) => {
            match agent_panel::jsonl::said_around_at(&transcript, &around) {
                Some(said) => {
                    println!("{}", serde_json::to_string(&said)?);
                    Ok(())
                }
                None => std::process::exit(1),
            }
        }
        Some(Cmd::Dialog { target, options }) => agent_panel::dialog::run_card(&target, options),
        Some(Cmd::Answer {
            target,
            key,
            expect,
            text,
        }) => agent_panel::dialog::run_answer(&target, key, &expect, &text),
        Some(Cmd::Plain { width }) => {
            let mut text = String::new();
            std::io::Read::read_to_string(&mut std::io::stdin(), &mut text)?;
            println!(
                "{}",
                agent_panel::md::plain(&text, width.unwrap_or_else(agent_panel::md::width))
            );
            Ok(())
        }
        Some(Cmd::Rows {
            map_file,
            asking,
            sort,
            query,
        }) => chooser::run_rows(&map_file, asking, sort, &query),
        Some(Cmd::Match { map_file, query }) => chooser::run_match(&map_file, &query),
        Some(Cmd::NewAgent { target }) => chooser::run_new_agent(&target),
        Some(Cmd::Preview { map_file, row }) => chooser::run_preview(&map_file, &row),
    }
}
