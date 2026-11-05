//! The rows under the Projects tab (projtab.rs): one project's open rows, or every project's
//! (the All entry), as `notes board --json` prints them, read through `hub_core::tasks`, the
//! same feed and writes as agent-web's Projects tab. Rows are grouped by profile and project
//! (each profile's Focus rows are their own group, read-only) and their text wraps, so a row
//! shows whole; j/k pick a row, `/` searches, `l` steps the lane filter, and a, s, d/D, x/X, m,
//! e, t/T, + and - add, start, finish, drop (with why, or the id it duplicates), move (to a
//! project or a version), edit, tag and untag, and step a row a release sooner or later through
//! `notes ptask --exact`; `o` opens the sheet at the row. This file writes nothing: it hands the app a `tasks::Write`, and a row edited since
//! the read fails in `notes` and the page re-reads.

use std::collections::BTreeMap;

use hub_core::tasks::{self, Feed, Row, Verb, Write};
use ratatui::crossterm::event::{KeyCode, KeyEvent};
use ratatui::text::{Line, Span};

use crate::fit::{cell, clip_line, wrap, Cell, Table};
use crate::fmt::Palette;

/// What a key on the rows asks the app to do.
#[derive(Debug, PartialEq)]
pub enum Ask {
    /// Not one of the tab's own keys.
    Pass,
    /// Handled here: a move, a prompt keystroke, a refusal.
    Done,
    /// Run this write; it has passed `tasks::argv` already.
    Write(String, Write),
    /// Open this sheet at this line in an editor.
    Open(String, usize),
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Kind {
    Search,
    Add,
    Proof,
    Unverified,
    Why,
    Dup,
    Move,
    Edit,
    Tag,
    Untag,
}

/// A line being typed at the status line, and the row it is about (none for a search).
#[derive(Debug)]
pub struct Prompt {
    pub kind: Kind,
    pub text: String,
    pub row: Option<Row>,
}

/// `l` steps through these; None shows every lane.
const LANES: [Option<&str>; 5] = [
    None,
    Some("human"),
    Some("agent"),
    Some("playtest"),
    Some("focus"),
];

#[derive(Debug, Default)]
pub struct TaskView {
    /// Index into `shown`.
    pub sel: usize,
    pub search: String,
    pub lane: Option<&'static str>,
    /// One project's rows, as (profile, project); None shows every project's.
    pub project: Option<(String, String)>,
    pub prompt: Option<Prompt>,
    /// The write now running, as "done in bnb/demo".
    pub running: Option<String>,
    /// The last write's answer: notes' output, or why it failed.
    pub said: Option<Result<String, String>>,
}

/// A row's group, as agent-web titles it.
fn group(r: &Row) -> String {
    match &r.project {
        Some(p) => format!("{}/{p}", r.profile),
        None => format!("{} Focus", r.profile),
    }
}

/// The rows the filters leave, grouped and in group order, each group in the feed's order.
pub fn groups<'a>(f: &'a Feed, v: &TaskView) -> Vec<(String, Vec<&'a Row>)> {
    let q = v.search.to_lowercase();
    let mut g: BTreeMap<String, Vec<&Row>> = BTreeMap::new();
    for r in &f.rows {
        if v.lane.is_some_and(|l| r.lane != l) {
            continue;
        }
        if let Some((profile, project)) = &v.project {
            if r.profile != *profile || r.project.as_ref() != Some(project) {
                continue;
            }
        }
        let hay = format!("{} {} {}", group(r), r.text, r.tags.join(" ")).to_lowercase();
        if !q.is_empty() && !hay.contains(&q) {
            continue;
        }
        g.entry(group(r)).or_default().push(r);
    }
    g.into_iter().collect()
}

/// The rows j/k move over, in the page's order.
pub fn shown<'a>(f: &'a Feed, v: &TaskView) -> Vec<&'a Row> {
    groups(f, v).into_iter().flat_map(|(_, r)| r).collect()
}

/// A write on a row, or None for a focus row (`notes focus` owns the daily note).
fn on(r: &Row, verb: Verb) -> Option<Write> {
    Some(Write {
        profile: r.profile.clone(),
        project: r.project.clone()?,
        lane: r.lane.clone(),
        verb,
    })
}

