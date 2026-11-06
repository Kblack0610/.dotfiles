//! The Sessions tab's header and table. The rows are `hub_core::session_table`'s, the ones
//! agent-web draws: every live and parked session (`hub_core::session_actions`, the same reader
//! and the same actions as agent-web's session buttons), then what ended today. The header is
//! `hub_core::capacity`'s, and each row's ETA comes from `fleet-bench forecast`, by target. One
//! row is selected, a key per action arms a confirm line before anything runs, and Enter opens
//! the selected session's detail under the table.

use std::cell::Cell as Remembered;

use hub_core::capacity::{Capacity, Part};
use hub_core::session_actions::{available, Action, Session, Snapshot};
use hub_core::session_page::{Part as PagePart, SessionPage};
use hub_core::session_table::{self, Feed, SessionRow, Source};
use ratatui::crossterm::event::{KeyCode, KeyEvent};
use ratatui::style::Style;
use ratatui::text::{Line, Span};
use serde_json::Value;

use crate::datatable::{DataTable, Took};
use crate::fit::{cell, clip_line, Cell, Table};
use crate::fleet;
use crate::fmt::{clock, dur, older, Palette};

/// Rows drawn; a day's ended sessions run to hundreds, and `/` reaches the rest.
const OPEN: usize = 200;

/// The key that asks for each action.
pub const KEYS: [(char, Action); 7] = [
    ('i', Action::Interrupt),
    ('p', Action::Park),
    ('u', Action::Unpark),
    ('m', Action::Move),
    ('x', Action::Stop),
    ('c', Action::Cancel),
    ('a', Action::ApprovePlan),
];

/// An action asked for and waiting on y or n.
#[derive(Clone, Debug, PartialEq)]
pub struct Confirm {
    pub target: String,
    pub action: Action,
    /// The accounts a move can go to (all but the session's own), and the chosen one.
    pub to: Vec<String>,
    pub pick: usize,
}

impl Confirm {
    pub fn account(&self) -> Option<&str> {
        self.to.get(self.pick).map(String::as_str)
    }
}

/// What a session key on the Sessions tab asks the app to do.
#[derive(Debug, PartialEq)]
pub enum Ask {
    /// Nothing: the key was not one of the controls' own.
    Pass,
    /// The key was handled here (a move, an armed or dropped confirm).
    Done,
    /// Run this action now: (target, action, account for a move).
    Run(String, Action, Option<String>),
    /// Start this timer now (`hub_core::capacity::start`).
    Start(String),
}

#[derive(Default)]
pub struct Controls {
    pub snap: Option<Snapshot>,
    pub sel: usize,
    pub confirm: Option<Confirm>,
    /// The action now running, as "move lab/x:1".
    pub running: Option<String>,
    /// The last action's answer: its output, or why it failed or was refused.
    pub said: Option<Result<String, String>>,
    /// fleet-sessions' session objects (state.json `sessions`), joined to the snapshot by target.
    pub state: Vec<Value>,
    /// fleet-bench forecast's `schedule` rows: each session's phases and finish p50.
    pub schedule: Vec<Value>,
    /// The selected session's detail is shown under the table (Enter).
    pub open: bool,
    /// The row whose page was last asked for, and its answer once read: None when nothing names it.
    asked: Option<String>,
    page: Option<(String, Option<SessionPage>)>,
    pub table: DataTable,
    /// What the table reads beyond the state document, and the header.
    pub feed: Feed,
    pub capacity: Option<Capacity>,
    /// The timer whose Start waits on y or n, and what its confirm says.
    pub starting: Option<(String, String)>,
    /// `session_table::rows` over the sources above, rebuilt when one moves.
    all: Vec<SessionRow>,
    /// Lines above the first row as last drawn, which the scroll follows the selection by.
    above: Remembered<usize>,
}

/// One table row, with the state-document object and live session it has, if any.
pub struct Row<'a> {
    /// The row's key: the target of a live row, else the item or session id.
    pub target: &'a str,
    pub row: &'a SessionRow,
    pub state: Option<&'a Value>,
    pub live: Option<&'a (hub_core::session_actions::Agent, Session)>,
}

