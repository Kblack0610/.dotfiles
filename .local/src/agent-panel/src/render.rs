//! Project grouping, ANSI fzf rows, and preview formatting.

use crate::chooser::Agent;
use crate::jsonl::Mode;
use crate::sort::{Key, Sort};

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
const WHITE: &str = "\x1b[1;37m"; // manual mode: cyan is the labels' colour, and one is `[manual]`

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
    path.trim_end_matches('/')
        .rsplit('/')
        .next()
        .unwrap_or(path)
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
    let agent = s
        .rsplit_once("-agent")
        .map(|(_, rest)| rest.trim_start_matches('-'));
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
    let Some(start) = started_at else {
        return "   ".to_string();
    };
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
        let mut projects: Vec<&str> = agents
            .iter()
            .filter(|a| !is_shepherd(a))
            .map(|a| a.project.as_str())
            .collect();
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
                agents
                    .iter()
                    .filter(|a| !is_shepherd(a) && a.project == project)
                    .collect(),
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
                Mode::Manual => format!("{WHITE}M{RESET}"),
                Mode::Other => " ".to_string(),
            };
            let ask = if a.ask.is_some() {
                format!("{BLUE}A{RESET}")
            } else {
                " ".to_string()
            };
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
                format!(
                    " {g} {mode}{ask} {open} {target}{tags} {DIM}{}{RESET}",
                    a.summary
                )
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
        let started = self.started_at.map(|t| t.to_string()).unwrap_or_default();
        [
            target,
            &self.project,
            &self.summary,
            &self.repo_full,
            &self.ask,
            &self.status,
            &started,
            self.mode.mark(),
            &self.account,
        ]
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
            project: get(1),
            summary: get(2),
            repo_full: get(3),
            ask: get(4),
            status: get(5),
            started_at: get(6).parse().ok(),
            mode: Mode::from_mark(&get(7)),
            account: get(8),
        };
        (get(0), facts)
    }
}

/// Print the preview for one agent row: one status line, then the agent's own pane in colour
/// with its scrollback, as it looks in its window, cleaned to fit the preview (`clean_pane`).
/// fzf opens it at the bottom and keeps the status line pinned (`fzf::args`). The questions panel
/// (Prefix+y) is the summary of an ask; this is the session itself. `now` is epoch seconds.
pub fn preview(target: &str, f: &Facts, now: u64) {
    let width = crate::md::width();
    let pane = crate::tmux::capture_pane(target, true, -SCROLLBACK);
    // A session waiting at a prompt (the row's `!`, which reads the hook state) or showing a
    // dialog `dialog::parse` knows needs the human, and its pane's foot is that prompt: keep it.
    let dialog = f.status == "waiting" || crate::dialog::parse(&strip_ansi(&pane)).is_some();
    println!("{}", status_line(target, f, now, width, dialog));
    print!("{}", clean_pane(&pane, width, dialog));
}

/// The pinned first line: who and where the agent is, then its pane title, cut to one row.
fn status_line(target: &str, f: &Facts, now: u64, width: usize, dialog: bool) -> String {
    let place = if !f.repo_full.is_empty() {
        &f.repo_full
    } else {
        &f.project
    };
    let mut status = vec![target.to_string()];
    status.extend(
        [place.clone(), f.status.clone()]
            .into_iter()
            .filter(|x| !x.is_empty()),
    );
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
    let mut parts = Vec::new();
    if !f.ask.is_empty() || dialog {
        // The one coloured word: it asks for the human (dashboards.md rule 5); Prefix+y has the card.
        parts.push((YELLOW, "needs you".to_string()));
    }
    parts.push((BOLD, status.join("  ")));
    if !f.summary.is_empty() {
        parts.push((DIM, f.summary.clone()));
    }
    let mut room = width;
    let mut out = Vec::new();
    for (colour, text) in parts {
        if room == 0 {
            break;
        }
        let cut: String = text.chars().take(room).collect();
        room = room.saturating_sub(cut.chars().count() + 2);
        out.push(format!("{colour}{cut}{RESET}"));
    }
    out.join("  ")
}

