//! The Sessions tab's table: one row per agent session, joining every live and parked session
//! (`hub_core::session_actions`, the same reader and the same actions as agent-web's session
//! buttons) with its stage from fleet-sessions' state document and its ETA from
//! `fleet-bench forecast`, by target. One row is selected, a key per action arms a confirm line
//! before anything runs, and Enter opens the selected session's detail under the table.

use hub_core::session_actions::{available, Action, Session, Snapshot};
use ratatui::crossterm::event::{KeyCode, KeyEvent};
use ratatui::text::Line;
use serde_json::Value;

use crate::fit::{cell, clip_line, Cell, Table};
use crate::fleet;
use crate::fmt::{clock, dur, Palette};

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
    /// The forecast band, burn-up and baseline are shown at the bottom (f).
    pub forecast: bool,
    /// The week's sessions ranked by friction are shown under the forecast (w).
    pub ranked: bool,
}

/// One table row: a session the snapshot, the state document or both know.
pub struct Row<'a> {
    pub target: &'a str,
    pub state: Option<&'a Value>,
    pub live: Option<&'a (hub_core::session_actions::Agent, Session)>,
}

impl Row<'_> {
    fn bucket(&self) -> &str {
        self.state
            .and_then(|x| x["bucket"].as_str())
            .unwrap_or("PARKED")
    }
}

impl Controls {
    fn len(&self) -> usize {
        self.rows().len()
    }