impl Controls {
    fn agents(&self) -> &[(hub_core::session_actions::Agent, Session)] {
        self.snap.as_ref().map_or(&[], |s| s.agents.as_slice())
    }

    /// The rows the view keeps, up to `OPEN`, in the table's own order or the view's sort.
    pub fn rows(&self) -> Vec<Row<'_>> {
        let agents = self.agents();
        self.table
            .view
            .apply(&self.all)
            .into_iter()
            .take(OPEN)
            .map(|r| {
                let on = r.source == Source::Live;
                Row {
                    target: &r.key,
                    row: r,
                    state: self
                        .state
                        .iter()
                        .find(|x| on && x["target"] == r.target.as_str()),
                    live: agents.iter().find(|(_, s)| {
                        (on && s.target == r.target)
                            || (!r.session_id.is_empty() && s.session_id == r.session_id)
                    }),
                }
            })
            .collect()
    }

    fn len(&self) -> usize {
        self.table.view.apply(&self.all).len().min(OPEN)
    }

    /// Rebuild the rows after `change`, keeping the selection on the same row when it is still
    /// there.
    fn moved(&mut self, change: impl FnOnce(&mut Self)) {
        let was = self.selected_key();
        change(self);
        self.all = session_table::rows(&self.state, &self.feed, self.agents());
        let rows = self.rows();
        self.sel = was
            .and_then(|t| rows.iter().position(|r| r.target == t))
            .unwrap_or(self.sel)
            .min(rows.len().saturating_sub(1));
    }

    /// A new snapshot.
    pub fn set(&mut self, snap: Snapshot) {
        self.moved(|c| c.snap = Some(snap));
    }

    /// A new state document or forecast.
    pub fn read(&mut self, state: Option<Vec<Value>>, schedule: Option<Vec<Value>>) {
        if let Some(s) = schedule {
            self.schedule = s;
        }
        if let Some(s) = state {
            self.moved(|c| c.state = s);
        }
    }

    /// New ended rows. The open page is read again with them.
    pub fn read_feed(&mut self, feed: Feed) {
        self.moved(|c| c.feed = feed);
        self.asked = None;
    }

    /// What to read the open detail's page from, when it shows no read of the selected row yet.
    pub fn wants_page(&mut self) -> Option<(String, Vec<SessionRow>, Vec<Value>)> {
        if !self.open {
            self.asked = None;
            return None;
        }
        let id = self.selected_key()?;
        if self.asked.as_ref() == Some(&id) {
            return None;
        }
        self.asked = Some(id.clone());
        Some((id, self.all.clone(), self.state.clone()))
    }

    /// A page read; one for a row left since is dropped.
    pub fn read_page(&mut self, id: String, page: Option<SessionPage>) {
        if self.asked.as_ref() == Some(&id) {
            self.page = Some((id, page));
        }
    }

    fn selected_key(&self) -> Option<String> {
        self.rows().get(self.sel).map(|r| r.target.to_string())
    }

    /// The controls' own keys; with a confirm armed every key is the confirm's.
    pub fn key(&mut self, k: KeyEvent) -> Ask {
        if self.starting.is_some() {
            match k.code {
                KeyCode::Char('y') | KeyCode::Enter => {
                    return Ask::Start(self.starting.take().expect("armed").0);
                }
                KeyCode::Char('n') | KeyCode::Esc => self.starting = None,
                _ => {}
            }
            return Ask::Done;
        }
        if let Some(c) = &mut self.confirm {
            match k.code {
                KeyCode::Char('y') | KeyCode::Enter => {
                    let c = self.confirm.take().expect("armed");
                    let acct = c.account().map(str::to_string);
                    return Ask::Run(c.target, c.action, acct);
                }
                KeyCode::Char('n') | KeyCode::Esc => self.confirm = None,
                KeyCode::Right | KeyCode::Tab | KeyCode::Char('l') if !c.to.is_empty() => {
                    c.pick = (c.pick + 1) % c.to.len()
                }
                KeyCode::Left | KeyCode::BackTab | KeyCode::Char('h') if !c.to.is_empty() => {
                    c.pick = (c.pick + c.to.len() - 1) % c.to.len()
                }
                _ => {}
            }
            return Ask::Done;
        }
        // The shared table keys, but for `x`, which stays Stop here: Esc clears the view instead.
        if self.table.typing.is_some() || matches!(k.code, KeyCode::Char('/' | 'f' | 's' | 'S')) {
            if self.table.key::<SessionRow>(k.code) == Took::View {
                self.sel = 0;
            }
            return Ask::Done;
        }
        match k.code {
            KeyCode::Char('j') | KeyCode::Down => {
                self.sel = (self.sel + 1).min(self.len().saturating_sub(1));
                Ask::Done
            }
            KeyCode::Char('k') | KeyCode::Up => {
                self.sel = self.sel.saturating_sub(1);
                Ask::Done
            }
            KeyCode::Enter => {
                self.open = !self.open;
                Ask::Done
            }
            KeyCode::Esc if self.open => {
                self.open = false;
                Ask::Done
            }
            KeyCode::Esc if !self.table.is_default() => {
                self.table.clear();
                self.sel = 0;
                Ask::Done
            }
            KeyCode::Char('T') => {
                self.arm_start();
                Ask::Done
            }
            KeyCode::Char(ch) => match KEYS.iter().find(|(c, _)| *c == ch) {
                Some((_, a)) => {
                    self.arm(*a);
                    Ask::Done
                }
                None => Ask::Pass,
            },
            _ => Ask::Pass,
        }
    }

    /// Arm the confirm for the first stopped timer, or say there is none.
    fn arm_start(&mut self) {
        if self.running.is_some() {
            self.said = Some(Err("an action is still running".into()));
            return;
        }
        let mut parts = self.capacity.iter().flat_map(|c| &c.parts);
        match parts.find_map(|p| Some((p.start?.to_string(), p.confirm.clone()))) {
            Some(armed) => {
                self.said = None;
                self.starting = Some(armed);
            }
            None => self.said = Some(Err("no timer is stopped".into())),
        }
    }

    /// Arm a confirm for the selected session, or say why the action is not offered.
    fn arm(&mut self, a: Action) {
        if self.running.is_some() {
            self.said = Some(Err("an action is still running".into()));
            return;
        }
        match self.offer(a) {
            Some(Ok(c)) => {
                self.said = None;
                self.confirm = Some(c);
            }
            Some(Err(e)) => self.said = Some(Err(e)),
            None => {}
        }
    }

    /// The confirm the selected session would arm for an action, or why it is not offered.
    fn offer(&self, a: Action) -> Option<Result<Confirm, String>> {
        let snap = self.snap.as_ref()?;
        let rows = self.rows();
        let row = rows.get(self.sel)?;
        let Some((_, s)) = row.live else {
            return Some(Err(format!(
                "{} is not a live or parked session on this machine: nothing to act on",
                row.target
            )));
        };
        let offered = available(s);
        if !offered.contains(&a) {
            let names: Vec<&str> = offered.iter().map(|a| a.name()).collect();
            return Some(Err(format!(
                "{} is not offered for {}; it offers {}",
                a.name(),
                s.target,
                names.join(", ")
            )));
        }
        let to: Vec<String> = if a == Action::Move {
            snap.accounts
                .iter()
                .filter(|x| **x != s.account)
                .cloned()
                .collect()
        } else {
            vec![]
        };
        if a == Action::Move && to.is_empty() {
            return Some(Err(
                "no other account in the claude-acct accounts file".into()
            ));
        }
        Some(Ok(Confirm {
            target: s.target.clone(),
            action: a,
            to,
            pick: 0,
        }))
    }

    /// The capacity line (one part a line when it does not fit), what could not be read, the
    /// sessions with no queue item, and the chips.
    fn head(&self, p: Palette, w: usize) -> Vec<Line<'static>> {
        let mut out = vec![];
        let warn = |e: &String| clip_line(Line::styled(e.clone(), p.warn()), w);
        if let Some(c) = &self.capacity {
            let span = |x: &Part| {
                let hint = if x.start.is_some() {
                    " (T starts it)"
                } else {
                    ""
                };
                let style = if x.warn { p.warn() } else { Style::new() };
                Span::styled(format!("{}{hint}", x.text), style)
            };
            let spans: Vec<Span> = c.parts.iter().map(span).collect();
            let long: usize = spans.iter().map(|s| s.content.len() + 3).sum();
            if long <= w + 3 {
                let mut line = vec![];
                for (i, s) in spans.into_iter().enumerate() {
                    if i > 0 {
                        line.push(Span::raw(" | "));
                    }
                    line.push(s);
                }
                out.push(Line::from(line));
            } else {
                out.extend(spans.into_iter().map(|s| clip_line(Line::from(s), w)));
            }
            out.extend(c.errors.iter().map(warn));
            if c.unlinked > 0 {
                let t = format!(
                    "{} of {} live sessions have no queue item (/item:none)",
                    c.unlinked, c.live
                );
                out.push(clip_line(Line::styled(t, p.dim()), w));
            }
        }
        out.extend(self.feed.errors.iter().map(warn));
        out.push(clip_line(Line::from(self.table.status(&self.all, p)), w));
        out
    }

    /// The header, the session table (the selected row reversed), then the confirm, the running
    /// action or the last answer, then the selected session's detail when it is open.
    pub fn lines(&self, p: Palette, now: i64, w: usize) -> Vec<Line<'static>> {
        let rows = self.rows();
        if self.snap.is_none() && rows.is_empty() {
            return vec![Line::styled("Reading sessions...", p.dim())];
        }
        let mut out = self.head(p, w);
        self.above.set(out.len() + 1);
        if rows.is_empty() {
            let none = if self.all.is_empty() {
                "No sessions, live or ended today."
            } else {
                "No sessions match."
            };
            out.push(Line::styled(none, p.dim()));
        } else {
            let cells: Vec<Vec<Cell>> = rows.iter().map(|r| self.row(r, p, now)).collect();
            let mut t = Table {
                mark: self.table.mark::<SessionRow>(),
                // The first eleven are `SessionRow::COLUMNS`, in its order, so the sort mark lands.
                header: vec![
                    "STAGE", "PROJECT", "TASK", "PR", "PLAN", "IDLE", "COST", "ACCOUNT", "ITEM",
                    "SOURCE", "SESSION", "ETA", "YOU", "ASK", "WHY",
                ],
                rows: cells,
                keep: vec![0, 2, 3, 4, 5, 10, 1, 6, 7, 13, 12, 11, 8, 9],
                flex: Some(14),
                flexmin: if w >= 100 { 30 } else { 12 },
                flexkeep: w >= 100,
                right: vec![5, 6],
                cap: vec![(1, 16), (2, 30), (8, 22), (10, fleet::NAME_MAX), (11, 22)],
            }
            .fit(w, p.head());
            if let Some(l) = t.get_mut(self.sel + 1) {
                l.style = p.sel();
            }
            out.append(&mut t);
        }
        out.extend(older(self.table.view.apply(&self.all).len(), rows.len(), p));
        out.push(self.status_line(p, w));
        if self.open {
            out.extend(self.detail(rows.get(self.sel), p, now, w));
        }
        out
    }

    /// Lines above the first row, as last drawn.
    pub fn above(&self) -> usize {
        self.above.get()
    }

    /// The forecast's schedule row for a session.
    fn plan(&self, target: &str) -> Option<&Value> {
        self.schedule.iter().find(|s| s["target"] == target)
    }

    /// The ETA: the forecast's finish p50 and how late it runs, else fleet-sessions' own.
    fn eta(&self, r: &Row, p: Palette, now: i64) -> Cell {
        if let Some(f) = self.plan(r.target).and_then(|s| s["finish_p50"].as_i64()) {
            let late = self.plan(r.target).and_then(|s| s["late_min"].as_i64());
            return match late {
                Some(m) => cell(
                    format!("{} late {}", clock(f, now), dur(m as f64 * 60.0)),
                    p.bad(),
                ),
                None => clock(f, now).into(),
            };
        }
        match r.state.and_then(|x| x["eta"].as_str()) {
            Some(e) if !e.is_empty() => e.into(),
            _ => "-".into(),
        }
    }

    fn row(&self, r: &Row, p: Palette, now: i64) -> Vec<Cell> {
        let x = r.row;
        let f = r.state.map(|x| fleet::row(x, p));
        let at = |j: usize| f.as_ref().map_or_else(|| Cell::from("-"), |f| f[j].clone());
        let (stage, why) = match (&f, r.live) {
            (Some(_), _) => (at(2), at(16)),
            (None, Some((a, s))) if x.source == Source::Live => {
                let state = if s.parked {
                    cell("parked", p.warn())
                } else {
                    cell(a.status.clone(), status_style(&a.status, p))
                };
                (state, a.summary.clone().into())
            }
            (None, _) => (cell(x.bucket.clone(), p.good()), "-".into()),
        };
        let ask = match r.live {
            Some((a, s)) => match (&a.ask, s.approve_key) {
                (Some(q), _) => cell(q.clone(), p.warn()),
                (None, Some(_)) => cell("plan ready", p.warn()),
                _ => "".into(),
            },
            None => "".into(),
        };
        let task = match x.task.as_str() {
            "" => dash(r.live.map_or("", |(a, _)| a.plan_slug.as_str())),
            t => t.into(),
        };
        let pr = match &x.pr {
            Some(n) => cell(
                format!("#{n} {} {}", x.pr_state, x.ci)
                    .trim_end()
                    .to_string(),
                fleet::ci_style(p, &x.ci),
            ),
            None => "-".into(),
        };
        let plan = match (x.phases_done, x.phases_total) {
            (Some(d), Some(t)) if t > 0 => format!("{d}/{t}").into(),
            _ => "-".into(),
        };
        let idle = if x.ended.is_empty() {
            at(13)
        } else {
            x.ended.as_str().into()
        };
        let session = match x.source {
            Source::Live => fleet::short(r.target),
            _ => x.session_id.chars().take(8).collect(),
        };
        vec![
            stage,
            dash(&x.project),
            task,
            pr,
            plan,
            idle,
            x.cost_usd.map_or("-".into(), |c| format!("${c:.2}").into()),
            dash(&x.account),
            dash(&x.item),
            x.source.name().into(),
            session.into(),
            self.eta(r, p, now),
            cell(
                if r.live.is_some_and(|(_, s)| s.attached) {
                    "here"
                } else {
                    ""
                },
                p.good(),
            ),
            ask,
            why,
        ]
    }

    /// Everything known about one session: each state-document cell, the live session's own
    /// fields, what it last said and what blocks it, and the forecast's phases for it (the
    /// timeline the Forecast tab drew, one session at a time).
    fn detail(&self, r: Option<&Row>, p: Palette, now: i64, w: usize) -> Vec<Line<'static>> {
        let Some(r) = r else { return vec![] };
        let mut out = vec![
            Line::raw(""),
            clip_line(
                Line::styled(
                    format!("DETAIL  {}   Enter or Esc closes", r.target),
                    p.head(),
                ),
                w,
            ),
        ];
        let field = |k: &str, v: &str| {
            clip_line(
                Line::from(vec![
                    ratatui::text::Span::styled(format!("  {k:<10} "), p.dim()),
                    ratatui::text::Span::raw(v.to_string()),
                ]),
                w,
            )
        };
        let page = self.page.as_ref().filter(|(id, _)| id == r.target);
        match page.map(|(_, p)| p.as_ref()) {
            None => out.push(field("PAGE", "reading")),
            Some(None) => out.push(field("PAGE", "nothing names this session")),
            Some(Some(page)) => {
                for e in &page.errors {
                    out.push(field("ERROR", e));
                }
                for part in &page.parts {
                    out.push(page_field(part, p, w));
                }
            }
        }
        if let Some(x) = r.state {
            for (k, c) in fleet::HEAD.iter().zip(fleet::row(x, p)).skip(1) {
                if !matches!(c.text.as_str(), "-" | "") {
                    out.push(field(k, &c.text));
                }
            }
            if let Some(v) = x["said"].as_str().filter(|v| !v.is_empty() && *v != "-") {
                out.push(field("SAID", &v.replace('\n', " ")));
            }
            for b in x["blockers"].as_array().into_iter().flatten() {
                if let Some(b) = b.as_str() {
                    out.push(field("BLOCKER", b));
                }
            }
        }
        if let Some((_, s)) = r.live {
            out.push(field("ACCOUNT", &s.account));
            let offered: Vec<&str> = available(s).iter().map(|a| a.name()).collect();
            out.push(field("OFFERS", &offered.join(", ")));
        }
        if r.row.source != Source::Live {
            let card = page
                .and_then(|(_, p)| p.as_ref())
                .map(|p| p.outcome.as_str());
            out.push(field("OUTCOME", ""));
            for l in card.unwrap_or_default().lines() {
                out.push(clip_line(Line::raw(format!("  {l}")), w));
            }
            return out;
        }
        match self.plan(r.target) {
            Some(f) => {
                out.push(field(
                    "TIMELINE",
                    "from the forecast, now to the slow finish",
                ));
                out.extend(crate::forecast::timeline(f, p, now, w));
            }
            None => out.push(field("TIMELINE", "no plan to schedule")),
        }
        out
    }

    fn status_line(&self, p: Palette, w: usize) -> Line<'static> {
        let l = if let Some((_, confirm)) = &self.starting {
            Line::styled(format!("{confirm}  y/Enter yes  n/Esc no"), p.warn())
        } else if let Some(c) = &self.confirm {
            let to = match c.account() {
                Some(a) => format!("  to: < {a} > (Left/Right)"),
                None => String::new(),
            };
            Line::styled(
                format!(
                    "{} {}? It will {}.{to}  y/Enter yes  n/Esc no",
                    cap(c.action.name()),
                    c.target,
                    c.action.describe()
                ),
                p.warn(),
            )
        } else if let Some(r) = &self.running {
            Line::styled(format!("Running {r}..."), p.dim())
        } else {
            match &self.said {
                Some(Ok(s)) => Line::styled(s.clone(), p.good()),
                Some(Err(e)) => Line::styled(e.clone(), p.bad()),
                None => Line::raw(""),
            }
        };
        clip_line(l, w)
    }
}

