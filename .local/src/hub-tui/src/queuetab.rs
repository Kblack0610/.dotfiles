//! The Queue tab: agent-queue's items as one table on the shared data-table component, the
//! Infra Jobs style, read through `hub_core::queue`, the same reader and the same `QueueRow` as
//! agent-web's Queue tab. The pipeline line (`flow`, `flowline`) leads Active; Left and Right switch
//! the inner tabs (`hub_core::layout`): Active, Up next and Done 24h are the one table in three
//! scopes (`hub_core::queue::scope`), and Candidates is the ranked board rows.
//! `/ f s S x` are the shared table's keys; j/k pick a row (a done one too), Enter opens its
//! detail, where `l` marks each record it names in turn (`Item::links`: session, project, row,
//! each PR and its CI runs) and Enter on a marked one opens it; `c` arms a cancel that waits on y and `+`/`-` move its priority one step, both for an
//! active item only. On Candidates (`hub_core::queue::candidates`, the snapshot each
//! `fleet-dispatch run` writes, `as of` its time, read only while it is open) j/k pick a row and
//! `p` starts it through the Projects tab's Start (`fleet-dispatch promote`). Every write goes
//! through hub-core.

use chrono::{DateTime, Utc};
use hub_core::flow::Rail;
use hub_core::layout;
use hub_core::links::Link;
use hub_core::queue::{
    money, Candidate, Candidates, Item, Queue, QueueRow, State, Timing, TABLE_OPEN_ROWS,
};
use hub_core::tasks::Write;
use ratatui::crossterm::event::{KeyCode, KeyEvent, KeyModifiers};
use ratatui::text::{Line, Span};

use crate::datatable::{DataTable, Took};
use crate::fit::{cell, clip_line, Cell, Table};
use crate::flowline::{self, LineView};
use crate::fmt::{clock, Palette};
use crate::innertabs;

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

#[derive(Default)]
pub struct QueueView {
    /// The shared table's view (query, state chip, sort) and its selection, an index into the
    /// drawn rows, or on Candidates into its rows.
    pub table: DataTable,
    /// The selected row's detail replaces the table.
    pub detail: bool,
    /// The detail's marked link (`l`): the item it was marked on and an index into its `links`;
    /// Enter opens it. A refresh that puts another item under the selection drops the mark.
    pub link: Option<(String, usize)>,
    /// The inner tab asked for (a `layout::Inner` id of Queue); "" lets the view pick
    /// (`hub_core::queue::scope`: the one holding its chip, else its search's, else Active).
    pub inner: &'static str,
    /// The step and problem picked on the pipeline line.
    pub line: LineView,
    /// The slug a cancel waits on y for.
    pub confirm: Option<String>,
    /// The action now running, as "cancel <slug>".
    pub running: Option<String>,
    /// The last action's answer: agent-queue's output, or why it failed.
    pub said: Option<Result<String, String>>,
}

/// One read of the queue scoped for the view: the inner tab shown and the rows it holds.
pub struct Scope<'a> {
    pub on: &'static str,
    pub rows: Vec<QueueRow<'a>>,
}

/// `now` (unix seconds) as the time the rows are measured at.
fn at(now: i64) -> DateTime<Utc> {
    DateTime::from_timestamp(now, 0).unwrap_or_default()
}

/// Queue's layout entry: its pinned pipeline and inner tabs.
pub fn tab() -> &'static layout::Tab {
    layout::resolve("queue").expect("queue is a tab")
}

impl QueueView {
    /// A request for the tab (`hub --tab "queue running"`): an inner tab's id opens it, an old
    /// section id opens the table on its state chip (and so the inner tab holding it), `flow` and
    /// `table` are the page as it is, and any other word is the query. The table starts from its
    /// own view.
    pub fn open(&mut self, query: &str) {
        let q = query.trim();
        self.table.clear();
        self.detail = false;
        self.inner = "";
        match (innertabs::named(tab(), q), hub_core::queue::section_chip(q)) {
            _ if q.is_empty() => {}
            (Some(id), _) => self.inner = id,
            (None, Some(chip)) => self.table.view.state = chip.into(),
            _ if ["flow", "table"].iter().any(|s| q.eq_ignore_ascii_case(s)) => {}
            _ => self.table.view.q = q.into(),
        }
    }