    /// Every session once, in the order the table lists them: by stage, what needs the human
    /// first, then by target; a session the state document does not have yet sorts with the
    /// parked ones, in the snapshot's order.
    pub fn rows(&self) -> Vec<Row<'_>> {
        let agents = self.snap.as_ref().map_or(&[][..], |s| s.agents.as_slice());
        let mut state: Vec<&Value> = self.state.iter().collect();
        state.sort_by(|a, b| a["target"].as_str().cmp(&b["target"].as_str()));
        let mut rows: Vec<Row> = state
            .into_iter()
            .filter_map(|x| {
                let target = x["target"].as_str()?;
                let live = agents.iter().find(|(_, s)| s.target == target);
                Some(Row {
                    target,
                    state: Some(x),
                    live,
                })
            })
            .collect();
        for a in agents {
            if !rows.iter().any(|r| r.target == a.1.target) {
                rows.push(Row {
                    target: &a.1.target,
                    state: None,
                    live: Some(a),
                });
            }
        }
        rows.sort_by_key(|r| fleet::rank(r.bucket()));
        rows
    }

    /// A new snapshot keeps the selection on the same target when it is still there.
    pub fn set(&mut self, snap: Snapshot) {
        let was = self.selected_target();
        self.snap = Some(snap);
        self.reselect(was);
    }

    /// A new state document or forecast, the same.
    pub fn read(&mut self, state: Option<Vec<Value>>, schedule: Option<Vec<Value>>) {
        let was = self.selected_target();
        if let Some(s) = state {
            self.state = s;
        }
        if let Some(s) = schedule {
            self.schedule = s;
        }
        self.reselect(was);
    }

    fn reselect(&mut self, was: Option<String>) {
        let rows = self.rows();
        let n = rows.len();
        self.sel = was
            .and_then(|t| rows.iter().position(|r| r.target == t))
            .unwrap_or(self.sel)
            .min(n.saturating_sub(1));
    }

    fn selected_target(&self) -> Option<String> {
        self.rows().get(self.sel).map(|r| r.target.to_string())
    }

    /// The controls' own keys; with a confirm armed every key is the confirm's.
    pub fn key(&mut self, k: KeyEvent) -> Ask {
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
            KeyCode::Char('f') => {
                self.forecast = !self.forecast;
                Ask::Done
            }
            KeyCode::Char('w') => {
                self.ranked = !self.ranked;
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

    /// The session table (the selected row reversed), then the confirm, the running action or
    /// the last answer, then the selected session's detail when it is open.
    pub fn lines(&self, p: Palette, now: i64, w: usize) -> Vec<Line<'static>> {
        let rows = self.rows();
        let mut out = vec![];
        if self.snap.is_none() && rows.is_empty() {
            out.push(Line::styled("Reading sessions...", p.dim()));
            return out;
        }
        if rows.is_empty() {
            out.push(Line::styled("No agent sessions.", p.dim()));
        } else {
            let cells: Vec<Vec<Cell>> = rows.iter().map(|r| self.row(r, p, now)).collect();
            let mut t = Table {
                header: vec![
                    "SESSION", "STAGE", "TASK", "PR", "CI", "PLAN", "ETA", "IDLE", "ACCOUNT",
                    "YOU", "ASK", "WHY",
                ],
                rows: cells,
                keep: vec![0, 1, 5, 6, 3, 4, 7, 8, 10, 2, 9],
                flex: Some(11),
                flexmin: if w >= 100 { 30 } else { 12 },
                flexkeep: w >= 100,
                right: vec![7],
                cap: vec![(0, fleet::NAME_MAX), (2, 22), (6, 22)],
            }
            .fit(w, p.head());
            if let Some(l) = t.get_mut(self.sel + 1) {
                l.style = p.sel();
            }
            out.append(&mut t);
        }
        out.push(self.status_line(p, w));
        if self.open {
            out.extend(self.detail(rows.get(self.sel), p, now, w));
        }
        out
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
        let f = r.state.map(|x| fleet::row(x, p));
        let at = |j: usize| f.as_ref().map_or_else(|| Cell::from("-"), |f| f[j].clone());
        let (stage, task, why) = match (&f, r.live) {
            (Some(_), live) => {
                let task = match at(1).text.as_str() {
                    "-" => dash(live.map_or("", |(a, _)| a.plan_slug.as_str())),
                    _ => at(1),
                };
                (at(2), task, at(16))
            }
            (None, Some((a, s))) => {
                let state = if s.parked {
                    cell("parked", p.warn())
                } else {
                    cell(a.status.clone(), status_style(&a.status, p))
                };
                (state, dash(&a.plan_slug), a.summary.clone().into())
            }
            (None, None) => ("-".into(), "-".into(), "-".into()),
        };
        let ask = match r.live {
            Some((a, s)) => match (&a.ask, s.approve_key) {
                (Some(q), _) => cell(q.clone(), p.warn()),
                (None, Some(_)) => cell("plan ready", p.warn()),
                _ => "".into(),
            },
            None => "".into(),
        };
        vec![
            fleet::short(r.target).into(),
            stage,
            task,
            at(6),
            at(8),
            at(9),
            self.eta(r, p, now),
            at(13),
            dash(r.live.map_or("", |(_, s)| s.account.as_str())),
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
        if let Some(x) = r.state {
            for (k, c) in fleet::HEAD.iter().zip(fleet::row(x, p)).skip(1) {
                if !matches!(c.text.as_str(), "-" | "") {
                    out.push(field(k, &c.text));
                }
            }
            for k in ["branch", "next_phase", "said"] {
                if let Some(v) = x[k].as_str().filter(|v| !v.is_empty() && *v != "-") {
                    out.push(field(
                        &k.replace('_', " ").to_uppercase(),
                        &v.replace('\n', " "),
                    ));
                }
            }
            for b in x["blockers"].as_array().into_iter().flatten() {
                if let Some(b) = b.as_str() {
                    out.push(field("BLOCKER", b));
                }
            }
        }
        if let Some((a, s)) = r.live {
            out.push(field("ACCOUNT", &s.account));
            if !a.plan_slug.is_empty() {
                out.push(field("PLAN FILE", &a.plan_slug));
            }
            if !s.items.is_empty() {
                out.push(field("QUEUE", &s.items.join(", ")));
            }
            let offered: Vec<&str> = available(s).iter().map(|a| a.name()).collect();
            out.push(field("OFFERS", &offered.join(", ")));
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
        let l = if let Some(c) = &self.confirm {
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
        f.agents.reverse();
        c.set(f);
        assert_eq!(c.sel, 0);
        assert_eq!(press(&mut c, KeyCode::Char('q')), Ask::Pass);
    }
}