/// One part of the page. A URL is printed, since nothing here is clicked; a `#tab` link is
/// agent-web's own.
fn page_field(part: &PagePart, p: Palette, w: usize) -> Line<'static> {
    let url = part.link.as_deref().filter(|l| l.starts_with("http"));
    let text = match url {
        Some(u) => format!("{}  {u}", part.text),
        None => part.text.clone(),
    };
    let style = if part.warn {
        p.warn()
    } else {
        Default::default()
    };
    clip_line(
        Line::from(vec![
            Span::styled(format!("  {:<10} ", part.label.to_uppercase()), p.dim()),
            Span::styled(text, style),
        ]),
        w,
    )
}

fn dash(s: &str) -> Cell {
    if s.is_empty() { "-" } else { s }.into()
}

fn cap(s: &str) -> String {
    let mut c = s.chars();
    c.next()
        .map(|f| f.to_ascii_uppercase().to_string() + c.as_str())
        .unwrap_or_default()
}

fn status_style(s: &str, p: Palette) -> ratatui::style::Style {
    match s {
        "waiting" => p.warn(),
        "busy" => p.good(),
        _ => Default::default(),
    }
}

#[cfg(test)]
pub mod tests {
    use super::*;
    use hub_core::session_actions::{Agent, Session};

    /// Two sessions: one attached and live with a queue item, one parked.
    pub fn fixture() -> Snapshot {
        Snapshot {
            agents: vec![live(), parked()],
            accounts: vec!["main".into(), "alt".into(), "bnb".into()],
        }
    }

