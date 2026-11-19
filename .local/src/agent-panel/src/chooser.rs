//! The chooser's CLI verbs: the interactive chooser, `next`, `list` and `jump`. The fzf
//! callbacks the open chooser runs (reload, match, move, preview, ctrl-n) are `callbacks`; the
//! agents themselves come from `agent_core::agent`.

use std::collections::HashSet;
use std::fs;
use std::io::IsTerminal;
use std::path::PathBuf;

use anyhow::Result;

use agent_core::agent::{self, collect, collect_read, Agent, Gaps};
use agent_core::{asks, tmux};

use crate::callbacks::write_rows;
use crate::{dispatched, fzf, render, search, sort};

fn map_file_path() -> PathBuf {
    std::env::temp_dir().join(format!("agent-panel-{}.map", std::process::id()))
}

/// Interactive chooser: render rows, drive fzf, jump to the selection. `query` is typed into
/// the search box up front.
pub fn run_interactive(query: Option<&str>) -> Result<()> {
    let agents = collect();
    if agents.is_empty() {
        println!("No claude agents running");
        // Launched in its own terminal (the pin, a popup), the window closes the moment
        // we exit, so the message would never be read. Hold it until a key.
        if std::io::stdin().is_terminal() {
            println!("(press enter)");
            let _ = std::io::stdin().read_line(&mut String::new());
        }
        return Ok(());
    }

    refresh_index();
    let map_file = map_file_path();
    let rows = write_rows(agents, &map_file, sort::saved())?;
    // fzf runs --disabled (the panel matches, `search`), so a query typed up front is applied here.
    let rows_text = match query.filter(|q| !q.trim().is_empty()) {
        Some(q) => search::filter(
            &fs::read_to_string(search::notes_path(&map_file))?,
            q,
            &search::read_topics(),
        ),
        None => rows_text(&rows),
    };
    // Position the cursor on the currently active agent, if it is listed.
    let restore_line = tmux::current_target().and_then(|cur| {
        rows_text
            .lines()
            .position(|l| l.split('\t').next() == Some(cur.as_str()))
            .map(|i| i + 1) // fzf pos() is 1-based
    });

    let selected = fzf::run(
        &rows_text,
        &map_file,
        restore_line,
        query,
        dispatched::saved().label(),
    );
    let _ = fs::remove_file(&map_file);
    let _ = fs::remove_file(search::notes_path(&map_file));
    let selected = selected?;

    if let Some(line) = selected {
        // Header rows carry the heavy bar and an empty target: ignore them.
        if line.contains("━━") {
            return Ok(());
        }
        let target = line.split('\t').next().unwrap_or("");
        if !target.is_empty() {
            tmux::jump(target);
        }
    }
    Ok(())
}

/// Start an incremental `sessions index` in the background, detached so closing the panel does
/// not kill it, the way `sessions search` does: the titles a session took since the last refresh
/// are searchable from the next open. Only when an index exists; the first build is sessions'.
/// Where `setsid` is missing (macOS) nothing starts and search reads the index as it stands.
fn refresh_index() {
    if search::index_path().is_some_and(|p| p.exists()) {
        let _ = std::process::Command::new("setsid")
            .args(["-f", "sessions", "index"])
            .stdin(std::process::Stdio::null())
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .status();
    }
}

fn rows_text(rows: &[render::Row]) -> String {
    rows.iter()
        .map(|r| r.text.as_str())
        .collect::<Vec<_>>()
        .join("\n")
}

/// Jump to one `<server>/<session>:<window>` target, for surfaces that list agents
/// themselves (fleet.sh) and should not re-implement the cross-server hop.
pub fn run_jump(target: &str) -> Result<()> {
    tmux::jump(target);
    Ok(())
}

/// Plain TSV of every live agent: `target \t glyph \t project \t summary`, where
/// target is `<server>/<session>:<window>`.
///
/// Exists so other surfaces (fleet.sh in the cockpit) can reuse the pane x
/// `~/.claude/sessions` join instead of reimplementing it in bash and drifting.
/// Deliberately raw fields, not the chooser's display text: that carries box-drawing
/// header rows and alignment padding meant only for fzf.
///
/// `json` prints one `agent_core::agent::ListRow` per line instead: the session and transcript
/// facts fleet-sessions buckets on and what an action on the session needs. `parked` adds the
/// parked rows (`collect_all`).
///
/// A read with gaps still prints the rows it has, then names each gap on stderr and exits 3:
/// a partial list must not pass for a whole one to a caller that reads a missing session as
/// gone (fleet-dispatch reap, ar-916).
pub fn run_list(json: bool, parked: bool, codex: bool) -> Result<()> {
    let (agents, gaps) = if parked {
        agent::collect_all_read()
    } else {
        collect_read()
    };
    let agents: Vec<Agent> = agents
        .into_iter()
        .filter(|a| codex || a.harness.is_empty())
        .collect();
    if !json {
        for a in &agents {
            println!("{}\t{}\t{}\t{}", a.target, a.glyph, a.project, a.summary);
        }
        return exit_on_gaps(&gaps);
    }
    for row in agent::list_rows(&agents) {
        println!("{}", serde_json::to_string(&row)?);
    }
    exit_on_gaps(&gaps)
}

