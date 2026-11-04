//! The Queue tab: agent-queue's items in agent-web's sections (Waiting for you, Running, Up next,
//! Done today), read through `hub_core::queue`, the same reader as agent-web's Queue tab. j/k
//! pick an active item, `c` arms a cancel that waits on y, and `+`/`-` move its priority one
//! step. Both run agent-queue through hub-core; this file writes nothing.

use hub_core::queue::{Item, Queue, State, SECTIONS};
use ratatui::crossterm::event::{KeyCode, KeyEvent};
use ratatui::text::{Line, Span};

use crate::fit::{cell, clip_line, Cell, Table};
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
}

#[derive(Default)]
pub struct QueueView {
    /// Index into `active`.
    pub sel: usize,
    /// The slug a cancel waits on y for.
    pub confirm: Option<String>,
    /// The action now running, as "cancel <slug>".
    pub running: Option<String>,
    /// The last action's answer: agent-queue's output, or why it failed.
    pub said: Option<Result<String, String>>,
}

/// The items j/k move over: every active one, in section order. A done item has no action.
pub fn active(q: &Queue) -> Vec<&Item> {
    SECTIONS
        .iter()
        .filter(|(s, _)| *s != State::Done)
        .flat_map(|(s, _)| q.in_state(*s))
        .collect()
}

