//! The Queue tab: agent-queue's items in agent-web's sections (Waiting for you, Running, Up next,
//! Done today), read through `hub_core::queue`, the same reader as agent-web's Queue tab. j/k
//! pick an active item, `c` arms a cancel that waits on y, and `+`/`-` move its priority one
//! step. Below them the Candidates fold (`hub_core::queue::candidates`, `fleet-dispatch
//! suggest`): `f` opens it, j/k carry on into its rows, and `p` starts the selected one through
//! the Projects tab's Start (`fleet-dispatch promote`). Every write goes through hub-core.

use hub_core::pipeline::{self, Pipeline};
use hub_core::queue::{Candidate, Candidates, Item, Queue, State, SECTIONS};
use hub_core::tasks::Write;
use ratatui::crossterm::event::{KeyCode, KeyEvent, KeyModifiers};
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
    /// Start a candidate: its label and the board write.
    Promote(String, Write),
}

#[derive(Default)]
pub struct QueueView {
    /// Index into `active`, then into the candidates the open fold shows.
    pub sel: usize,
    pub cands_open: bool,
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

    /// The candidates the fold lists: none while it is shut.
    pub fn shown<'a>(&self, c: &'a [Candidate]) -> &'a [Candidate] {
        if self.cands_open {
            c
        } else {
            &[]
        }
    }

    pub fn selected_cand<'a>(&self, q: &Queue, c: &'a [Candidate]) -> Option<&'a Candidate> {
        let i = self.sel.checked_sub(active(q).len())?;
        self.shown(c).get(i)
    }

    /// A new read keeps the selection on the same slug when it is still active, and otherwise
    /// in range of the items and shown candidates.
    pub fn reselect(&mut self, was: Option<String>, q: &Queue, c: &[Candidate]) {
        let rows = active(q);
        let n = rows.len() + self.shown(c).len();
        self.sel = was
            .and_then(|s| rows.iter().position(|i| i.slug == s))
            .unwrap_or(self.sel)
            .min(n.saturating_sub(1));
    }

    /// `page` is the body's height in rows: PgUp/PgDn and space move the selection a page,
    /// Ctrl-d/Ctrl-u half of one, g/G to the first and last row. The app keeps the selected row
    /// in view, so every move scrolls the page with it.
    pub fn key(&mut self, k: KeyEvent, q: Option<&Queue>, c: &[Candidate], page: usize) -> Ask {
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
        let n = active(q).len() + self.shown(c).len();
        let last = n.saturating_sub(1);
        let half = (page / 2).max(1);
        let ctrl = k.modifiers.contains(KeyModifiers::CONTROL);
        let busy = || Some(Err("an action is still running".to_string()));
        match k.code {
            KeyCode::Char('d') if ctrl => self.sel = (self.sel + half).min(last),
            KeyCode::Char('u') if ctrl => self.sel = self.sel.saturating_sub(half),
            _ if ctrl => return Ask::Pass,
            KeyCode::Char('j') | KeyCode::Down => self.sel = (self.sel + 1).min(last),
            KeyCode::Char('k') | KeyCode::Up => self.sel = self.sel.saturating_sub(1),
            KeyCode::PageDown | KeyCode::Char(' ') => self.sel = (self.sel + page.max(1)).min(last),
            KeyCode::PageUp => self.sel = self.sel.saturating_sub(page.max(1)),
            KeyCode::Char('g') | KeyCode::Home => self.sel = 0,
            KeyCode::Char('G') | KeyCode::End => self.sel = last,
            KeyCode::Char('f') => {
                self.cands_open = !self.cands_open;
                self.reselect(None, q, c);
            }
            KeyCode::Char('p') => match self.selected_cand(q, c) {
                _ if self.running.is_some() => self.said = busy(),
                Some(cand) => {
                    self.said = None;
                    return Ask::Promote(
                        format!("promote {} {}", cand.project, cand.key),
                        cand.start(),
                    );
                }
                None if !self.cands_open => {
                    self.said = Some(Err("f opens the candidates, then j/k onto one".into()))
                }
                None => self.said = Some(Err("j/k onto a candidate to promote it".into())),
            },
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
    // The weight (agent-queue's, heavy or light) rides in extra; MODE shows it beside the mode.
    let mode = match i.extra.get("weight").and_then(|w| w.as_str()) {
        Some(w) => format!("{} {w}", i.mode),
        None => i.mode.clone(),
    };
    let mut task = i.title().to_string();
    if let Some(n) = &i.note {
        task = format!("{task}  ({n})");
    }
    vec![
        cell(i.slug.clone(), Default::default()),
        cell(i.priority.clone(), prio),
        i.project.clone().into(),
        mode.into(),
        t.into(),
        state(i, p),
        task.into(),
    ]
}

/// The pipeline summary at the top of the page (hub_core::pipeline, the agent_chain_* gauges):
/// the counts, a bottleneck line when a step is past its bound, `o graph` when Grafana is known.
/// While the read runs it says so; with the gauges absent or the read failed it says `pipeline -`
/// and never a zero.
pub fn pipeline_lines(
    pipe: Option<&Result<Option<Pipeline>, String>>,
    graph: bool,
    p: Palette,
    w: usize,
) -> Vec<Line<'static>> {
    let hint = if graph { "   o graph" } else { "" };
    match pipe {
        None => vec![clip_line(
            Line::styled("pipeline  reading Prometheus", p.dim()),
            w,
        )],
        Some(Err(e)) => vec![clip_line(
            Line::styled(format!("{}  {e}", pipeline::NONE), p.warn()),
            w,
        )],
        Some(Ok(None)) => vec![clip_line(
            Line::styled(format!("{}{hint}", pipeline::NONE), p.dim()),
            w,
        )],
        Some(Ok(Some(pl))) => {
            let mut out = vec![clip_line(Line::raw(format!("{}{hint}", pl.line())), w)];
            if let Some(b) = pl.bottleneck_line() {
                out.push(clip_line(Line::styled(b, p.warn()), w));
            }
            out
        }
    }
}