    fn live() -> (Agent, Session) {
        let a = Agent {
            target: "lab/dotfiles-agent-3:2".into(),
            status: "idle".into(),
            summary: "session controls".into(),
            plan_slug: "new-curious-garden".into(),
            ask: Some("a1".into()),
            server: "lab".into(),
            tmux_session: "dotfiles-agent-3".into(),
            pane: "lab/%7".into(),
            window_id: "@4".into(),
            pid: 4242,
            attached: true,
            account: "bnb".into(),
            ..Default::default()
        };
        let mut s = Session::from(&a);
        s.items = vec!["fix-the-thing".into()];
        (a, s)
    }

    fn parked() -> (Agent, Session) {
        let a = Agent {
            target: "lab/dotfiles-agent-9:1".into(),
            status: "parked".into(),
            summary: "parked (park)".into(),
            server: "lab".into(),
            tmux_session: "dotfiles-agent-9".into(),
            account: "main".into(),
            parked: true,
            ..Default::default()
        };
        let s = Session::from(&a);
        (a, s)
    }

    fn press(c: &mut Controls, k: KeyCode) -> Ask {
        c.key(KeyEvent::from(k))
    }

    #[test]
    fn a_approves_only_a_session_whose_pane_shows_the_plan_dialog() {
        let mut c = Controls::default();
        c.set(fixture());
        press(&mut c, KeyCode::Char('a'));
        assert!(c.confirm.is_none());
        assert!(matches!(&c.said, Some(Err(e)) if e.contains("approve-plan is not offered")));
        let mut snap = fixture();
        snap.agents[0].1.approve_key = Some('1');
        c.set(snap);
        press(&mut c, KeyCode::Char('a'));
        assert_eq!(
            c.confirm.as_ref().map(|x| x.action),
            Some(Action::ApprovePlan)
        );
        assert_eq!(
            press(&mut c, KeyCode::Char('y')),
            Ask::Run("lab/dotfiles-agent-3:2".into(), Action::ApprovePlan, None)
        );
    }

