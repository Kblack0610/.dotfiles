//! Project grouping, ANSI fzf rows, and preview formatting.

use crate::chooser::Agent;

// ANSI codes. Title is bold-only so it inherits the active terminal theme.
const RED: &str = "\x1b[1;31m";
const YELLOW: &str = "\x1b[1;33m";
const GREEN: &str = "\x1b[1;32m";
const TITLE: &str = "\x1b[1m";
const DIM: &str = "\x1b[2m";
const RESET: &str = "\x1b[0m";
const CYAN: &str = "\x1b[36m";
const BOLD: &str = "\x1b[1m";

/// Normalize a working-directory path to a project name: basename with any
/// `-agent`, `-agent2`, `-agent-2` worktree suffix stripped, and the dotfiles
/// dir folded to `dotfiles`.
pub fn project_from_path(path: &str) -> String {
    let base = basename(path);
    let stripped = strip_agent_suffix(base);
    match stripped {
        ".dotfiles" | "_dotfiles" => "dotfiles".to_string(),
        other => other.to_string(),
    }
}

pub fn basename(path: &str) -> &str {
    path.trim_end_matches('/').rsplit('/').next().unwrap_or(path)
}

/// Strip a trailing `-agent-?[0-9]*` worktree marker.
fn strip_agent_suffix(s: &str) -> &str {
    if let Some(idx) = s.rfind("-agent") {
        let rest = &s[idx + "-agent".len()..];
        let digits = rest.strip_prefix('-').unwrap_or(rest);
        if digits.chars().all(|c| c.is_ascii_digit()) {
            return &s[..idx];
        }
    }
    s
}

/// Row label under a project header: the worktree's agent number, then the tmux
/// window index, e.g. session "platform-agent-4" window "2" -> "4:2". These are
/// two distinct values -- the agent number identifies the worktree, the window
/// index distinguishes tasks within it. Falls back to the window index alone
/// when the session carries no "-agent-N" worktree suffix.
pub fn short_target(session: &str, window_index: &str) -> String {
    let s = session.trim_start_matches(['_', '.']);
    let agent = s.rsplit_once("-agent").map(|(_, rest)| rest.trim_start_matches('-'));
    match agent {
        Some(n) if !n.is_empty() && n.chars().all(|c| c.is_ascii_digit()) => {
            format!("{n}:{window_index}")
        }
        _ => window_index.to_string(),
    }
}

fn colorize(g: char) -> String {
    match g {
        '!' => format!("{RED}!{RESET}"),
        '~' => format!("{YELLOW}~{RESET}"),
        '✓' => format!("{GREEN}✓{RESET}"),
        other => other.to_string(),
    }
}

/// Strip a leading status glyph + space from a Claude pane title (the row's own
/// glyph already conveys state). e.g. "✳ Doing a thing" -> "Doing a thing".
pub fn strip_title_glyph(title: &str) -> String {
    let mut chars = title.chars();
    if let Some(first) = chars.next() {
        if !first.is_alphanumeric() && !first.is_whitespace() && chars.next() == Some(' ') {
            return chars.collect::<String>().trim().to_string();
        }
    }
    title.trim().to_string()
}

/// An fzf row: tab-separated `<full_target>\t<display>`. fzf hides field 1
/// (`--with-nth=2..`) and we recover it on selection to drive switch-client.
pub struct Row {
    pub target: String, // empty for non-selectable project headers
    pub text: String,   // full row, tab included
}

/// Build the grouped fzf rows (projects sorted) and the preview map-file body.
/// Returns `(rows, map_lines)`.
pub fn build(agents: &[Agent]) -> (Vec<Row>, Vec<String>) {
    let mut projects: Vec<&String> = agents.iter().map(|a| &a.project).collect();
    projects.sort();
    projects.dedup();

    let mut rows = Vec::new();
    let mut map = Vec::new();

    for project in projects {
        let group: Vec<&Agent> = agents.iter().filter(|a| &a.project == project).collect();
        let statuses: String = group.iter().map(|a| colorize(a.glyph)).collect();
        let count = group.len();
        rows.push(Row {
            target: String::new(),
            text: format!("\t{TITLE}━━━ {project}{RESET} {statuses} {DIM}({count}){RESET}"),
        });

        for a in group {
            let g = colorize(a.glyph);
            let display = if a.summary.is_empty() {
                format!(" {g} {}", a.short_target)
            } else {
                format!(" {g} {} {DIM}{}{RESET}", a.short_target, a.summary)
            };
            rows.push(Row {
                target: a.target.clone(),
                text: format!("{}\t{display}", a.target),
            });

            let jsonl = a
                .jsonl
                .as_ref()
                .map(|p| p.to_string_lossy().into_owned())
                .unwrap_or_default();
            map.push(format!(
                "{}\t{}\t{}\t{}\t{}",
                a.target, jsonl, a.project, a.summary, a.repo_full
            ));
        }
    }

    (rows, map)
}

/// Render the preview pane for one agent row.
pub fn preview(target: &str, jsonl: Option<&std::path::Path>, project: &str, summary: &str, repo_full: &str) {
    let mut header = if repo_full.is_empty() {
        if project.is_empty() {
            target.to_string()
        } else {
            project.to_string()
        }
    } else {
        repo_full.to_string()
    };
    if !summary.is_empty() {
        header = format!("{header} - {summary}");
    }
    println!("{CYAN}{BOLD}── {header} ──{RESET}");

    // Live pane state — keep colour escapes so it renders like the real pane.
    let pane = crate::tmux::capture_pane(target, true, -60);
    let lines: Vec<&str> = pane.lines().collect();
    for line in &lines[lines.len().saturating_sub(40)..] {
        println!("{line}");
    }
    println!();

    if let Some(path) = jsonl {
        if path.exists() {
            println!("{CYAN}{BOLD}── claude: recent events ──────────────────────{RESET}");
            for ev in crate::jsonl::recent_events(path, 6) {
                println!("{ev}");
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn strips_agent_suffixes() {
        assert_eq!(project_from_path("/a/b/platform-agent-2"), "platform");
        assert_eq!(project_from_path("/a/b/foo-agent"), "foo");
        assert_eq!(project_from_path("/a/b/bar-agent3"), "bar");
        assert_eq!(project_from_path("/a/b/.dotfiles"), "dotfiles");
        assert_eq!(project_from_path("/a/b/plain"), "plain");
        // "-agent" mid-name without a trailing suffix is not stripped.
        assert_eq!(project_from_path("/a/b/my-agentic-tool"), "my-agentic-tool");
    }

    #[test]
    fn labels_agent_and_window() {
        // agent number leads (the worktree identity), window index trails.
        assert_eq!(short_target("platform-agent-4", "2"), "4:2");
        assert_eq!(short_target("platform-agent-2", "1"), "2:1");
        assert_eq!(short_target("platform-agent-2", "4"), "2:4");
        // no "-agent-N" suffix -> window index only.
        assert_eq!(short_target("platform", "3"), "3");
        assert_eq!(short_target("_dotfiles", "0"), "0");
    }

    #[test]
    fn strips_title_glyph() {
        assert_eq!(strip_title_glyph("✳ Hello there"), "Hello there");
        assert_eq!(strip_title_glyph("Plain title"), "Plain title");
        assert_eq!(strip_title_glyph("✳nospaces"), "✳nospaces");
    }
}
