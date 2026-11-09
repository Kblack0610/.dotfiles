//! Project grouping, ANSI fzf rows, and preview formatting.

use crate::chooser::Agent;
use crate::sort::{Key, Sort};
use crate::jsonl::Mode;

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
/// `@fleet_fmt`). WORKING and NEEDS print nothing: NEEDS is already the `!` glyph. CHAT, the
/// human's own conversation, prints uncoloured: it is not attention.
fn stage(stage: &str) -> String {
    let colour = match stage {
        "STALLED" => RED,
        "CHAT" => return format!(" {stage}"),
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

/// How long a session has been open, 3 columns wide so the targets after it stay aligned:
/// ` 5m`, `45m`, ` 3h`, ` 2d`. Blank for a row with no start time (a parked one).
pub fn age(now: u64, started_at: Option<u64>) -> String {
    let Some(start) = started_at else { return "   ".to_string() };
    let secs = now.saturating_sub(start);
    match secs {
        s if s < 3600 => format!("{:>2}m", s / 60),
        s if s < 86_400 => format!("{:>2}h", s / 3600),
        s => format!("{:>2}d", (s / 86_400).min(99)),
    }
}

/// Build the fzf rows and the preview map-file body, ordered by `sort`. The project sort
/// groups rows under a header per project (the shepherd first, then projects by name, which
/// reverse flips); any other sort is one flat list under one header that names it, each
/// target led by its project since no group header carries it. `now` (epoch seconds) dates
/// the open column. Returns `(rows, map_lines)`.
pub fn build(agents: &[Agent], sort: Sort, now: u64) -> (Vec<Row>, Vec<String>) {
    let mut groups: Vec<(String, Vec<&Agent>)> = Vec::new();
    if sort.key == Key::Project {
        let mut projects: Vec<&str> =
            agents.iter().filter(|a| !is_shepherd(a)).map(|a| a.project.as_str()).collect();
        projects.sort();
        projects.dedup();
        if sort.reverse {
            projects.reverse();
        }
        let shepherd: Vec<&Agent> = agents.iter().filter(|a| is_shepherd(a)).collect();
        if !shepherd.is_empty() {
            groups.push((SHEPHERD.to_string(), shepherd));
        }
        for project in projects {
            groups.push((
                project.to_string(),
                agents.iter().filter(|a| !is_shepherd(a) && a.project == project).collect(),
            ));
        }
    } else {
        let mut all: Vec<&Agent> = agents.iter().collect();
        sort.order(&mut all);
        groups.push((format!("all, {}", sort.label()), all));
    }
    let flat = sort.key != Key::Project;

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
            // Mode (plan, manual) and pending-ask markers, each in its own column, blank
            // otherwise, so targets stay aligned.
            let mode = match a.mode {
                Mode::Plan => format!("{MAGENTA}P{RESET}"),
                Mode::Manual => format!("{CYAN}M{RESET}"),
                Mode::Other => " ".to_string(),
            };
            let ask = if a.ask.is_some() { format!("{BLUE}A{RESET}") } else { " ".to_string() };
            let open = format!("{DIM}{}{RESET}", age(now, a.started_at));
            let target = if flat {
                format!("{} {}", a.project, a.short_target)
            } else {
                a.short_target.clone()
            };
            // Window tags (Prefix+t) sit between the target and the summary so
            // the row still reads target-first when a window is untagged.
            let tags = if a.tags.is_empty() {
                String::new()
            } else {
                format!(" {ORANGE}[{}]{RESET}", a.tags.replace(' ', ","))
            };
            let tags = format!("{}{tags}{}", stage(&a.stage), labels(&a.labels));
            let display = if a.summary.is_empty() {
                format!(" {g} {mode}{ask} {open} {target}{tags}")
            } else {
                format!(" {g} {mode}{ask} {open} {target}{tags} {DIM}{}{RESET}", a.summary)
            };
            rows.push(Row {
                target: a.target.clone(),
                text: format!("{}\t{display}", a.target),
            });

            map.push(Facts::of(a).line(&a.target));
        }
    }

    (rows, map)
}

/// What the preview needs of a row, written to the map file when the panel opens so the preview
/// callback does not walk every pane again: one tab-separated line per row, the target first.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Facts {
    pub jsonl: Option<std::path::PathBuf>,
    pub project: String,
    pub summary: String,
    pub repo_full: String,
    pub ask: String,
    pub status: String,
    pub started_at: Option<u64>,
    pub mode: Mode,
    pub account: String,
}