    #[test]
    fn a_move_asks_first_and_picks_another_account() {
        let mut c = Controls::default();
        c.set(fixture());
        assert_eq!(press(&mut c, KeyCode::Char('m')), Ask::Done);
        let armed = c.confirm.clone().unwrap();
        assert_eq!(armed.to, vec!["main", "alt"], "never the account it is on");
        press(&mut c, KeyCode::Right);
        assert_eq!(
            press(&mut c, KeyCode::Char('y')),
            Ask::Run(
                "lab/dotfiles-agent-3:2".into(),
                Action::Move,
                Some("alt".into())
            )
        );
        assert!(c.confirm.is_none());
    }

    #[test]
    fn n_or_esc_drops_the_confirm_and_runs_nothing() {
        let mut c = Controls::default();
        c.set(fixture());
        for k in [KeyCode::Char('n'), KeyCode::Esc] {
            press(&mut c, KeyCode::Char('x'));
            assert!(c.confirm.is_some());
            assert_eq!(press(&mut c, k), Ask::Done);
            assert!(c.confirm.is_none());
        }
    }

    #[test]
    fn a_parked_row_offers_only_unpark() {
        let mut c = Controls::default();
        c.set(fixture());
        press(&mut c, KeyCode::Char('j'));
        press(&mut c, KeyCode::Char('x'));
        assert!(c.confirm.is_none());
        assert!(matches!(&c.said, Some(Err(e)) if e.contains("offers unpark")));
        press(&mut c, KeyCode::Char('u'));
        assert_eq!(
            press(&mut c, KeyCode::Enter),
            Ask::Run("lab/dotfiles-agent-9:1".into(), Action::Unpark, None)
        );
    }

