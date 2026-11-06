//! The Projects tab: one card per lab project with its open version's progress, built by
//! `hub_core::projects` (the same cards and words as agent-web's Projects tab), in flight
//! first, under an All entry. j/k pick a card, Enter opens its rows (tasktab.rs, every row key
//! works there), `/` opens All with a search; in the rows Esc clears a filter first and then
//! comes back here, as Backspace does at once. `P` steps the selected project's priority
//! (normal, focus, high, low); app.rs runs the write. This file reads and writes nothing.

use std::collections::HashMap;

use hub_core::projects::{self, Card, Projects, Stats};
use hub_core::session_actions::Runner;
use hub_core::tasks::Feed;
use ratatui::crossterm::event::{KeyCode, KeyEvent};
use ratatui::text::{Line, Span};

use crate::fit::{clip_line, wrap};
use crate::fmt::Palette;
use crate::tasktab::{Kind, Prompt, TaskView};

/// One read of the cards' inputs that are not the board feed: `notes projects --stats --json`
/// and project-map.json's repos (the queue join).
#[derive(Debug)]
pub struct Loaded {
    pub stats: Result<Vec<Stats>, String>,
    pub repos: HashMap<String, String>,
}

pub fn load(runner: &dyn Runner) -> Loaded {
    let repos = std::fs::read_to_string(projects::map_path())
        .map(|t| projects::repos(&t))
        .unwrap_or_default();
    Loaded {
        stats: projects::stats(runner),
        repos,
    }
}

#[derive(Debug, Default)]
pub struct ProjView {
    /// 0 is All, then the cards in their order.
    pub card: usize,
    /// The rows are open (tasktab), for one card or for All.
    pub open: bool,
    /// A `hub tab projects <name>` that came before the cards: opened when they arrive.
    pub want: Option<String>,
}

impl ProjView {
    /// Open the selected entry's rows: All, or one card's project.
    pub fn open(&mut self, tv: &mut TaskView, cards: &[Card]) {
        tv.project = self
            .card
            .checked_sub(1)
            .and_then(|i| cards.get(i))
            .map(|c| (c.profile.clone(), c.name.clone()));
        if tv.project.is_none() {
            self.card = 0;
        }
        tv.search.clear();
        tv.said = None;
        tv.sel = 0;
        self.open = true;
    }

    /// Back to the cards, with the open project's card selected.
    pub fn close(&mut self, tv: &mut TaskView) {
        self.open = false;
        tv.prompt = None;
        tv.said = None;
    }

    /// `hub tab projects <name>`: the card of that name, else All searched for it.
    pub fn go(&mut self, tv: &mut TaskView, cards: &[Card], name: &str) {
        let named = |c: &Card| {
            c.name.eq_ignore_ascii_case(name)
                || format!("{}/{}", c.profile, c.name).eq_ignore_ascii_case(name)
        };
        match cards.iter().position(named) {
            Some(i) => {
                self.card = i + 1;
                self.open(tv, cards);
            }
            None => {
                self.card = 0;
                self.open(tv, cards);
                tv.search = name.to_string();
            }
        }
    }

    /// The card list's keys; false for one it does not take.
    pub fn key(&mut self, tv: &mut TaskView, k: KeyEvent, cards: &[Card], page: usize) -> bool {
        let last = cards.len();
        match k.code {
            KeyCode::Char('j') | KeyCode::Down => self.card = (self.card + 1).min(last),
            KeyCode::Char('k') | KeyCode::Up => self.card = self.card.saturating_sub(1),
            KeyCode::PageDown | KeyCode::Char(' ') => {
                self.card = (self.card + page.max(1)).min(last)
            }
            KeyCode::PageUp => self.card = self.card.saturating_sub(page.max(1)),
            KeyCode::Char('g') | KeyCode::Home => self.card = 0,
            KeyCode::Char('G') | KeyCode::End => self.card = last,
            KeyCode::Enter => self.open(tv, cards),
            KeyCode::Char('/') => {
                self.card = 0;
                self.open(tv, cards);
                tv.prompt = Some(Prompt {
                    kind: Kind::Search,
                    text: String::new(),
                    row: None,
                });
            }
            _ => return false,
        }
        true
    }
}