impl Facts {
    pub fn of(a: &Agent) -> Facts {
        Facts {
            jsonl: a.jsonl.clone(),
            project: a.project.clone(),
            summary: a.summary.clone(),
            repo_full: a.repo_full.clone(),
            ask: a.ask.clone().unwrap_or_default(),
            status: a.status.clone(),
            started_at: a.started_at,
            mode: a.mode,
            account: a.account.clone(),
        }
    }

    /// The map file line: `target`, then the fields in declaration order. A tab or newline in
    /// a field (a pane title) becomes a space, so the line keeps its columns.
    pub fn line(&self, target: &str) -> String {
        let jsonl = self.jsonl.as_ref().map(|p| p.to_string_lossy().into_owned()).unwrap_or_default();
        let started = self.started_at.map(|t| t.to_string()).unwrap_or_default();
        [target, &jsonl, &self.project, &self.summary, &self.repo_full, &self.ask, &self.status, &started, self.mode.mark(), &self.account]
            .iter()
            .map(|f| f.replace(['\t', '\n'], " "))
            .collect::<Vec<_>>()
            .join("\t")
    }

    /// A map file line back: `(target, facts)`. Missing trailing fields read as empty.
    pub fn parse(line: &str) -> (String, Facts) {
        let f: Vec<&str> = line.split('\t').collect();
        let get = |i: usize| f.get(i).copied().unwrap_or("").to_string();
        let facts = Facts {
            jsonl: f.get(1).filter(|s| !s.is_empty()).map(std::path::PathBuf::from),
            project: get(2),
            summary: get(3),
            repo_full: get(4),
            ask: get(5),
            status: get(6),
            started_at: get(7).parse().ok(),
            mode: Mode::from_mark(&get(8)),
            account: get(9),
        };
        (get(0), facts)
    }
}

/// Print the preview for one agent row, summary first (dashboards.md rules 3, 4): who and where
/// it is in one line, then what it needs from you (the same ask card or dialog card the
/// questions panel shows), its last tool, its last message in plain text, and last a few lines
/// of its pane, which a dialog card replaces since it is that dialog. `now` is epoch seconds.
pub fn preview(target: &str, f: &Facts, now: u64) {
    let width = crate::md::width();
    let pane = crate::tmux::capture_pane(target, false, 0);
    // One read of the transcript serves the last message, the last tool and an open plan.
    let info = match f.jsonl.as_deref().filter(|p| p.exists()) {
        Some(path) => crate::jsonl::preview_info(path),
        None => Default::default(),
    };
    let dialog = crate::dialog::parse(&pane).map(|d| {
        let plan = crate::dialog::Plan::of(&d, info.plan.clone());
        crate::dialog::card(&d, &format!("{target}  {}", f.project), plan, true, width)
    });
    let ask = if f.ask.is_empty() { String::new() } else { crate::asks::card(&f.ask) };
    let read = Read { ask: &ask, dialog: dialog.as_deref(), tool: &info.tool, message: &info.message, pane: &pane };
    print!("{}", page(target, f, now, width, &read));
}

/// What `preview` read for one agent: its ask card, its dialog's card, its transcript's last tool
/// and message, and its pane capture.
struct Read<'a> {
    ask: &'a str,
    dialog: Option<&'a str>,
    tool: &'a str,
    message: &'a str,
    pane: &'a str,
}

/// The preview's text, from what `preview` read: pure, so the order and the sections are tested.
fn page(target: &str, f: &Facts, now: u64, width: usize, r: &Read) -> String {
    use std::fmt::Write;
    let Read { ask, dialog, tool, message, pane } = *r;
    let mut s = String::new();
    let place = if !f.repo_full.is_empty() { &f.repo_full } else { &f.project };
    let mut status = vec![target.to_string()];
    status.extend([place.clone(), f.status.clone()].into_iter().filter(|x| !x.is_empty()));
    match f.mode {
        Mode::Plan => status.push("plan mode".into()),
        Mode::Manual => status.push("manual mode".into()),
        Mode::Other => {}
    }
    if f.started_at.is_some() {
        status.push(format!("open {}", age(now, f.started_at).trim_start()));
    }
    if !f.account.is_empty() {
        status.push(f.account.clone());
    }
    let _ = writeln!(s, "{BOLD}{}{RESET}", status.join("  "));
    if !f.summary.is_empty() {
        let _ = writeln!(s, "{DIM}{}{RESET}", f.summary);
    }
    if !ask.is_empty() || dialog.is_some() {
        // The one coloured title: it asks for the human (dashboards.md rule 5).
        section(&mut s, "needs you", YELLOW, width);
        s.push_str(ask);
        if let Some(card) = dialog {
            if !ask.is_empty() {
                s.push('\n');
            }
            s.push_str(card);
        }
    }
    if !tool.is_empty() {
        let line: String = tool.lines().next().unwrap_or("").chars().take(width.saturating_sub(11)).collect();
        let _ = write!(s, "\n{BOLD}last tool{RESET}  {line}\n");
    }
    if !message.is_empty() {
        section(&mut s, "last message", BOLD, width);
        let _ = writeln!(s, "{}", crate::md::plain(message, width));
    }
    if dialog.is_none() {
        let tail = pane_tail(pane, PANE_TAIL);
        if !tail.is_empty() {
            section(&mut s, "pane", BOLD, width);
            let _ = writeln!(s, "{}", tail.join("\n"));
        }
    }
    s
}

