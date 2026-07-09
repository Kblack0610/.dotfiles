//! Orchestration for the three entry points: interactive chooser, `next`, and
//! the internal `preview` callback.

use std::collections::HashSet;
use std::fs;
use std::path::{Path, PathBuf};

use anyhow::Result;

use crate::{fzf, jsonl, procmap::ProcMap, render, session, tmux};

/// One detected Claude agent, ready to render.
pub struct Agent {
    pub glyph: char,
    pub target: String,       // session:window
    pub short_target: String, // display target under the project header
    pub project: String,
    pub repo_full: String, // basename incl. worktree suffix, for preview header
    pub summary: String,
    pub jsonl: Option<PathBuf>,
}

/// Walk every tmux pane, keep those whose process tree contains a live Claude
/// session, and build an ordered agent list.
fn collect() -> Vec<Agent> {
    let panes = tmux::list_panes();
    let Ok(procmap) = ProcMap::capture() else {
        return Vec::new();
    };
    let sessions = session::load_all();
    let live_claude: Vec<u32> = sessions
        .keys()
        .copied()
        .filter(|&pid| procmap.is_live(pid))
        .collect();
    let pane_to_claude = procmap.pane_to_claude(&live_claude);

    let mut seen = HashSet::new();
    let mut agents = Vec::new();
    for pane in panes {
        let target = format!("{}:{}", pane.session, pane.window_index);
        if !seen.insert(target.clone()) {
            continue;
        }
        let Some(&cpid) = pane_to_claude.get(&pane.pid) else {
            continue; // not a Claude agent
        };
        let Some(sess) = sessions.get(&cpid) else {
            continue;
        };

        let jsonl_path = session::jsonl_path(&sess.session_id, &sess.cwd);
        let mut summary = if jsonl_path.exists() {
            jsonl::last_event(&jsonl_path)
        } else {
            String::new()
        };
        // Prefer Claude's pane title (the live session title) over the JSONL
        // "say:" text; the row glyph already conveys status.
        if !pane.title.is_empty() {
            let cleaned = render::strip_title_glyph(&pane.title);
            if !cleaned.is_empty() {
                summary = cleaned;
            }
        }

        let project = render::project_from_path(&pane.current_path);
        let repo_full = render::basename(&pane.current_path).to_string();
        let short_target = render::short_target(&pane.session, &pane.window_index);

        agents.push(Agent {
            glyph: session::glyph(&sess.status),
            target,
            short_target,
            project,
            repo_full,
            summary,
            jsonl: jsonl_path.exists().then_some(jsonl_path),
        });
    }
    agents
}

fn map_file_path() -> PathBuf {
    std::env::temp_dir().join(format!("agent-panel-{}.map", std::process::id()))
}

/// Interactive chooser: render rows, drive fzf, jump to the selection.
pub fn run_interactive() -> Result<()> {
    let agents = collect();
    if agents.is_empty() {
        println!("No claude agents running");
        return Ok(());
    }

    let (rows, map_lines) = render::build(&agents);
    let map_file = map_file_path();
    fs::write(&map_file, map_lines.join("\n"))?;

    let rows_text = rows
        .iter()
        .map(|r| r.text.clone())
        .collect::<Vec<_>>()
        .join("\n");

    // Position the cursor on the currently active agent, if any.
    let restore_line = tmux::current_target().and_then(|cur| {
        rows.iter()
            .position(|r| r.target == cur)
            .map(|i| i + 1) // fzf pos() is 1-based
    });

    let selected = fzf::run(&rows_text, &map_file, restore_line);
    let _ = fs::remove_file(&map_file);
    let selected = selected?;

    if let Some(line) = selected {
        // Header rows carry the heavy bar and an empty target — ignore them.
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

/// Jump to the next agent needing attention (`!`), else the next in the list.
pub fn run_next() -> Result<()> {
    let agents = collect();
    if agents.is_empty() {
        return Ok(());
    }
    let current = tmux::current_target();
    let cur_idx = current
        .as_ref()
        .and_then(|c| agents.iter().position(|a| &a.target == c));
    let total = agents.len();
    let start = cur_idx.map(|i| i as isize).unwrap_or(-1);

    // First look for the next attention-needed agent after the current one.
    let mut target: Option<&str> = None;
    for step in 1..=total {
        let idx = (((start + step as isize) % total as isize + total as isize)
            % total as isize) as usize;
        if agents[idx].glyph == '!' {
            target = Some(&agents[idx].target);
            break;
        }
    }
    // Otherwise just advance to the next agent.
    let next_target = target.unwrap_or_else(|| {
        let idx = (((start + 1) % total as isize + total as isize) % total as isize) as usize;
        &agents[idx].target
    });

    tmux::jump(next_target);
    Ok(())
}

/// fzf preview callback: render the pane state + recent events for one row.
pub fn run_preview(map_file: &Path, row: &str) -> Result<()> {
    if row.contains("━━") {
        return Ok(()); // header row, no preview
    }
    let mut target = row.split('\t').next().unwrap_or("").to_string();
    // Fallback: dig a session:window token out of the visible text.
    if !target.contains(':') {
        target = extract_target(row).unwrap_or_default();
    }
    if target.is_empty() {
        return Ok(());
    }

    let (jsonl_path, project, summary, repo_full) = lookup(map_file, &target);
    render::preview(
        &target,
        jsonl_path.as_deref(),
        &project,
        &summary,
        &repo_full,
    );
    Ok(())
}

/// Find a `session:window` token in arbitrary row text.
fn extract_target(row: &str) -> Option<String> {
    for tok in row.split_whitespace() {
        if let Some((a, b)) = tok.split_once(':') {
            if !a.is_empty()
                && a.chars().all(|c| c.is_alphanumeric() || c == '_' || c == '-')
                && !b.is_empty()
                && b.chars().all(|c| c.is_ascii_digit())
            {
                return Some(tok.to_string());
            }
        }
    }
    None
}

/// Read the preview map file for a target row:
/// `target \t jsonl \t project \t summary \t repo_full`.
fn lookup(map_file: &Path, target: &str) -> (Option<PathBuf>, String, String, String) {
    let Ok(text) = fs::read_to_string(map_file) else {
        return (None, String::new(), String::new(), String::new());
    };
    for line in text.lines() {
        let f: Vec<&str> = line.split('\t').collect();
        if f.first() == Some(&target) {
            let jsonl = f.get(1).filter(|s| !s.is_empty()).map(PathBuf::from);
            return (
                jsonl,
                f.get(2).unwrap_or(&"").to_string(),
                f.get(3).unwrap_or(&"").to_string(),
                f.get(4).unwrap_or(&"").to_string(),
            );
        }
    }
    (None, String::new(), String::new(), String::new())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn extracts_target_token() {
        assert_eq!(
            extract_target(" ✓ agent-2:1 some summary"),
            Some("agent-2:1".to_string())
        );
        assert_eq!(extract_target("no target here"), None);
    }
}