impl TaskView {
    pub fn selected<'a>(&self, f: &'a Feed) -> Option<&'a Row> {
        shown(f, self).get(self.sel).copied()
    }

    /// A new read keeps the selection on the same line when it is still open.
    pub fn reselect(&mut self, was: Option<Row>, f: &Feed) {
        let rows = shown(f, self);
        self.sel = was
            .and_then(|w| {
                rows.iter()
                    .position(|r| r.sheet == w.sheet && r.raw == w.raw)
            })
            .unwrap_or(self.sel)
            .min(rows.len().saturating_sub(1));
    }

    /// The selected row when it can be written, else why not (said on the status line).
    fn target(&mut self, f: &Feed, playtest_ok: bool) -> Option<Row> {
        let why = match self.selected(f) {
            _ if self.running.is_some() => "a write is still running",
            None => "no row selected",
            Some(r) if r.project.is_none() => {
                "a Focus row is read-only here: notes focus owns the daily note"
            }
            Some(r) if r.lane == "playtest" && !playtest_ok => {
                "a playtest check has no state, version or edit: d done, x drop"
            }
            Some(r) => {
                self.said = None;
                return Some(r.clone());
            }
        };
        self.said = Some(Err(why.into()));
        None
    }

    /// Check a write the way `notes` will be asked it, so a refusal shows before anything runs.
    fn ask(&mut self, label: String, w: Option<Write>) -> Ask {
        let Some(w) = w else { return Ask::Done };
        match tasks::argv(&w) {
            Ok(_) => Ask::Write(label, w),
            Err(e) => {
                self.said = Some(Err(e));
                Ask::Done
            }
        }
    }

    fn submit(&mut self, p: Prompt) -> Ask {
        let Some(r) = p.row else {
            self.search = p.text.trim().to_string();
            self.sel = 0;
            return Ask::Done;
        };
        let at = group(&r);
        let (label, verb) = match p.kind {
            Kind::Search => unreachable!("a search has no row"),
            Kind::Add => (
                format!("add to {at} ({})", r.lane),
                Verb::Add {
                    text: p.text,
                    priority: "high".into(),
                    to: None,
                    game: r.game.clone().filter(|_| r.lane == "playtest"),
                },
            ),
            Kind::Move => {
                // Words: a vX.Y.Z is the version, anything else the project; `notes` checks both.
                let (mut project, mut to) = (None, None);
                for word in p.text.split_whitespace() {
                    let slot = if word.starts_with('v')
                        && word[1..].starts_with(|c: char| c.is_ascii_digit())
                    {
                        &mut to
                    } else {
                        &mut project
                    };
                    *slot = Some(word.to_string());
                }
                (
                    format!("move in {at}"),
                    Verb::Move {
                        raw: r.raw.clone(),
                        project,
                        to,
                    },
                )
            }
            Kind::Edit => (
                format!("edit in {at}"),
                Verb::Edit {
                    raw: r.raw.clone(),
                    text: p.text,
                },
            ),
            Kind::Tag | Kind::Untag => {
                let tags: Vec<String> = p.text.split_whitespace().map(str::to_string).collect();
                let (add, remove) = if p.kind == Kind::Tag {
                    (tags, vec![])
                } else {
                    (vec![], tags)
                };
                (
                    format!("tag in {at}"),
                    Verb::Tag {
                        raw: r.raw.clone(),
                        add,
                        remove,
                    },
                )
            }
            Kind::Proof | Kind::Unverified => {
                let (proof, unverified) = if p.kind == Kind::Proof {
                    (Some(p.text), None)
                } else {
                    (None, Some(p.text))
                };
                (
                    format!("done in {at}"),
                    Verb::Done {
                        raw: r.raw.clone(),
                        proof,
                        unverified,
                    },
                )
            }
            Kind::Why | Kind::Dup => {
                let (why, dup) = if p.kind == Kind::Why {
                    (Some(p.text), None)
                } else {
                    (None, Some(p.text))
                };
                (
                    format!("drop in {at}"),
                    Verb::Drop {
                        raw: r.raw.clone(),
                        why,
                        dup,
                    },
                )
            }
        };
        self.ask(label, on(&r, verb))
    }

    /// `page` is the body's height, for PgUp/PgDn.
    pub fn key(&mut self, k: KeyEvent, f: Option<&Feed>, page: usize) -> Ask {
        if let Some(p) = self.prompt.as_mut() {
            match k.code {
                KeyCode::Enter => {
                    let p = self.prompt.take().unwrap();
                    return self.submit(p);
                }
                KeyCode::Esc => {
                    if p.kind == Kind::Search {
                        self.search.clear();
                        self.sel = 0;
                    }
                    self.prompt = None;
                }
                KeyCode::Backspace => {
                    p.text.pop();
                }
                KeyCode::Char(c) => p.text.push(c),
                _ => {}
            }
            return Ask::Done;
        }
        let Some(f) = f else { return Ask::Pass };
        let last = shown(f, self).len().saturating_sub(1);
        let n = page.max(1);
        let prompt = |kind, row| {
            Some(Prompt {
                kind,
                text: String::new(),
                row,
            })
        };
        match k.code {
            KeyCode::Char('j') | KeyCode::Down => self.sel = (self.sel + 1).min(last),
            KeyCode::Char('k') | KeyCode::Up => self.sel = self.sel.saturating_sub(1),
            KeyCode::PageDown | KeyCode::Char(' ') => self.sel = (self.sel + n).min(last),
            KeyCode::PageUp => self.sel = self.sel.saturating_sub(n),
            KeyCode::Char('g') | KeyCode::Home => self.sel = 0,
            KeyCode::Char('G') | KeyCode::End => self.sel = last,
            KeyCode::Char('/') => {
                self.prompt = Some(Prompt {
                    kind: Kind::Search,
                    text: self.search.clone(),
                    row: None,
                })
            }
            KeyCode::Char('l') => {
                let at = LANES.iter().position(|l| *l == self.lane).unwrap_or(0);
                self.lane = LANES[(at + 1) % LANES.len()];
                self.sel = 0;
            }
            KeyCode::Esc => {
                self.search.clear();
                self.lane = None;
                self.said = None;
                self.sel = 0;
            }
            KeyCode::Char('a') => {
                if let Some(r) = self.target(f, true) {
                    self.prompt = prompt(Kind::Add, Some(r));
                }
            }
            KeyCode::Char('s') => {
                if let Some(r) = self.target(f, false) {
                    let label = format!("start in {}", group(&r));
                    return self.ask(label, on(&r, Verb::Start { raw: r.raw.clone() }));
                }
            }
            KeyCode::Char(c @ ('d' | 'D')) => {
                if let Some(r) = self.target(f, true) {
                    let kind = if c == 'd' {
                        Kind::Proof
                    } else {
                        Kind::Unverified
                    };
                    self.prompt = prompt(kind, Some(r));
                }
            }
            KeyCode::Char(c @ ('x' | 'X')) => {
                if let Some(r) = self.target(f, true) {
                    let kind = if c == 'x' { Kind::Why } else { Kind::Dup };
                    self.prompt = prompt(kind, Some(r));
                }
            }
            KeyCode::Char('m') => {
                if let Some(r) = self.target(f, false) {
                    self.prompt = prompt(Kind::Move, Some(r));
                }
            }
            KeyCode::Char(c @ ('t' | 'T')) => {
                if let Some(r) = self.target(f, false) {
                    let kind = if c == 't' { Kind::Tag } else { Kind::Untag };
                    self.prompt = prompt(kind, Some(r));
                }
            }
            KeyCode::Char('e') => {
                if let Some(r) = self.target(f, false) {
                    self.prompt = Some(Prompt {
                        kind: Kind::Edit,
                        text: r.text.clone(),
                        row: Some(r),
                    });
                }
            }
            KeyCode::Char(c @ ('+' | '-')) => {
                if let Some(r) = self.target(f, false) {
                    let (word, verb) = if c == '+' {
                        ("sooner", Verb::Promote { raw: r.raw.clone() })
                    } else {
                        ("later", Verb::Demote { raw: r.raw.clone() })
                    };
                    return self.ask(format!("a release {word} in {}", group(&r)), on(&r, verb));
                }
            }
            KeyCode::Char('o') => {
                return match self.selected(f) {
                    Some(r) => Ask::Open(r.sheet.clone(), r.line),
                    None => Ask::Done,
                };
            }
            _ => return Ask::Pass,
        }
        Ask::Done
    }
}

