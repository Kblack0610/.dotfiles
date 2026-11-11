//! The Projects tab: one table row per lab project with its open version's progress, built by
//! `hub_core::projects` (the same rows and words as agent-web's Projects tab), in flight first,
//! on the shared `DataTable`. j/k pick a project, Enter opens its card over its rows (tasktab.rs,
//! every row key works there), `a` opens every project's rows; in the rows Esc clears the view
//! first and then comes back here, as Backspace does at once. `P` steps the selected project's
//! priority (normal, focus, high, low; from `only` it clears it); app.rs runs the write. This file reads and writes
//! nothing.

use hub_core::deliverables::{Deliverable, Deliverables};
use hub_core::page::{Page, System};
use hub_core::projects::{self, Card, Projects, Stats};
use hub_core::session_actions::Runner;
use hub_core::tasks::Feed;
use ratatui::crossterm::event::{KeyCode, KeyEvent};
use ratatui::text::{Line, Span};

use crate::datatable::{DataTable, Took};
use crate::fit::{cell, clip_line, wrap, Cell, Table};
use crate::fmt::Palette;
use crate::tasktab::TaskView;

/// One read of the cards' input that is not the board feed: `notes projects --stats --json`.
#[derive(Debug)]
pub struct Loaded {
    pub stats: Result<Vec<Stats>, String>,
}

pub fn load(runner: &dyn Runner) -> Loaded {
    Loaded {
        stats: projects::stats(runner),
    }
}

/// The list's columns, `Card`'s `Row::COLUMNS` in order, so the sort's mark lands on its header.
const HEADER: [&str; 19] = [
    "PROJECT", "PROFILE", "STAGE", "VERSION", "PRIO", "OPEN", "DOING", "HOT", "DONE", "7D", "PCT",
    "PACE/WK", "ETA", "RUN", "WAIT", "QUEUED", "HELD", "TODAY", "OLDEST",
];

#[derive(Debug, Default)]
pub struct ProjView {
    /// The list's search, chip and sort, and its selected row.
    pub table: DataTable,
    /// The rows are open (tasktab), for one project or for every project.
    pub open: bool,
    /// A `hub tab projects <name>` that came before the cards: opened when they arrive.
    pub want: Option<String>,
    /// The opened card's folded sections are open (`F`).
    pub folds: bool,
    /// The system open under Build by system (`z`), and its epic open to its tasks (`Z`).
    pub sys: Option<String>,
    pub epic: Option<String>,
    /// The Deliverables table's search, chip and sort, and its selected row.
    pub dv: DataTable,
    /// The Deliverables table has the keys (`d`), not the project list.
    pub dfocus: bool,
}

impl ProjView {
    /// The cards the view keeps, in its order.
    pub fn shown<'a>(&self, cards: &'a [Card]) -> Vec<&'a Card> {
        self.table.view.apply(cards)
    }

    /// The selected row of `n`: a re-read can leave the selection past what the view now keeps.
    fn at(&self, n: usize) -> usize {
        self.table.sel.min(n.saturating_sub(1))
    }

    /// The selected project, when the view keeps one.
    pub fn selected<'a>(&self, cards: &'a [Card]) -> Option<&'a Card> {
        let shown = self.shown(cards);
        shown.get(self.at(shown.len())).copied()
    }

    /// Open one project's rows, or with None every project's.
    pub fn open(&mut self, tv: &mut TaskView, c: Option<&Card>) {
        tv.project = c.map(|c| (c.profile.clone(), c.name.clone()));
        tv.table.clear();
        tv.said = None;
        self.open = true;
        self.fold_systems(tv);
    }

    /// Back to the list, the selection on the row it was on.
    pub fn close(&mut self, tv: &mut TaskView) {
        self.open = false;
        tv.prompt = None;
        tv.said = None;
        self.fold_systems(tv);
    }

    /// Every system folded, and the rows no longer narrowed to an epic's.
    fn fold_systems(&mut self, tv: &mut TaskView) {
        self.sys = None;
        self.close_epic(tv);
    }

    /// The open epic folded, and the rows back to the whole project's.
    pub fn close_epic(&mut self, tv: &mut TaskView) {
        self.epic = None;
        if tv.only.take().is_some() {
            tv.table.sel = 0;
        }
    }

    /// `z`: open the next system that has epics, after the last one fold them all.
    pub fn step_system(&mut self, tv: &mut TaskView, pg: &Page) {
        let ids: Vec<&str> = pg
            .systems
            .iter()
            .filter(|s| opens(s))
            .map(|s| s.id.as_str())
            .collect();
        self.sys = next_of(&ids, self.sys.as_deref());
        self.close_epic(tv);
    }

    /// `Z`: open the open system's next epic, its tasks listed and the rows below narrowed to its
    /// open ones (every row key works on them); after the last one fold it. With no system open
    /// it opens the first one with an open epic.
    pub fn step_epic(&mut self, tv: &mut TaskView, pg: &Page) {
        if self.sys.is_none() {
            self.sys = pg
                .systems
                .iter()
                .find(|s| !s.epics.is_empty())
                .map(|s| s.id.clone());
        }
        let Some(sys) = pg.systems.iter().find(|s| Some(&s.id) == self.sys.as_ref()) else {
            return;
        };
        let ids: Vec<&str> = sys.epics.iter().map(|e| e.id.as_str()).collect();
        self.epic = next_of(&ids, self.epic.as_deref());
        self.narrow(tv, pg);
        tv.table.sel = 0;
    }

    /// The rows narrowed to the open epic's open tasks as `pg` has them, so a re-read page keeps
    /// them current; an epic the page no longer has folds.
    pub fn narrow(&mut self, tv: &mut TaskView, pg: &Page) {
        let Some(want) = self.epic.clone() else {
            tv.only = None;
            return;
        };
        match pg
            .systems
            .iter()
            .flat_map(|s| &s.epics)
            .find(|e| e.id == want)
        {
            Some(e) => {
                tv.only = Some(
                    e.leaves
                        .iter()
                        .filter(|l| !l.done)
                        .map(|l| l.id.clone())
                        .collect(),
                )
            }
            None => self.close_epic(tv),
        }
    }

    /// `hub tab projects <name>`: the project of that name, whatever the list's view keeps, else
    /// every project's rows searched for it.
    pub fn go(&mut self, tv: &mut TaskView, cards: &[Card], name: &str) {
        let named = |c: &Card| {
            c.name.eq_ignore_ascii_case(name)
                || format!("{}/{}", c.profile, c.name).eq_ignore_ascii_case(name)
        };
        match cards.iter().find(|c| named(c)) {
            Some(c) => {
                if let Some(i) = self.shown(cards).iter().position(|s| named(s)) {
                    self.table.sel = i;
                }
                self.open(tv, Some(c));
            }
            None => {
                self.open(tv, None);
                tv.table.view.q = name.to_string();
            }
        }
    }

    /// The deliverables the view keeps, in its order.
    pub fn dshown<'a>(&self, d: &'a Deliverables) -> Vec<&'a Deliverable> {
        self.dv.view.apply(&d.rows)
    }

    /// The Deliverables table's keys while it has them: the shared table keys and moves, Enter
    /// opens the selected epic's project with its system and epic open, Esc clears the view and
    /// then gives the keys back to the list, as `d` does at once.
    pub fn dkey(
        &mut self,
        tv: &mut TaskView,
        k: KeyEvent,
        cards: &[Card],
        d: &Deliverables,
        page: usize,
    ) -> bool {
        if self.dv.key::<Deliverable>(k.code) != Took::No
            || self.dv.moves(k, self.dshown(d).len(), page)
        {
            return true;
        }
        match k.code {
            KeyCode::Enter => {
                let shown = self.dshown(d);
                let want = shown.get(self.dv.sel.min(shown.len().saturating_sub(1)));
                if let Some(r) = want.filter(|r| cards.iter().any(|c| same(c, r))) {
                    let (key, sys, id) = (r.key(), r.system.clone(), r.id.clone());
                    self.dfocus = false;
                    self.go(tv, cards, &key);
                    self.sys = Some(sys).filter(|s| !s.is_empty());
                    self.epic = Some(id);
                }
            }
            KeyCode::Esc if !self.dv.is_default() => self.dv.clear(),
            KeyCode::Esc | KeyCode::Char('d') => self.dfocus = false,
            _ => return false,
        }
        true
    }

    /// The list's keys; false for one it does not take.
    pub fn key(&mut self, tv: &mut TaskView, k: KeyEvent, cards: &[Card], page: usize) -> bool {
        if self.table.key::<Card>(k.code) != Took::No
            || self.table.moves(k, self.shown(cards).len(), page)
        {
            return true;
        }
        match k.code {
            KeyCode::Enter => {
                if let Some(c) = self.selected(cards) {
                    self.open(tv, Some(c));
                }
            }
            KeyCode::Char('a') => self.open(tv, None),
            KeyCode::Char('d') => self.dfocus = true,
            KeyCode::Esc if !self.table.is_default() => self.table.clear(),
            _ => return false,
        }
        true
    }
}