/// A section title after a blank line, in `colour`, with a dim rule to the width.
fn section(s: &mut String, title: &str, colour: &str, width: usize) {
    let rule = "-".repeat(width.saturating_sub(title.chars().count() + 1).min(80));
    s.push_str(&format!("\n{colour}{title}{RESET} {DIM}{rule}{RESET}\n"));
}

/// The last `n` lines of a plain pane capture above Claude Code's own chrome: its input box (a
/// rule, the prompt line, a rule) and the status bar under it. Blank lines at either end go.
pub fn pane_tail(capture: &str, n: usize) -> Vec<String> {
    let mut lines: Vec<&str> = capture.lines().map(str::trim_end).collect();
    let rule = |l: &str| {
        let t = l.trim();
        t.chars().count() >= 10 && t.chars().all(|c| c == '\u{2500}')
    };
    // The input box is the last two rules, a few lines apart with the prompt between them; cut
    // at the upper one. Two rules of the agent's own output have no prompt between them.
    let rules: Vec<usize> = lines.iter().enumerate().filter(|(_, l)| rule(l)).map(|(i, _)| i).collect();
    if let [.., upper, lower] = rules[..] {
        let prompt = lines[upper + 1..lower].iter().any(|l| l.trim_start().starts_with('\u{276f}'));
        if lower - upper <= INPUT_BOX_LINES && prompt {
            lines.truncate(upper);
        }
    }
    while lines.last().is_some_and(|l| l.trim().is_empty()) {
        lines.pop();
    }
    let start = lines.len().saturating_sub(n);
    lines[start..].iter().skip_while(|l| l.trim().is_empty()).map(|l| l.to_string()).collect()
}