/// A read with gaps names each on stderr and exits 3, after the rows it could print.
fn exit_on_gaps(gaps: &Gaps) -> Result<()> {
    if gaps.is_empty() {
        return Ok(());
    }
    let _ = std::io::Write::flush(&mut std::io::stdout()); // a reader gone (EPIPE) still gets the 3
    for g in gaps {
        eprintln!("agent-panel: incomplete read: {g}");
    }
    std::process::exit(3)
}

/// Prefix G: jump to the next agent that needs the human, after the current one. With none, it
/// says so in the message bar and stays put; jumping somewhere else would read as "this one".
/// Asks no live session owns have nowhere to jump to, so the message counts them.
pub fn run_next() -> Result<()> {
    let (agents, gaps) = collect_read();
    let current = tmux::current_target();
    // A partial read could take a live owner for a gone one, so it counts nothing (ar-916).
    let orphans = || {
        let live: HashSet<&str> = agents.iter().map(|a| a.session_id.as_str()).collect();
        gaps.is_empty()
            .then(|| asks::without_live_owner(&asks::root(), &live))
    };
    match next_needing(&agents, current.as_deref()) {
        Next::Jump(target) => tmux::jump(target),
        Next::OnlyHere => tmux::message(&with_orphans("only this session needs you", orphans())),
        Next::Nobody => tmux::message(&with_orphans("no session needs you", orphans())),
    }
    Ok(())
}

/// `base`, plus how many asks wait in Prefix y with no live session to jump to.
fn with_orphans(base: &str, orphans: Option<usize>) -> String {
    match orphans {
        Some(1) => format!("{base}; 1 ask with no live session in Prefix y"),
        Some(n) if n > 1 => format!("{base}; {n} asks with no live session in Prefix y"),
        _ => base.to_string(),
    }
}

#[derive(Debug, PartialEq)]
enum Next<'a> {
    Jump(&'a str),
    OnlyHere,
    Nobody,
}

/// The first agent needing attention after `current` in list order, wrapping around.
fn next_needing<'a>(agents: &'a [Agent], current: Option<&str>) -> Next<'a> {
    let start = current
        .and_then(|c| agents.iter().position(|a| a.target == c))
        .map_or(0, |i| i + 1);
    let n = agents.len();
    let hit = (0..n)
        .map(|k| &agents[(start + k) % n])
        .find(|a| a.needs_attention());
    match hit {
        None => Next::Nobody,
        Some(a) if Some(a.target.as_str()) == current => Next::OnlyHere,
        Some(a) => Next::Jump(&a.target),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn live_agent(server: &str, sess: &str, attached: bool) -> Agent {
        Agent {
            target: format!("{server}/{sess}:1"),
            server: server.into(),
            tmux_session: sess.into(),
            attached,
            ..Agent::default()
        }
    }

    #[test]
    fn prefix_g_jumps_only_to_what_needs_you() {
        let quiet = |s| Agent {
            glyph: '✓',
            ..live_agent("hub", s, false)
        };
        let prompt = |s| Agent {
            glyph: '!',
            ..live_agent("hub", s, false)
        };
        // Nothing needs you: no jump, with or without a current window.
        let none = vec![quiet("a"), quiet("b")];
        assert_eq!(next_needing(&none, Some("hub/a:1")), Next::Nobody);
        assert_eq!(next_needing(&none, None), Next::Nobody);
        assert_eq!(next_needing(&[], None), Next::Nobody);
        // The next one after the current, wrapping past the end.
        let agents = vec![prompt("a"), quiet("b"), prompt("c")];
        assert_eq!(
            next_needing(&agents, Some("hub/a:1")),
            Next::Jump("hub/c:1")
        );
        assert_eq!(
            next_needing(&agents, Some("hub/c:1")),
            Next::Jump("hub/a:1")
        );
        assert_eq!(next_needing(&agents, None), Next::Jump("hub/a:1"));
        // Only the current one: say so instead of jumping to itself.
        let solo = vec![prompt("a"), quiet("b")];
        assert_eq!(next_needing(&solo, Some("hub/a:1")), Next::OnlyHere);
    }

    #[test]
    fn prefix_g_counts_the_asks_it_cannot_jump_to() {
        assert_eq!(
            with_orphans("no session needs you", Some(0)),
            "no session needs you"
        );
        assert_eq!(
            with_orphans("no session needs you", None),
            "no session needs you",
            "a partial read claims nothing"
        );
        assert_eq!(
            with_orphans("no session needs you", Some(1)),
            "no session needs you; 1 ask with no live session in Prefix y"
        );
        assert_eq!(
            with_orphans("only this session needs you", Some(26)),
            "only this session needs you; 26 asks with no live session in Prefix y"
        );
    }
}