/// A coloured `capture-pane -e` capture, cleaned to read inside a preview `width` wide: Claude
/// Code's input box and the status bar under it cut (never while `dialog` is open, whose options
/// also start with the prompt glyph), trailing spaces trimmed, runs of blank lines one, and
/// full-width rules shortened to the width so they do not wrap onto a second row.
pub fn clean_pane(capture: &str, width: usize, dialog: bool) -> String {
    let mut lines: Vec<&str> = capture.lines().collect();
    let plain: Vec<String> = lines.iter().map(|l| strip_ansi(l)).collect();
    let rule = |l: &str| {
        let t = l.trim();
        t.chars().count() >= 10 && t.chars().all(|c| c == '\u{2500}')
    };
    // The input box is the last two rules, a few lines apart with the prompt between them, and
    // only the status bar under it; cut at the upper one. Two rules of the agent's own output have
    // no prompt between them, and an old box in the scrollback has the newer output under it.
    let foot = plain
        .iter()
        .rposition(|l| !l.trim().is_empty())
        .map_or(0, |i| i + 1);
    let rules: Vec<usize> = plain
        .iter()
        .enumerate()
        .filter(|(_, l)| rule(l))
        .map(|(i, _)| i)
        .collect();
    if let [.., upper, lower] = rules[..] {
        let prompt = plain[upper + 1..lower]
            .iter()
            .any(|l| l.trim_start().starts_with('\u{276f}'));
        let at_foot = foot - lower <= STATUS_BAR_LINES + 1;
        if !dialog && at_foot && lower - upper <= INPUT_BOX_LINES && prompt {
            lines.truncate(upper);
        }
    }
    let mut out = String::new();
    let mut blank = true; // no blank lines at the top
    for (line, plain) in lines.iter().zip(&plain) {
        if plain.trim().is_empty() {
            if !blank {
                out.push('\n');
            }
            blank = true;
            continue;
        }
        blank = false;
        if rule(plain) {
            let n = plain.trim().chars().count().min(width);
            out.push_str(&format!("{DIM}{}{RESET}\n", "\u{2500}".repeat(n)));
        } else {
            out.push_str(trim_end_ansi(line));
            out.push_str(if line.contains('\x1b') { RESET } else { "" });
            out.push('\n');
        }
    }
    while out.ends_with("\n\n") {
        out.pop();
    }
    out
}

/// `line` without its escape sequences (CSI `ESC [ ... final`, and the two-byte ones).
fn strip_ansi(line: &str) -> String {
    let mut out = String::with_capacity(line.len());
    let mut chars = line.chars().peekable();
    while let Some(c) = chars.next() {
        if c != '\x1b' {
            out.push(c);
            continue;
        }
        if chars.next() == Some('[') {
            while let Some(&n) = chars.peek() {
                chars.next();
                if ('@'..='~').contains(&n) {
                    break;
                }
            }
        }
    }
    out
}

/// `line` cut after its last visible non-space character, so trailing spaces and the escapes
/// among them go; the caller closes it with a reset.
fn trim_end_ansi(line: &str) -> &str {
    let bytes = line.as_bytes();
    let (mut i, mut end) = (0, 0);
    while i < bytes.len() {
        if bytes[i] == 0x1b {
            i += 1;
            if bytes.get(i) == Some(&b'[') {
                i += 1;
                while i < bytes.len() && !(0x40..=0x7e).contains(&bytes[i]) {
                    i += 1;
                }
                i += 1;
            } else {
                // A two-character escape: skip the whole character after ESC, never into it.
                i += line
                    .get(i..)
                    .and_then(|r| r.chars().next())
                    .map_or(1, char::len_utf8);
            }
            continue;
        }
        let c = line[i..].chars().next().unwrap_or(' ');
        i += c.len_utf8();
        if !c.is_whitespace() {
            end = i;
        }
    }
    &line[..end]
}