    #[test]
    fn the_selection_follows_its_target_across_a_reread() {
        let mut c = Controls::default();
        c.set(fixture());
        press(&mut c, KeyCode::Char('j'));
        let mut f = fixture();
        f.agents.remove(0);
        c.set(f);
        assert_eq!(c.sel, 0);
        assert_eq!(c.rows()[0].target, "lab/dotfiles-agent-9:1");
        assert_eq!(press(&mut c, KeyCode::Char('q')), Ask::Pass);
    }

    fn capacity(stopped: bool) -> Capacity {
        Capacity {
            parts: vec![
                Part {
                    text: "2 live: 2 hand".into(),
                    ..Part::default()
                },
                Part {
                    text: if stopped {
                        "shepherd timer stopped"
                    } else {
                        "shepherd on"
                    }
                    .into(),
                    warn: stopped,
                    start: stopped.then_some("shepherd"),
                    confirm: if stopped {
                        "Start the shepherd timer?"
                    } else {
                        ""
                    }
                    .into(),
                },
            ],
            live: 2,
            unlinked: 2,
            errors: vec![],
        }
    }

    fn ended() -> Feed {
        let item = serde_json::json!({"slug": "ucp-394", "project": "apociseum", "state": "done",
            "task": "ucp-394 fix", "finished": chrono::Local::now().to_rfc3339(),
            "sessions": "sid-ended", "pr": "Kblack0610/x#1915", "merged": "abc", "status": "ok"});
        Feed {
            items: hub_core::queue::parse(&item.to_string()),
            ..Feed::default()
        }
    }