const BAR: usize = 20;

/// `[#######.............]`, the closed share of the open version by size.
fn bar(percent: Option<u32>, p: Palette) -> Vec<Span<'static>> {
    let on = percent.map_or(0, |pc| (pc as usize * BAR).div_ceil(100).min(BAR));
    vec![
        Span::raw("["),
        Span::styled("#".repeat(on), p.good()),
        Span::styled(".".repeat(BAR - on), p.dim()),
        Span::raw("]"),
    ]
}

/// `text` word-wrapped to `w` under a `lead` label, continuation lines indented to match.
fn wrapped(
    lead: &str,
    text: &str,
    style: ratatui::style::Style,
    p: Palette,
    w: usize,
) -> Vec<Line<'static>> {
    let words: Vec<&str> = text.split_whitespace().collect();
    let room = w.saturating_sub(lead.len()).max(10);
    wrap(&words, " ", room)
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

/// One card: name, the bar and its numbers, the goal, what is running, the counts, the status.
pub fn card_lines(c: &Card, p: Palette, w: usize) -> Vec<Line<'static>> {
    let mut out = vec![clip_line(
        Line::from(vec![
            Span::styled(c.name.to_uppercase(), p.head()),
            Span::styled(format!("  {}, {}", c.profile, c.stage), p.dim()),
            Span::styled(
                if c.prio.is_empty() {
                    String::new()
                } else {
                    format!(", prio {}", c.prio)
                },
                if c.prio == "focus" { p.head() } else { p.dim() },
            ),
        ]),
        w,
    )];
    let mut b = vec![Span::raw("  ")];
    b.extend(bar(c.percent, p));
    let numbers = projects::summary(c);
    if w == 0 || BAR + 5 + numbers.len() <= w {
        b.push(Span::raw(format!("  {numbers}")));
        out.push(Line::from(b));
    } else {
        out.push(Line::from(b));
        out.extend(wrapped("  ", &numbers, Default::default(), p, w));
    }
    if !c.goal.is_empty() {
        out.extend(wrapped("  goal     ", &c.goal, Default::default(), p, w));
    }
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
    let counts = format!(
        "{} running, {} waiting, {} queued; {} rows #requested, {} in the inbox",
        c.running.len(),
        c.waiting,
        c.queued,
        c.requested,
        c.inbox
    );
    out.extend(wrapped("  queue    ", &counts, Default::default(), p, w));
    if !c.status.is_empty() {
        let lead = format!("  {} ", c.status_date);
        out.extend(wrapped(&lead, &c.status, p.dim(), p, w));
    }
    out
}

