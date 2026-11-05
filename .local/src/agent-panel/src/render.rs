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
const ORANGE: &str = "\x1b[38;5;214m"; // window tags, matching the tmux status bar
const MAGENTA: &str = "\x1b[1;35m";
const BLUE: &str = "\x1b[1;34m";

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

/// The fleet stage beside the target, coloured as in the tmux status bar (`.tmux.conf`
/// `@fleet_fmt`). WORKING and NEEDS print nothing: NEEDS is already the `!` glyph.
fn stage(stage: &str) -> String {
    let colour = match stage {
        "STALLED" => RED,
        "UNCLEAR" => YELLOW,
        "LANDED" | "DONE" => GREEN,
        "PARKED" => DIM,
        _ => return String::new(),
    };
    format!(" {colour}{stage}{RESET}")
}

/// Session labels (`fleet-sessions label`), apart from the window tags by colour.
fn labels(labels: &str) -> String {
    if labels.is_empty() {
        String::new()
    } else {
        format!(" {CYAN}[{labels}]{RESET}")
    }
}

/// The group pinned above every project: the agent holding the live shepherd lease. Its window
/// carries the `shepherd` tag only while the lease is fresh (`tmux::list_panes`), so a stopped
/// pass drops out of the group by itself.
const SHEPHERD: &str = "shepherd";

fn is_shepherd(a: &Agent) -> bool {
    a.tags.split_whitespace().any(|t| t == SHEPHERD)
}

/// Build the grouped fzf rows (the shepherd first, then projects sorted) and the preview
/// map-file body. Returns `(rows, map_lines)`.
pub fn build(agents: &[Agent]) -> (Vec<Row>, Vec<String>) {
    let mut projects: Vec<&str> =
        agents.iter().filter(|a| !is_shepherd(a)).map(|a| a.project.as_str()).collect();
    projects.sort();
    projects.dedup();

    let shepherd: Vec<&Agent> = agents.iter().filter(|a| is_shepherd(a)).collect();
    let mut groups: Vec<(&str, Vec<&Agent>)> = Vec::new();
    if !shepherd.is_empty() {
        groups.push((SHEPHERD, shepherd));
    }
    for project in projects {
        groups.push((
            project,
            agents.iter().filter(|a| !is_shepherd(a) && a.project == project).collect(),
        ));
    }

    let mut rows = Vec::new();
    let mut map = Vec::new();

    for (title, group) in groups {
        let statuses: String = group.iter().map(|a| colorize(a.glyph)).collect();
        let count = group.len();
        rows.push(Row {
            target: String::new(),
            text: format!("\t{TITLE}━━━ {title}{RESET} {statuses} {DIM}({count}){RESET}"),
        });

        for a in group {
            let g = colorize(a.glyph);
            // Plan-mode and pending-ask markers, each in its own column, blank otherwise,
            // so targets stay aligned.
            let mode = if a.plan { format!("{MAGENTA}P{RESET}") } else { " ".to_string() };
            let ask = if a.ask.is_some() { format!("{BLUE}A{RESET}") } else { " ".to_string() };
            // Window tags (Prefix+t) sit between the target and the summary so
            // the row still reads target-first when a window is untagged.
            let tags = if a.tags.is_empty() {
                String::new()
            } else {
                format!(" {ORANGE}[{}]{RESET}", a.tags.replace(' ', ","))
            };
            let tags = format!("{}{tags}{}", stage(&a.stage), labels(&a.labels));
            let display = if a.summary.is_empty() {
                format!(" {g} {mode}{ask} {}{tags}", a.short_target)
            } else {
                format!(" {g} {mode}{ask} {}{tags} {DIM}{}{RESET}", a.short_target, a.summary)
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
                "{}\t{}\t{}\t{}\t{}\t{}",
                a.target,
                jsonl,
                a.project,
                a.summary,
                a.repo_full,
                a.ask.as_deref().unwrap_or("")
            ));
        }
    }

    (rows, map)
}

/// Render the preview pane for one agent row.
pub fn preview(
    target: &str,
    jsonl: Option<&std::path::Path>,
    project: &str,
    summary: &str,
    repo_full: &str,
    ask: &str,
) {
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

    // What it is asking comes first.
    // `agent-ask card` owns the ask format, so the panel prints it rather than parse it.
    if !ask.is_empty() {
        println!("{BLUE}{BOLD}── question ──{RESET}");
        print!("{}", crate::asks::card(ask));
    }

    // The session's last word, whole: the pane tail usually has it scrolled away under tool
    // output. Then its last tool call, then a short pane tail for what only the pane shows
    // (a permission dialog, a live prompt).
    if let Some(path) = jsonl.filter(|p| p.exists()) {
        let (message, tool) = crate::jsonl::preview_info(path);
        if !message.is_empty() {
            println!("{CYAN}{BOLD}── last message ──{RESET}");
            println!("{message}");
        }
        if !tool.is_empty() {
            println!("{DIM}last tool: {tool}{RESET}");
        }
    }

    println!("{CYAN}{BOLD}── pane ──{RESET}");
    let pane = crate::tmux::capture_pane(target, true, -PANE_TAIL);
    let lines: Vec<&str> = pane.lines().collect();
    for line in &lines[lines.len().saturating_sub(PANE_TAIL as usize)..] {
        println!("{line}");
    }
}