impl QueueView {
    pub fn selected<'a>(&self, q: &'a Queue) -> Option<&'a Item> {
        active(q).get(self.sel).copied()
    }

    /// A new read keeps the selection on the same slug when it is still active.
    pub fn reselect(&mut self, was: Option<String>, q: &Queue) {
        let rows = active(q);
        self.sel = was
            .and_then(|s| rows.iter().position(|i| i.slug == s))
            .unwrap_or(self.sel)
            .min(rows.len().saturating_sub(1));
    }

    pub fn key(&mut self, k: KeyEvent, q: Option<&Queue>) -> Ask {
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
        let Some(q) = q else { return Ask::Pass };
        let n = active(q).len();
        let busy = || Some(Err("an action is still running".to_string()));
        match k.code {
            KeyCode::Char('j') | KeyCode::Down => {
                self.sel = (self.sel + 1).min(n.saturating_sub(1))
            }
            KeyCode::Char('k') | KeyCode::Up => self.sel = self.sel.saturating_sub(1),
            KeyCode::Char('c') => match self.selected(q) {
                _ if self.running.is_some() => self.said = busy(),
                Some(i) => {
                    self.said = None;
                    self.confirm = Some(i.slug.clone());
                }
                None => self.said = Some(Err("nothing active to cancel".into())),
            },
            KeyCode::Char(c @ ('+' | '=' | '-')) => {
                let Some(i) = self.selected(q) else {
                    return Ask::Done;
                };
                if self.running.is_some() {
                    self.said = busy();
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

/// An ISO time from the store as the local clock, or "" when there is none.
fn when(t: Option<&str>, now: i64) -> String {
    t.and_then(|t| chrono::DateTime::parse_from_rfc3339(t).ok())
        .map_or(String::new(), |d| clock(d.timestamp(), now))
}

/// The Overview's one line: what waits on you, what runs, what is next, what finished today.
pub fn counts(q: &Queue) -> String {
    let held = q
        .in_state(State::Queued)
        .filter(|i| i.hold.is_some())
        .count();
    let mut s = format!(
        "{} waiting for you, {} running, {} up next",
        q.count(State::Waiting),
        q.count(State::Running),
        q.count(State::Queued)
    );
    if held > 0 {
        s += &format!(" ({held} held)");
    }
    s + &format!(", {} done today", q.count(State::Done))
}

fn heading(title: &str, rest: String, p: Palette) -> Line<'static> {
    Line::from(vec![
        Span::styled(title.to_string(), p.head()),
        Span::styled(rest, p.dim()),
    ])
}

/// What the row's state column says: the hold, the session, or how it finished.
fn state(i: &Item, p: Palette) -> Cell {
    match i.state {
        State::Queued => match &i.hold {
            Some(h) => cell(format!("waits: {h}"), p.warn()),
            None => cell("ready", p.good()),
        },
        State::Waiting | State::Running => i.session.clone().unwrap_or_default().into(),
        State::Done => {
            let st = i.status.clone().unwrap_or_default();
            let style = if st == "ok" { p.good() } else { p.bad() };
            match &i.pr {
                Some(pr) => cell(format!("{st}, PR {pr}"), style),
                None => cell(st, style),
            }
        }
    }
}

fn row(i: &Item, p: Palette, now: i64) -> Vec<Cell> {
    let t = match i.state {
        State::Done => when(i.finished.as_deref(), now),
        _ if i.started.is_some() => when(i.started.as_deref(), now),
        _ => when(i.queued.as_deref(), now),
    };
    let prio = match i.priority.as_str() {
        "urgent" => p.bad(),
        "high" => p.warn(),
        _ => Default::default(),
    };
    let mut task = i.title().to_string();
    if let Some(n) = &i.note {
        task = format!("{task}  ({n})");
    }
    vec![
        cell(i.slug.clone(), Default::default()),
        cell(i.priority.clone(), prio),
        i.project.clone().into(),
        i.mode.clone().into(),
        t.into(),
        state(i, p),
        task.into(),
    ]
}

pub fn page(q: &Queue, v: &QueueView, p: Palette, now: i64, w: usize) -> Vec<Line<'static>> {
    let mut out = vec![];
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
    let sel = v.selected(q).map(|i| i.slug.clone());
    for (s, title) in SECTIONS {
        let rows: Vec<&Item> = q.in_state(s).collect();
        if rows.is_empty() && s == State::Waiting {
            continue;
        }
        out.push(Line::raw(""));
        out.push(heading(
            &title.to_uppercase(),
            format!("  {}", rows.len()),
            p,
        ));
        if rows.is_empty() {
            let what = if s == State::Done {
                "finished today"
            } else {
                "here"
            };
            out.push(Line::styled(format!("Nothing {what}."), p.dim()));
            continue;
        }
        let mut t = Table {
            header: vec![
                "SLUG", "PRIORITY", "PROJECT", "MODE", "WHEN", "STATE", "TASK",
            ],
            rows: rows.iter().map(|i| row(i, p, now)).collect(),
            keep: vec![0, 5, 1, 4, 2, 3],
            flex: Some(6),
            flexmin: 20,
            cap: vec![(0, 40), (5, 36)],
            ..Default::default()
        }
        .fit(w, p.head());
        if s != State::Done {
            if let Some(at) = rows.iter().position(|i| Some(&i.slug) == sel.as_ref()) {
                t[at + 1].style = p.sel();
            }
        }
        out.append(&mut t);
    }
    out
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
            r#"{"slug":"pick-sides","project":"game","mode":"plan","priority":"high","queued":"2026-11-03T10:00:00Z","started":"2026-11-03T10:05:00Z","session":"lab:game-agent-2","state":"waiting","task":"Pick a side\nmore"}"#,
            "\n",
            r#"{"slug":"fix-menu","project":"game","mode":"oneshot","priority":"normal","queued":"2026-11-03T10:10:00Z","started":"2026-11-03T10:20:00Z","session":"lab:game-agent-3","state":"running","task":"Fix the menu"}"#,
            "\n",
            // agent-queue's own order: priority, then queued.
            r#"{"slug":"next-up","project":"dotfiles","mode":"oneshot","priority":"urgent","queued":"2026-11-03T11:30:00Z","state":"queued","task":"Next"}"#,
            "\n",
            r#"{"slug":"night-sweep","project":"dotfiles","mode":"oneshot","priority":"low","tags":"night","queued":"2026-11-03T11:00:00Z","state":"queued","hold":"night (01:00-06:00)","task":"Sweep"}"#,
            "\n",
            r#"{"slug":"landed","project":"dotfiles","mode":"oneshot","priority":"normal","state":"done","status":"ok","pr":"812","finished":"2026-11-03T12:00:00Z","task":"Landed"}"#,
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

    fn text(q: &Queue, v: &QueueView, w: usize) -> String {
        page(q, v, Palette { no_color: true }, 0, w)
            .iter()
            .map(plain)
            .collect::<Vec<_>>()
            .join("\n")
    }

    fn key(c: char) -> KeyEvent {
        KeyEvent::from(KeyCode::Char(c))
    }

    #[test]
    fn the_page_has_the_web_pages_sections_in_order() {
        let q = fixture();
        let s = text(&q, &QueueView::default(), 160);
        let at = |h: &str| s.find(h).unwrap_or_else(|| panic!("{h} missing from\n{s}"));
        assert!(at("WAITING FOR YOU  1") < at("RUNNING  1"));
        assert!(at("RUNNING  1") < at("UP NEXT  2"));
        assert!(at("UP NEXT  2") < at("DONE TODAY  1"));
        assert!(s.contains("4 done (3 ok, 0 failed, 1 cancelled)"), "{s}");
        assert!(s.contains("to PR median 95m"), "{s}");
        assert!(s.contains("waits: night (01:00-06:00)"), "{s}");
        assert!(s.contains("ok, PR 812"), "{s}");
        assert!(
            s.contains("lab:game-agent-3") && s.contains("Pick a side"),
            "{s}"
        );

        let empty = Queue::default();
        let s = text(&empty, &QueueView::default(), 120);
        assert!(
            !s.contains("WAITING FOR YOU"),
            "an empty waiting section is left out"
        );
        assert!(
            s.contains("Nothing here.") && s.contains("Nothing finished today."),
            "{s}"
        );
    }

    #[test]
    fn the_overview_line_counts_each_state_and_the_held_ones() {
        assert_eq!(
            counts(&fixture()),
            "1 waiting for you, 1 running, 2 up next (1 held), 1 done today"
        );
    }

    #[test]
    fn cancel_waits_on_y_and_bump_steps_the_selected_item() {
        let q = fixture();
        let mut v = QueueView::default();
        assert_eq!(v.selected(&q).unwrap().slug, "pick-sides");
        assert_eq!(v.key(key('c'), Some(&q)), Ask::Done);
        assert_eq!(v.confirm.as_deref(), Some("pick-sides"));
        assert!(text(&q, &v, 200).contains("Cancel pick-sides?"));
        assert_eq!(v.key(key('n'), Some(&q)), Ask::Done, "n drops it");
        assert!(v.confirm.is_none());
        v.key(key('c'), Some(&q));
        assert_eq!(v.key(key('y'), Some(&q)), Ask::Cancel("pick-sides".into()));

        assert_eq!(
            v.key(key('+'), Some(&q)),
            Ask::Bump("pick-sides".into(), "urgent")
        );
        for _ in 0..9 {
            v.key(key('j'), Some(&q));
        }
        let at = |v: &QueueView| v.selected(&q).unwrap().slug.clone();
        assert_eq!(at(&v), "night-sweep", "j stops at the last active item");
        assert_eq!(v.key(key('-'), Some(&q)), Ask::Done);
        assert!(
            matches!(&v.said, Some(Err(e)) if e.contains("already low")),
            "{:?}",
            v.said
        );
        assert_eq!(
            v.key(key('+'), Some(&q)),
            Ask::Bump("night-sweep".into(), "normal")
        );
        v.key(key('k'), Some(&q));
        assert_eq!(at(&v), "next-up");
        assert_eq!(v.key(key('+'), Some(&q)), Ask::Done);
        assert!(
            matches!(&v.said, Some(Err(e)) if e.contains("already urgent")),
            "{:?}",
            v.said
        );
        assert_eq!(
            v.key(key('-'), Some(&q)),
            Ask::Bump("next-up".into(), "high")
        );

        v.running = Some("cancel x".into());
        v.key(key('c'), Some(&q));
        assert!(v.confirm.is_none(), "no second action while one runs");
        assert_eq!(v.key(key('x'), Some(&q)), Ask::Pass);
    }

    #[test]
    fn a_new_read_keeps_the_selection_on_its_slug() {
        let q = fixture();
        let mut v = QueueView {
            sel: 2,
            ..Default::default()
        };
        assert_eq!(v.selected(&q).unwrap().slug, "next-up");
        let mut fewer = fixture();
        fewer.items.retain(|i| i.slug != "pick-sides");
        v.reselect(Some("next-up".into()), &fewer);
        assert_eq!(v.selected(&fewer).unwrap().slug, "next-up");
        v.reselect(Some("gone".into()), &Queue::default());
        assert_eq!(v.sel, 0);
    }
}