/// Pane lines at the foot of the preview.
const PANE_TAIL: usize = 8;
/// The most lines Claude Code's input box spans between its two rules (a long typed prompt).
const INPUT_BOX_LINES: usize = 10;

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

    fn agent(target: &str, glyph: char, mode: Mode, ask: bool) -> Agent {
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
            mode,
            ask: ask.then(|| "a1".to_string()),
            ..Agent::default()
        }
    }

    fn row<'a>(rows: &'a [Row], target: &str) -> &'a str {
        &rows.iter().find(|r| r.target == target).unwrap().text
    }

    #[test]
    fn marks_pending_ask_beside_plan_and_manual_mode() {
        let agents = [
            agent("s:1", '✓', Mode::Other, true),
            agent("s:2", '✓', Mode::Other, false),
            agent("s:3", '~', Mode::Plan, true),
            agent("s:4", '✓', Mode::Manual, false),
        ];
        let (rows, _) = build(&agents, Sort::default(), 0);
        let a = format!("{BLUE}A{RESET}");
        let p = format!("{MAGENTA}P{RESET}");
        let o = format!("{DIM}   {RESET}"); // no start time: a blank open column
        assert!(row(&rows, "s:1").contains(&format!("  {a} {o} s:1")));
        // Negative control: no pending ask (answered, cancelled or none) -> no mark,
        // and the blank column keeps the target aligned.
        assert!(!row(&rows, "s:2").contains(&a));
        assert!(row(&rows, "s:2").contains(&format!("    {o} s:2")));
        assert!(row(&rows, "s:3").contains(&format!("{p}{a} {o} s:3")));
        // Manual mode takes the same column as plan mode, in its own letter.
        assert!(row(&rows, "s:4").contains(&format!("{CYAN}M{RESET}  {o} s:4")));
    }

    #[test]
    fn shows_stage_and_labels_after_the_target() {
        let mut stalled = agent("s:1", '✓', Mode::Other, false);
        stalled.stage = "STALLED".into();
        stalled.labels = "manual".into();
        stalled.tags = "pinned".into();
        let mut working = agent("s:2", '~', Mode::Other, false);
        working.stage = "WORKING".into();
        let (rows, _) = build(&[stalled, working], Sort::default(), 0);
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
        let mut a = agent("s:1", '✓', Mode::Other, false);
        a.project = "alpha".into();
        let mut shep = agent("s:2", '~', Mode::Other, false);
        shep.project = "zulu".into();
        shep.tags = "pinned shepherd".into();
        let (rows, _) = build(&[a.clone(), shep], Sort::default(), 0);
        assert_eq!(headers(&rows), ["shepherd", "alpha"]);
        assert_eq!(rows[1].target, "s:2");
        // Negative control: without the lease tag it sorts into its project like any other row.
        let mut plain = agent("s:2", '~', Mode::Other, false);
        plain.project = "zulu".into();
        plain.tags = "pinned".into();
        let (rows, _) = build(&[a, plain], Sort::default(), 0);
        assert_eq!(headers(&rows), ["alpha", "zulu"]);
    }

    #[test]
    fn the_open_column_is_three_wide_at_every_unit() {
        let now = 100_000_000;
        for (secs, want) in [(0, " 0m"), (59 * 60, "59m"), (3600, " 1h"), (23 * 3600 + 3599, "23h"), (86_400, " 1d"), (200 * 86_400, "99d")] {
            assert_eq!(age(now, Some(now - secs)), want, "{secs}s");
        }
        assert_eq!(age(now, None), "   ");
        // A start in the future (clock skew) reads as just opened, never a panic.
        assert_eq!(age(now, Some(now + 10)), " 0m");
    }

    #[test]
    fn a_sort_other_than_project_is_one_flat_list_led_by_each_project() {
        use crate::sort::Key;
        let mut old = agent("s:1", '✓', Mode::Other, false);
        old.project = "zulu".into();
        old.started_at = Some(100);
        let mut new = agent("s:2", '~', Mode::Other, false);
        new.project = "alpha".into();
        new.started_at = Some(5000);
        let open = Sort { key: Key::Open, reverse: false };
        let (rows, map) = build(&[new.clone(), old.clone()], open, 7300);
        assert_eq!(headers(&rows), ["all, longest open first"]);
        assert_eq!((rows[1].target.as_str(), rows[2].target.as_str()), ("s:1", "s:2"));
        assert!(row(&rows, "s:1").contains(&format!("{DIM} 2h{RESET} zulu s:1")), "{}", row(&rows, "s:1"));
        assert!(row(&rows, "s:2").contains(&format!("{DIM}38m{RESET} alpha s:2")), "{}", row(&rows, "s:2"));
        assert!(map[0].starts_with("s:1\t"), "the preview map follows the row order");
        // Negative control: the project sort keeps one header per project and bare targets.
        let (rows, _) = build(&[new.clone(), old.clone()], Sort::default(), 7300);
        assert_eq!(headers(&rows), ["alpha", "zulu"]);
        assert!(row(&rows, "s:1").contains(&format!("{DIM} 2h{RESET} s:1")));
        let (rows, _) = build(&[new, old], Sort { key: Key::Project, reverse: true }, 7300);
        assert_eq!(headers(&rows), ["zulu", "alpha"]);
    }

    #[test]
    fn pending_ask_needs_attention() {
        assert!(agent("s:1", '✓', Mode::Other, true).needs_attention());
        assert!(agent("s:1", '!', Mode::Other, false).needs_attention());
        assert!(!agent("s:1", '~', Mode::Plan, false).needs_attention());
    }

    #[test]
    fn the_map_line_carries_every_preview_fact_and_reads_back() {
        let f = Facts {
            jsonl: Some("/t/s.jsonl".into()),
            project: "dotfiles".into(),
            summary: "a\ttitle".into(),
            repo_full: "dotfiles-agent-5".into(),
            ask: "a1".into(),
            status: "waiting".into(),
            started_at: Some(42),
            mode: Mode::Plan,
            account: "bnb".into(),
        };
        let (target, back) = Facts::parse(&f.line("hub/s:1"));
        assert_eq!(target, "hub/s:1");
        assert_eq!(back, Facts { summary: "a title".into(), ..f });
        // Negative control: a short line from an older panel reads its missing fields as empty.
        let (_, old) = Facts::parse("hub/s:1\t\tproj");
        assert_eq!(old, Facts { project: "proj".into(), ..Facts::default() });
    }

    /// The input box and status bar as Claude Code draws them under its output.
    const PANE: &str = "\
earlier line
  \u{23bf}  picked 27