fn heading(title: &str, rest: String, p: Palette) -> Line<'static> {
    Line::from(vec![
        Span::styled(title.to_string(), p.head()),
        Span::styled(rest, p.dim()),
    ])
}

fn row(r: &Row, p: Palette) -> Vec<Cell> {
    let prio = match r.priority.as_str() {
        "urgent" => p.bad(),
        "high" => p.warn(),
        _ => p.dim(),
    };
    let version = if r.lane == "playtest" {
        r.game.clone()
    } else {
        r.version.clone()
    };
    let state = if r.state == "doing" {
        cell("doing", p.good())
    } else {
        cell(r.state.clone(), Default::default())
    };
    let mut text = r.text.clone();
    if r.requested {
        text += "  #requested";
    }
    vec![
        cell(r.priority.clone(), prio),
        r.lane.clone().into(),
        version.unwrap_or_default().into(),
        state,
        text.into(),
    ]
}

/// The page, and the line the selected row is on (the app keeps it in view).
pub fn page(f: &Feed, v: &TaskView, p: Palette, w: usize) -> (Vec<Line<'static>>, Option<usize>) {
    let gs = groups(f, v);
    let n: usize = gs.iter().map(|(_, r)| r.len()).sum();
    let mut filter = String::new();
    if let Some(l) = v.lane {
        filter += &format!("  lane {l}");
    }
    if !v.search.is_empty() {
        filter += &format!("  search \"{}\"", v.search);
    }
    let mut out = vec![
        clip_line(
            heading(
                if v.project.is_some() {
                    "OPEN ROWS"
                } else {
                    "ALL PROJECTS"
                },
                format!("  {n} open rows in {} groups{filter}", gs.len()),
                p,
            ),
            w,
        ),
        status_line(v, p, w),
    ];
    if gs.is_empty() {
        out.push(Line::raw(""));
        out.push(Line::styled("No open rows match.", p.dim()));
        return (out, None);
    }
    let sel = v.selected(f).map(|r| (r.sheet.clone(), r.raw.clone()));
    let mut at = None;
    for (title, rows) in gs {
        let urgent = rows.iter().filter(|r| r.priority == "urgent").count();
        out.push(Line::raw(""));
        let mut rest = format!("  {}", rows.len());
        if urgent > 0 {
            rest += &format!(", {urgent} urgent");
        }
        if rows[0].project.is_none() {
            rest += "  (read-only)";
        }
        out.push(clip_line(heading(&title.to_uppercase(), rest, p), w));
        let (mut t, starts) = Table {
            header: vec!["PRIO", "LANE", "VERSION", "STATE", "TEXT"],
            rows: rows.iter().map(|r| row(r, p)).collect(),
            keep: vec![0, 3, 1, 2],
            flex: Some(4),
            flexmin: 20,
            flexkeep: true,
            cap: vec![(2, 16)],
            ..Default::default()
        }
        .fit_wrapped(w, p.head());
        if let Some(i) = rows
            .iter()
            .position(|r| sel.as_ref() == Some(&(r.sheet.clone(), r.raw.clone())))
        {
            let end = starts.get(i + 1).copied().unwrap_or(t.len());
            for l in &mut t[starts[i]..end] {
                l.style = p.sel();
            }
            at = Some(out.len() + starts[i]);
        }
        out.append(&mut t);
    }
    (out, at)
}

