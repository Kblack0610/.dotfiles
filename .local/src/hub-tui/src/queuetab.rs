//! The Queue tab: agent-queue's items as one table on the shared data-table component, the
//! Infra Jobs style, read through `hub_core::queue`, the same reader and the same `QueueRow` as
//! agent-web's Queue tab. Its sections are `flow` (the pipeline line, `flowline`), `table` and `candidates`.
//! `/ f s S x` are the shared table's keys; j/k pick a row (a done one too), Enter opens its
//! detail, where `l` marks each record it names in turn (`Item::links`: session, project, row,
//! each PR and its CI runs) and Enter on a marked one opens it; `c` arms a cancel that waits on y and `+`/`-` move its priority one step, both for an
//! active item only. Below the table the Candidates fold (`hub_core::queue::candidates`, the
//! snapshot each `fleet-dispatch run` writes, `as of` its time): `C` opens it, j/k carry on into
//! its rows, and `p` starts the selected one through the Projects tab's Start (`fleet-dispatch
//! promote`). Every write goes through hub-core.

use chrono::{DateTime, Utc};
use hub_core::flow::Rail;
use hub_core::links::Link;
use hub_core::queue::{money, Candidate, Candidates, Item, Queue, QueueRow, State, Timing};
use hub_core::table::Row;
use hub_core::tasks::Write;
use ratatui::crossterm::event::{KeyCode, KeyEvent, KeyModifiers};
use ratatui::text::{Line, Span};

use crate::datatable::{DataTable, Took};
use crate::fit::{cell, clip_line, Cell, Table};
use crate::flowline::{self, LineView};
use crate::fmt::{clock, Palette};

/// What a key on the Queue tab asks the app to do.
#[derive(Debug, PartialEq)]
pub enum Ask {
    /// Not one of the tab's own keys.
    Pass,
    /// Handled here: a move, an armed or dropped confirm, a refusal.
    Done,
    Cancel(String),
    Bump(String, &'static str),
    /// Start a candidate: its label and the board write.
    Promote(String, Write),
    /// Open a record the item names.
    Follow(Link),
}

pub struct QueueView {
    /// The shared table's view (query, state chip, sort) and its selection, an index into the
    /// drawn rows, then into the candidates the open fold shows.
    pub table: DataTable,
    /// The selected row's detail replaces the table.
    pub detail: bool,
    /// The detail's marked link (`l`): the item it was marked on and an index into its `links`;
    /// Enter opens it. A refresh that puts another item under the selection drops the mark.
    pub link: Option<(String, usize)>,
    pub cands_open: bool,
    /// The step and problem picked on the pipeline line.
    pub line: LineView,
    /// The slug a cancel waits on y for.
    pub confirm: Option<String>,
    /// The action now running, as "cancel <slug>".
    pub running: Option<String>,
    /// The last action's answer: agent-queue's output, or why it failed.
    pub said: Option<Result<String, String>>,
}

/// `now` (unix seconds) as the time the rows are measured at.
fn at(now: i64) -> DateTime<Utc> {
    DateTime::from_timestamp(now, 0).unwrap_or_default()
}

impl Default for QueueView {
    /// The candidates start open (dashboards rule 4).
    fn default() -> QueueView {
        QueueView {
            table: DataTable::default(),
            detail: false,
            link: None,
            cands_open: true,
            line: LineView::default(),
            confirm: None,
            running: None,
            said: None,
        }
    }
}

impl QueueView {
    /// A request for the tab (`hub --tab "queue running"`): an old section id opens the table on
    /// its state chip, `candidates` opens that fold, `flow` and `table` are the page as it is, and
    /// any other word is the query, over every row (a slug names a done item as often as a live one).
    /// The table starts from its own view.
    pub fn open(&mut self, query: &str) {
        let q = query.trim();
        self.table.clear();
        self.detail = false;
        match hub_core::queue::section_chip(q) {
            _ if q.is_empty() => {}
            Some(chip) => self.table.view.state = chip.into(),
            None if q.eq_ignore_ascii_case("candidates") => self.cands_open = true,
            None if ["flow", "table"].iter().any(|s| q.eq_ignore_ascii_case(s)) => {}
            None => {
                self.table.view.q = q.into();
                self.table.view.state = "all".into();
            }
        }
    }

    /// The rows the table holds, from every row in the table's own order: every one the view
    /// keeps, one line each, so j/k reaches every row; `page` formats only those on screen.
    fn drawn<'a>(&self, all: &[QueueRow<'a>]) -> Vec<QueueRow<'a>> {
        self.table.view.apply(all).into_iter().copied().collect()
    }

    pub fn shown<'a>(&self, q: &'a Queue, now: i64) -> Vec<QueueRow<'a>> {
        self.drawn(&q.rows(at(now)))
    }

    pub fn selected<'a>(&self, q: &'a Queue, now: i64) -> Option<&'a Item> {
        self.shown(q, now).get(self.table.sel).map(|r| r.item)
    }

    /// The candidates the fold lists: none while it is shut.
    pub fn shown_cands<'a>(&self, c: &'a [Candidate]) -> &'a [Candidate] {
        if self.cands_open {
            c
        } else {
            &[]
        }
    }

    pub fn selected_cand<'a>(
        &self,
        q: &Queue,
        c: &'a [Candidate],
        now: i64,
    ) -> Option<&'a Candidate> {
        let i = self.table.sel.checked_sub(self.shown(q, now).len())?;
        self.shown_cands(c).get(i)
    }

    /// The marked link's index, when it was marked on this item.
    fn mark(&self, i: &Item) -> Option<usize> {
        self.link
            .as_ref()
            .filter(|(s, _)| *s == i.slug)
            .map(|(_, at)| *at)
    }

    /// A new read keeps the selection on the same slug when it is still shown, and otherwise
    /// in range of the rows and shown candidates.
    pub fn reselect(&mut self, was: Option<String>, q: &Queue, c: &[Candidate], now: i64) {
        let rows = self.shown(q, now);
        let n = rows.len() + self.shown_cands(c).len();
        let at = was.and_then(|s| rows.iter().position(|r| r.item.slug == s));
        self.table.keep(at, n);
    }

    /// `page` is the body's height in rows: PgUp/PgDn and space move the selection a page,
    /// Ctrl-d/Ctrl-u half of one, g/G to the first and last row. The app keeps the selected row
    /// in view, so every move scrolls the page with it.
    pub fn key(
        &mut self,
        k: KeyEvent,
        q: Option<&Queue>,
        c: &[Candidate],
        page: usize,
        now: i64,
    ) -> Ask {
        if let Some(slug) = &self.confirm {
            return match k.code {
                KeyCode::Char('y') | KeyCode::Enter => {
                    let s = slug.clone();
                    self.confirm = None;
                    Ask::Cancel(s)
                }
                KeyCode::Char('n') | KeyCode::Esc => {
                    self.confirm = None;
                    Ask::Done
                }
                _ => Ask::Done,
            };
        }
        let ctrl = k.modifiers.contains(KeyModifiers::CONTROL);
        // `/ f s S x`, and every key while a query is being typed, are the shared table's.
        if !ctrl && (self.table.typing.is_some() || DataTable::owns(k.code)) {
            if self.table.key::<QueueRow>(k.code) == Took::View {
                (self.detail, self.link) = (false, None);
            }
            return Ask::Done;
        }
        let Some(q) = q else { return Ask::Pass };
        let rows = self.shown(q, now);
        if self
            .table
            .moves(k, rows.len() + self.shown_cands(c).len(), page)
        {
            self.link = None;
            return Ask::Done;
        }
        if ctrl {
            return Ask::Pass;
        }
        let busy = || Some(Err("an action is still running".to_string()));
        let item = rows.get(self.table.sel).map(|r| r.item);
        let links = item.filter(|_| self.detail).map_or(vec![], Item::links);
        let mark = item.and_then(|i| self.mark(i));
        match k.code {
            KeyCode::Char('l') if !links.is_empty() => {
                let at = mark.map_or(0, |at| (at + 1) % links.len());
                self.link = item.map(|i| (i.slug.clone(), at));
            }
            KeyCode::Enter if mark.is_some_and(|at| at < links.len()) => {
                self.link = None;
                return Ask::Follow(links[mark.unwrap_or_default()].link.clone());
            }
            KeyCode::Enter if item.is_some() => {
                (self.detail, self.link) = (!self.detail, None);
            }
            KeyCode::Esc if self.detail => (self.detail, self.link) = (false, None),
            KeyCode::Esc if !self.table.is_default() => self.table.clear(),
            KeyCode::Char('C') => {
                self.cands_open = !self.cands_open;
                self.reselect(None, q, c, now);
            }
            KeyCode::Char('p') => match self.selected_cand(q, c, now) {
                _ if self.running.is_some() => self.said = busy(),
                Some(cand) => {
                    self.said = None;
                    return Ask::Promote(
                        format!("promote {} {}", cand.project, cand.key),
                        cand.start(),
                    );
                }
                None if !self.cands_open => {
                    self.said = Some(Err("C opens the candidates, then j/k onto one".into()))
                }
                None => self.said = Some(Err("j/k onto a candidate to promote it".into())),
            },
            KeyCode::Char('c') => match item {
                _ if self.running.is_some() => self.said = busy(),
                Some(i) if i.state == State::Done => self.said = Some(done_row(i)),
                Some(i) => {
                    self.said = None;
                    self.confirm = Some(i.slug.clone());
                }
                None => self.said = Some(Err("nothing active to cancel".into())),
            },
            KeyCode::Char(c @ ('+' | '=' | '-')) => {
                let Some(i) = item else {
                    return Ask::Done;
                };
                if self.running.is_some() {
                    self.said = busy();
                    return Ask::Done;
                }
                if i.state == State::Done {
                    self.said = Some(done_row(i));
                    return Ask::Done;
                }
                match i.bumped(c != '-') {
                    Some(p) => return Ask::Bump(i.slug.clone(), p),
                    None => self.said = Some(Err(format!("{} is already {}", i.slug, i.priority))),
                }
            }
            _ => return Ask::Pass,
        }
        Ask::Done
    }
}

