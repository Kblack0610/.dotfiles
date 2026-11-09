//! The Queue tab: agent-queue's items as one table on the shared data-table component, the
//! Infra Jobs style, read through `hub_core::queue`, the same reader and the same `QueueRow` as
//! agent-web's Queue tab. Its sections are `flow` (the pipeline line, `flowline`), `table` and `candidates`.
//! `/ f s S x` are the shared table's keys; j/k pick a row (a done one too), Enter opens its
//! detail, `c` arms a cancel that waits on y and `+`/`-` move its priority one step, both for an
//! active item only. Below the table the Candidates fold (`hub_core::queue::candidates`, the
//! snapshot each `fleet-dispatch run` writes, `as of` its time): `C` opens it, j/k carry on into
//! its rows, and `p` starts the selected one through the Projects tab's Start (`fleet-dispatch
//! promote`). Every write goes through hub-core.

use chrono::{DateTime, Utc};
use hub_core::flow::Rail;
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
}

#[derive(Default)]
pub struct QueueView {
    /// The shared table's view (query, state chip, sort) and its selection, an index into the
    /// drawn rows, then into the candidates the open fold shows.
    pub table: DataTable,
    /// The selected row's detail replaces the table.
    pub detail: bool,
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

impl QueueView {
    /// A request for the tab (`hub --tab "queue running"`): an old section id opens the table on
    /// its state chip, `candidates` opens that fold, `flow` and `table` are the page as it is, and
    /// any other word is the query. The table starts from its own view.
    pub fn open(&mut self, query: &str) {
        let q = query.trim();
        self.table.clear();
        self.detail = false;
        match hub_core::queue::section_chip(q) {
            _ if q.is_empty() => {}
            Some(chip) => self.table.view.state = chip.into(),
            None if q.eq_ignore_ascii_case("candidates") => self.cands_open = true,
            None if ["flow", "table"].iter().any(|s| q.eq_ignore_ascii_case(s)) => {}
            None => self.table.view.q = q.into(),
        }
    }