\u{b7} Flowing\u{2026} (11m 16s)

\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}
\u{276f}\u{a0}
\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}
  \u{23f5}\u{23f5} bypass permissions on (shift+tab to cycle)

";

    #[test]
    fn the_pane_tail_stops_above_the_input_box_and_status_bar() {
        assert_eq!(pane_tail(PANE, 8), ["earlier line", "  \u{23bf}  picked 27", "\u{b7} Flowing\u{2026} (11m 16s)"]);
        assert_eq!(pane_tail(PANE, 1), ["\u{b7} Flowing\u{2026} (11m 16s)"]);
        // Negative control: a pane with no input box (a shell) keeps its foot.
        assert_eq!(pane_tail("$ ls\nfile\n\n", 8), ["$ ls", "file"]);
        // Negative control: two rules of the agent's own output, no prompt between, cut nothing.
        let rule = "\u{2500}".repeat(10);
        assert_eq!(pane_tail(&format!("a\n{rule}\nb\n{rule}\nc"), 8).len(), 5);
    }

    fn facts() -> Facts {
        Facts { project: "dotfiles".into(), status: "waiting".into(), started_at: Some(0), summary: "doing it".into(), ..Facts::default() }
    }

    fn plain(s: &str) -> String {
        let mut out = String::new();
        let mut esc = false;
        for c in s.chars() {
            match (esc, c) {
                (_, '\x1b') => esc = true,
                (true, 'm') => esc = false,
                (true, _) => {}
                (false, c) => out.push(c),
            }
        }
        out
    }

    #[test]
    fn the_preview_reads_summary_first_then_needs_tool_message_and_pane() {
        let p = plain(&page("hub/s:1", &facts(), 3600, 40, &Read { ask: "ASK CARD\n", dialog: None, tool: "Bash: make", message: "## Done\n**all** green", pane: PANE }));
        let at = |needle: &str| p.find(needle).unwrap_or_else(|| panic!("{needle} missing:\n{p}"));
        assert!(p.starts_with("hub/s:1  dotfiles  waiting  open 1h\ndoing it\n"), "{p}");
        assert!(at("needs you") < at("ASK CARD") && at("ASK CARD") < at("last tool  Bash: make"));
        assert!(at("last tool") < at("last message") && at("last message") < at("Done\nall green"));
        assert!(at("last message") < at("pane") && p.trim_end().ends_with("(11m 16s)"), "{p}");
        assert!(!p.contains("bypass permissions"), "the status bar is chrome: {p}");
        // Amber is the needs title's alone; nothing in the preview is cyan or blue.
        let raw = page("hub/s:1", &facts(), 3600, 40, &Read { ask: "x\n", dialog: None, tool: "t", message: "m", pane: PANE });
        assert!(raw.contains(&format!("{YELLOW}needs you{RESET}")));
        assert_eq!(raw.matches(YELLOW).count(), 1, "{raw:?}");
        assert!(!raw.contains(CYAN) && !raw.contains(BLUE), "{raw:?}");
    }

    #[test]
    fn a_dialog_card_replaces_the_pane_tail_and_nothing_waiting_shows_no_needs() {
        let p = plain(&page("hub/s:1", &facts(), 0, 40, &Read { ask: "", dialog: Some("DIALOG CARD\n"), tool: "", message: "", pane: PANE }));
        assert!(p.contains("needs you") && p.contains("DIALOG CARD"), "{p}");
        assert!(!p.contains("Flowing") && !p.contains("\npane "), "the dialog is the pane: {p}");
        // Negative control: nothing asked, no needs section; the pane shows.
        let p = plain(&page("hub/s:1", &facts(), 0, 40, &Read { ask: "", dialog: None, tool: "", message: "", pane: PANE }));
        assert!(!p.contains("needs you") && p.contains("Flowing"), "{p}");
    }

    #[test]
    fn strips_title_glyph() {
        assert_eq!(strip_title_glyph("✳ Hello there"), "Hello there");
        assert_eq!(strip_title_glyph("Plain title"), "Plain title");
        assert_eq!(strip_title_glyph("✳nospaces"), "✳nospaces");
    }
}