pub fn page(
    q: &Queue,
    v: &QueueView,
    cands: Option<&Result<Candidates, String>>,
    pipe: (Option<&Result<Option<Pipeline>, String>>, bool),
    p: Palette,
    now: i64,
    w: usize,
) -> (Vec<Line<'static>>, Option<usize>) {
    let mut out = pipeline_lines(pipe.0, pipe.1, p, w);
    let mut at_line = None;
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
                at_line = Some(out.len() + at + 1);
            }
        }
        out.append(&mut t);
    }
    out.push(Line::raw(""));
    let top = out.len();
    let (more, cand_at) = candidates(q, v, cands, p, w);
    out.extend(more);
    (out, at_line.or(cand_at.map(|a| a + top)))
}

/// The Candidates fold: its heading counts every ranked row and how many a worker takes; open,
/// it lists the first `CANDIDATES_SHOWN` in rank order and says how many more there are.
fn candidates(
    q: &Queue,
    v: &QueueView,
    cands: Option<&Result<Candidates, String>>,
    p: Palette,
    w: usize,
) -> (Vec<Line<'static>>, Option<usize>) {
    let mark = if v.cands_open { "-" } else { "+" };
    let hint = if v.cands_open {
        "f folds, p promotes"
    } else {
        "f opens"
    };
    let (count, hint) = match cands {
        None => (String::new(), "reading fleet-dispatch suggest"),
        Some(Err(_)) => (String::new(), ""),
        Some(Ok(c)) => (format!(" ({}, {} auto)", c.total, c.auto), hint),
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
    let shown = v.shown(&c.rows);
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
    if let Some(at) = v
        .sel
        .checked_sub(active(q).len())
        .filter(|i| *i < shown.len())
    {
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

    fn text(q: &Queue, v: &QueueView, w: usize) -> String {
        text_with(q, v, None, w)
    }

    fn text_with(
        q: &Queue,
        v: &QueueView,
        c: Option<&Result<Candidates, String>>,
        w: usize,
    ) -> String {
        page(q, v, c, (None, false), Palette { no_color: true }, 0, w)
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
            s.contains("plan heavy"),
            "the weight shows beside the mode\n{s}"
        );
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
    fn cancel_waits_on_y_and_bump_steps_the_selected_item() {
        let q = fixture();
        let mut v = QueueView::default();
        assert_eq!(v.selected(&q).unwrap().slug, "pick-sides");
        assert_eq!(v.key(key('c'), Some(&q), &[], 10), Ask::Done);
        assert_eq!(v.confirm.as_deref(), Some("pick-sides"));
        assert!(text(&q, &v, 200).contains("Cancel pick-sides?"));
        assert_eq!(v.key(key('n'), Some(&q), &[], 10), Ask::Done, "n drops it");
        assert!(v.confirm.is_none());
        v.key(key('c'), Some(&q), &[], 10);
        assert_eq!(
            v.key(key('y'), Some(&q), &[], 10),
            Ask::Cancel("pick-sides".into())
        );

        assert_eq!(
            v.key(key('+'), Some(&q), &[], 10),
            Ask::Bump("pick-sides".into(), "urgent")
        );
        for _ in 0..9 {
            v.key(key('j'), Some(&q), &[], 10);
        }
        let at = |v: &QueueView| v.selected(&q).unwrap().slug.clone();
        assert_eq!(at(&v), "night-sweep", "j stops at the last active item");
        assert_eq!(v.key(key('-'), Some(&q), &[], 10), Ask::Done);
        assert!(
            matches!(&v.said, Some(Err(e)) if e.contains("already low")),
            "{:?}",
            v.said
        );
        assert_eq!(
            v.key(key('+'), Some(&q), &[], 10),
            Ask::Bump("night-sweep".into(), "high")
        );
        v.key(key('k'), Some(&q), &[], 10);
        assert_eq!(at(&v), "next-up");
        assert_eq!(v.key(key('+'), Some(&q), &[], 10), Ask::Done);
        assert!(
            matches!(&v.said, Some(Err(e)) if e.contains("already urgent")),
            "{:?}",
            v.said
        );
        assert_eq!(
            v.key(key('-'), Some(&q), &[], 10),
            Ask::Bump("next-up".into(), "high")
        );

        v.running = Some("cancel x".into());
        v.key(key('c'), Some(&q), &[], 10);
        assert!(v.confirm.is_none(), "no second action while one runs");
        assert_eq!(v.key(key('x'), Some(&q), &[], 10), Ask::Pass);
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
        v.reselect(Some("next-up".into()), &fewer, &[]);
        assert_eq!(v.selected(&fewer).unwrap().slug, "next-up");
        v.reselect(Some("gone".into()), &Queue::default(), &[]);
        assert_eq!(v.sel, 0);
    }
    #[test]
    fn candidates_fold_shut_with_their_counts_below_the_queue() {
        let q = fixture();
        let c = Ok(cands());
        let s = text_with(&q, &QueueView::default(), Some(&c), 200);
        assert!(s.contains("+ CANDIDATES (3, 2 auto)  f opens"), "{s}");
        assert!(
            s.find("DONE TODAY").unwrap() < s.find("CANDIDATES").unwrap(),
            "below the queue\n{s}"
        );
        assert!(!s.contains("bar-17"), "no row shows while folded\n{s}");
        assert!(text(&q, &QueueView::default(), 200).contains("+ CANDIDATES  reading"));
        let err = Err("fleet-dispatch: unknown command suggest".to_string());
        assert!(text_with(&q, &QueueView::default(), Some(&err), 200)
            .contains("No candidates: fleet-dispatch: unknown command suggest"));
    }

    #[test]
    fn open_candidates_list_ranked_rows_with_auto_or_man_and_held() {
        let q = fixture();
        let c = Ok(cands());
        let mut v = QueueView::default();
        assert_eq!(v.key(key('f'), Some(&q), &cands().rows, 10), Ask::Done);
        let s = text_with(&q, &v, Some(&c), 200);
        assert!(
            s.contains("- CANDIDATES (3, 2 auto)  f folds, p promotes"),
            "{s}"
        );
        let line = |k: &str| {
            s.lines()
                .find(|l| l.contains(k))
                .unwrap_or_else(|| panic!("{k}\n{s}"))
        };
        let (a, b, m) = (line("bar-17"), line("ucp-408"), line("tr-41"));
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
            v.key(key('p'), Some(&q), &c, 10),
            Ask::Done,
            "shut: nothing to promote"
        );
        assert!(
            matches!(&v.said, Some(Err(e)) if e.contains("f opens")),
            "{:?}",
            v.said
        );
        v.key(key('f'), Some(&q), &c, 10);
        for _ in 0..4 {
            v.key(key('j'), Some(&q), &c, 10);
        }
        assert_eq!(
            v.selected_cand(&q, &c).unwrap().key,
            "bar-17",
            "j runs on past the items"
        );
        assert!(text_with(&q, &v, Some(&Ok(cands())), 200).contains("fix the jump arc"));
        let Ask::Promote(label, w) = v.key(key('p'), Some(&q), &c, 10) else {
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
        v.key(key('j'), Some(&q), &c, 10);
        v.key(key('j'), Some(&q), &c, 10);
        let Ask::Promote(_, w) = v.key(key('p'), Some(&q), &c, 10) else {
            panic!("p promotes")
        };
        let argv = hub_core::tasks::argv(&w).unwrap();
        assert!(argv.contains(&"trader".to_string()), "{argv:?}");
        assert!(!argv.contains(&"--agent".to_string()), "{argv:?}");
        assert_eq!(v.key(key('c'), Some(&q), &c, 10), Ask::Done);
        assert!(v.confirm.is_none(), "c does not cancel a candidate");

        v.key(key('f'), Some(&q), &c, 10);
        assert_eq!(v.sel, 3, "folding brings the selection back to the items");
        v.running = Some("promote x".into());
        v.key(key('f'), Some(&q), &c, 10);
        assert_eq!(
            v.key(key('p'), Some(&q), &c, 10),
            Ask::Done,
            "no second action while one runs"
        );
    }

    fn series(step: &str, v: f64) -> hub_core::prom::Series {
        hub_core::prom::Series {
            labels: [("step".to_string(), step.to_string())].into(),
            value: Some(v),
            points: vec![],
        }
    }

    fn pipe(ratio: f64) -> Result<Option<Pipeline>, String> {
        let wip: Vec<_> = [
            ("inbox", 4.0),
            ("backlog", 312.0),
            ("queued", 3.0),
            ("running", 5.0),
            ("waiting", 2.0),
        ]
        .iter()
        .map(|(s, v)| series(s, *v))
        .collect();
        Ok(pipeline::from_series(
            &wip,
            &[series("waiting", 540.0)],
            &[series("waiting", ratio)],
        ))
    }

    fn lines_of(p: Option<&Result<Option<Pipeline>, String>>, graph: bool) -> Vec<String> {
        pipeline_lines(p, graph, Palette { no_color: true }, 80)
            .iter()
            .map(plain)
            .map(|s| s.trim_end().to_string())
            .collect()
    }

    #[test]
    fn the_pipeline_line_is_the_mockup_with_a_bottleneck() {
        assert_eq!(
            lines_of(Some(&pipe(2.25)), true),
            vec![
                "pipeline  inbox 4  backlog 312  queued 3  running 5  waiting 2   o graph",
                "          ! bottleneck: waiting, age p90 9h (bound 4h)",
            ]
        );
    }

    #[test]
    fn no_step_past_its_bound_is_one_line_and_no_grafana_is_no_hint() {
        assert_eq!(
            lines_of(Some(&pipe(0.8)), false),
            vec!["pipeline  inbox 4  backlog 312  queued 3  running 5  waiting 2"]
        );
    }

    #[test]
    fn negative_control_no_gauges_read_pipeline_dash_never_zeros() {
        let none: Result<Option<Pipeline>, String> = Ok(None);
        assert_eq!(lines_of(Some(&none), true), vec!["pipeline -   o graph"]);
        let err: Result<Option<Pipeline>, String> = Err("CC_PROM_URL is not set".into());
        let l = lines_of(Some(&err), true);
        assert_eq!(l, vec!["pipeline -  CC_PROM_URL is not set"]);
        assert_eq!(lines_of(None, true), vec!["pipeline  reading Prometheus"]);
        assert!(l.iter().all(|s| !s.contains(" 0")));
    }
}