/// Why cancel and priority leave a finished item alone.
fn done_row(i: &Item) -> Result<String, String> {
    Err(format!("{} is done", i.slug))
}

fn heading(title: &str, rest: String, p: Palette) -> Line<'static> {
    Line::from(vec![
        Span::styled(title.to_string(), p.head()),
        Span::styled(rest, p.dim()),
    ])
}

/// A span of minutes as the table prints it: `14m`, `1h05`, `2d03h`; `-` where the item has not
/// reached the stage.
fn mins(m: Option<i64>) -> String {
    match m {
        None => "-".into(),
        Some(m) if m < 60 => format!("{m}m"),
        Some(m) if m < 24 * 60 => format!("{}h{:02}", m / 60, m % 60),
        Some(m) => format!("{}d{:02}h", m / (24 * 60), m % (24 * 60) / 60),
    }
}

/// The STATE column: what the item needs, or how it finished.
fn state(i: &Item, p: Palette) -> Cell {
    match i.state {
        State::Waiting => cell("needs you", p.warn()),
        State::Running => cell("running", p.good()),
        State::Review => "on a PR".into(),
        State::Queued if i.is_held() => cell("held", p.warn()),
        State::Queued => "ready".into(),
        State::Done => {
            let st = i.status.clone().unwrap_or_else(|| "done".into());
            let style = if st == "ok" || st == "done" {
                p.good()
            } else {
                p.bad()
            };
            cell(st, style)
        }
    }
}

/// hub-core `QueueRow::COLUMNS` in capitals, the web table's columns: the sort mark is an index
/// into that list. The title leads; `#` is the start order of the ready items.
const HEADER: [&str; 17] = [
    "#", "TITLE", "PROJECT", "PRIORITY", "STATE", "HOLD", "FROM", "IN", "WAIT", "RUN", "PR", "ROW",
    "KIND", "SIZE", "ACCT", "MODE", "PLAN",
];

fn row(r: &QueueRow, p: Palette) -> Vec<Cell> {
    let i = r.item;
    let pr = match i.pr_link() {
        Some((label, _)) => label.into(),
        None if i.unproven() => cell("! none", p.warn()),
        None => "-".into(),
    };
    let or_dash = |v: Option<&str>| match v.map(str::trim) {
        Some(s) if !s.is_empty() => s.to_string(),
        _ => "-".into(),
    };
    let mut title = i.title();
    if let Some(n) = &i.note {
        title = format!("{title}  ({n})");
    }
    let prio = or_dash(Some(&i.priority));
    vec![
        r.start.map_or(String::new(), |n| n.to_string()).into(),
        title.into(),
        or_dash(Some(&i.project)).into(),
        if prio == "urgent" {
            cell(prio, p.warn())
        } else {
            prio.into()
        },
        state(i, p),
        or_dash(r.val("hold").shown().as_deref()).into(),
        or_dash(r.val("from").shown().as_deref()).into(),
        mins(r.timing.in_state).into(),
        mins(r.timing.wait).into(),
        mins(r.timing.run).into(),
        pr,
        or_dash(r.val("row").shown().as_deref()).into(),
        or_dash(i.kind.as_deref()).into(),
        or_dash(i.size.as_deref()).into(),
        or_dash(i.account.as_deref()).into(),
        or_dash(Some(&i.mode)).into(),
        or_dash(i.plan_label.as_deref()).into(),
    ]
}

/// One `label  value` line of the detail.
fn kv(k: &str, v: String, p: Palette, w: usize) -> Line<'static> {
    clip_line(
        Line::from(vec![Span::styled(format!("{k:<9}"), p.dim()), Span::raw(v)]),
        w,
    )
}

/// A header's text, or None when it is blank.
fn some(v: &Option<String>) -> Option<&str> {
    v.as_deref().map(str::trim).filter(|s| !s.is_empty())
}