    /// The inner tab shown (the one asked for, else the one the view picks) and the rows it
    /// holds, in the table's own order. A key or a draw works it out once and hands it down.
    pub fn scoped<'a>(&self, q: &'a Queue, now: i64) -> Scope<'a> {
        let (on, rows) =
            hub_core::queue::scope(&q.rows(at(now)), self.inner, &self.table.view, now);
        Scope { on, rows }
    }

    /// The rows the table draws, from the inner tab's: the view applied, then capped at
    /// `TABLE_OPEN_ROWS`; and how many the cap left out.
    fn drawn<'a>(&self, scoped: &[QueueRow<'a>]) -> (Vec<QueueRow<'a>>, usize) {
        let mut rows: Vec<QueueRow<'a>> =
            self.table.view.apply(scoped).into_iter().copied().collect();
        let older = rows.len().saturating_sub(TABLE_OPEN_ROWS);
        rows.truncate(TABLE_OPEN_ROWS);
        (rows, older)
    }

    pub fn shown<'a>(&self, sc: &Scope<'a>) -> Vec<QueueRow<'a>> {
        self.drawn(&sc.rows).0
    }

    pub fn selected<'a>(&self, sc: &Scope<'a>) -> Option<&'a Item> {
        self.shown(sc).get(self.table.sel).map(|r| r.item)
    }

    /// The candidates the page lists: none off their inner tab.
    pub fn shown_cands<'a>(&self, c: &'a [Candidate]) -> &'a [Candidate] {
        if self.inner == "candidates" {
            c
        } else {
            &[]
        }
    }

    /// The candidate selected, past the `rows` table rows drawn above the list.
    pub fn selected_cand<'a>(&self, rows: usize, c: &'a [Candidate]) -> Option<&'a Candidate> {
        let i = self.table.sel.checked_sub(rows)?;
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
    pub fn reselect(&mut self, was: Option<String>, sc: &Scope, c: &[Candidate]) {
        let rows = self.shown(sc);
        let n = rows.len() + self.shown_cands(c).len();
        let at = was.and_then(|s| rows.iter().position(|r| r.item.slug == s));
        self.table.keep(at, n);
    }

    /// `sc` is the queue's scope for this key (`scoped`), None before the first read. `page` is
    /// the body's height in rows: PgUp/PgDn and space move the selection a page, Ctrl-d/Ctrl-u
    /// half of one, g/G to the first and last row. The app keeps the selected row in view, so
    /// every move scrolls the page with it.
    pub fn key(&mut self, k: KeyEvent, sc: Option<&Scope>, c: &[Candidate], page: usize) -> Ask {
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
        let typing = self.table.typing.is_some();
        // Left and Right switch the inner tab, which starts from no chip: the last one's may not
        // be among the new one's.
        if !ctrl && !typing && matches!(k.code, KeyCode::Left | KeyCode::Right) {
            let on = sc.map_or(self.inner, |s| s.on);
            self.inner = innertabs::step(tab(), on, k.code == KeyCode::Left);
            self.table.view.state.clear();
            self.table.sel = 0;
            (self.detail, self.link) = (false, None);
            return Ask::Done;
        }
        // The table hides its empty chips, so `f` steps over the ones the inner tab draws.
        if !ctrl && !typing && k.code == KeyCode::Char('f') {
            if let Some(sc) = sc {
                self.table.view.cycle_shown(&sc.rows);
                (self.table.sel, self.detail, self.link) = (0, false, None);
            }
            return Ask::Done;
        }
        // `/ s S x`, and every key while a query is being typed, are the shared table's.
        if !ctrl && (typing || DataTable::owns(k.code)) {
            if self.table.key::<QueueRow>(k.code) == Took::View {
                (self.detail, self.link) = (false, None);
            }
            return Ask::Done;
        }
        let Some(sc) = sc else { return Ask::Pass };
        let rows = self.shown(sc);
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
            KeyCode::Char('p') => match self.selected_cand(rows.len(), c) {
                _ if self.running.is_some() => self.said = busy(),
                Some(cand) => {
                    self.said = None;
                    return Ask::Promote(
                        format!("promote {} {}", cand.project, cand.key),
                        cand.start(),
                    );
                }
                None if self.inner != "candidates" => {
                    self.said = Some(Err("-> to Candidates, then j/k onto one".into()))
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
        State::Queued if i.hold.is_some() => cell("held", p.warn()),
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

const HEADER: [&str; 11] = [
    "STATE", "IN", "WAIT", "RUN", "PROJECT", "KIND", "SIZE", "ACCT", "PR", "PLAN", "TITLE",
];

fn row(r: &QueueRow, p: Palette) -> Vec<Cell> {
    let i = r.item;
    let pr = match i.pr_link() {
        Some((label, _)) => label.into(),
        None if i.unproven() => cell("! none", p.warn()),
        None => "-".into(),
    };
    let or_dash = |v: &Option<String>| match v.as_deref().map(str::trim) {
        Some(s) if !s.is_empty() => s.to_string(),
        _ => "-".into(),
    };
    let mut title = i.title();
    if let Some(n) = &i.note {
        title = format!("{title}  ({n})");
    }
    vec![
        state(i, p),
        mins(r.timing.in_state).into(),
        mins(r.timing.wait).into(),
        mins(r.timing.run).into(),
        or_dash(&Some(i.project.clone())).into(),
        or_dash(&i.kind).into(),
        or_dash(&i.size).into(),
        or_dash(&i.account).into(),
        pr,
        or_dash(&i.plan_label).into(),
        title.into(),
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
/// ACCT, SIZE, KIND and WAIT go first, then PR, RUN, PROJECT and IN; STATE and TITLE stay.
fn table(rows: &[QueueRow], v: &QueueView, p: Palette, w: usize) -> Vec<Line<'static>> {
    Table {
        header: HEADER.to_vec(),
        rows: rows.iter().map(|r| row(r, p)).collect(),
        keep: vec![0, 1, 4, 3, 8, 2, 5, 6, 7, 9],
        flex: Some(10),
        flexmin: 20,
        flexkeep: true,
        right: vec![1, 2, 3],
        cap: vec![(4, 18), (5, 8), (7, 10), (8, 14), (9, 20)],
        mark: v.table.mark::<QueueRow>(),
    }
    .fit(w, p.head())
}

pub fn page(
    q: &Queue,
    v: &QueueView,
    cands: Option<&Result<Candidates, String>>,
    flow: (&Rail, bool),
    p: Palette,
    now: i64,
    w: usize,
) -> (Vec<Line<'static>>, Option<usize>) {
    let Scope { on, rows: scoped } = v.scoped(q, now);
    // The strip leads: Active amber while an item needs you, Candidates while an urgent row is blocked.
    let needs = q.items.iter().any(|i| i.state == State::Waiting);
    let urgent = matches!(cands, Some(Ok(c)) if c.urgent_blocked > 0);
    let flagged: Vec<&str> = [(needs, "active"), (urgent, "candidates")]
        .into_iter()
        .filter_map(|(f, s)| f.then_some(s))
        .collect();
    let mut out = vec![innertabs::strip(tab(), on, &flagged, p, w)];
    if on == "active" {
        out.extend(flowline::lines(flow.0, &v.line, flow.1, p, w));
    }
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
    out.push(status_line(v, p, w));
    if on == "candidates" {
        out.push(Line::raw(""));
        let top = out.len();
        let (more, cand_at) = candidates(v, cands, p, w);
        out.extend(more);
        return (out, cand_at.map(|a| a + top));
    }
    let (rows, older) = v.drawn(&scoped);
    let mut chips = v.table.status(&scoped, p);
    chips.push(Span::styled(
        format!("    {} of {}", rows.len() + older, scoped.len()),
        p.dim(),
    ));
    out.push(clip_line(Line::from(chips), w));
    out.extend(DataTable::legend::<QueueRow>(p, w));
    let mut at_line = None;
    if let (true, Some(r)) = (v.detail, rows.get(v.table.sel)) {
        out.push(Line::raw(""));
        at_line = Some(out.len());
        out.extend(detail(r.item, r.timing, v.mark(r.item), p, now, w));
    } else if rows.is_empty() {
        out.push(Line::styled(
            if scoped.is_empty() {
                "Nothing here (<- -> the other inner tabs)."
            } else {
                "No item matches (/ query, f state, x clears)."
            },
            p.dim(),
        ));
    } else {
        let mut t = table(&rows, v, p, w);
        at_line = v.table.style(&mut t, p).map(|i| out.len() + i);
        out.append(&mut t);
        if older > 0 {
            out.push(Line::styled(format!("+{older} older"), p.dim()));
        }
    }
    (out, at_line)
}

/// The Candidates inner tab: its heading counts every ranked row and how many a worker takes;
/// it lists the first `CANDIDATES_SHOWN` in rank order and says how many more there are.
fn candidates(
    v: &QueueView,
    cands: Option<&Result<Candidates, String>>,
    p: Palette,
    w: usize,
) -> (Vec<Line<'static>>, Option<usize>) {
    let hint = "p promotes";
    let (count, hint) = match cands {
        None => (String::new(), "reading".to_string()),
        Some(Err(_)) => (String::new(), String::new()),
        Some(Ok(c)) => (
            format!(" ({}, {} auto)", c.total, c.auto),
            match c.as_of.as_str() {
                "" => hint.into(),
                t => format!("as of {t}  {hint}"),
            },
        ),
    };
    let mut out = vec![clip_line(
        heading(
            &format!("CANDIDATES{count}"),
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
        Some(Ok(c)) => c,
        None => return (out, None),
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
    if let Some(at) = Some(v.table.sel).filter(|i| *i < shown.len()) {
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
        hit(v, key(ch), q, c)
    }

    /// One key on the view over `q`, its scope worked out once as the app does.
    fn hit(v: &mut QueueView, k: KeyEvent, q: &Queue, c: &[Candidate]) -> Ask {
        let sc = v.scoped(q, now());
        v.key(k, Some(&sc), c, 10)
    }

    /// A fresh view on one inner tab.
    fn on(inner: &'static str) -> QueueView {
        QueueView {
            inner,
            ..QueueView::default()
        }
    }

    fn slugs(v: &QueueView, q: &Queue) -> Vec<String> {
        v.shown(&v.scoped(q, now()))
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
        let s = text(&q, &QueueView::default(), 160);
        let header = line(&s, "STATE");
        let cols = [
            "STATE", "IN", "WAIT", "RUN", "PROJECT", "KIND", "SIZE", "ACCT", "PR", "PLAN", "TITLE",
        ];
        assert_eq!(
            header.split_whitespace().collect::<Vec<_>>(),
            cols,
            "columns in order"
        );
        // Active opens: the waiting row, then the running one; the rest are on their inner tabs.
        assert!(
            s.find("Pick a side").unwrap() < s.find("Fix the menu").unwrap(),
            "{s}"
        );
        assert!(!s.contains("Next") && !s.contains("Landed"), "{s}");
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
        // The chips count the inner tab's rows, an empty one hidden (on a PR here).
        assert!(s.contains("all 2  needs you 1  running 1    2 of 2"), "{s}");
        let s = text(&q, &on("next"), 160);
        assert!(s.find("Next").unwrap() < s.find("Sweep").unwrap(), "{s}");
        assert!(line(&s, "Sweep").contains("held"));
        assert!(line(&s, "Next").contains("ready"));
        assert!(s.contains("all 2  up next 2    2 of 2"), "{s}");
        let s = text(&q, &on("today"), 160);
        let done = line(&s, "Landed");
        assert!(done.contains("ok") && done.contains("#812"), "{done}");
        assert!(
            s.contains("4 done (3 ok, 0 failed, 1 cancelled)") && s.contains("to PR median 95m"),
            "{s}"
        );
        let empty = text(&Queue::default(), &QueueView::default(), 120);
        assert!(
            empty.contains("Nothing here (<- -> the other inner tabs)."),
            "{empty}"
        );
    }

    #[test]
    fn at_80_columns_the_columns_drop_by_priority_and_the_title_stays() {
        let mut q = fixture();
        q.items.extend(hub_core::queue::parse(concat!(
            r#"{"slug":"wide","project":"unity-core-playground","type":"feat","size":"m","account":"claude-lazer","queued":"2026-11-03T12:00:00Z","state":"review","pr":"owner/repo#1234","started":"2026-11-03T12:10:00Z","task":"Wide row"}"#,
            "\n",
        )));
        let heads = |w: usize| -> Vec<String> {
            let s = text(&q, &QueueView::default(), w);
            line(&s, "STATE")
                .split_whitespace()
                .map(String::from)
                .collect()
        };
        assert_eq!(
            heads(160),
            ["STATE", "IN", "WAIT", "RUN", "PROJECT", "KIND", "SIZE", "ACCT", "PR", "PLAN", "TITLE"]
        );
        // PLAN, ACCT, SIZE and KIND give way first (then WAIT, PR, RUN, PROJECT, IN); STATE and TITLE never do.
        assert_eq!(
            heads(80),
            ["STATE", "IN", "WAIT", "RUN", "PROJECT", "PR", "TITLE"],
            "{}",
            text(&q, &QueueView::default(), 80)
        );
        let s = text(&q, &QueueView::default(), 80);
        assert!(s.lines().all(|l| l.chars().count() <= 80), "{s}");
        let r = line(&s, "Pick a side");
        assert!(
            r.contains("needs you") && r.contains("2h55") && r.contains("game"),
            "{r}"
        );
        assert!(line(&s, "Wide row").contains("repo#1234"), "{s}");
        let s = text(&q, &QueueView::default(), 40);
        assert!(line(&s, "Pick a side").contains("needs you"), "{s}");
        assert!(s.lines().all(|l| l.chars().count() <= 40), "{s}");
    }

    #[test]
    fn f_cycles_the_state_chip_and_the_sort_keys_reorder() {
        let q = fixture();
        let mut v = QueueView::default();
        press(&mut v, &q, &[], 'j');
        assert_eq!(v.table.sel, 1);
        // f steps over the chips Active draws: on a PR has no row, so it is skipped.
        let want: [(&str, &[&str]); 3] = [
            ("needs you", &["pick-sides"]),
            ("running", &["fix-menu"]),
            ("", &["pick-sides", "fix-menu"]),
        ];
        for (chip, slugs_in) in want {
            assert_eq!(press(&mut v, &q, &[], 'f'), Ask::Done);
            assert_eq!(v.table.view.state, chip);
            assert_eq!(slugs(&v, &q), slugs_in, "{chip}");
            assert_eq!(v.table.sel, 0, "a changed view starts at the top");
        }
        // s sorts by the next column, S flips it: by `in` the longest-waiting row goes last.
        press(&mut v, &q, &[], 's');
        assert_eq!(v.table.view.sort, "state");
        assert!(text(&q, &v, 160).contains("STATE ^") || text(&q, &v, 160).contains("STATE v"));
        press(&mut v, &q, &[], 'x');
        assert!(v.table.is_default());
        v.inner = "next";
        press(&mut v, &q, &[], 's');
        press(&mut v, &q, &[], 's');
        assert_eq!(v.table.view.sort, "in");
        assert_eq!(
            slugs(&v, &q),
            ["night-sweep", "next-up"],
            "the longest in its state first"
        );
        assert_eq!(press(&mut v, &q, &[], 'S'), Ask::Done);
        assert_eq!(slugs(&v, &q), ["next-up", "night-sweep"], "S flips it");
    }

    #[test]
    fn l_marks_each_record_an_opened_item_names_and_enter_opens_it() {
        use hub_core::links::{Kind, Link};
        let q = fixture();
        let mut v = QueueView::default();
        assert_eq!(v.selected(&v.scoped(&q, now())).unwrap().slug, "pick-sides");
        assert_eq!(
            press(&mut v, &q, &[], 'l'),
            Ask::Pass,
            "a closed row has no links to mark"
        );
        hit(&mut v, KeyEvent::from(KeyCode::Enter), &q, &[]);
        assert!(v.detail);
        let s = text(&q, &v, 160);
        assert!(s.contains("opens (l marks, Enter opens)"), "{s}");
        assert!(s.contains("  session  lab:game-agent-2"), "{s}");
        press(&mut v, &q, &[], 'l');
        assert!(text(&q, &v, 160).contains("> session  lab:game-agent-2"));
        press(&mut v, &q, &[], 'l');
        assert_eq!(
            hit(&mut v, KeyEvent::from(KeyCode::Enter), &q, &[]),
            Ask::Follow(Link::to(Kind::Project, "game"))
        );
        assert!(
            v.detail && v.link.is_none(),
            "the detail stays, the mark goes"
        );
        hit(&mut v, KeyEvent::from(KeyCode::Enter), &q, &[]);
        assert!(
            !v.detail,
            "Enter with nothing marked closes the detail as before"
        );
        hit(&mut v, KeyEvent::from(KeyCode::Enter), &q, &[]);
        press(&mut v, &q, &[], 'l');
        // A refresh that puts another item under the selection: its mark is not this item's.
        v.link.as_mut().unwrap().0 = "another-item".into();
        assert!(!text(&q, &v, 160).contains("> session"));
        hit(&mut v, KeyEvent::from(KeyCode::Enter), &q, &[]);
        assert!(!v.detail, "Enter follows no other item's mark");
    }

    #[test]
    fn a_done_row_is_selectable_but_cancel_and_priority_refuse_it() {
        let q = fixture();
        let mut v = on("today");
        press(&mut v, &q, &[], 'G');
        assert_eq!(v.selected(&v.scoped(&q, now())).unwrap().slug, "landed");
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
        let mut v = on("next");
        assert_eq!(v.selected(&v.scoped(&q, now())).unwrap().slug, "next-up");
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
        assert_eq!(slugs(&v, &q).len(), 2, "nothing applies before Enter");
        assert!(text(&q, &v, 160).contains("| /project:dotfiles_"));
        assert_eq!(
            hit(&mut v, KeyEvent::from(KeyCode::Enter), &q, &[]),
            Ask::Done
        );
        // Active holds no dotfiles row, so the search opens the first inner tab that does.
        assert_eq!(slugs(&v, &q), ["next-up", "night-sweep"]);
        assert_eq!(v.scoped(&q, now()).on, "next");
        assert_eq!(v.table.sel, 0);
        let s = text(&q, &v, 160);
        assert!(
            s.contains("2 of 2") && s.contains("| /project:dotfiles") && s.contains("[Up next]"),
            "{s}"
        );
        assert!(!s.contains("Pick a side"), "{s}");
        // A word searches the slug and tags too: `night` finds night-sweep by its tag.
        v.table.view.q = "night".into();
        assert_eq!(slugs(&v, &q), ["night-sweep"]);
        // Esc clears the view; with it clear Esc is the app's.
        let esc = || KeyEvent::from(KeyCode::Esc);
        assert_eq!(hit(&mut v, esc(), &q, &[]), Ask::Done);
        assert!(v.table.is_default());
        assert_eq!(hit(&mut v, esc(), &q, &[]), Ask::Pass);
        v.table.view.q = "zzz".into();
        assert!(text(&q, &v, 160).contains("No item matches"));
    }

    #[test]
    fn an_old_section_id_opens_the_table_on_its_chip_and_other_words_search() {
        let q = fixture();
        for (old, chip, n) in [
            ("waiting", "needs you", 1),
            ("running", "running", 1),
            ("queued", "up next", 2),
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
        v.open("project:game");
        assert_eq!(v.table.view.q, "project:game");
        assert!(
            v.table.view.state.is_empty(),
            "a new request starts from the table's own view"
        );
        v.open("candidates");
        assert!(v.inner == "candidates" && v.table.is_default());
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
        let mut v = QueueView::default();
        v.table.view.q = "shipped".into();
        assert_eq!(
            hit(&mut v, KeyEvent::from(KeyCode::Enter), &q, &[]),
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
            assert!(line(&s, &format!("{stage} ")).contains(gap), "{stage}\n{s}");
        }
        assert!(line(&s, "merged ").contains("abcdef1234"), "{s}");
        assert!(!s.contains("STATE "), "the detail replaces the table\n{s}");
        // Esc closes the detail first, and the query stays.
        let esc = || KeyEvent::from(KeyCode::Esc);
        assert_eq!(hit(&mut v, esc(), &q, &[]), Ask::Done);
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
        let s = text(&q, &on("today"), 200);
        assert!(line(&s, "Merged one").contains("r#7"), "{s}");
        assert!(line(&s, "Nothing shown").contains("! none"), "{s}");
        assert!(line(&s, "Broke").contains("failed"), "{s}");
        let mut v = QueueView::default();
        v.table.view.q = "merged-one".into();
        hit(&mut v, KeyEvent::from(KeyCode::Enter), &q, &[]);
        let s = text(&q, &v, 200);
        assert!(s.contains("PR r#7 merged") && s.contains("$6.10"), "{s}");
    }

    #[test]
    fn only_the_cap_of_rows_is_drawn_and_the_rest_are_counted_older() {
        let n = TABLE_OPEN_ROWS + 5;
        let jsonl: Vec<String> = (0..n)
            .map(|i| {
                format!(
                    r#"{{"slug":"d-{i}","project":"p","state":"queued","queued":"2026-11-03T{:02}:{:02}:00Z","task":"T{i}"}}"#,
                    i / 60 % 24,
                    i % 60
                )
            })
            .collect();
        let q = Queue {
            items: hub_core::queue::parse(&jsonl.join("\n")),
            ..Default::default()
        };
        let v = on("next");
        assert_eq!(v.shown(&v.scoped(&q, now())).len(), TABLE_OPEN_ROWS);
        let s = text(&q, &v, 120);
        assert!(s.contains("+5 older"), "{s}");
        assert!(
            s.contains(&format!("{n} of {n}")) && s.contains(&format!("up next {n}")),
            "{s}"
        );
    }

    #[test]
    fn cancel_waits_on_y_and_bump_steps_the_selected_item() {
        let q = fixture();
        let mut v = QueueView::default();
        assert_eq!(v.selected(&v.scoped(&q, now())).unwrap().slug, "pick-sides");
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
        v.inner = "next";
        v.table.sel = 1;
        let at = |v: &QueueView| v.selected(&v.scoped(&q, now())).unwrap().slug.clone();
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
        v.inner = "today";
        for _ in 0..10 {
            press(&mut v, &q, &[], 'j');
        }
        assert_eq!(at(&v), "landed", "j stops at the last row, a done one");
    }

    #[test]
    fn a_new_read_keeps_the_selection_on_its_slug() {
        let q = fixture();
        let mut v = on("next");
        v.table.sel = 1;
        assert_eq!(
            v.selected(&v.scoped(&q, now())).unwrap().slug,
            "night-sweep"
        );
        let mut fewer = fixture();
        fewer.items.retain(|i| i.slug != "next-up");
        v.reselect(Some("night-sweep".into()), &v.scoped(&fewer, now()), &[]);
        assert_eq!(
            v.selected(&v.scoped(&fewer, now())).unwrap().slug,
            "night-sweep"
        );
        v.inner = "today";
        v.reselect(Some("landed".into()), &v.scoped(&fewer, now()), &[]);
        assert_eq!(
            v.selected(&v.scoped(&fewer, now())).unwrap().slug,
            "landed",
            "a done row keeps its place too"
        );
        v.reselect(
            Some("gone".into()),
            &v.scoped(&Queue::default(), now()),
            &[],
        );
        assert_eq!(v.table.sel, 0);
    }

    #[test]
    fn candidates_are_their_own_inner_tab_with_their_counts() {
        let q = fixture();
        let c = Ok(cands());
        let s = text_with(&q, &QueueView::default(), Some(&c), 200);
        assert!(
            !s.contains("CANDIDATES") && !s.contains("bar-17"),
            "off their inner tab\n{s}"
        );
        let v = on("candidates");
        let s = text_with(&q, &v, Some(&c), 200);
        assert!(s.contains("CANDIDATES (3, 2 auto)  p promotes"), "{s}");
        assert!(s.contains("bar-17") && !s.contains("Pick a side"), "{s}");
        assert!(s.lines().next().unwrap().contains("[Candidates]"), "{s}");
        assert!(text(&q, &v, 200).contains("CANDIDATES  reading"));
        let err = Err("no snapshot yet, the next dispatch pass writes one".to_string());
        assert!(text_with(&q, &v, Some(&err), 200)
            .contains("No candidates: no snapshot yet, the next dispatch pass writes one"));
        let mut stamped = cands();
        stamped.as_of = "08:07".into();
        let s = text_with(&q, &v, Some(&Ok(stamped)), 200);
        assert!(
            s.contains("CANDIDATES (3, 2 auto)  as of 08:07  p promotes"),
            "{s}"
        );
    }

    #[test]
    fn left_and_right_switch_the_inner_tab_and_drop_the_last_ones_chip() {
        let q = fixture();
        let mut v = QueueView::default();
        let arrow = |v: &mut QueueView, code| hit(v, KeyEvent::from(code), &q, &[]);
        press(&mut v, &q, &[], 'f');
        assert_eq!(v.table.view.state, "needs you");
        for want in ["next", "today", "candidates", "active"] {
            assert_eq!(arrow(&mut v, KeyCode::Right), Ask::Done);
            assert_eq!(
                (v.scoped(&q, now()).on, v.table.view.state.as_str()),
                (want, "")
            );
        }
        assert_eq!(arrow(&mut v, KeyCode::Left), Ask::Done);
        assert_eq!(v.inner, "candidates", "Left wraps");
        // A chip with no inner tab named opens the one holding it, as `#queue?s=up%20next` does.
        let mut v = QueueView::default();
        v.open("queued");
        assert_eq!(v.scoped(&q, now()).on, "next");
        assert!(text(&q, &v, 160).starts_with(" Active 1 [Up next]"));
        v.open("today");
        assert_eq!(v.inner, "today");
        // NEGATIVE CONTROL: while a query is typed, the arrows are the query's.
        press(&mut v, &q, &[], '/');
        arrow(&mut v, KeyCode::Right);
        assert_eq!(v.inner, "today");
    }

    #[test]
    fn open_candidates_list_ranked_rows_with_auto_or_man_and_held() {
        let q = fixture();
        let c = Ok(cands());
        let v = on("candidates");
        let s = text_with(&q, &v, Some(&c), 200);
        assert!(s.contains("CANDIDATES (3, 2 auto)  p promotes"), "{s}");
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
        let arrow = |v: &mut QueueView, code| hit(v, KeyEvent::from(code), &q, &c);
        assert_eq!(
            press(&mut v, &q, &c, 'p'),
            Ask::Done,
            "off Candidates: nothing to promote"
        );
        assert!(
            matches!(&v.said, Some(Err(e)) if e.contains("-> to Candidates")),
            "{:?}",
            v.said
        );
        arrow(&mut v, KeyCode::Left);
        assert_eq!(
            v.selected_cand(v.shown(&v.scoped(&q, now())).len(), &c)
                .unwrap()
                .key,
            "bar-17",
            "the selection starts on the first candidate"
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

        arrow(&mut v, KeyCode::Right);
        assert_eq!(
            (v.inner, v.table.sel),
            ("active", 0),
            "leaving brings the selection back to the rows"
        );
        v.running = Some("promote x".into());
        arrow(&mut v, KeyCode::Left);
        assert_eq!(
            press(&mut v, &q, &c, 'p'),
            Ask::Done,
            "no second action while one runs"
        );
    }
}
