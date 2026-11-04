//! The Sessions tab's controls: every live and parked agent session (`hub_core::session_actions`,
//! the same reader and the same actions as agent-web's session buttons), one selected, and a key
//! per action that arms a confirm line before anything runs.

use hub_core::session_actions::{available, Action, Snapshot};
use ratatui::crossterm::event::{KeyCode, KeyEvent};
use ratatui::text::Line;

use crate::fit::{cell, clip_line, Cell, Table};
use crate::fmt::Palette;

/// The key that asks for each action.
pub const KEYS: [(char, Action); 6] = [
    ('i', Action::Interrupt),
    ('p', Action::Park),
    ('u', Action::Unpark),
    ('m', Action::Move),
    ('x', Action::Stop),
    ('c', Action::Cancel),
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

/// What a key on the Sessions tab asks the app to do.
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
}

impl Controls {
    fn len(&self) -> usize {
        self.snap.as_ref().map_or(0, |s| s.agents.len())
    }

    /// A new snapshot keeps the selection on the same target when it is still there.
    pub fn set(&mut self, snap: Snapshot) {
        let was = self.selected_target();
        self.sel = was
            .and_then(|t| snap.agents.iter().position(|(_, s)| s.target == t))
            .unwrap_or(self.sel)
            .min(snap.agents.len().saturating_sub(1));
        self.snap = Some(snap);
    }

    fn selected_target(&self) -> Option<String> {
        let s = self.snap.as_ref()?;
        s.agents.get(self.sel).map(|(_, x)| x.target.clone())
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
        let Some(snap) = &self.snap else { return };
        let Some((_, s)) = snap.agents.get(self.sel) else {
            return;
        };
        let offered = available(s);
        if !offered.contains(&a) {
            let names: Vec<&str> = offered.iter().map(|a| a.name()).collect();
            self.said = Some(Err(format!(
                "{} is not offered for {}; it offers {}",
                a.name(),
                s.target,
                names.join(", ")
            )));
            return;
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
            self.said = Some(Err(
                "no other account in the claude-acct accounts file".into()
            ));
            return;
        }
        self.said = None;
        self.confirm = Some(Confirm {
            target: s.target.clone(),
            action: a,
            to,
            pick: 0,
        });
    }

    /// The controls as lines: a title, the session table (the selected row reversed), and the
    /// confirm, the running action or the last answer.
    pub fn lines(&self, p: Palette, w: usize) -> Vec<Line<'static>> {
        let keys: Vec<String> = KEYS
            .iter()
            .map(|(c, a)| format!("{c} {}", a.name()))
            .collect();
        let mut out = vec![clip_line(
            Line::styled(format!("SESSION CONTROLS  {}", keys.join("  ")), p.head()),
            w,
        )];
        let Some(snap) = &self.snap else {
            out.push(Line::styled("Reading sessions...", p.dim()));
            return out;
        };
        if snap.agents.is_empty() {
            out.push(Line::styled("No agent sessions.", p.dim()));
        } else {
            let rows: Vec<Vec<Cell>> = snap
                .agents
                .iter()
                .map(|(a, s)| {
                    let state = if s.parked {
                        cell("parked", p.warn())
                    } else {
                        cell(a.status.clone(), status_style(&a.status, p))
                    };
                    vec![
                        cell(s.target.clone(), Default::default()),
                        cell(if s.attached { "here" } else { "" }, p.good()),
                        state,
                        dash(&s.account),
                        dash(&a.plan_slug),
                        cell(a.ask.clone().unwrap_or_default(), p.warn()),
                        dash(s.item.as_deref().unwrap_or("")),
                        a.summary.clone().into(),
                    ]
                })
                .collect();
            let mut t = Table {
                header: vec![
                    "SESSION", "YOU", "STATE", "ACCOUNT", "PLAN", "ASK", "QUEUE", "DOING",
                ],
                rows,
                keep: vec![0, 2, 3, 1, 5, 4, 6],
                flex: Some(7),
                flexmin: 12,
                cap: vec![(0, 34), (4, 28), (6, 24)],
                ..Default::default()
            }
            .fit(w, p.head());
            if let Some(l) = t.get_mut(self.sel + 1) {
                l.style = p.sel();
            }
            out.append(&mut t);
        }
        out.push(self.status_line(p, w));
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
        s.item = Some("fix-the-thing".into());
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