/// The selected row in full: every header, then the timeline queued -> ready -> started ->
/// waiting -> finished -> merged with the minutes from the step before. The agent-queue log is
/// `notes log --item <slug>`, named here and not read.
fn detail(
    i: &Item,
    t: Timing,
    mark: Option<usize>,
    p: Palette,
    now: i64,
    w: usize,
) -> Vec<Line<'static>> {
    let mut out = vec![clip_line(
        Line::from(vec![
            Span::styled(i.slug.clone(), p.head()),
            Span::raw(format!("  {}", i.title())),
        ]),
        w,
    )];
    let mut state_words = format!("{:?}", i.state).to_lowercase();
    if let Some(s) = some(&i.status) {
        state_words += &format!(" ({s})");
    }
    if let Some(h) = &i.hold {
        state_words += &format!(", waits: {h}");
    }
    let mode = match some(&i.weight) {
        Some(wt) => format!("{} {wt}", i.mode),
        None => i.mode.clone(),
    };
    let mut fields = vec![
        ("state", state_words),
        ("priority", i.priority.clone()),
        ("project", i.project.clone()),
        ("mode", mode),
        ("kind", some(&i.kind).unwrap_or("").to_string()),
        ("size", some(&i.size).unwrap_or("").to_string()),
        ("acct", some(&i.account).unwrap_or("").to_string()),
        ("harness", i.harness_label()),
        ("session", some(&i.session).unwrap_or("").to_string()),
        ("tags", i.tags.clone()),
        ("area", some(&i.area).unwrap_or("").to_string()),
        ("from", some(&i.from).unwrap_or("").to_string()),
        ("row", some(&i.row).unwrap_or("").to_string()),
        ("after", some(&i.after).unwrap_or("").to_string()),
        ("pr", i.pr_words().unwrap_or_default()),
        ("cost", i.cost().map(money).unwrap_or_default()),
        (
            "timing",
            format!(
                "in {}  wait {}  run {}  lead {}",
                mins(t.in_state),
                mins(t.wait),
                mins(t.run),
                mins(t.lead)
            ),
        ),
    ];
    if i.unproven() {
        fields.push(("proof", "! no PR, no proof".into()));
    }
    out.extend(
        fields
            .into_iter()
            .filter(|(_, v)| !v.trim().is_empty())
            .map(|(k, v)| kv(k, v, p, w)),
    );
    let links = i.links();
    if !links.is_empty() {
        out.push(Line::raw(""));
        out.push(Line::styled("opens (l marks, Enter opens)", p.head()));
        for (n, l) in links.iter().enumerate() {
            let on = mark == Some(n);
            let line = Line::from(vec![
                Span::styled(
                    format!("{} {:<9}", if on { ">" } else { " " }, l.what),
                    p.dim(),
                ),
                Span::styled(l.text.clone(), if on { p.head() } else { p.dim() }),
            ]);
            out.push(clip_line(line, w));
        }
    }
    out.push(Line::raw(""));
    out.push(Line::styled("timeline", p.head()));
    for st in i.timeline() {
        let value = match (&st.at, &st.sha) {
            (_, Some(sha)) => sha.chars().take(10).collect(),
            (Some(at), None) => {
                let when = chrono::DateTime::parse_from_rfc3339(at.trim())
                    .map_or(at.clone(), |d| clock(d.timestamp(), now));
                match st.gap_min {
                    Some(g) => format!("{when}  +{}", mins(Some(g))),
                    None => when,
                }
            }
            _ => continue,
        };
        out.push(kv(st.step, value, p, w));
    }
    out.push(Line::raw(""));
    out.push(clip_line(
        Line::styled(format!("log: notes log --item {}", i.slug), p.dim()),
        w,
    ));
    let task: Vec<&str> = i.task.lines().take(8).collect();
    if !task.is_empty() {
        out.push(Line::raw(""));
        out.extend(
            task.into_iter()
                .map(|l| clip_line(Line::raw(l.to_string()), w)),
        );
    }
    out
}

/// The table's lines (header first), one per drawn row, columns dropped by priority to fit `w`:
/// PLAN, MODE, ACCT, SIZE and KIND go first, then WAIT, ROW, FROM, RUN, PR and IN; STATE, TITLE,
/// `#`, PROJECT, PRIORITY and HOLD stay longest.
fn table(rows: &[QueueRow], v: &QueueView, p: Palette, w: usize) -> Vec<Line<'static>> {
    Table {
        header: HEADER.to_vec(),
        rows: rows.iter().map(|r| row(r, p)).collect(),
        keep: vec![4, 0, 2, 3, 5, 7, 10, 9, 6, 11, 8, 12, 13, 14, 15, 16],
        flex: Some(1),
        flexmin: 20,
        flexkeep: true,
        right: vec![0, 7, 8, 9],
        cap: vec![
            (2, 18),
            (5, 18),
            (6, 8),
            // PR: room for `home-config#875 +2`, an item landed in several repos.
            (10, 20),
            (11, 10),
            (12, 8),
            (14, 10),
            (16, 20),
        ],
        mark: v.table.mark::<QueueRow>(),
    }
    .fit(w, p.head())
}

/// The page, one line per table row. `win` is the app's scroll and the body's height: a row line
/// outside both that window and a body's height around the selection (where the app scrolls to
/// keep it in view) is left blank, so a frame formats a screen of rows, not thousands; the line
/// count stays, so the scroll and every row's place are the same. None formats every row
/// (`hub --once`).
#[allow(clippy::too_many_arguments)]
pub fn page(
    q: &Queue,
    v: &QueueView,
    cands: Option<&Result<Candidates, String>>,
    flow: (&Rail, bool),
    p: Palette,
    now: i64,
    w: usize,
    win: Option<(usize, usize)>,
) -> (Vec<Line<'static>>, Option<usize>) {
    let mut out = flowline::lines(flow.0, &v.line, flow.1, p, w);
    for e in &q.errors {
        out.push(clip_line(Line::styled(e.clone(), p.warn()), w));
    }
    let rest = q
        .stats
        .as_ref()
        .map_or(String::new(), |s| format!("  {}", s.week()));
    out.push(clip_line(heading("AGENT QUEUE", rest, p), w));
    if let Some(l) = q.stats.as_ref().and_then(|s| s.sitting_line()) {
        out.push(clip_line(Line::raw(l), w));
    }
    if let Some(d) = &q.dispatch {
        let style = if d.warn() { p.warn() } else { p.dim() };
        out.push(clip_line(Line::styled(d.line(), style), w));
    }
    out.push(status_line(v, p, w));
    let all = q.rows(at(now));
    let rows = v.drawn(&all);
    let mut chips = v.table.status(&all, p);
    chips.push(Span::styled(
        format!("    {} of {}", rows.len(), all.len()),
        p.dim(),
    ));
    out.push(clip_line(Line::from(chips), w));
    out.extend(DataTable::legend::<QueueRow>(p, w));
    let (more, cand_at) = candidates(rows.len(), v, cands, p, w);
    let mut at_line = None;
    if let (true, Some(r)) = (v.detail, rows.get(v.table.sel)) {
        out.push(Line::raw(""));
        at_line = Some(out.len());
        out.extend(detail(r.item, r.timing, v.mark(r.item), p, now, w));
    } else if rows.is_empty() {
        out.push(Line::styled(
            if all.is_empty() {
                "Nothing in the queue."
            } else {
                "No item matches (/ query, f state, x clears)."
            },
            p.dim(),
        ));
    } else {
        // The header is at `out.len()`, row i one line under it, the fold two under the last.
        let head = out.len();
        let total = head + 1 + rows.len() + 1 + more.len();
        let on_screen = |i: usize| match win {
            None => true,
            Some((scroll, h)) => {
                let top = scroll.min(total.saturating_sub(h));
                let line = head + 1 + i;
                (top..top + h).contains(&line) || i.abs_diff(v.table.sel) <= h + 2
            }
        };
        let kept: Vec<QueueRow> = rows
            .iter()
            .enumerate()
            .filter(|(i, _)| on_screen(*i))
            .map(|(_, r)| *r)
            .collect();
        let mut fitted = table(&kept, v, p, w).into_iter();
        let mut t: Vec<Line<'static>> = fitted.next().into_iter().collect();
        t.extend((0..rows.len()).map(|i| {
            if on_screen(i) {
                fitted.next().unwrap_or_default()
            } else {
                Line::default()
            }
        }));
        at_line = v.table.style(&mut t, p).map(|i| out.len() + i);
        out.append(&mut t);
    }
    out.push(Line::raw(""));
    let top = out.len();
    out.extend(more);
    (out, at_line.or(cand_at.map(|a| a + top)))
}