/// The card list, and the line the selected entry starts on (the app keeps it in view).
pub fn page(
    pr: &Projects,
    feed: Option<&Feed>,
    pv: &ProjView,
    p: Palette,
    w: usize,
) -> (Vec<Line<'static>>, Option<usize>) {
    let flying = pr.cards.iter().filter(|c| c.in_flight()).count();
    let mut out = vec![clip_line(
        Line::from(vec![
            Span::styled("PROJECTS", p.head()),
            Span::styled(
                format!(
                    "  {} projects, {flying} in flight; progress is the open version's rows by size (#size/s 1, m 3, l 8)",
                    pr.cards.len()
                ),
                p.dim(),
            ),
        ]),
        w,
    )];
    for e in &pr.errors {
        out.extend(wrapped("", e, p.warn(), p, w));
    }
    out.push(Line::raw(""));
    let rows = feed.map_or("reading notes board".to_string(), |f| {
        format!("{} open rows", f.rows.len())
    });
    let mut all = clip_line(
        Line::from(vec![
            Span::styled("ALL PROJECTS", p.head()),
            Span::styled(
                format!("  {rows}; / searches them, l steps the lane"),
                p.dim(),
            ),
        ]),
        w,
    );
    let mut at = None;
    if pv.card == 0 {
        all.style = p.sel();
        at = Some(out.len());
    }
    out.push(all);
    for (i, c) in pr.cards.iter().enumerate() {
        out.push(Line::raw(""));
        let mut l = card_lines(c, p, w);
        if pv.card == i + 1 {
            l[0].style = p.sel();
            at = Some(out.len());
        }
        out.extend(l);
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

    #[test]
    fn a_card_draws_its_bar_numbers_and_queue_and_wraps_to_the_width() {
        let pr = fixture();
        let l: Vec<String> = card_lines(&pr.cards[0], Palette { no_color: true }, 120)
            .iter()
            .map(plain)
            .collect();
        assert_eq!(l[0], "GARDEN  personal, alpha");
        assert_eq!(
            l[1],
            "  [###############.....]  v0.0.1 75% (3 of 4 by size), 7d 2, 28d 4, ETA 7d"
        );
        assert_eq!(l[2], "  goal     the human can see where each project is");
        assert!(
            l[3].starts_with("  queue    0 running, 0 waiting, 0 queued"),
            "{l:?}"
        );
        assert_eq!(l[4], "  2026-11-05 landed the cards");
        let narrow: Vec<String> = card_lines(&pr.cards[0], Palette { no_color: true }, 40)
            .iter()
            .map(plain)
            .collect();
        assert!(narrow.iter().all(|s| s.len() <= 40), "{narrow:?}");
        assert!(narrow.join(" ").contains("ETA 7d"), "{narrow:?}");
    }

    #[test]
    fn enter_opens_a_card_slash_searches_all_and_a_name_opens_its_card() {
        let pr = fixture();
        let (mut pv, mut tv) = (ProjView::default(), TaskView::default());
        let k = |c| KeyEvent::from(KeyCode::Char(c));
        for _ in 0..3 {
            assert!(pv.key(&mut tv, k('j'), &pr.cards, 10));
        }
        assert_eq!(pv.card, 2, "j stops at the last card");
        pv.key(&mut tv, KeyEvent::from(KeyCode::Enter), &pr.cards, 10);
        assert!(pv.open);
        assert_eq!(tv.project, Some(("personal".into(), "demo".into())));
        pv.close(&mut tv);
        assert!(!pv.open);
        assert_eq!(pv.card, 2, "back on the card it opened");
        pv.key(&mut tv, k('/'), &pr.cards, 10);
        assert!(pv.open && tv.project.is_none());
        assert_eq!(tv.prompt.as_ref().map(|p| p.kind), Some(Kind::Search));
        assert!(!pv.key(&mut tv, k('x'), &pr.cards, 10));

        pv.go(&mut tv, &pr.cards, "personal/Garden");
        assert_eq!(
            (pv.card, tv.project.clone()),
            (1, Some(("personal".into(), "garden".into())))
        );
        pv.go(&mut tv, &pr.cards, "menu");
        assert_eq!(
            (pv.card, tv.project.clone(), tv.search.as_str()),
            (0, None, "menu")
        );
    }

    #[test]
    fn the_list_puts_all_first_and_names_what_no_card_claims() {
        let pr = fixture();
        let pv = ProjView {
            card: 1,
            ..Default::default()
        };
        let (l, at) = page(&pr, None, &pv, Palette { no_color: true }, 200);
        let s: Vec<String> = l.iter().map(plain).collect();
        assert!(
            s[0].starts_with("PROJECTS  2 projects, 0 in flight"),
            "{s:?}"
        );
        assert!(
            s[2].starts_with("ALL PROJECTS  reading notes board"),
            "{s:?}"
        );
        assert_eq!(s[at.unwrap()], "GARDEN  personal, alpha");
        let tail = s.join("\n");
        assert!(
            tail.contains("NOT ON A CARD  1 active queue items"),
            "{tail}"
        );
        assert!(tail.ends_with("  dotfiles: fix the hook"), "{tail}");
    }
}