/// The card a deliverable's project is.
fn same(c: &Card, r: &Deliverable) -> bool {
    c.profile == r.profile && c.name == r.project
}

/// The warning style when `b`, else none.
fn warn_if(b: bool, p: Palette) -> ratatui::style::Style {
    if b {
        p.warn()
    } else {
        ratatui::style::Style::default()
    }
}

/// A system has something to open: open epics, or a count of closed ones.
fn opens(s: &System) -> bool {
    !s.epics.is_empty() || !s.closed.is_empty()
}

/// The id after `at` in `ids`, the first when `at` is None, None after the last: one key steps
/// through them and then folds.
fn next_of(ids: &[&str], at: Option<&str>) -> Option<String> {
    let i = match at {
        None => 0,
        Some(a) => ids.iter().position(|i| *i == a).map_or(0, |i| i + 1),
    };
    ids.get(i).map(|s| s.to_string())
}

const BAR: usize = 20;

/// `[#######.............]`, the closed share of the open version by size.
fn bar(percent: Option<u32>, p: Palette) -> Vec<Span<'static>> {
    let (on, off) = crate::fmt::bar(percent, None, BAR);
    vec![
        Span::raw("["),
        Span::styled(on, p.good()),
        Span::styled(off, p.dim()),
        Span::raw("]"),
    ]
}

/// `text` word-wrapped to `w` under a `lead` label, continuation lines indented to match.
pub(crate) fn wrapped(
    lead: &str,
    text: &str,
    style: ratatui::style::Style,
    p: Palette,
    w: usize,
) -> Vec<Line<'static>> {
    // A line that fits keeps its own spacing: the epic lines' columns are two spaces apart.
    let lines = if w == 0 || lead.len() + text.len() <= w {
        vec![text.to_string()]
    } else {
        let words: Vec<&str> = text.split_whitespace().collect();
        wrap(&words, " ", w.saturating_sub(lead.len()).max(10))
    };
    lines
        .into_iter()
        .enumerate()
        .map(|(i, l)| {
            let head = if i == 0 {
                Span::styled(lead.to_string(), p.dim())
            } else {
                Span::raw(" ".repeat(lead.len()))
            };
            Line::from(vec![head, Span::styled(l, style)])
        })
        .collect()
}

/// The opened card's first line: name, profile, stage, priority.
fn head(c: &Card, p: Palette, w: usize) -> Line<'static> {
    let spans = vec![
        Span::styled(c.name.to_uppercase(), p.head()),
        Span::styled(format!("  {}, {}", c.profile, c.stage), p.dim()),
        Span::styled(
            if c.prio.is_empty() {
                String::new()
            } else {
                format!(", prio {}", c.prio)
            },
            if matches!(c.prio.as_str(), "focus" | "only") {
                p.head()
            } else {
                p.dim()
            },
        ),
    ];
    clip_line(Line::from(spans), w)
}

/// The bar and the open version's numbers, wrapped under the bar when they do not fit beside it.
fn bar_lines(c: &Card, p: Palette, w: usize) -> Vec<Line<'static>> {
    let mut b = vec![Span::raw("  ")];
    b.extend(bar(c.percent, p));
    let numbers = projects::summary(c);
    if w == 0 || BAR + 5 + numbers.len() <= w {
        b.push(Span::raw(format!("  {numbers}")));
        vec![Line::from(b)]
    } else {
        let mut out = vec![Line::from(b)];
        out.extend(wrapped("  ", &numbers, Default::default(), p, w));
        out
    }
}

/// A folded section's head: `TITLE  what it holds`, then the key when it is folded.
fn fold_head(title: &str, says: &str, folds: bool, p: Palette, w: usize) -> Line<'static> {
    let mut spans = vec![
        Span::styled(title.to_string(), p.head()),
        Span::styled(format!("  {says}"), p.dim()),
    ];
    if !folds {
        spans.push(Span::styled("  F opens it", p.dim()));
    }
    clip_line(Line::from(spans), w)
}