/// The Candidates fold: its heading counts every ranked row and how many a worker takes; open,
/// it lists the first `CANDIDATES_SHOWN` in rank order and says how many more there are.
fn candidates(
    above: usize,
    v: &QueueView,
    cands: Option<&Result<Candidates, String>>,
    p: Palette,
    w: usize,
) -> (Vec<Line<'static>>, Option<usize>) {
    let mark = if v.cands_open { "-" } else { "+" };
    let hint = if v.cands_open {
        "C folds, p promotes"
    } else {
        "C opens"
    };
    let (count, hint) = match cands {
        None => (String::new(), "reading".to_string()),
        Some(Err(_)) => (String::new(), String::new()),
        Some(Ok(c)) => (
            format!(" ({}, {} auto)", c.total, c.auto),
            match c.as_of(chrono::Local::now()).as_str() {
                "" => hint.into(),
                t => format!("as of {t}  {hint}"),
            },
        ),
    };
    let mut out = vec![clip_line(
        heading(
            &format!("{mark} CANDIDATES{count}"),
            format!("  {hint}").trim_end().into(),
            p,
        ),
        w,
    )];
    let c = match cands {
        Some(Err(e)) => {
            out.push(clip_line(
                Line::styled(format!("No candidates: {e}"), p.warn()),
                w,
            ));
            return (out, None);
        }
        Some(Ok(c)) if v.cands_open => c,
        _ => return (out, None),
    };
    let shown = v.shown_cands(&c.rows);
    if shown.is_empty() {
        out.push(Line::styled("No open board row to start.", p.dim()));
        return (out, None);
    }
    let rows = shown
        .iter()
        .enumerate()
        .map(|(i, c)| {
            let style = if c.held {
                p.warn()
            } else if c.auto {
                p.good()
            } else {
                Default::default()
            };
            vec![
                cell(format!("{}", i + 1), Default::default()),
                c.project.clone().into(),
                c.key.clone().into(),
                c.title().into(),
                cell(c.start_label(), style),
                c.why_line().into(),
            ]
        })
        .collect();
    let mut t = Table {
        mark: None,
        header: vec!["#", "PROJECT", "KEY", "TASK", "START", "WHY"],
        rows,
        // The why never hides: project, then key, give way first.
        keep: vec![0, 4, 3, 2, 1],
        flex: Some(5),
        flexmin: 24,
        flexkeep: true,
        right: vec![0],
        cap: vec![(1, 22), (2, 16), (3, 40)],
    }
    .fit(w, p.head());
    let mut sel_at = None;
    if let Some(at) = v.table.sel.checked_sub(above).filter(|i| *i < shown.len()) {
        t[at + 1].style = p.sel();
        sel_at = Some(out.len() + at + 1);
    }
    out.append(&mut t);
    if c.more() > 0 {
        out.push(Line::styled(format!("+{} more", c.more()), p.dim()));
    }
    if !c.reasons.is_empty() {
        let by: Vec<String> = c.reasons.iter().map(|(r, n)| format!("{r} {n}")).collect();
        out.push(clip_line(
            Line::styled(format!("blocked: {}", by.join(", ")), p.dim()),
            w,
        ));
    }
    if !c.uncovered.is_empty() {
        out.push(clip_line(
            Line::styled(
                format!("worked on today, no worker: {}", c.uncovered.join(", ")),
                p.warn(),
            ),
            w,
        ));
    }
    (out, sel_at)
}