/// How far back the preview reads the pane: enough to scroll a long turn, bounded for speed.
const SCROLLBACK: i32 = 2000;
/// The most lines Claude Code draws under its input box (status bar, mode line, hints).
const STATUS_BAR_LINES: usize = 4;
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
        assert!(row(&rows, "s:4").contains(&format!("{WHITE}M{RESET}  {o} s:4")));
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
            .map(|r| {
                r.text
                    .split("━━━ ")
                    .nth(1)
                    .unwrap()
                    .split(RESET)
                    .next()
                    .unwrap()
                    .to_string()
            })
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
        for (secs, want) in [
            (0, " 0m"),
            (59 * 60, "59m"),
            (3600, " 1h"),
            (23 * 3600 + 3599, "23h"),
            (86_400, " 1d"),
            (200 * 86_400, "99d"),
        ] {
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
        let open = Sort {
            key: Key::Open,
            reverse: false,
        };
        let (rows, map) = build(&[new.clone(), old.clone()], open, 7300);
        assert_eq!(headers(&rows), ["all, longest open first"]);
        assert_eq!(
            (rows[1].target.as_str(), rows[2].target.as_str()),
            ("s:1", "s:2")
        );
        assert!(
            row(&rows, "s:1").contains(&format!("{DIM} 2h{RESET} zulu s:1")),
            "{}",
            row(&rows, "s:1")
        );
        assert!(
            row(&rows, "s:2").contains(&format!("{DIM}38m{RESET} alpha s:2")),
            "{}",
            row(&rows, "s:2")
        );
        assert!(
            map[0].starts_with("s:1\t"),
            "the preview map follows the row order"
        );
        // Negative control: the project sort keeps one header per project and bare targets.
        let (rows, _) = build(&[new.clone(), old.clone()], Sort::default(), 7300);
        assert_eq!(headers(&rows), ["alpha", "zulu"]);
        assert!(row(&rows, "s:1").contains(&format!("{DIM} 2h{RESET} s:1")));
        let (rows, _) = build(
            &[new, old],
            Sort {
                key: Key::Project,
                reverse: true,
            },
            7300,
        );
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
        assert_eq!(
            back,
            Facts {
                summary: "a title".into(),
                ..f
            }
        );
        let manual = Facts {
            mode: Mode::Manual,
            ..back.clone()
        };
        assert_eq!(Facts::parse(&manual.line("hub/s:1")).1.mode, Mode::Manual);
        // Negative control: a short line from an older panel reads its missing fields as empty.
        let (_, old) = Facts::parse("hub/s:1\tproj");
        assert_eq!(
            old,
            Facts {
                project: "proj".into(),
                ..Facts::default()
            }
        );
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
    fn the_pane_drops_the_input_box_and_status_bar_and_keeps_the_rest() {
        assert_eq!(
            clean_pane(PANE, 40, false),
            "earlier line\n  \u{23bf}  picked 27\n\u{b7} Flowing\u{2026} (11m 16s)\n"
        );
        // Negative control: a pane with no input box (a shell) keeps its foot.
        assert_eq!(clean_pane("$ ls\nfile\n\n", 40, false), "$ ls\nfile\n");
        // Negative control: two rules of the agent's own output, no prompt between, cut nothing.
        let rule = "\u{2500}".repeat(10);
        assert_eq!(
            plain(&clean_pane(&format!("a\n{rule}\nb\n{rule}\nc"), 40, false))
                .lines()
                .count(),
            5
        );
        // An open dialog is kept whole: its options start with the prompt glyph too.
        assert!(clean_pane(PANE, 40, true).contains('\u{276f}'));
        // An old input box in the scrollback, with newer output under it, cuts nothing.
        let old = format!("{PANE}later output\nmore\nand more\nstill more\nthe newest line\n");
        assert!(
            clean_pane(&old, 40, false).ends_with("the newest line\n"),
            "{:?}",
            clean_pane(&old, 40, false)
        );
    }

    #[test]
    fn a_coloured_pane_is_cut_by_what_it_shows_and_fits_the_width() {
        let r = "\u{2500}".repeat(120);
        let coloured = format!(
            "\n\n\x1b[1mtitle\x1b[0m   \x1b[0m  \n\n\n\nbody\n\x1b[2m{r}\x1b[0m\n\x1b[2m{r}\x1b[0m\n\x1b[2m{r}\x1b[0m\n\x1b[1m\u{276f}\x1b[0m \n\x1b[2m{r}\x1b[0m\nstatus bar\n"
        );
        let got = clean_pane(&coloured, 40, false);
        // Leading blanks gone, the blank run one line, trailing spaces gone, the colour closed.
        assert!(got.starts_with("\x1b[1mtitle\x1b[0m\n\nbody\n"), "{got:?}");
        // The agent's own rule is shortened to the width; the input box and status bar are gone.
        let p = plain(&got);
        assert_eq!(
            p.lines().last(),
            Some("\u{2500}".repeat(40).as_str()),
            "{p}"
        );
        assert!(!p.contains('\u{276f}') && !p.contains("status bar"), "{p}");
    }

    #[test]
    fn trims_trailing_spaces_among_escapes() {
        assert_eq!(trim_end_ansi("ab \x1b[0m  "), "ab");
        assert_eq!(
            trim_end_ansi("\x1b[31m\u{276f} x\x1b[0m"),
            "\x1b[31m\u{276f} x"
        );
        assert_eq!(strip_ansi("\x1b[38;5;214mok\x1b[0m"), "ok");
        // A two-character escape before a multibyte character skips the whole character.
        assert_eq!(trim_end_ansi("a\x1b\u{2500} b"), "a\x1b\u{2500} b");
        assert_eq!(trim_end_ansi("a\x1b\u{2500} "), "a");
    }

    fn facts() -> Facts {
        Facts {
            project: "dotfiles".into(),
            status: "waiting".into(),
            started_at: Some(0),
            summary: "doing it".into(),
            ..Facts::default()
        }
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
    fn the_status_line_is_one_row_with_needs_you_first() {
        let asking = Facts {
            ask: "a1".into(),
            ..facts()
        };
        let line = status_line("hub/s:1", &asking, 3600, 200, false);
        assert_eq!(
            plain(&line),
            "needs you  hub/s:1  dotfiles  waiting  open 1h  doing it"
        );
        assert!(line.starts_with(&format!("{YELLOW}needs you{RESET}")));
        assert!(
            plain(&status_line("hub/s:1", &asking, 3600, 20, false))
                .chars()
                .count()
                <= 20
        );
        // Negative control: nothing asked, no amber and no needs word.
        let line = status_line("hub/s:1", &facts(), 3600, 200, false);
        assert!(
            !line.contains(YELLOW) && !line.contains("needs you"),
            "{line:?}"
        );
        // An open dialog needs the human with no ask posted.
        assert!(plain(&status_line("hub/s:1", &facts(), 3600, 200, true)).starts_with("needs you"));
    }

    #[test]
    fn strips_title_glyph() {
        assert_eq!(strip_title_glyph("✳ Hello there"), "Hello there");
        assert_eq!(strip_title_glyph("Plain title"), "Plain title");
        assert_eq!(strip_title_glyph("✳nospaces"), "✳nospaces");
    }
}