/// Pane lines at the foot of the preview.
const PANE_TAIL: i32 = 12;

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

    fn agent(target: &str, glyph: char, plan: bool, ask: bool) -> Agent {
        Agent {
            glyph,
            target: target.to_string(),
            short_target: target.to_string(),
            project: "proj".to_string(),
            repo_full: String::new(),
            summary: String::new(),
            jsonl: None,
            tags: String::new(),
            pane: String::new(),
            session_id: String::new(),
            cwd: String::new(),
            status: String::new(),
            plan,
            ask: ask.then(|| "a1".to_string()),
            ..Agent::default()
        }
    }

    fn row<'a>(rows: &'a [Row], target: &str) -> &'a str {
        &rows.iter().find(|r| r.target == target).unwrap().text
    }

    #[test]
    fn marks_pending_ask_beside_plan_mode() {
        let agents = [
            agent("s:1", '✓', false, true),
            agent("s:2", '✓', false, false),
            agent("s:3", '~', true, true),
        ];
        let (rows, _) = build(&agents);
        let a = format!("{BLUE}A{RESET}");
        let p = format!("{MAGENTA}P{RESET}");
        assert!(row(&rows, "s:1").contains(&format!("  {a} s:1")));
        // Negative control: no pending ask (answered, cancelled or none) -> no mark,
        // and the blank column keeps the target aligned.
        assert!(!row(&rows, "s:2").contains(&a));
        assert!(row(&rows, "s:2").contains("    s:2"));
        assert!(row(&rows, "s:3").contains(&format!("{p}{a} s:3")));
    }

    #[test]
    fn shows_stage_and_labels_after_the_target() {
        let mut stalled = agent("s:1", '✓', false, false);
        stalled.stage = "STALLED".into();
        stalled.labels = "manual".into();
        stalled.tags = "pinned".into();
        let mut working = agent("s:2", '~', false, false);
        working.stage = "WORKING".into();
        let (rows, _) = build(&[stalled, working]);
        let want = format!("s:1 {RED}STALLED{RESET} {ORANGE}[pinned]{RESET} {CYAN}[manual]{RESET}");
        assert!(row(&rows, "s:1").contains(&want), "{}", row(&rows, "s:1"));
        // Negative control: WORKING and no labels add nothing after the target.
        assert!(row(&rows, "s:2").ends_with(" s:2"), "{}", row(&rows, "s:2"));
    }

    fn headers(rows: &[Row]) -> Vec<String> {
        rows.iter()
            .filter(|r| r.target.is_empty())
            .map(|r| r.text.split("━━━ ").nth(1).unwrap().split(RESET).next().unwrap().to_string())
            .collect()
    }

    #[test]
    fn pins_the_shepherd_above_every_project() {
        let mut a = agent("s:1", '✓', false, false);
        a.project = "alpha".into();
        let mut shep = agent("s:2", '~', false, false);
        shep.project = "zulu".into();
        shep.tags = "pinned shepherd".into();
        let (rows, _) = build(&[a.clone(), shep]);
        assert_eq!(headers(&rows), ["shepherd", "alpha"]);
        assert_eq!(rows[1].target, "s:2");
        // Negative control: without the lease tag it sorts into its project like any other row.
        let mut plain = agent("s:2", '~', false, false);
        plain.project = "zulu".into();
        plain.tags = "pinned".into();
        let (rows, _) = build(&[a, plain]);
        assert_eq!(headers(&rows), ["alpha", "zulu"]);
    }

    #[test]
    fn pending_ask_needs_attention() {
        assert!(agent("s:1", '✓', false, true).needs_attention());
        assert!(agent("s:1", '!', false, false).needs_attention());
        assert!(!agent("s:1", '~', true, false).needs_attention());
    }

    #[test]
    fn strips_title_glyph() {
        assert_eq!(strip_title_glyph("✳ Hello there"), "Hello there");
        assert_eq!(strip_title_glyph("Plain title"), "Plain title");
        assert_eq!(strip_title_glyph("✳nospaces"), "✳nospaces");
    }
}