    fn text(c: &Controls, w: usize) -> String {
        let p = Palette { no_color: true };
        let lines = c.lines(p, 0, w);
        let plain = lines.iter().map(crate::fit::plain);
        plain.collect::<Vec<_>>().join("\n")
    }

    #[test]
    fn a_stopped_timer_starts_only_after_its_confirm() {
        let mut c = Controls::default();
        c.set(fixture());
        c.capacity = Some(capacity(true));
        assert!(text(&c, 140).contains("shepherd timer stopped (T starts it)"));

        press(&mut c, KeyCode::Char('T'));
        assert!(text(&c, 140).contains("Start the shepherd timer?  y/Enter yes"));
        assert_eq!(press(&mut c, KeyCode::Char('n')), Ask::Done);
        assert!(c.starting.is_none());

        press(&mut c, KeyCode::Char('T'));
        assert_eq!(
            press(&mut c, KeyCode::Char('j')),
            Ask::Done,
            "only y or n answers"
        );
        assert_eq!(
            press(&mut c, KeyCode::Char('y')),
            Ask::Start("shepherd".into())
        );
    }

    #[test]
    fn t_says_so_when_no_timer_is_stopped() {
        let mut c = Controls::default();
        c.set(fixture());
        c.capacity = Some(capacity(false));
        press(&mut c, KeyCode::Char('T'));
        assert!(c.starting.is_none());
        assert!(matches!(&c.said, Some(Err(e)) if e.contains("no timer")));
    }