/// The selected row in full, for the pane under the rows: what the table clips or leaves out
/// (its id, tags, worker, dates, marker and the sheet line a write lands on).
pub fn preview(r: &Row, p: Palette, w: usize) -> Vec<Line<'static>> {
    let mut head = vec![
        r.id.clone().unwrap_or_else(|| "no id".into()),
        group(r),
        r.lane.clone(),
    ];
    let version = if r.lane == "playtest" {
        &r.game
    } else {
        &r.version
    };
    head.extend(version.iter().cloned());
    head.push(r.state.clone());
    head.push(r.priority.clone());
    head.extend(r.size.iter().map(|s| format!("size/{s}")));
    let mut out: Vec<Line<'static>> = wrap(&head, "  ", w)
        .into_iter()
        .map(|l| clip_line(Line::styled(l, p.head()), w))
        .collect();
    let words: Vec<&str> = r.text.split_whitespace().collect();
    out.extend(
        wrap(&words, " ", w)
            .into_iter()
            .map(|l| clip_line(Line::raw(l), w)),
    );
    // A label, then its items wrapped under one another.
    let field = |k: &str, items: &[String], sep: &str| -> Vec<Line<'static>> {
        wrap(items, sep, w.saturating_sub(7).max(1))
            .into_iter()
            .enumerate()
            .map(|(i, v)| {
                let k = if i == 0 { k } else { "" };
                clip_line(
                    Line::from(vec![Span::styled(format!("{k:<7}"), p.dim()), Span::raw(v)]),
                    w,
                )
            })
            .collect()
    };
    if !r.tags.is_empty() || r.requested {
        let mut t: Vec<String> = r.tags.iter().map(|t| format!("#{t}")).collect();
        if r.requested && !r.tags.iter().any(|t| t == "requested") {
            t.push("#requested".into());
        }
        out.extend(field("tags", &t, " "));
    }
    let mut when = vec![];
    if let Some(wk) = &r.worker {
        when.push(format!("worker {wk}"));
    }
    if let Some(d) = &r.since {
        when.push(format!("since {d}"));
    }
    if let Some(d) = &r.filed {
        when.push(format!("filed {d}"));
    }
    if let Some(m) = &r.marker {
        when.push(m.clone());
    }
    if !when.is_empty() {
        out.extend(field("about", &when, "  "));
    }
    let home = std::env::var("HOME").unwrap_or_default();
    let sheet = match r.sheet.strip_prefix(&home) {
        Some(rest) if !home.is_empty() => format!("~{rest}"),
        _ => r.sheet.clone(),
    };
    out.extend(field("sheet", &[format!("{sheet}:{}", r.line)], ""));
    out
}