/// Build by system, always open: one line per system with its percent, features and criteria,
/// a `+` on one that opens (`z`), its open epics with their percents under the open one, and the
/// open epic's tasks under it (`Z`).
fn system_lines(pg: &Page, pv: &ProjView, p: Palette, w: usize) -> Vec<Line<'static>> {
    let keys = if pg.systems.iter().any(opens) {
        "  z opens a system, Z its epics"
    } else {
        ""
    };
    let mut out = vec![clip_line(
        Line::from(vec![
            Span::styled("BUILD BY SYSTEM", p.head()),
            Span::styled(format!("  {}{keys}", pg.systems_says), p.dim()),
        ]),
        w,
    )];
    for s in &pg.systems {
        let open = pv.sys.as_ref() == Some(&s.id);
        let mark = match (opens(s), open) {
            (false, _) => "    ",
            (true, false) => "  + ",
            (true, true) => "  - ",
        };
        out.extend(wrapped(mark, &s.head, Default::default(), p, w));
        if !open {
            continue;
        }
        for e in &s.epics {
            let open = pv.epic.as_ref() == Some(&e.id);
            let mark = if open { "      - " } else { "      + " };
            out.extend(wrapped(mark, &e.line, warn_if(e.behind, p), p, w));
            if open {
                for l in &e.leaves {
                    let style = if l.done { p.dim() } else { Default::default() };
                    out.extend(wrapped("          ", &l.line, style, p, w));
                }
                if e.leaves.is_empty() {
                    out.extend(wrapped("          ", "no tasks yet", p.dim(), p, w));
                }
            }
        }
        if !s.closed.is_empty() {
            out.extend(wrapped("        ", &s.closed, p.dim(), p, w));
        }
    }
    out
}

/// The opened card, over its rows: the card, its goal and Flow, then Build by system (always
/// open, [`system_lines`]), what needs the human (always open), then Next stage, Shipped,
/// Timeline, In flight and the Agent note as folded heads with their counts, which `F` opens
/// together. `page` is None while it is read.
pub fn open_lines(
    c: &Card,
    page: Option<&Page>,
    pv: &ProjView,
    p: Palette,
    w: usize,
) -> Vec<Line<'static>> {
    let folds = pv.folds;
    let mut out = vec![head(c, p, w)];
    out.extend(bar_lines(c, p, w));
    let (goal, style) = if c.goal.is_empty() {
        ("no goal set", p.dim())
    } else {
        (c.goal.as_str(), Default::default())
    };
    out.extend(wrapped("  goal     ", goal, style, p, w));
    let Some(pg) = page else {
        out.push(Line::styled("  reading the page...", p.dim()));
        return out;
    };
    if let Some(f) = &pg.flow_line {
        out.extend(wrapped("  flow     ", f, Default::default(), p, w));
    }
    if let Some(b) = &pg.releases {
        out.extend(wrapped(
            "  releases ",
            &format!("{} (R opens)", b.says),
            crate::releases::alert(b.level, p),
            p,
            w,
        ));
    }
    for e in &pg.errors {
        out.extend(wrapped("  ", e, p.warn(), p, w));
    }
    out.push(Line::raw(""));
    out.extend(system_lines(pg, pv, p, w));
    out.push(clip_line(
        Line::from(vec![
            Span::styled("NEEDS YOU", p.head()),
            Span::styled(
                if pg.needs.is_empty() {
                    "  nothing".to_string()
                } else {
                    format!("  {}", pg.needs.len())
                },
                p.dim(),
            ),
        ]),
        w,
    ));
    for n in &pg.needs {
        out.extend(wrapped("  ", n, p.warn(), p, w));
    }
    out.push(fold_head("NEXT STAGE", &pg.next_says, folds, p, w));
    if folds {
        for r in &pg.next_rows {
            out.extend(wrapped(
                &format!("  {:<6} ", r.result),
                &format!("{} ({})", r.requirement, r.stage),
                warn_if(r.result == "FAIL", p),
                p,
                w,
            ));
        }
    }
    out.push(fold_head("SHIPPED", &pg.shipped_says, folds, p, w));
    if folds {
        for s in &pg.shipped {
            out.extend(wrapped("  ", s, Default::default(), p, w));
        }
    }
    if let Some(t) = &pg.timeline {
        out.push(fold_head("TIMELINE", &t.says, folds, p, w));
        if folds {
            for n in &t.notes {
                out.extend(wrapped("  ", n, p.dim(), p, w));
            }
            for l in &t.lines {
                out.push(clip_line(
                    Line::styled(format!("  {}", l.line), crate::releases::alert(l.level, p)),
                    w,
                ));
            }
            let shown = t.lines.len();
            out.extend(crate::fmt::older(shown + t.older, shown, p));
        }
    }
    out.push(fold_head("IN FLIGHT", &projects::counts(c), folds, p, w));
    if folds {
        for r in &c.running {
            let mut t = r.title.clone();
            if let Some(ph) = &r.phases {
                t += &format!(" (phase {} of {}", ph.done + 1, ph.total);
                if let Some(n) = &ph.next {
                    t += &format!(": {n}");
                }
                t += ")";
            }
            out.extend(wrapped("  running  ", &t, p.good(), p, w));
        }
    }
    out.push(fold_head(
        "AGENT NOTE",
        &projects::note_says(c),
        folds,
        p,
        w,
    ));
    if folds && !c.status.is_empty() {
        out.extend(wrapped("  ", &c.status, p.dim(), p, w));
    }
    out
}

/// One line of the list: `Card`'s columns, a blank word as `-`.
fn row(c: &Card, p: Palette) -> Vec<Cell> {
    let dash = |s: &str| if s.is_empty() { "-" } else { s }.to_string();
    let or_dash = |n: Option<u32>, unit: &str| n.map_or("-".to_string(), |n| format!("{n}{unit}"));
    let lit = |n: usize, on| {
        let style = if n > 0 { on } else { p.dim() };
        cell(n.to_string(), style)
    };
    vec![
        c.name.clone().into(),
        c.profile.clone().into(),
        dash(&c.stage).into(),
        dash(c.version.as_deref().unwrap_or_default()).into(),
        cell(
            dash(&c.prio),
            if matches!(c.prio.as_str(), "focus" | "only") {
                p.head()
            } else {
                p.dim()
            },
        ),
        c.progress.open.to_string().into(),
        c.doing.to_string().into(),
        lit(c.hot, p.warn()),
        c.progress.done.to_string().into(),
        c.progress.closed_7d.to_string().into(),
        or_dash(c.percent, "%").into(),
        format!("{:.1}", c.pace()).into(),
        or_dash(c.eta_days, "d").into(),
        lit(c.running.len(), p.good()),
        lit(c.waiting, p.warn()),
        c.queued.to_string().into(),
        c.held.to_string().into(),
        lit(c.done_today, p.good()),
        projects::wait_word(c.oldest_ready_min).into(),
    ]
}