    #[test]
    fn the_done_today_chip_shows_what_ended_and_its_source() {
        let mut c = Controls::default();
        c.set(fixture());
        c.read_feed(ended());
        for _ in 0..4 {
            press(&mut c, KeyCode::Char('f'));
        }
        let rows = c.rows();
        assert_eq!(rows.len(), 1, "{}", text(&c, 200));
        assert_eq!(rows[0].row.source, Source::Queue);
        assert!(rows[0].live.is_none());
        drop(rows);
        let out = text(&c, 200);
        assert!(out.contains("#1915") && out.contains("queue"), "{out}");

        press(&mut c, KeyCode::Enter);
        assert!(text(&c, 200).contains("ucp-394"));

        // No action reaches an ended row, and Esc closes the detail before it clears the view.
        press(&mut c, KeyCode::Esc);
        assert_eq!(c.rows().len(), 1);
        press(&mut c, KeyCode::Esc);
        assert_eq!(c.rows().len(), 3);
    }

    #[test]
    fn the_query_keys_are_the_tables_until_it_is_applied() {
        let mut c = Controls::default();
        c.set(fixture());
        press(&mut c, KeyCode::Char('/'));
        for k in "agent-9".chars() {
            assert_eq!(press(&mut c, KeyCode::Char(k)), Ask::Done);
        }
        assert!(c.confirm.is_none(), "a typed letter arms no action");
        press(&mut c, KeyCode::Enter);
        assert_eq!(c.rows().len(), 1);
        assert_eq!(c.rows()[0].target, "lab/dotfiles-agent-9:1");
    }

    #[test]
    fn the_header_breaks_a_line_a_part_at_80_columns() {
        let mut c = Controls::default();
        c.set(fixture());
        let mut cap = capacity(true);
        cap.parts[0].text =
            "38 live: 14 hand, 18 dispatched (0/40 run units, 3 per pass), 6 other".into();
        c.capacity = Some(cap);
        let p = Palette { no_color: true };
        let lines: Vec<String> = c.lines(p, 0, 80).iter().map(crate::fit::plain).collect();
        assert!(
            lines[0].starts_with("38 live") && !lines[0].contains('|'),
            "{lines:?}"
        );
        assert!(lines[1].starts_with("shepherd timer stopped"), "{lines:?}");
        assert!(lines.iter().all(|l| l.chars().count() <= 80), "{lines:?}");
        assert_eq!(
            c.above(),
            lines.iter().position(|l| l.starts_with("STAGE")).unwrap() + 1
        );
    }
}