    /// The rows the table draws, from every row in the table's own order: the view applied, then
    /// capped at `TABLE_OPEN_ROWS`; and how many the cap left out.
    fn drawn<'a>(&self, all: &[QueueRow<'a>]) -> (Vec<QueueRow<'a>>, usize) {
        let mut rows: Vec<QueueRow<'a>> = self.table.view.apply(all).into_iter().copied().collect();
        let older = rows.len().saturating_sub(TABLE_OPEN_ROWS);
        rows.truncate(TABLE_OPEN_ROWS);
        (rows, older)
    }

    pub fn shown<'a>(&self, q: &'a Queue, now: i64) -> Vec<QueueRow<'a>> {
        self.drawn(&q.rows(at(now))).0
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
                self.detail = false;
            }
            return Ask::Done;
        }
        let Some(q) = q else { return Ask::Pass };
        let rows = self.shown(q, now);
        if self
            .table
            .moves(k, rows.len() + self.shown_cands(c).len(), page)
        {
            return Ask::Done;
        }
        if ctrl {
            return Ask::Pass;
        }
        let busy = || Some(Err("an action is still running".to_string()));
        let item = rows.get(self.table.sel).map(|r| r.item);
        match k.code {
            KeyCode::Enter if item.is_some() => self.detail = !self.detail,
            KeyCode::Esc if self.detail => self.detail = false,
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

const HEADER: [&str; 10] = [
    "STATE", "IN", "WAIT", "RUN", "PROJECT", "KIND", "SIZE", "ACCT", "PR", "TITLE",
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
fn detail(i: &Item, t: Timing, p: Palette, now: i64, w: usize) -> Vec<Line<'static>> {
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
        keep: vec![0, 1, 4, 3, 8, 2, 5, 6, 7],
        flex: Some(9),
        flexmin: 20,
        flexkeep: true,
        right: vec![1, 2, 3],
        cap: vec![(4, 18), (5, 8), (7, 10), (8, 14)],
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
    out.push(status_line(v, p, w));
    let all = q.rows(at(now));
    let (rows, older) = v.drawn(&all);
    let mut chips = v.table.status(&all, p);
    chips.push(Span::styled(
        format!("    {} of {}", rows.len() + older, all.len()),
        p.dim(),
    ));
    out.push(clip_line(Line::from(chips), w));
    let mut at_line = None;
    if let (true, Some(r)) = (v.detail, rows.get(v.table.sel)) {
        out.push(Line::raw(""));
        at_line = Some(out.len());
        out.extend(detail(r.item, r.timing, p, now, w));
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
        let mut t = table(&rows, v, p, w);
        at_line = v.table.style(&mut t, p).map(|i| out.len() + i);
        out.append(&mut t);
        if older > 0 {
            out.push(Line::styled(format!("+{older} older"), p.dim()));
        }
    }
    out.push(Line::raw(""));
    let top = out.len();
    let (more, cand_at) = candidates(rows.len(), v, cands, p, w);
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
            match c.as_of.as_str() {
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
        v.key(key(ch), Some(q), c, 10, now())
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
        let s = text(&q, &QueueView::default(), 160);
        let header = line(&s, "STATE");
        let cols = [
            "STATE", "IN", "WAIT", "RUN", "PROJECT", "KIND", "SIZE", "ACCT", "PR", "TITLE",
        ];
        assert_eq!(
            header.split_whitespace().collect::<Vec<_>>(),
            cols,
            "columns in order"
        );
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
        assert!(line(&s, "Sweep").contains("held"));
        assert!(line(&s, "Next").contains("ready"));
        let done = line(&s, "Landed");
        assert!(done.contains("ok") && done.contains("#812"), "{done}");
        assert!(
            s.contains("all 5  needs you 1  running 1  up next 2  done 1    5 of 5"),
            "{s}"
        );
        assert!(
            s.contains("4 done (3 ok, 0 failed, 1 cancelled)") && s.contains("to PR median 95m"),
            "{s}"
        );
        let empty = text(&Queue::default(), &QueueView::default(), 120);
        assert!(empty.contains("Nothing in the queue."), "{empty}");
    }

    #[test]
    fn at_80_columns_the_columns_drop_by_priority_and_the_title_stays() {
        let mut q = fixture();
        q.items.extend(hub_core::queue::parse(concat!(
            r#"{"slug":"wide","project":"unity-core-playground","type":"feat","size":"m","account":"claude-lazer","queued":"2026-11-03T12:00:00Z","state":"done","status":"ok","pr":"owner/repo#1234","finished":"2026-11-03T12:30:00Z","task":"Wide row"}"#,
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
            ["STATE", "IN", "WAIT", "RUN", "PROJECT", "KIND", "SIZE", "ACCT", "PR", "TITLE"]
        );
        // ACCT, SIZE and KIND give way first (then WAIT, PR, RUN, PROJECT, IN); STATE and TITLE never do.
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
        press(&mut v, &q, &[], 'j');
        assert_eq!(v.table.sel, 2);
        let want: [(&str, &[&str]); 5] = [
            ("needs you", &["pick-sides"]),
            ("running", &["fix-menu"]),
            ("up next", &["next-up", "night-sweep"]),
            ("done", &["landed"]),
            (
                "",
                &["pick-sides", "fix-menu", "next-up", "night-sweep", "landed"],
            ),
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
        press(&mut v, &q, &[], 's');
        press(&mut v, &q, &[], 's');
        assert_eq!(v.table.view.sort, "in");
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
    fn a_done_row_is_selectable_but_cancel_and_priority_refuse_it() {
        let q = fixture();
        let mut v = QueueView::default();
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
        assert_eq!(slugs(&v, &q).len(), 5, "nothing applies before Enter");
        assert!(text(&q, &v, 160).contains("| /project:dotfiles_"));
        assert_eq!(
            v.key(KeyEvent::from(KeyCode::Enter), Some(&q), &[], 10, now()),
            Ask::Done
        );
        assert_eq!(slugs(&v, &q), ["next-up", "night-sweep", "landed"]);
        assert_eq!(v.table.sel, 0);
        let s = text(&q, &v, 160);
        assert!(
            s.contains("3 of 5") && s.contains("| /project:dotfiles"),
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
        let mut v = QueueView::default();
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
            assert!(line(&s, &format!("{stage} ")).contains(gap), "{stage}\n{s}");
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
        let s = text(&q, &QueueView::default(), 200);
        assert!(line(&s, "Merged one").contains("r#7"), "{s}");
        assert!(line(&s, "Nothing shown").contains("! none"), "{s}");
        assert!(line(&s, "Broke").contains("failed"), "{s}");
        let mut v = QueueView::default();
        v.table.view.q = "merged-one".into();
        v.key(KeyEvent::from(KeyCode::Enter), Some(&q), &[], 10, now());
        let s = text(&q, &v, 200);
        assert!(s.contains("PR r#7 merged") && s.contains("$6.10"), "{s}");
    }

    #[test]
    fn only_the_cap_of_rows_is_drawn_and_the_rest_are_counted_older() {
        let n = TABLE_OPEN_ROWS + 5;
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
        let v = QueueView::default();
        assert_eq!(v.shown(&q, now()).len(), TABLE_OPEN_ROWS);
        let s = text(&q, &v, 120);
        assert!(s.contains("+5 older"), "{s}");
        assert!(
            s.contains(&format!("{n} of {n}")) && s.contains(&format!("done {n}")),
            "{s}"
        );
    }

    #[test]
    fn cancel_waits_on_y_and_bump_steps_the_selected_item() {
        let q = fixture();
        let mut v = QueueView::default();
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
        let mut v = QueueView::default();
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
    fn candidates_fold_shut_with_their_counts_below_the_queue() {
        let q = fixture();
        let c = Ok(cands());
        let s = text_with(&q, &QueueView::default(), Some(&c), 200);
        assert!(s.contains("+ CANDIDATES (3, 2 auto)  C opens"), "{s}");
        assert!(
            s.find("Landed").unwrap() < s.find("CANDIDATES").unwrap(),
            "below the queue\n{s}"
        );
        assert!(!s.contains("bar-17"), "no row shows while folded\n{s}");
        assert!(text(&q, &QueueView::default(), 200).contains("+ CANDIDATES  reading"));
        let err = Err("no snapshot yet, the next dispatch pass writes one".to_string());
        assert!(text_with(&q, &QueueView::default(), Some(&err), 200)
            .contains("No candidates: no snapshot yet, the next dispatch pass writes one"));
        let mut stamped = cands();
        stamped.as_of = "08:07".into();
        let s = text_with(&q, &QueueView::default(), Some(&Ok(stamped)), 200);
        assert!(
            s.contains("+ CANDIDATES (3, 2 auto)  as of 08:07  C opens"),
            "{s}"
        );
    }

    #[test]
    fn open_candidates_list_ranked_rows_with_auto_or_man_and_held() {
        let q = fixture();
        let c = Ok(cands());
        let mut v = QueueView::default();
        assert_eq!(press(&mut v, &q, &cands().rows, 'C'), Ask::Done);
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
        for _ in 0..5 {
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
            v.table.sel, 4,
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