/// How many deliverables show at once; the rest scroll under the selection once `d` has the keys.
const DELIVERABLE_ROWS: usize = 12;

const DHEADER: [&str; 6] = ["PROJECT", "EPIC", "SYS", "DONE", "ETA", "TRACK"];

/// The Deliverables section: its head, the chips, the table, the coverage line, a blank line;
/// and the line the selected row is on when `d` has the keys. A failed read says so, never an
/// empty table.
fn deliverables(
    dl: Option<&Result<Deliverables, String>>,
    pv: &ProjView,
    p: Palette,
    w: usize,
) -> (Vec<Line<'static>>, Option<usize>) {
    let head = |says: &str, hint: &str| {
        clip_line(
            Line::from(vec![
                Span::styled(says.to_string(), p.head()),
                Span::styled(hint.to_string(), p.dim()),
            ]),
            w,
        )
    };
    let mut out = vec![];
    let mut at = None;
    match dl {
        None => out.push(head("Deliverables", "  reading fleet-bench epics")),
        Some(Err(e)) => {
            out.push(head("Deliverables", ""));
            out.extend(wrapped("", e, p.warn(), p, w));
        }
        Some(Ok(d)) => {
            let hint = if pv.dfocus {
                "  Enter opens the epic's project, Esc back"
            } else {
                "  d browses them"
            };
            out.push(head(&d.says, hint));
            out.push(clip_line(Line::from(pv.dv.status(&d.rows, p)), w));
            let shown = pv.dshown(d);
            if shown.is_empty() {
                let none = if d.rows.is_empty() {
                    "No open feature epics."
                } else {
                    "No deliverable matches."
                };
                out.push(Line::styled(none, p.dim()));
            } else {
                let sel = pv.dv.sel.min(shown.len() - 1);
                let top = if pv.dfocus {
                    (sel + 1).saturating_sub(DELIVERABLE_ROWS)
                } else {
                    0
                };
                let seen: Vec<&&Deliverable> =
                    shown.iter().skip(top).take(DELIVERABLE_ROWS).collect();
                let mut t = Table {
                    header: DHEADER.to_vec(),
                    rows: seen.iter().map(|r| drow(r, p)).collect(),
                    keep: vec![1, 0, 5, 3, 4, 2],
                    right: vec![3, 4],
                    cap: vec![(0, 16), (1, 44)],
                    mark: pv.dv.mark::<Deliverable>(),
                    ..Default::default()
                }
                .fit(w, p.head());
                if pv.dfocus {
                    if let Some(l) = t.get_mut(sel - top + 1) {
                        l.style = p.sel();
                        at = Some(out.len() + sel - top + 1);
                    }
                }
                out.append(&mut t);
                let (before, after) = (top, shown.len() - top - seen.len());
                if before + after > 0 {
                    out.push(Line::styled(
                        format!("  {before} above, {after} below"),
                        p.dim(),
                    ));
                }
            }
            out.push(clip_line(
                Line::styled(format!("{}; {}", d.coverage_says, d.legend), p.dim()),
                w,
            ));
        }
    }
    out.push(Line::raw(""));
    (out, at)
}

/// One deliverable's cells, the same words as agent-web's row.
fn drow(r: &Deliverable, p: Palette) -> Vec<Cell> {
    let dash = |s: &str| {
        if s.is_empty() {
            "-".to_string()
        } else {
            s.to_string()
        }
    };
    vec![
        r.project.clone().into(),
        r.title.clone().into(),
        dash(&r.system).into(),
        r.done_says.clone().into(),
        dash(&r.eta_day).into(),
        cell(dash(&r.track), warn_if(r.track == "behind", p)),
    ]
}

/// The list, and the line the selected row is on (the app keeps it in view); the Deliverables
/// section comes first.
pub fn page(
    pr: &Projects,
    feed: Option<&Feed>,
    dl: Option<&Result<Deliverables, String>>,
    pv: &ProjView,
    p: Palette,
    w: usize,
) -> (Vec<Line<'static>>, Option<usize>) {
    let (mut out, dat) = deliverables(dl, pv, p, w);
    let (mut list, at) = list(pr, feed, pv, p, w);
    let at = if pv.dfocus {
        dat
    } else {
        at.map(|a| a + out.len())
    };
    out.append(&mut list);
    (out, at)
}