fn status_line(v: &QueueView, p: Palette, w: usize) -> Line<'static> {
    let l = if let Some(s) = &v.confirm {
        Line::styled(
            format!("Cancel {s}? agent-queue moves it to done and kills a session it started.  y/Enter yes  n/Esc no"),
            p.warn(),
        )
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
    use hub_core::queue::Stats;
    use hub_core::table::Row;

    pub fn fixture() -> Queue {
        let jsonl = concat!(
            r#"{"slug":"pick-sides","project":"game","mode":"plan","weight":"heavy","priority":"high","queued":"2026-11-03T10:00:00Z","started":"2026-11-03T10:05:00Z","session":"lab:game-agent-2","state":"waiting","task":"Pick a side\nmore"}"#,
            "\n",
            r#"{"slug":"fix-menu","project":"game","mode":"oneshot","priority":"high","queued":"2026-11-03T10:10:00Z","started":"2026-11-03T10:20:00Z","session":"lab:game-agent-3","state":"running","task":"Fix the menu"}"#,
            "\n",
            // agent-queue's own order: priority, then queued.
            r#"{"slug":"next-up","project":"dotfiles","mode":"oneshot","priority":"urgent","queued":"2026-11-03T11:30:00Z","state":"queued","task":"Next"}"#,
            "\n",
            r#"{"slug":"night-sweep","project":"dotfiles","mode":"oneshot","priority":"low","tags":"night","queued":"2026-11-03T11:00:00Z","state":"queued","hold":"night (01:00-06:00)","task":"Sweep"}"#,
            "\n",
            r#"{"slug":"landed","project":"dotfiles","mode":"oneshot","priority":"high","state":"done","status":"ok","pr":"812","finished":"2026-11-03T12:00:00Z","task":"Landed"}"#,
            "\n",
        );
        Queue {
            items: hub_core::queue::parse(jsonl),
            stats: Some(Stats {
                since: "2026-10-27".into(),
                done: [("ok".to_string(), 3), ("cancelled".to_string(), 1)].into(),
                wait_minutes_median: Some(12),
                to_pr_minutes_median: Some(95),
                ..Default::default()
            }),
            dispatch: Some(hub_core::capacity::Dispatch {
                held: Some("load 31.31 on 24 cores is over the 0.9 pace".into()),
                runnable: 1,
                ..Default::default()
            }),
            errors: vec![],
        }
    }

    /// Three hours after the fixture's first item was queued: its running rows have run 2h55 and 2h40.
    fn now() -> i64 {
        chrono::DateTime::parse_from_rfc3339("2026-11-03T13:00:00Z")
            .unwrap()
            .timestamp()
    }

    fn text(q: &Queue, v: &QueueView, w: usize) -> String {
        text_with(q, v, None, w)
    }

    fn text_with(
        q: &Queue,
        v: &QueueView,
        c: Option<&Result<Candidates, String>>,
        w: usize,
    ) -> String {
        page(
            q,
            v,
            c,
            (&Rail::build(Some(q), None, now()), false),
            Palette { no_color: true },
            now(),
            w,
            None,
        )
        .0
        .iter()
        .map(plain)
        .collect::<Vec<_>>()
        .join("\n")
    }

    /// Three ranked rows: an auto one with a verdict, a held auto one, a human-lane manual one.
    pub fn cands() -> Candidates {
        hub_core::queue::parse_candidates(concat!(
            r##"{"profile":"bnb","project":"shape-city","lane":"agent","key":"bar-17","text":"- [ ] fix the jump arc #high <!-- id:bar-17 -->","why":"focus project, due today, #high, beta","auto":true,"verdict":"dispatch","held":false}"##,
            "\n",
            r##"{"profile":"bnb","project":"unity-core-playground","lane":"agent","key":"ucp-408","text":"- [ ] fix(cutscene): smooth the blend #requested <!-- id:ucp-408 -->","why":"requested, #high, beta, 5d old","auto":true,"verdict":"unjudged","held":true,"area":"unity"}"##,
            "\n",
            r##"{"profile":"personal","project":"trader","lane":"human","key":"tr-41","text":"- [ ] backtest report <!-- id:tr-41 -->","why":"#high, alpha, 9d old","auto":false,"verdict":"unjudged","held":false}"##,
            "\n",
        ))
    }

    fn key(c: char) -> KeyEvent {
        KeyEvent::from(KeyCode::Char(c))
    }

    /// One key on the view, with no candidates unless given.
    fn press(v: &mut QueueView, q: &Queue, c: &[Candidate], ch: char) -> Ask {
        v.key(key(ch), Some(q), c, 10, now())
    }

    /// The view on the `all` chip: the default `active` hides done rows.
    fn all() -> QueueView {
        let mut v = QueueView::default();
        v.table.view.state = "all".into();
        v
    }

    fn slugs(v: &QueueView, q: &Queue) -> Vec<String> {
        v.shown(q, now())
            .iter()
            .map(|r| r.item.slug.clone())
            .collect()
    }

    /// The first line of `s` that has `what` in it.
    fn line<'a>(s: &'a str, what: &str) -> &'a str {
        s.lines()
            .find(|l| l.contains(what))
            .unwrap_or_else(|| panic!("{what} missing from\n{s}"))
    }

    #[test]
    fn the_table_opens_exceptions_first_with_every_column() {
        let q = fixture();
        let s = text(&q, &all(), 160);
        let header = line(&s, "STATE");
        assert_eq!(
            header.split_whitespace().collect::<Vec<_>>(),
            HEADER,
            "columns in order"
        );
        // The sort mark is an index into hub-core's columns, so the header is them in capitals.
        let core: Vec<String> = QueueRow::COLUMNS.iter().map(|c| c.to_uppercase()).collect();
        assert_eq!(HEADER.to_vec(), core);
        let order = ["Pick a side", "Fix the menu", "Next", "Sweep", "Landed"];
        let pos: Vec<usize> = order.iter().map(|t| s.find(t).unwrap()).collect();
        assert!(pos.windows(2).all(|w| w[0] < w[1]), "{s}");
        // A waiting row: needs you, in its state for 2h55 (since started), no PR.
        let waiting = line(&s, "Pick a side");
        assert!(
            waiting.contains("needs you") && waiting.contains("2h55"),
            "{waiting}"
        );
        // Running: 2h40 in state and run, the 10m it waited after it could start.
        let running = line(&s, "Fix the menu");
        assert!(
            running.contains("running") && running.contains("2h40") && running.contains("10m"),
            "{running}"
        );
        let held = line(&s, "Sweep");
        assert!(held.contains("held") && held.contains("night"), "{held}");
        assert!(
            !held.trim_start().starts_with('1'),
            "a held item has no start place"
        );
        let next = line(&s, "Next");
        assert!(next.contains("ready") && next.contains("urgent"), "{next}");
        assert!(
            next.trim_start().starts_with("1 "),
            "the first ready item starts first: {next}"
        );
        let done = line(&s, "Landed");
        assert!(done.contains("ok") && done.contains("#812"), "{done}");
        assert!(
            s.contains(
                "active 4  needs you 1  running 1  on a PR 0  ready 1  held 1  done 1  all 5    5 of 5"
            ),
            "{s}"
        );
        assert!(
            s.contains("Dispatch held: load 31.31 on 24 cores is over the 0.9 pace. It could start 0 of 1 runnable."),
            "{s}"
        );
        let open = text(&q, &QueueView::default(), 160);
        assert!(
            !open.contains("Landed") && open.contains("Sweep"),
            "it opens on active work, done one chip away\n{open}"
        );
        assert!(
            s.contains("4 done (3 ok, 0 failed, 1 cancelled)") && s.contains("to PR median 95m"),
            "{s}"
        );
        let empty = text(&Queue::default(), &QueueView::default(), 120);
        assert!(empty.contains("Nothing in the queue."), "{empty}");
    }

    #[test]
    fn the_dispatch_line_is_amber_when_held_and_dim_when_running() {
        let p = Palette { no_color: false };
        let fg = |q: &Queue| {
            let lines = page(
                q,
                &all(),
                None,
                (&Rail::build(Some(q), None, now()), false),
                p,
                now(),
                160,
                None,
            )
            .0;
            let l = lines
                .iter()
                .find(|l| plain(l).starts_with("Dispatch "))
                .expect("a dispatch line");
            l.style.patch(l.spans[0].style).fg
        };
        let mut q = fixture();
        assert_eq!(fg(&q), p.warn().fg, "held reads amber");
        // NEGATIVE CONTROL: a running dispatch is dim, not amber.
        q.dispatch = Some(hub_core::capacity::Dispatch {
            could_start: 2,
            runnable: 3,
            ..Default::default()
        });
        assert_eq!(fg(&q), p.dim().fg);
        assert_ne!(p.dim().fg, p.warn().fg);
    }

    #[test]
    fn at_80_columns_the_columns_drop_by_priority_and_the_title_stays() {
        let mut q = fixture();
        q.items.extend(hub_core::queue::parse(concat!(
            r#"{"slug":"wide","project":"unity-core-playground","type":"feat","size":"m","account":"claude-lazer","queued":"2026-11-03T12:00:00Z","state":"done","status":"ok","pr":"owner/repo#1234","finished":"2026-11-03T12:30:00Z","task":"Wide row"}"#,
            "\n",
        )));
        let heads = |w: usize| -> Vec<String> {
            let s = text(&q, &all(), w);
            line(&s, "STATE")
                .split_whitespace()
                .map(String::from)
                .collect()
        };
        assert_eq!(
            heads(160),
            [
                "#", "TITLE", "PROJECT", "PRIORITY", "STATE", "HOLD", "FROM", "IN", "WAIT", "RUN",
                "PR", "ROW", "KIND", "SIZE", "ACCT", "MODE", "PLAN"
            ]
        );
        // PLAN, MODE, ACCT, SIZE and KIND give way first (then WAIT, ROW, FROM, RUN, PR, IN, HOLD); STATE and TITLE never do.
        assert_eq!(
            heads(80),
            ["#", "TITLE", "PROJECT", "PRIORITY", "STATE", "HOLD", "IN"],
            "{}",
            text(&q, &all(), 80)
        );
        let s = text(&q, &all(), 80);
        assert!(s.lines().all(|l| l.chars().count() <= 80), "{s}");
        let r = line(&s, "Pick a side");
        assert!(
            r.contains("needs you") && r.contains("2h55") && r.contains("game"),
            "{r}"
        );
        assert!(line(&s, "Wide row").contains("unity-core"), "{s}");
        let s = text(&q, &all(), 40);
        assert!(line(&s, "Pick a side").contains("needs you"), "{s}");
        assert!(s.lines().all(|l| l.chars().count() <= 40), "{s}");
    }

    #[test]
    fn f_cycles_the_state_chip_and_the_sort_keys_reorder() {
        let q = fixture();
        let mut v = QueueView::default();
        press(&mut v, &q, &[], 'j');
        press(&mut v, &q, &[], 'j');
        assert_eq!(v.table.sel, 2);
        let want: [(&str, &[&str]); 8] = [
            ("needs you", &["pick-sides"]),
            ("running", &["fix-menu"]),
            ("on a PR", &[]),
            ("ready", &["next-up"]),
            ("held", &["night-sweep"]),
            ("done", &["landed"]),
            (
                "all",
                &["pick-sides", "fix-menu", "next-up", "night-sweep", "landed"],
            ),
            ("", &["pick-sides", "fix-menu", "next-up", "night-sweep"]),
        ];
        for (chip, slugs_in) in want {
            assert_eq!(press(&mut v, &q, &[], 'f'), Ask::Done);
            assert_eq!(v.table.view.state, chip);
            assert_eq!(slugs(&v, &q), slugs_in, "{chip}");
            assert_eq!(v.table.sel, 0, "a changed view starts at the top");
        }
        // s sorts by the next column, S flips it: by `in` the longest-waiting row goes last.
        press(&mut v, &q, &[], 's');
        assert_eq!(v.table.view.sort, "#");
        assert_eq!(
            slugs(&v, &q)[0],
            "next-up",
            "by # the item that starts next comes first"
        );
        press(&mut v, &q, &[], 'x');
        assert!(v.table.is_default());
        v.table.view.state = "all".into();
        while v.table.view.sort != "in" {
            press(&mut v, &q, &[], 's');
            assert!(!v.table.view.sort.is_empty(), "s reaches the in column");
        }
        assert_eq!(
            slugs(&v, &q),
            ["pick-sides", "fix-menu", "night-sweep", "next-up", "landed"],
            "the longest in its state first, the done row (no time) last"
        );
        assert_eq!(press(&mut v, &q, &[], 'S'), Ask::Done);
        assert_eq!(
            slugs(&v, &q),
            ["next-up", "night-sweep", "fix-menu", "pick-sides", "landed"],
            "S flips it"
        );
    }

    #[test]
    fn l_marks_each_record_an_opened_item_names_and_enter_opens_it() {
        use hub_core::links::{Kind, Link};
        let q = fixture();
        let mut v = QueueView::default();
        assert_eq!(v.selected(&q, now()).unwrap().slug, "pick-sides");
        assert_eq!(
            press(&mut v, &q, &[], 'l'),
            Ask::Pass,
            "a closed row has no links to mark"
        );
        v.key(KeyEvent::from(KeyCode::Enter), Some(&q), &[], 10, now());
        assert!(v.detail);
        let s = text(&q, &v, 160);
        assert!(s.contains("opens (l marks, Enter opens)"), "{s}");
        assert!(s.contains("  session  lab:game-agent-2"), "{s}");
        press(&mut v, &q, &[], 'l');
        assert!(text(&q, &v, 160).contains("> session  lab:game-agent-2"));
        press(&mut v, &q, &[], 'l');
        assert_eq!(
            v.key(KeyEvent::from(KeyCode::Enter), Some(&q), &[], 10, now()),
            Ask::Follow(Link::to(Kind::Project, "game"))
        );
        assert!(
            v.detail && v.link.is_none(),
            "the detail stays, the mark goes"
        );
        v.key(KeyEvent::from(KeyCode::Enter), Some(&q), &[], 10, now());
        assert!(
            !v.detail,
            "Enter with nothing marked closes the detail as before"
        );
        v.key(KeyEvent::from(KeyCode::Enter), Some(&q), &[], 10, now());
        press(&mut v, &q, &[], 'l');
        // A refresh that puts another item under the selection: its mark is not this item's.
        v.link.as_mut().unwrap().0 = "another-item".into();
        assert!(!text(&q, &v, 160).contains("> session"));
        v.key(KeyEvent::from(KeyCode::Enter), Some(&q), &[], 10, now());
        assert!(!v.detail, "Enter follows no other item's mark");
    }

    #[test]
    fn a_done_row_is_selectable_but_cancel_and_priority_refuse_it() {
        let q = fixture();
        let mut v = all();
        press(&mut v, &q, &[], 'G');
        assert_eq!(v.selected(&q, now()).unwrap().slug, "landed");
        for ch in ['c', '+', '-'] {
            assert_eq!(press(&mut v, &q, &[], ch), Ask::Done);
            assert!(
                matches!(&v.said, Some(Err(e)) if e == "landed is done"),
                "{ch}: {:?}",
                v.said
            );
            assert!(v.confirm.is_none());
        }
        // NEGATIVE CONTROL: the same key on an active row acts.
        press(&mut v, &q, &[], 'k');
        press(&mut v, &q, &[], 'k');
        assert_eq!(v.selected(&q, now()).unwrap().slug, "next-up");
        assert!(matches!(press(&mut v, &q, &[], '-'), Ask::Bump(..)));
    }

    #[test]
    fn slash_searches_with_a_project_token_and_enter_applies_it() {
        let q = fixture();
        let mut v = QueueView::default();
        press(&mut v, &q, &[], 'j');
        press(&mut v, &q, &[], '/');
        for ch in "project:dotfiles".chars() {
            assert_eq!(
                press(&mut v, &q, &[], ch),
                Ask::Done,
                "typed into the query"
            );
        }
        assert_eq!(slugs(&v, &q).len(), 4, "nothing applies before Enter");
        assert!(text(&q, &v, 160).contains("| /project:dotfiles_"));
        assert_eq!(
            v.key(KeyEvent::from(KeyCode::Enter), Some(&q), &[], 10, now()),
            Ask::Done
        );
        assert_eq!(slugs(&v, &q), ["next-up", "night-sweep"]);
        assert_eq!(v.table.sel, 0);
        let s = text(&q, &v, 160);
        assert!(
            s.contains("2 of 5") && s.contains("| /project:dotfiles"),
            "{s}"
        );
        assert!(!s.contains("Pick a side"), "{s}");
        // A word searches the slug and tags too: `night` finds night-sweep by its tag.
        v.table.view.q = "night".into();
        assert_eq!(slugs(&v, &q), ["night-sweep"]);
        // Esc clears the view; with it clear Esc is the app's.
        let esc = || KeyEvent::from(KeyCode::Esc);
        assert_eq!(v.key(esc(), Some(&q), &[], 10, now()), Ask::Done);
        assert!(v.table.is_default());
        assert_eq!(v.key(esc(), Some(&q), &[], 10, now()), Ask::Pass);
        v.table.view.q = "zzz".into();
        assert!(text(&q, &v, 160).contains("No item matches"));
    }

    #[test]
    fn an_old_section_id_opens_the_table_on_its_chip_and_other_words_search() {
        let q = fixture();
        for (old, chip, n) in [
            ("waiting", "needs you", 1),
            ("running", "running", 1),
            ("queued", "ready", 1),
            ("done", "done", 1),
        ] {
            let mut v = QueueView::default();
            v.open(old);
            assert_eq!(v.table.view.state, chip, "{old}");
            assert!(v.table.view.q.is_empty());
            assert_eq!(slugs(&v, &q).len(), n, "{old}");
        }
        let mut v = QueueView::default();
        v.open("Running");
        assert_eq!(v.table.view.state, "running", "case does not matter");
        v.open("landed");
        assert_eq!(v.table.view.q, "landed");
        assert_eq!(
            slugs(&v, &q),
            ["landed"],
            "a slug finds its item, done ones too"
        );
        v.open("Running");
        v.open("project:game");
        assert_eq!(v.table.view.q, "project:game");
        assert_eq!(
            v.table.view.state, "all",
            "a new request starts from the table's own view, over every row"
        );
        v.open("candidates");
        assert!(v.cands_open && v.table.is_default());
        v.open("table");
        assert!(v.table.is_default());
        v.open("  ");
        assert!(v.table.is_default());
    }

    #[test]
    fn enter_opens_the_detail_with_every_header_and_the_timeline_in_minutes() {
        let mut q = fixture();
        q.items.extend(hub_core::queue::parse(concat!(
            r#"{"slug":"shipped","project":"dotfiles","mode":"oneshot","weight":"heavy","priority":"high","type":"feat","size":"m","account":"a2","model":"opus","tags":"night","queued":"2026-11-03T08:00:00Z","ready":"2026-11-03T08:10:00Z","started":"2026-11-03T08:25:00Z","waiting":"2026-11-03T09:00:00Z","finished":"2026-11-03T09:30:00Z","state":"done","status":"ok","pr":"o/r#7","merged":"abcdef1234567","cost_usd":"6.10","task":"feat(x): Ship it\nthe body"}"#,
            "\n",
        )));
        let mut v = all();
        v.table.view.q = "shipped".into();
        assert_eq!(
            v.key(KeyEvent::from(KeyCode::Enter), Some(&q), &[], 10, now()),
            Ask::Done
        );
        assert!(v.detail);
        let s = text(&q, &v, 100);
        for want in [
            "shipped",
            "done (ok)",
            "oneshot heavy",
            "dotfiles",
            "feat",
            "a2",
            "opus",
            "night",
            "PR r#7 merged",
            "$6.10",
            "in -  wait 15m  run 1h05  lead 1h30",
            "log: notes log --item shipped",
        ] {
            assert!(s.contains(want), "{want} missing from\n{s}");
        }
        let at = |h: &str| s.find(h).unwrap_or_else(|| panic!("{h}\n{s}"));
        let order = [
            "queued ",
            "ready ",
            "started ",
            "waiting ",
            "finished ",
            "merged ",
        ];
        let pos: Vec<usize> = order.iter().map(|h| at(&format!("\n{h}")) + 1).collect();
        assert!(pos.windows(2).all(|w| w[0] < w[1]), "{s}");
        // Gaps are minutes from the step before: ready +10m, started +15m, waiting +35m, finished +30m.
        for (stage, gap) in [
            ("ready", "+10m"),
            ("started", "+15m"),
            ("waiting", "+35m"),
            ("finished", "+30m"),
        ] {
            let row = s.lines().find(|l| l.starts_with(&format!("{stage} ")));
            assert!(row.is_some_and(|l| l.contains(gap)), "{stage}\n{s}");
        }
        assert!(line(&s, "merged ").contains("abcdef1234"), "{s}");
        assert!(!s.contains("STATE "), "the detail replaces the table\n{s}");
        // Esc closes the detail first, and the query stays.
        let esc = || KeyEvent::from(KeyCode::Esc);
        assert_eq!(v.key(esc(), Some(&q), &[], 10, now()), Ask::Done);
        assert!(!v.detail && v.table.view.q == "shipped");
        assert!(text(&q, &v, 100).contains("STATE"));
    }

    #[test]
    fn a_done_row_shows_its_pr_in_the_column_and_flags_a_finish_with_no_proof() {
        let mut q = fixture();
        q.items.extend(hub_core::queue::parse(concat!(
            r#"{"slug":"merged-one","project":"dotfiles","state":"done","status":"ok","pr":"o/r#7","merged":"abc","cost_usd":"6.10","finished":"2026-11-03T12:00:00Z","task":"Merged one"}"#,
            "\n",
            r#"{"slug":"nothing-shown","project":"dotfiles","state":"done","status":"ok","cost_usd":"0","finished":"2026-11-03T12:00:00Z","task":"Nothing shown"}"#,
            "\n",
            r#"{"slug":"broke","project":"dotfiles","state":"done","status":"failed","finished":"2026-11-03T12:00:00Z","task":"Broke"}"#,
            "\n",
        )));
        let s = text(&q, &all(), 200);
        assert!(line(&s, "Merged one").contains("r#7"), "{s}");
        assert!(line(&s, "Nothing shown").contains("! none"), "{s}");
        assert!(line(&s, "Broke").contains("failed"), "{s}");
        let mut v = all();
        v.table.view.q = "merged-one".into();
        v.key(KeyEvent::from(KeyCode::Enter), Some(&q), &[], 10, now());
        let s = text(&q, &v, 200);
        assert!(s.contains("PR r#7 merged") && s.contains("$6.10"), "{s}");
    }

    #[test]
    fn every_row_the_view_keeps_is_drawn_and_a_frame_formats_one_screen() {
        let n = 200;
        let jsonl: Vec<String> = (0..n)
            .map(|i| {
                format!(
                    r#"{{"slug":"d-{i}","project":"p","state":"done","status":"ok","finished":"2026-11-03T{:02}:{:02}:00Z","task":"T{i}"}}"#,
                    i / 60 % 24,
                    i % 60
                )
            })
            .collect();
        let q = Queue {
            items: hub_core::queue::parse(&jsonl.join("\n")),
            ..Default::default()
        };
        let v = all();
        assert_eq!(v.shown(&q, now()).len(), n);
        let s = text(&q, &v, 120);
        assert!(!s.contains("older"), "{s}");
        assert!(
            s.contains(&format!("{n} of {n}")) && s.contains(&format!("done {n}")),
            "{s}"
        );
        let frame = |v: &QueueView, win| {
            page(
                &q,
                v,
                None,
                (&Rail::build(Some(&q), None, now()), false),
                Palette { no_color: true },
                now(),
                120,
                win,
            )
        };
        let row = |l: &Line| plain(l).contains(" T");
        let (every, _) = frame(&v, None);
        let (top, at) = frame(&v, Some((0, 20)));
        assert_eq!(
            top.len(),
            every.len(),
            "the same lines, so the scroll means the same"
        );
        let formatted = top.iter().filter(|l| row(l)).count();
        assert!(formatted < 50, "one screen of rows, not {n}: {formatted}");
        let at = at.unwrap();
        assert_eq!(
            plain(&top[at]),
            plain(&every[at]),
            "the selected row is drawn"
        );
        let mut far = all();
        for _ in 0..150 {
            far.key(KeyEvent::from(KeyCode::Char('j')), Some(&q), &[], 20, now());
        }
        let (l, at) = frame(&far, Some((0, 20)));
        let at = at.unwrap();
        assert!(row(&l[at]), "a row far down is drawn once selected");
        assert_eq!(plain(&l[at]), plain(&every[at]));
    }

    #[test]
    fn cancel_waits_on_y_and_bump_steps_the_selected_item() {
        let q = fixture();
        let mut v = all();
        assert_eq!(v.selected(&q, now()).unwrap().slug, "pick-sides");
        assert_eq!(press(&mut v, &q, &[], 'c'), Ask::Done);
        assert_eq!(v.confirm.as_deref(), Some("pick-sides"));
        assert!(text(&q, &v, 200).contains("Cancel pick-sides?"));
        assert_eq!(press(&mut v, &q, &[], 'n'), Ask::Done, "n drops it");
        assert!(v.confirm.is_none());
        press(&mut v, &q, &[], 'c');
        assert_eq!(
            press(&mut v, &q, &[], 'y'),
            Ask::Cancel("pick-sides".into())
        );

        assert_eq!(
            press(&mut v, &q, &[], '+'),
            Ask::Bump("pick-sides".into(), "urgent")
        );
        for _ in 0..3 {
            press(&mut v, &q, &[], 'j');
        }
        let at = |v: &QueueView| v.selected(&q, now()).unwrap().slug.clone();
        assert_eq!(at(&v), "night-sweep");
        assert_eq!(press(&mut v, &q, &[], '-'), Ask::Done);
        assert!(
            matches!(&v.said, Some(Err(e)) if e.contains("already low")),
            "{:?}",
            v.said
        );
        assert_eq!(
            press(&mut v, &q, &[], '+'),
            Ask::Bump("night-sweep".into(), "high")
        );
        press(&mut v, &q, &[], 'k');
        assert_eq!(at(&v), "next-up");
        assert_eq!(press(&mut v, &q, &[], '+'), Ask::Done);
        assert!(
            matches!(&v.said, Some(Err(e)) if e.contains("already urgent")),
            "{:?}",
            v.said
        );
        assert_eq!(
            press(&mut v, &q, &[], '-'),
            Ask::Bump("next-up".into(), "high")
        );

        v.running = Some("cancel x".into());
        press(&mut v, &q, &[], 'c');
        assert!(v.confirm.is_none(), "no second action while one runs");
        assert_eq!(press(&mut v, &q, &[], 'o'), Ask::Pass);
        for _ in 0..10 {
            press(&mut v, &q, &[], 'j');
        }
        assert_eq!(at(&v), "landed", "j stops at the last row, a done one");
    }

    #[test]
    fn a_new_read_keeps_the_selection_on_its_slug() {
        let q = fixture();
        let mut v = all();
        v.table.sel = 2;
        assert_eq!(v.selected(&q, now()).unwrap().slug, "next-up");
        let mut fewer = fixture();
        fewer.items.retain(|i| i.slug != "pick-sides");
        v.reselect(Some("next-up".into()), &fewer, &[], now());
        assert_eq!(v.selected(&fewer, now()).unwrap().slug, "next-up");
        v.reselect(Some("landed".into()), &fewer, &[], now());
        assert_eq!(
            v.selected(&fewer, now()).unwrap().slug,
            "landed",
            "a done row keeps its place too"
        );
        v.reselect(Some("gone".into()), &Queue::default(), &[], now());
        assert_eq!(v.table.sel, 0);
    }

    #[test]
    fn candidates_start_open_and_c_folds_them_to_their_counts_below_the_queue() {
        let q = fixture();
        let c = Ok(cands());
        assert!(
            text_with(&q, &QueueView::default(), Some(&c), 200).contains("bar-17"),
            "the candidates start open"
        );
        let shut = QueueView {
            cands_open: false,
            ..QueueView::default()
        };
        let s = text_with(&q, &shut, Some(&c), 200);
        assert!(s.contains("+ CANDIDATES (3, 2 auto)  C opens"), "{s}");
        assert!(
            s.find("Sweep").unwrap() < s.find("CANDIDATES").unwrap(),
            "below the queue\n{s}"
        );
        assert!(!s.contains("bar-17"), "no row shows while folded\n{s}");
        assert!(text(&q, &shut, 200).contains("+ CANDIDATES  reading"));
        let err = Err("no snapshot yet, the next dispatch pass writes one".to_string());
        assert!(text_with(&q, &QueueView::default(), Some(&err), 200)
            .contains("No candidates: no snapshot yet, the next dispatch pass writes one"));
        let mut stamped = cands();
        let today = chrono::Local::now()
            .date_naive()
            .and_hms_opt(8, 7, 0)
            .unwrap();
        stamped.written = Some(today.and_local_timezone(chrono::Local).unwrap().into());
        let s = text_with(&q, &shut, Some(&Ok(stamped)), 200);
        assert!(
            s.contains("+ CANDIDATES (3, 2 auto)  as of 08:07  C opens"),
            "{s}"
        );
    }

    #[test]
    fn open_candidates_list_ranked_rows_with_auto_or_man_and_held() {
        let q = fixture();
        let c = Ok(cands());
        let v = QueueView::default();
        let s = text_with(&q, &v, Some(&c), 200);
        assert!(
            s.contains("- CANDIDATES (3, 2 auto)  C folds, p promotes"),
            "{s}"
        );
        let (a, b, m) = (line(&s, "bar-17"), line(&s, "ucp-408"), line(&s, "tr-41"));
        assert!(
            a.trim_start().starts_with("1 ") && b.trim_start().starts_with("2 "),
            "{s}"
        );
        assert!(
            a.contains("fix the jump arc") && !a.contains("<!--") && !a.contains("#high  "),
            "{a}"
        );
        assert!(
            a.contains("auto dispatch") && a.contains("focus project, due today"),
            "{a}"
        );
        assert!(b.contains("auto held") && !b.contains("unjudged"), "{b}");
        assert!(m.contains("man ") && !m.contains("held"), "{m}");

        let many: Vec<String> = (0..hub_core::queue::CANDIDATES_SHOWN + 5)
            .map(|i| format!(r#"{{"key":"k-{i}"}}"#))
            .collect();
        let many = hub_core::queue::parse_candidates(&many.join("\n"));
        let s = text_with(&q, &v, Some(&Ok(many)), 200);
        assert!(
            s.contains("CANDIDATES (35, 0 auto)") && s.contains("+5 more"),
            "{s}"
        );
        assert!(s.contains("k-29") && !s.contains("k-30"), "{s}");
    }

    #[test]
    fn p_promotes_the_selected_candidate_through_the_boards_start() {
        let q = fixture();
        let c = cands().rows;
        let mut v = QueueView::default();
        press(&mut v, &q, &c, 'C');
        assert_eq!(
            press(&mut v, &q, &c, 'p'),
            Ask::Done,
            "shut: nothing to promote"
        );
        assert!(
            matches!(&v.said, Some(Err(e)) if e.contains("C opens")),
            "{:?}",
            v.said
        );
        press(&mut v, &q, &c, 'C');
        for _ in 0..4 {
            press(&mut v, &q, &c, 'j');
        }
        assert_eq!(
            v.selected_cand(&q, &c, now()).unwrap().key,
            "bar-17",
            "j runs on past the rows"
        );
        assert!(text_with(&q, &v, Some(&Ok(cands())), 200).contains("fix the jump arc"));
        let Ask::Promote(label, w) = press(&mut v, &q, &c, 'p') else {
            panic!("p promotes")
        };
        assert_eq!(label, "promote shape-city bar-17");
        assert_eq!(
            hub_core::tasks::argv(&w).unwrap(),
            [
                "fleet-dispatch",
                "promote",
                "--project",
                "shape-city",
                "--profile",
                "bnb",
                "--agent",
                "--raw",
                "- [ ] fix the jump arc #high <!-- id:bar-17 -->"
            ]
        );
        // NEGATIVE CONTROL: the human-lane row is promoted with no --agent.
        press(&mut v, &q, &c, 'j');
        press(&mut v, &q, &c, 'j');
        let Ask::Promote(_, w) = press(&mut v, &q, &c, 'p') else {
            panic!("p promotes")
        };
        let argv = hub_core::tasks::argv(&w).unwrap();
        assert!(argv.contains(&"trader".to_string()), "{argv:?}");
        assert!(!argv.contains(&"--agent".to_string()), "{argv:?}");
        assert_eq!(press(&mut v, &q, &c, 'c'), Ask::Done);
        assert!(v.confirm.is_none(), "c does not cancel a candidate");

        press(&mut v, &q, &c, 'C');
        assert_eq!(
            v.table.sel, 3,
            "folding brings the selection back to the rows"
        );
        v.running = Some("promote x".into());
        press(&mut v, &q, &c, 'C');
        assert_eq!(
            press(&mut v, &q, &c, 'p'),
            Ask::Done,
            "no second action while one runs"
        );
    }
}