fn status_line(v: &TaskView, p: Palette, w: usize) -> Line<'static> {
    let l = if let Some(pr) = &v.prompt {
        let what = match (pr.kind, &pr.row) {
            (Kind::Search, _) => "Search: ".to_string(),
            (Kind::Add, Some(r)) => format!(
                "Add to {} ({}), #urgent or #low to set it: ",
                group(r),
                r.lane
            ),
            (Kind::Proof, _) => "Done, the proof (pr:N or a URL): ".into(),
            (Kind::Unverified, _) => "Done unverified, because: ".into(),
            (Kind::Why, _) => "Drop it, because: ".into(),
            (Kind::Dup, _) => "Drop it as a duplicate of id: ".into(),
            (Kind::Move, _) => "Move to a project, a version vX.Y.Z, or both: ".into(),
            (Kind::Edit, _) => "New text (tags stay): ".into(),
            (Kind::Tag, _) => "Add tags (size/s, requested; a new size replaces the old): ".into(),
            (Kind::Untag, _) => "Remove tags: ".into(),
            (_, None) => String::new(),
        };
        Line::styled(format!("{what}{}_", pr.text), p.warn())
    } else if let Some(r) = &v.running {
        Line::styled(format!("Running {r}..."), p.dim())
    } else {
        match &v.said {
            Some(Ok(s)) => Line::styled(s.clone(), p.good()),
            Some(Err(e)) => Line::styled(e.clone(), p.bad()),
            None => Line::raw(""),
        }
    };
    clip_line(l, w)
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    use crate::fit::plain;

    pub fn fixture() -> Feed {
        let row = |profile: &str, project: Option<&str>, lane: &str, prio: &str, text: &str| Row {
            profile: profile.into(),
            project: project.map(String::from),
            lane: lane.into(),
            version: Some("v0.1.0".into()).filter(|_| lane != "focus" && lane != "playtest"),
            game: Some("demo".into()).filter(|_| lane == "playtest"),
            state: "open".into(),
            priority: prio.into(),
            text: text.into(),
            sheet: format!("/v/{profile}/{}/{lane}.md", project.unwrap_or("focus")),
            raw: format!("- [ ] {text}"),
            ..Default::default()
        };
        Feed {
            today: "2026-11-04".into(),
            projects: vec![
                tasks::Project {
                    profile: "bnb".into(),
                    project: "demo".into(),
                    ..Default::default()
                },
                tasks::Project {
                    profile: "personal".into(),
                    project: "garden".into(),
                    ..Default::default()
                },
            ],
            rows: vec![
                row("personal", Some("garden"), "human", "low", "water the beds"),
                row("bnb", Some("demo"), "human", "urgent", "fix the menu"),
                row("bnb", Some("demo"), "agent", "high", "sweep the logs"),
                row("bnb", Some("demo"), "playtest", "high", "jump feels late"),
                row("bnb", None, "focus", "urgent", "ship the board"),
            ],
        }
    }

    fn text(f: &Feed, v: &TaskView, w: usize) -> String {
        page(f, v, Palette { no_color: true }, w)
            .0
            .iter()
            .map(plain)
            .collect::<Vec<_>>()
            .join("\n")
    }

    fn key(c: char) -> KeyEvent {
        KeyEvent::from(KeyCode::Char(c))
    }

    fn typed(v: &mut TaskView, f: &Feed, s: &str) {
        for c in s.chars() {
            assert_eq!(v.key(key(c), Some(f), 10), Ask::Done);
        }
    }

    fn enter(v: &mut TaskView, f: &Feed) -> Ask {
        v.key(KeyEvent::from(KeyCode::Enter), Some(f), 10)
    }

    #[test]
    fn rows_group_by_profile_and_project_with_focus_read_only() {
        let f = fixture();
        let v = TaskView::default();
        let s = text(&f, &v, 120);
        let at = |h: &str| s.find(h).unwrap_or_else(|| panic!("{h} missing from\n{s}"));
        assert!(s.contains("ALL PROJECTS  5 open rows in 3 groups"), "{s}");
        assert!(at("BNB FOCUS  1, 1 urgent  (read-only)") < at("BNB/DEMO  3, 1 urgent"));
        assert!(at("BNB/DEMO") < at("PERSONAL/GARDEN  1"));
        assert!(s.contains("v0.1.0") && s.contains("demo"), "{s}");
        // j/k follow the page's order, not the feed's.
        let order: Vec<&str> = shown(&f, &v).iter().map(|r| r.text.as_str()).collect();
        assert_eq!(
            order,
            [
                "ship the board",
                "fix the menu",
                "sweep the logs",
                "jump feels late",
                "water the beds"
            ]
        );
        let (_, line) = page(&f, &v, Palette { no_color: true }, 120);
        // heading, status, blank, group heading, table header, then the first row.
        assert_eq!(line, Some(5));
    }

    #[test]
    fn search_and_the_lane_filter_narrow_the_rows() {
        let f = fixture();
        let mut v = TaskView::default();
        v.key(key('/'), Some(&f), 10);
        typed(&mut v, &f, "GARDEN");
        assert!(text(&f, &v, 120).contains("Search: GARDEN_"));
        assert_eq!(enter(&mut v, &f), Ask::Done);
        assert_eq!(shown(&f, &v).len(), 1);
        v.key(KeyEvent::from(KeyCode::Esc), Some(&f), 10);
        assert_eq!(shown(&f, &v).len(), 5, "Esc clears the filters");
        v.key(key('l'), Some(&f), 10);
        v.key(key('l'), Some(&f), 10);
        assert_eq!(v.lane, Some("agent"));
        assert_eq!(shown(&f, &v)[0].text, "sweep the logs");
        assert!(text(&f, &v, 120).contains("lane agent"));
        for _ in 0..3 {
            v.key(key('l'), Some(&f), 10);
        }
        assert_eq!(v.lane, None, "l comes back round to every lane");
        v.search = "nothing like it".into();
        assert!(text(&f, &v, 120).contains("No open rows match."));
    }

    #[test]
    fn writes_carry_the_rows_raw_line_and_focus_is_read_only() {
        let f = fixture();
        let mut v = TaskView::default();
        assert_eq!(v.key(key('s'), Some(&f), 10), Ask::Done);
        assert!(
            matches!(&v.said, Some(Err(e)) if e.contains("read-only")),
            "{:?}",
            v.said
        );
        assert_eq!(v.key(key('x'), Some(&f), 10), Ask::Done);
        assert!(v.prompt.is_none(), "no drop on a focus row");

        v.key(key('j'), Some(&f), 10);
        let Ask::Write(label, w) = v.key(key('s'), Some(&f), 10) else {
            panic!("start runs")
        };
        assert_eq!(label, "start in bnb/demo");
        assert_eq!(
            tasks::argv(&w).unwrap(),
            [
                "fleet-dispatch",
                "promote",
                "--project",
                "demo",
                "--profile",
                "bnb",
                "--raw",
                "- [ ] fix the menu"
            ]
        );

        // A drop says why, or names the row it duplicates; Esc drops nothing.
        v.key(key('x'), Some(&f), 10);
        assert!(text(&f, &v, 160).contains("Drop it, because: "));
        assert_eq!(
            enter(&mut v, &f),
            Ask::Done,
            "a drop with no reason is refused"
        );
        assert!(
            matches!(&v.said, Some(Err(e)) if e.contains("why")),
            "{:?}",
            v.said
        );
        v.key(key('x'), Some(&f), 10);
        assert_eq!(v.key(KeyEvent::from(KeyCode::Esc), Some(&f), 10), Ask::Done);
        assert!(v.prompt.is_none());
        v.key(key('X'), Some(&f), 10);
        typed(&mut v, &f, "ar-142");
        let Ask::Write(label, w) = enter(&mut v, &f) else {
            panic!("a drop runs")
        };
        assert_eq!(label, "drop in bnb/demo");
        assert_eq!(
            tasks::argv(&w).unwrap()[5..],
            [
                "--exact",
                "drop",
                "--dup",
                "ar-142",
                "--",
                "- [ ] fix the menu"
            ]
        );

        v.key(key('d'), Some(&f), 10);
        assert_eq!(
            enter(&mut v, &f),
            Ask::Done,
            "a done with no proof is refused"
        );
        assert!(
            matches!(&v.said, Some(Err(e)) if e.contains("proof")),
            "{:?}",
            v.said
        );
        v.key(key('D'), Some(&f), 10);
        typed(&mut v, &f, "checked by hand");
        let Ask::Write(_, w) = enter(&mut v, &f) else {
            panic!("done runs")
        };
        assert_eq!(
            w.verb,
            Verb::Done {
                raw: "- [ ] fix the menu".into(),
                proof: None,
                unverified: Some("checked by hand".into())
            }
        );
    }

    #[test]
    fn move_edit_and_the_version_keys_carry_the_rows_raw_line() {
        let f = fixture();
        let mut v = TaskView::default();
        v.key(key('j'), Some(&f), 10);
        assert_eq!(v.selected(&f).unwrap().text, "fix the menu");

        v.key(key('m'), Some(&f), 10);
        typed(&mut v, &f, "garden v0.2.0");
        let Ask::Write(label, w) = enter(&mut v, &f) else {
            panic!("move runs")
        };
        assert_eq!(label, "move in bnb/demo");
        assert_eq!(
            tasks::argv(&w).unwrap()[5..],
            [
                "--exact",
                "move",
                "--project",
                "garden",
                "--to",
                "v0.2.0",
                "--",
                "- [ ] fix the menu"
            ]
        );
        v.key(key('m'), Some(&f), 10);
        assert_eq!(enter(&mut v, &f), Ask::Done, "a move to nowhere is refused");
        assert!(matches!(&v.said, Some(Err(e)) if e.contains("move to")));

        v.key(key('e'), Some(&f), 10);
        assert_eq!(
            v.prompt.as_ref().unwrap().text,
            "fix the menu",
            "edit starts from the text"
        );
        typed(&mut v, &f, " bar");
        let Ask::Write(_, w) = enter(&mut v, &f) else {
            panic!("edit runs")
        };
        assert_eq!(
            w.verb,
            Verb::Edit {
                raw: "- [ ] fix the menu".into(),
                text: "fix the menu bar".into()
            }
        );

        let Ask::Write(label, w) = v.key(key('+'), Some(&f), 10) else {
            panic!("+ runs")
        };
        assert_eq!(label, "a release sooner in bnb/demo");
        assert_eq!(
            w.verb,
            Verb::Promote {
                raw: "- [ ] fix the menu".into()
            }
        );
        let Ask::Write(_, w) = v.key(key('-'), Some(&f), 10) else {
            panic!("- runs")
        };
        assert_eq!(
            w.verb,
            Verb::Demote {
                raw: "- [ ] fix the menu".into()
            }
        );

        assert_eq!(
            v.key(key('o'), Some(&f), 10),
            Ask::Open("/v/bnb/demo/human.md".into(), 0)
        );

        // The playtest row and the focus row refuse the version keys before anything runs.
        for _ in 0..2 {
            v.key(key('j'), Some(&f), 10);
        }
        assert_eq!(v.selected(&f).unwrap().lane, "playtest");
        assert_eq!(v.key(key('+'), Some(&f), 10), Ask::Done);
        assert!(matches!(&v.said, Some(Err(e)) if e.contains("playtest")));
        v.key(key('g'), Some(&f), 10);
        assert_eq!(v.key(key('m'), Some(&f), 10), Ask::Done);
        assert!(v.prompt.is_none(), "no move on a focus row");
    }

    #[test]
    fn add_goes_to_the_selected_rows_project_and_lane() {
        let f = fixture();
        let mut v = TaskView::default();
        for _ in 0..3 {
            v.key(key('j'), Some(&f), 10);
        }
        assert_eq!(v.selected(&f).unwrap().lane, "playtest");
        assert_eq!(v.key(key('s'), Some(&f), 10), Ask::Done);
        assert!(matches!(&v.said, Some(Err(e)) if e.contains("playtest")));
        v.key(key('a'), Some(&f), 10);
        // Every letter types while the prompt is open, q and the tab digits too.
        typed(&mut v, &f, "q1 menu sticks #urgent");
        assert!(text(&f, &v, 160).contains("Add to bnb/demo (playtest)"));
        let Ask::Write(label, w) = enter(&mut v, &f) else {
            panic!("add runs")
        };
        assert_eq!(label, "add to bnb/demo (playtest)");
        assert_eq!(
            tasks::argv(&w).unwrap()[5..],
            [
                "--playtest",
                "add",
                "--game",
                "demo",
                "--",
                "q1 menu sticks #urgent"
            ]
        );

        v.running = Some("add".into());
        v.key(key('a'), Some(&f), 10);
        assert!(v.prompt.is_none(), "no second write while one runs");
        assert_eq!(v.key(key('z'), Some(&f), 10), Ask::Pass);
    }

    #[test]
    fn a_new_read_keeps_the_selection_on_its_line() {
        let f = fixture();
        let mut v = TaskView {
            sel: 2,
            ..Default::default()
        };
        let was = v.selected(&f).cloned();
        let mut fewer = fixture();
        fewer.rows.remove(1);
        v.reselect(was, &fewer);
        assert_eq!(v.selected(&fewer).unwrap().text, "sweep the logs");
        v.reselect(None, &Feed::default());
        assert_eq!(v.sel, 0);
    }

    #[test]
    fn one_project_wraps_its_rows_whole_and_t_tags_the_selected_one() {
        let mut f = fixture();
        f.rows[1].text = "fix the menu so the back button returns to the map".into();
        f.rows[1].size = Some("m".into());
        let mut v = TaskView {
            project: Some(("bnb".into(), "demo".into())),
            ..Default::default()
        };
        assert_eq!(shown(&f, &v).len(), 3, "only bnb/demo's rows");
        let s = text(&f, &v, 50);
        assert!(s.contains("OPEN ROWS  3 open rows in 1 groups"), "{s}");
        assert!(!s.contains('~'), "nothing is clipped:\n{s}");
        assert!(
            s.contains("returns to the map"),
            "the text wraps whole:\n{s}"
        );
        // The selected row is lit on every line it wraps onto.
        let (lines, at) = page(&f, &v, Palette::default(), 50);
        let at = at.unwrap();
        assert_eq!(lines[at].style, lines[at + 1].style);
        assert!(
            plain(&lines[at + 1]).starts_with(' '),
            "{:?}",
            plain(&lines[at + 1])
        );

        v.key(key('t'), Some(&f), 10);
        assert!(text(&f, &v, 160).contains("Add tags"));
        typed(&mut v, &f, "size/s #requested");
        let Ask::Write(label, w) = enter(&mut v, &f) else {
            panic!("tag runs")
        };
        assert_eq!(label, "tag in bnb/demo");
        assert_eq!(
            tasks::argv(&w).unwrap()[5..],
            [
                "--exact",
                "tag",
                "--add=size/s",
                "--add=requested",
                "--",
                "- [ ] fix the menu"
            ]
        );
        v.key(key('T'), Some(&f), 10);
        typed(&mut v, &f, "v0.2.0");
        assert_eq!(enter(&mut v, &f), Ask::Done, "a release is move's");
        assert!(matches!(&v.said, Some(Err(e)) if e.contains("release")));
    }

    #[test]
    fn the_preview_shows_the_selected_row_whole_with_what_the_table_leaves_out() {
        let mut f = fixture();
        let r = &mut f.rows[1];
        r.id = Some("bnb-7".into());
        r.size = Some("m".into());
        r.tags = vec!["p1".into(), "size/m".into()];
        r.since = Some("2026-10-27".into());
        r.marker = Some("carried:3 id:bnb-7".into());
        r.line = 36;
        r.text = "fix the menu so the back button returns to the map".into();
        let l: Vec<String> = preview(&f.rows[1], Palette { no_color: true }, 30)
            .iter()
            .map(plain)
            .collect();
        assert_eq!(
            l,
            [
                "bnb-7  bnb/demo  human  v0.1.0",
                "open  urgent  size/m",
                "fix the menu so the back",
                "button returns to the map",
                "tags   #p1 #size/m",
                "about  since 2026-10-27",
                "       carried:3 id:bnb-7",
                "sheet  /v/bnb/demo/human.md:36",
            ],
            "nothing is clipped: every part wraps between words"
        );

        // A row with nothing extra: no tags or about line, and it says it has no id.
        let l: Vec<String> = preview(&f.rows[0], Palette { no_color: true }, 80)
            .iter()
            .map(plain)
            .collect();
        assert_eq!(
            l,
            [
                "no id  personal/garden  human  v0.1.0  open  low",
                "water the beds",
                "sheet  /v/personal/garden/human.md:0"
            ]
        );
    }
}