/// The project list under the Deliverables section.
fn list(
    pr: &Projects,
    feed: Option<&Feed>,
    pv: &ProjView,
    p: Palette,
    w: usize,
) -> (Vec<Line<'static>>, Option<usize>) {
    let shown = pv.shown(&pr.cards);
    let total = pr.cards.len();
    let count = if shown.len() == total {
        total.to_string()
    } else {
        format!("{} of {total}", shown.len())
    };
    let flying = pv
        .table
        .view
        .states(&pr.cards)
        .iter()
        .find(|c| c.name == "in flight")
        .map_or(0, |c| c.n);
    let mut out = vec![clip_line(
        Line::from(vec![
            Span::styled("PROJECTS", p.head()),
            Span::styled(
                format!(
                    "  {count} projects, {flying} in flight; progress is the open version's rows by size (#size/s 1, m 3, l 8)"
                ),
                p.dim(),
            ),
        ]),
        w,
    )];
    for e in &pr.errors {
        out.extend(wrapped("", e, p.warn(), p, w));
    }
    out.push(clip_line(Line::from(pv.table.status(&pr.cards, p)), w));
    let rows = feed.map_or("reading notes board".to_string(), |f| {
        format!("{} open rows", f.open_rows(None).len())
    });
    out.push(clip_line(
        Line::from(vec![
            Span::styled("ALL ROWS", p.head()),
            Span::styled(format!("  {rows}; a opens them"), p.dim()),
        ]),
        w,
    ));
    out.push(Line::raw(""));
    let mut at = None;
    if shown.is_empty() {
        let none = if total > 0 {
            "No project matches."
        } else {
            "No projects."
        };
        out.push(Line::styled(none, p.dim()));
    } else {
        let (mut t, starts) = Table {
            header: HEADER.to_vec(),
            rows: shown.iter().map(|c| row(c, p)).collect(),
            keep: vec![
                0, 10, 13, 14, 15, 7, 18, 5, 2, 12, 16, 17, 6, 8, 9, 11, 3, 4, 1,
            ],
            right: (5..HEADER.len()).collect(),
            mark: pv.table.mark::<Card>(),
            ..Default::default()
        }
        .fit_wrapped(w, p.head());
        // The Deliverables table has the keys: the list keeps no highlight.
        if let (false, Some(&start)) = (pv.dfocus, starts.get(pv.at(shown.len()))) {
            t[start].style = p.sel();
            at = Some(out.len() + start);
        }
        out.append(&mut t);
    }
    if !pr.unlinked.is_empty() {
        out.push(Line::raw(""));
        out.push(clip_line(
            Line::from(vec![
                Span::styled("NOT ON A CARD", p.head()),
                Span::styled(
                    format!(
                        "  {} active queue items no project claims (no board origin, and their repo is not one lab project's)",
                        pr.unlinked.len()
                    ),
                    p.dim(),
                ),
            ]),
            w,
        ));
        for u in &pr.unlinked {
            out.extend(wrapped("  ", u, p.dim(), p, w));
        }
    }
    (out, at)
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    use crate::fit::plain;
    use hub_core::projects::Progress;

    pub fn fixture() -> Projects {
        let card = |name: &str, done: u32, open: u32| Card {
            profile: "personal".into(),
            name: name.into(),
            stage: "alpha".into(),
            version: Some("v0.0.1".into()),
            goal: "the human can see where each project is".into(),
            progress: Progress {
                open,
                done,
                open_weight: open,
                done_weight: done,
                closed_7d: 2,
                closed_28d: 4,
                closed_weight_7d: 2,
                closed_weight_28d: 4,
            },
            percent: projects::percent(&Progress {
                open_weight: open,
                done_weight: done,
                ..Default::default()
            }),
            eta_days: Some(open * 7),
            status: "landed the cards".into(),
            status_date: "2026-11-05".into(),
            ..Default::default()
        };
        Projects {
            cards: vec![card("garden", 3, 1), card("demo", 0, 2)],
            unlinked: vec!["dotfiles: fix the hook".into()],
            errors: vec![],
        }
    }

    fn a_page() -> Page {
        Page {
            project: "garden".into(),
            releases: None,
            flow_line: Some(
                "ideas 3 | briefs 1 | plans 1 | epics 2 | rows 5 | landed 1 | verified 0".into(),
            ),
            needs: vec!["verify: Saves (4 of 4 rows landed, no live proof)".into()],
            systems: vec![
                hub_core::page::System {
                    id: "ui".into(),
                    head: "ui  25%  1 feature, 0 done  criteria 5 of 7".into(),
                    percent: Some(25),
                    epics: vec![hub_core::page::EpicLine {
                        id: "gm-1".into(),
                        line: "Menus  25%  [rows]  brief yes  plan 1 of 3  rows 2 of 4  behind"
                            .into(),
                        behind: true,
                        leaves: vec![
                            hub_core::page::Leaf {
                                id: "gm-3".into(),
                                line: "[x] gm-3  feat: Main menu  m  pr 101".into(),
                                done: true,
                            },
                            hub_core::page::Leaf {
                                id: "gm-4".into(),
                                line: "[ ] gm-4  Pause menu".into(),
                                done: false,
                            },
                        ],
                    }],
                    closed: "+1 closed, 1 verified".into(),
                    wave: None,
                },
                hub_core::page::System {
                    id: "ci".into(),
                    head: "ci  criteria 1 of 2".into(),
                    ..Default::default()
                },
            ],
            systems_says: "2 systems, 1 open epics (2 rows with no epic)".into(),
            next_says: "beta  4 of 12 met, 1 failing, 1 human, 6 not checkable yet".into(),
            gate: None,
            next_rows: vec![hub_core::page::Requirement {
                stage: "beta".into(),
                result: "FAIL".into(),
                requirement: "a soak test".into(),
            }],
            shipped_says: "none yet".into(),
            shipped: vec![],
            timeline: Some(hub_core::timeline::Timeline {
                says: "7d: 1 commit (1 red on CI)".into(),
                lines: vec![hub_core::timeline::Line {
                    line: "14:02  commit  fix(web): keep the cart (#12)  CI red".into(),
                    level: hub_core::releases::Level::Bad,
                    url: String::new(),
                }],
                older: 3,
                notes: vec!["PRs: the origin is not GitHub".into()],
            }),
            errors: vec!["project-stage-check --systems: exited 2".into()],
        }
    }

    #[test]
    fn the_opened_card_puts_needs_you_open_and_folds_the_rest_to_heads_with_counts() {
        let pr = fixture();
        let np = Palette { no_color: true };
        let draw = |pg: Option<&Page>, folds: bool| -> Vec<String> {
            let pv = ProjView {
                folds,
                ..Default::default()
            };
            open_lines(&pr.cards[0], pg, &pv, np, 200)
                .iter()
                .map(plain)
                .collect()
        };
        let pg = a_page();
        let l = draw(Some(&pg), false);
        assert_eq!(l[0], "GARDEN  personal, alpha");
        assert_eq!(l[2], "  goal     the human can see where each project is");
        assert!(l[3].starts_with("  flow     ideas 3 | briefs 1"), "{l:?}");
        assert_eq!(l[4], "  project-stage-check --systems: exited 2");
        assert_eq!(
            l[6..].to_vec(),
            [
                "BUILD BY SYSTEM  2 systems, 1 open epics (2 rows with no epic)  z opens a system, Z its epics",
                "  + ui  25%  1 feature, 0 done  criteria 5 of 7",
                "    ci  criteria 1 of 2",
                "NEEDS YOU  1",
                "  verify: Saves (4 of 4 rows landed, no live proof)",
                "NEXT STAGE  beta  4 of 12 met, 1 failing, 1 human, 6 not checkable yet  F opens it",
                "SHIPPED  none yet  F opens it",
                "TIMELINE  7d: 1 commit (1 red on CI)  F opens it",
                "IN FLIGHT  0 running, 0 waiting, 0 queued; 0 rows #requested, 0 in the inbox  F opens it",
                "AGENT NOTE  model-written, 2026-11-05  F opens it",
            ]
        );
        let open = draw(Some(&pg), true).join("\n");
        assert!(!open.contains("Menus"), "F opens the folds, not a system");
        for s in [
            "  FAIL   a soak test (beta)",
            "TIMELINE  7d: 1 commit (1 red on CI)\n  PRs: the origin is not GitHub\n  14:02  commit  fix(web): keep the cart (#12)  CI red\n  +3 older",
            "AGENT NOTE  model-written, 2026-11-05\n  landed the cards",
        ] {
            assert!(open.contains(s), "{s} in {open}");
        }
        assert!(!open.contains("F opens it"));
        let reading = draw(None, true);
        assert_eq!(reading.last().unwrap(), "  reading the page...");
        let mut c = pr.cards[0].clone();
        c.goal.clear();
        let l: Vec<String> = open_lines(&c, None, &ProjView::default(), np, 200)
            .iter()
            .map(plain)
            .collect();
        assert_eq!(l[2], "  goal     no goal set");
    }

    #[test]
    fn z_opens_each_system_with_epics_in_turn_and_capital_z_its_epics_and_their_tasks() {
        let pr = fixture();
        let np = Palette { no_color: true };
        let pg = a_page();
        let (mut pv, mut tv) = (ProjView::default(), TaskView::default());
        pv.open(&mut tv, Some(&pr.cards[0]));
        let draw = |pv: &ProjView| -> String {
            open_lines(&pr.cards[0], Some(&pg), pv, np, 200)
                .iter()
                .map(plain)
                .collect::<Vec<_>>()
                .join("\n")
        };
        pv.step_system(&mut tv, &pg);
        assert_eq!(pv.sys.as_deref(), Some("ui"));
        let s = draw(&pv);
        assert!(
            s.contains(
                "  - ui  25%  1 feature, 0 done  criteria 5 of 7\n      + Menus  25%  [rows]"
            ),
            "{s}"
        );
        assert!(
            s.contains("        +1 closed, 1 verified\n    ci  criteria"),
            "{s}"
        );
        assert!(!s.contains("gm-3"), "an epic's tasks wait for Z:\n{s}");
        assert_eq!(tv.only, None);

        tv.table.sel = 3;
        pv.step_epic(&mut tv, &pg);
        assert_eq!(pv.epic.as_deref(), Some("gm-1"));
        assert_eq!(tv.only, Some(vec!["gm-4".to_string()]), "its open tasks");
        assert_eq!(tv.table.sel, 0);
        let s = draw(&pv);
        assert!(
            s.contains("      - Menus  25%  [rows]  brief yes  plan 1 of 3  rows 2 of 4  behind\n          [x] gm-3  feat: Main menu  m  pr 101\n          [ ] gm-4  Pause menu"),
            "{s}"
        );

        // A re-read that drops the epic folds it and widens the rows.
        let mut gone = a_page();
        gone.systems[0].epics.clear();
        pv.narrow(&mut tv, &gone);
        assert_eq!((pv.epic.as_deref(), tv.only.as_ref()), (None, None));
        pv.step_epic(&mut tv, &pg);
        pv.step_epic(&mut tv, &pg);
        assert_eq!(pv.epic, None, "after the last epic it folds");
        assert_eq!(tv.only, None);

        pv.step_system(&mut tv, &pg);
        assert_eq!(pv.sys, None, "ci has nothing to open, so z folds after ui");
        pv.step_epic(&mut tv, &pg);
        assert_eq!(
            (pv.sys.as_deref(), pv.epic.as_deref()),
            (Some("ui"), Some("gm-1")),
            "Z with no system open opens the first one's first epic"
        );
        pv.close(&mut tv);
        assert_eq!(
            (pv.sys.as_ref(), pv.epic.as_ref(), tv.only.as_ref()),
            (None, None, None)
        );

        // Z skips a system that has only closed epics to count: there is nothing to narrow to.
        let mut closed_first = a_page();
        closed_first.systems.insert(
            0,
            hub_core::page::System {
                id: "save".into(),
                closed: "+2 closed, 2 verified".into(),
                ..Default::default()
            },
        );
        pv.step_epic(&mut tv, &closed_first);
        assert_eq!(
            (pv.sys.as_deref(), pv.epic.as_deref()),
            (Some("ui"), Some("gm-1"))
        );
    }

    fn key(c: char) -> KeyEvent {
        KeyEvent::from(KeyCode::Char(c))
    }

    fn enter() -> KeyEvent {
        KeyEvent::from(KeyCode::Enter)
    }

    #[test]
    fn enter_opens_the_selected_project_a_opens_every_row_and_a_name_opens_its_project() {
        let pr = fixture();
        let (mut pv, mut tv) = (ProjView::default(), TaskView::default());
        for _ in 0..3 {
            assert!(pv.key(&mut tv, key('j'), &pr.cards, 10));
        }
        assert_eq!(pv.table.sel, 1, "j stops at the last row");
        pv.key(&mut tv, enter(), &pr.cards, 10);
        assert!(pv.open);
        assert_eq!(tv.project, Some(("personal".into(), "demo".into())));
        pv.close(&mut tv);
        assert!(!pv.open);
        assert_eq!(pv.table.sel, 1, "back on the row it opened");
        pv.key(&mut tv, key('a'), &pr.cards, 10);
        assert!(pv.open && tv.project.is_none());
        assert_eq!(pv.table.sel, 1, "All leaves the selection where it was");
        assert!(!pv.key(&mut tv, key('z'), &pr.cards, 10));

        pv.go(&mut tv, &pr.cards, "personal/Garden");
        assert_eq!(
            (pv.table.sel, tv.project.clone()),
            (0, Some(("personal".into(), "garden".into())))
        );
        pv.go(&mut tv, &pr.cards, "menu");
        assert_eq!(
            (tv.project.clone(), tv.table.view.q.as_str()),
            (None, "menu")
        );
    }

    #[test]
    fn the_header_is_cards_columns_in_order() {
        use hub_core::table::Row as _;
        assert_eq!(HEADER.len(), Card::COLUMNS.len());
        for (h, c) in HEADER.iter().zip(Card::COLUMNS) {
            assert!(h.to_lowercase().starts_with(c), "{h} is not {c}");
        }
    }

    #[test]
    fn a_re_read_that_shrinks_the_view_leaves_the_last_row_selected() {
        let pr = fixture();
        let (mut pv, mut tv) = (
            ProjView {
                table: DataTable {
                    sel: 5,
                    ..Default::default()
                },
                ..Default::default()
            },
            TaskView::default(),
        );
        assert_eq!(pv.selected(&pr.cards).unwrap().name, "demo");
        let (l, at) = page(&pr, None, None, &pv, Palette { no_color: true }, 200);
        assert!(plain(&l[at.unwrap()]).starts_with("demo"));
        pv.key(&mut tv, key('k'), &pr.cards, 10);
        assert_eq!(pv.table.sel, 0, "k moves from the row on screen");
    }

    #[test]
    fn the_shared_keys_narrow_the_list_and_enter_opens_the_row_on_screen() {
        let pr = fixture();
        let (mut pv, mut tv) = (ProjView::default(), TaskView::default());
        pv.key(&mut tv, key('j'), &pr.cards, 10);
        for c in "/demo".chars() {
            assert!(pv.key(&mut tv, key(c), &pr.cards, 10), "{c} is typed");
        }
        assert!(pv.table.typing.is_some());
        assert_eq!(pv.shown(&pr.cards).len(), 2, "nothing applies until Enter");
        pv.key(&mut tv, enter(), &pr.cards, 10);
        assert!(!pv.open, "Enter ends the search, it opens nothing");
        assert_eq!(
            pv.table.sel, 0,
            "the view changed, so the selection is back on top"
        );
        assert_eq!(pv.shown(&pr.cards).len(), 1);
        pv.key(&mut tv, enter(), &pr.cards, 10);
        assert_eq!(tv.project, Some(("personal".into(), "demo".into())));
        pv.close(&mut tv);

        // A project the view hides still opens by name, and Back keeps the selection.
        pv.go(&mut tv, &pr.cards, "garden");
        assert_eq!(pv.table.sel, 0);
        pv.close(&mut tv);

        assert!(pv.key(&mut tv, KeyEvent::from(KeyCode::Esc), &pr.cards, 10));
        assert!(pv.table.is_default(), "Esc clears the view");
        assert!(!pv.key(&mut tv, KeyEvent::from(KeyCode::Esc), &pr.cards, 10));

        pv.key(&mut tv, key('s'), &pr.cards, 10);
        assert_eq!(pv.table.view.sort, "project");
        let (l, _) = page(&pr, None, None, &pv, Palette { no_color: true }, 200);
        let s: Vec<String> = l.iter().map(plain).collect();
        assert!(s.iter().any(|l| l.starts_with("PROJECT v")), "{s:?}");
        pv.key(&mut tv, key('f'), &pr.cards, 10);
        assert_eq!(pv.shown(&pr.cards).len(), 0, "none is in flight");
        let (l, at) = page(&pr, None, None, &pv, Palette { no_color: true }, 200);
        let s = l.iter().map(plain).collect::<Vec<_>>().join("\n");
        assert!(s.contains("0 of 2 projects"), "{s}");
        assert!(s.contains("No project matches."), "{s}");
        assert_eq!(at, None);
    }

    #[test]
    fn the_list_is_one_row_a_project_and_names_what_no_card_claims() {
        let mut pr = fixture();
        pr.cards[0].prio = "focus".into();
        pr.cards[0].waiting = 1;
        pr.cards[1].version = None;
        pr.cards[1].eta_days = None;
        let pv = ProjView {
            table: DataTable {
                sel: 1,
                ..Default::default()
            },
            ..Default::default()
        };
        let (l, at) = page(&pr, None, None, &pv, Palette { no_color: true }, 200);
        let s: Vec<String> = l.iter().map(plain).collect();
        // The Deliverables section is on top and still reading; the list follows it.
        assert_eq!(s[0], "Deliverables  reading fleet-bench epics");
        let s = s[2..].to_vec();
        assert!(
            s[0].starts_with("PROJECTS  2 projects, 1 in flight"),
            "{s:?}"
        );
        assert_eq!(s[1], "all 2  in flight 1  waiting 1");
        assert!(s[2].starts_with("ALL ROWS  reading notes board"), "{s:?}");
        assert_eq!(s[4].split_whitespace().collect::<Vec<_>>(), HEADER.to_vec());
        assert_eq!(
            s[5].split_whitespace().collect::<Vec<_>>(),
            [
                "garden", "personal", "alpha", "v0.0.1", "focus", "1", "0", "0", "3", "2", "75%",
                "1.0", "7d", "0", "1", "0", "0", "0", "-"
            ]
        );
        assert_eq!(
            s[at.unwrap() - 2].split_whitespace().collect::<Vec<_>>(),
            [
                "demo", "personal", "alpha", "-", "-", "2", "0", "0", "0", "2", "0%", "1.0", "-",
                "0", "0", "0", "0", "0", "-"
            ]
        );
        let tail = s.join("\n");
        assert!(
            tail.contains("NOT ON A CARD  1 active queue items"),
            "{tail}"
        );
        assert!(tail.ends_with("  dotfiles: fix the hook"), "{tail}");

        let narrow = page(&pr, None, None, &pv, Palette { no_color: true }, 40).0;
        assert!(narrow.iter().all(|l| plain(l).len() <= 40));
        let head = narrow.iter().map(plain).find(|l| l.starts_with("PROJECT "));
        let head = head.expect("the header stays");
        assert!(head.contains("PCT"), "{head}");
    }

    fn deliverable(project: &str, id: &str, title: &str, system: &str, track: &str) -> Deliverable {
        Deliverable {
            project: project.into(),
            profile: "personal".into(),
            id: id.into(),
            title: title.into(),
            system: system.into(),
            done: 8,
            total: 19,
            percent: Some(60),
            done_says: "60% 8/19".into(),
            eta: Some(1),
            eta_day: "11-13".into(),
            track: track.into(),
        }
    }

    fn delivs() -> Result<Deliverables, String> {
        Ok(Deliverables {
            rows: vec![
                deliverable("garden", "g-1", "school days", "gameplay", "behind"),
                deliverable("demo", "d-1", "Lobby", "netcode", "on track"),
            ],
            says: "Deliverables (2 open, 0 ready to verify, 1 on track, 1 behind)".into(),
            coverage_says: "Coverage: 4 linked / 9 open rows (44%)".into(),
            legend: hub_core::deliverables::LEGEND,
            ..Default::default()
        })
    }

    fn lines(l: &[Line<'static>]) -> Vec<String> {
        l.iter().map(plain).collect()
    }

    #[test]
    fn deliverables_sit_above_the_list_with_the_webs_words() {
        let pr = fixture();
        let d = delivs();
        let (l, at) = page(
            &pr,
            None,
            Some(&d),
            &ProjView::default(),
            Palette { no_color: true },
            120,
        );
        let s = lines(&l);
        assert!(
            s[0].starts_with("Deliverables (2 open, 0 ready to verify, 1 on track, 1 behind)"),
            "{s:?}"
        );
        assert_eq!(s[1], "all 2  behind 1  on track 1  verify 0");
        assert_eq!(
            s[2].split_whitespace().collect::<Vec<_>>(),
            ["PROJECT", "EPIC", "SYS", "DONE", "ETA", "TRACK"]
        );
        // worst first, the web's cell words: percent, then done/all
        assert_eq!(
            s[3].split_whitespace().collect::<Vec<_>>(),
            ["garden", "school", "days", "gameplay", "60%", "8/19", "11-13", "behind"]
        );
        assert!(
            s[5].starts_with("Coverage: 4 linked / 9 open rows (44%); percent is"),
            "{s:?}"
        );
        let list = s.iter().position(|l| l.starts_with("PROJECTS ")).unwrap();
        assert!(list > 5, "the list is under the section: {s:?}");
        // the list's own row is the highlighted one until `d` moves the keys
        assert!(at.unwrap() > list);
    }

    #[test]
    fn a_failed_read_says_so_and_a_missing_one_says_reading() {
        let pr = fixture();
        let pv = ProjView::default();
        let p = Palette { no_color: true };
        let bad: Result<Deliverables, String> = Err("fleet-bench epics: exit 2".into());
        let s = lines(&page(&pr, None, Some(&bad), &pv, p, 120).0);
        assert_eq!(s[0], "Deliverables");
        assert_eq!(s[1], "fleet-bench epics: exit 2");
        assert!(
            !s.iter()
                .any(|l| l.starts_with("PROJECT ") && l.contains("EPIC")),
            "{s:?}"
        );
        let none = Ok(Deliverables::default());
        let s = lines(&page(&pr, None, Some(&none), &pv, p, 120).0);
        assert!(s.iter().any(|l| l == "No open feature epics."), "{s:?}");
    }

    #[test]
    fn d_gives_the_table_the_keys_and_enter_opens_the_epics_project_with_its_folds() {
        let pr = fixture();
        let d = delivs();
        let mut tv = TaskView::default();
        let mut pv = ProjView::default();
        let key = |c| KeyEvent::from(c);
        assert!(pv.key(&mut tv, key(KeyCode::Char('d')), &pr.cards, 20));
        assert!(pv.dfocus);
        let (l, at) = page(&pr, None, Some(&d), &pv, Palette { no_color: true }, 120);
        let s = lines(&l);
        assert_eq!(s[at.unwrap()].split_whitespace().next(), Some("garden"));
        // j moves in the table, not the project list
        assert!(pv.dkey(
            &mut tv,
            key(KeyCode::Char('j')),
            &pr.cards,
            d.as_ref().unwrap(),
            20
        ));
        assert_eq!((pv.dv.sel, pv.table.sel), (1, 0));
        // the shared keys work: f steps the chip
        assert!(pv.dkey(
            &mut tv,
            key(KeyCode::Char('f')),
            &pr.cards,
            d.as_ref().unwrap(),
            20
        ));
        assert_eq!(pv.dv.view.state, "behind");
        assert!(pv.dkey(
            &mut tv,
            key(KeyCode::Char('x')),
            &pr.cards,
            d.as_ref().unwrap(),
            20
        ));
        pv.dv.sel = 0;
        // Enter: the project's rows open with the system and epic open
        assert!(pv.dkey(
            &mut tv,
            key(KeyCode::Enter),
            &pr.cards,
            d.as_ref().unwrap(),
            20
        ));
        assert!(pv.open && !pv.dfocus);
        assert_eq!(tv.project, Some(("personal".into(), "garden".into())));
        assert_eq!(
            (pv.sys.as_deref(), pv.epic.as_deref()),
            (Some("gameplay"), Some("g-1"))
        );
        // Esc from the table: clear the view first, then back to the list
        pv.close(&mut tv);
        pv.dfocus = true;
        pv.dv.view.q = "zzz".into();
        assert!(pv.dkey(
            &mut tv,
            key(KeyCode::Esc),
            &pr.cards,
            d.as_ref().unwrap(),
            20
        ));
        assert!(pv.dfocus && pv.dv.is_default());
        assert!(pv.dkey(
            &mut tv,
            key(KeyCode::Esc),
            &pr.cards,
            d.as_ref().unwrap(),
            20
        ));
        assert!(!pv.dfocus);
    }

    #[test]
    fn an_epic_whose_project_has_no_card_opens_nothing() {
        let pr = fixture();
        let d: Result<Deliverables, String> = Ok(Deliverables {
            rows: vec![deliverable("ghost", "x-1", "Lost", "ui", "behind")],
            ..Default::default()
        });
        let mut tv = TaskView::default();
        let mut pv = ProjView {
            dfocus: true,
            ..Default::default()
        };
        pv.dkey(
            &mut tv,
            KeyEvent::from(KeyCode::Enter),
            &pr.cards,
            d.as_ref().unwrap(),
            20,
        );
        assert!(!pv.open && pv.epic.is_none());
    }

    #[test]
    fn a_long_table_shows_a_window_that_follows_the_selection() {
        let pr = fixture();
        let rows: Vec<Deliverable> = (0..30)
            .map(|i| {
                deliverable(
                    "garden",
                    &format!("g-{i}"),
                    &format!("epic {i:02}"),
                    "ui",
                    "on track",
                )
            })
            .collect();
        let d = Ok(Deliverables {
            rows,
            says: "Deliverables (30 open)".into(),
            ..Default::default()
        });
        let p = Palette { no_color: true };
        let mut pv = ProjView::default();
        let s = lines(&page(&pr, None, Some(&d), &pv, p, 120).0);
        assert!(
            s.iter().any(|l| l.contains("epic 00")) && !s.iter().any(|l| l.contains("epic 20"))
        );
        assert!(s.iter().any(|l| l.contains("0 above, 18 below")), "{s:?}");
        pv.dfocus = true;
        pv.dv.sel = 25;
        let (l, at) = page(&pr, None, Some(&d), &pv, p, 120);
        let s = lines(&l);
        assert!(s[at.unwrap()].contains("epic 25"), "{:?}", s[at.unwrap()]);
        assert!(!s.iter().any(|l| l.contains("epic 00")));
    }
}
