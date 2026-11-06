//! The Projects tab: one card per lab project with its open version's progress, built by
//! `hub_core::projects` (the same cards and words as agent-web's Projects tab), in flight
//! first, under an All entry. j/k pick a card, Enter opens its rows (tasktab.rs, every row key
//! works there), `/` opens All with a search; in the rows Esc clears a filter first and then
//! comes back here, as Backspace does at once. `P` steps the selected project's priority
//! (normal, focus, high, low); app.rs runs the write. This file reads and writes nothing.

use hub_core::page::Page;
use hub_core::projects::{self, Card, Projects, Stats};
use hub_core::session_actions::Runner;
use hub_core::tasks::Feed;
use ratatui::crossterm::event::{KeyCode, KeyEvent};
use ratatui::text::{Line, Span};

use crate::fit::{clip_line, wrap};
use crate::fmt::Palette;
use crate::tasktab::{Kind, Prompt, TaskView};

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

#[derive(Debug, Default)]
pub struct ProjView {
    /// 0 is All, then the cards in their order.
    pub card: usize,
    /// The rows are open (tasktab), for one card or for All.
    pub open: bool,
    /// A `hub tab projects <name>` that came before the cards: opened when they arrive.
    pub want: Option<String>,
    /// The opened card's folded sections are open (`f`).
    pub folds: bool,
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

/// The card's first line: name, profile, stage, priority, then its queue (`queue` adds it).
fn head(c: &Card, p: Palette, w: usize, queue: bool) -> Line<'static> {
    let mut spans = vec![
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
    ];
    if queue {
        spans.push(Span::styled(format!("  {}", projects::queue(c)), p.dim()));
    }
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

/// One card in the list: what it is, its stage and queue, then the bar and its numbers. The rest
/// is the opened card's (open_lines).
pub fn card_lines(c: &Card, p: Palette, w: usize) -> Vec<Line<'static>> {
    let mut out = vec![head(c, p, w, true)];
    out.extend(bar_lines(c, p, w));
    out
}

/// A folded section's head: `TITLE  what it holds`, then the key when it is folded.
fn fold_head(title: &str, says: &str, folds: bool, p: Palette, w: usize) -> Line<'static> {
    let mut spans = vec![
        Span::styled(title.to_string(), p.head()),
        Span::styled(format!("  {says}"), p.dim()),
    ];
    if !folds {
        spans.push(Span::styled("  f opens it", p.dim()));
    }
    clip_line(Line::from(spans), w)
}

/// The opened card, over its rows: the card, its goal and Flow, what needs the human (always
/// open), then Build by system, Next stage, Shipped, In flight and the Agent note as folded
/// heads with their counts, which `f` opens together. `page` is None while it is read.
pub fn open_lines(
    c: &Card,
    page: Option<&Page>,
    folds: bool,
    p: Palette,
    w: usize,
) -> Vec<Line<'static>> {
    let mut out = vec![head(c, p, w, false)];
    out.extend(bar_lines(c, p, w));
    let warn_if = |b: bool| if b { p.warn() } else { Default::default() };
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
    for e in &pg.errors {
        out.extend(wrapped("  ", e, p.warn(), p, w));
    }
    out.push(Line::raw(""));
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
    out.push(fold_head("BUILD BY SYSTEM", &pg.systems_says, folds, p, w));
    if folds {
        for s in &pg.systems {
            out.extend(wrapped("  ", &s.head, Default::default(), p, w));
            for e in &s.epics {
                out.extend(wrapped("    ", &e.line, warn_if(e.behind), p, w));
            }
            if !s.closed.is_empty() {
                out.extend(wrapped("    ", &s.closed, p.dim(), p, w));
            }
        }
    }
    out.push(fold_head("NEXT STAGE", &pg.next_says, folds, p, w));
    if folds {
        for r in &pg.next_rows {
            out.extend(wrapped(
                &format!("  {:<6} ", r.result),
                &format!("{} ({})", r.requirement, r.stage),
                warn_if(r.result == "FAIL"),
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
    fn a_list_card_is_its_head_with_the_queue_and_its_bar_and_wraps_to_the_width() {
        let pr = fixture();
        let l: Vec<String> = card_lines(&pr.cards[0], Palette { no_color: true }, 120)
            .iter()
            .map(plain)
            .collect();
        assert_eq!(
            l,
            [
                "GARDEN  personal, alpha  0 running, 0 waiting, 0 queued",
                "  [###############.....]  v0.0.1 75% (3 of 4 by size), 7d 2, 28d 4, ETA 7d",
            ],
            "the goal, running list and status are the opened card's"
        );
        let narrow: Vec<String> = card_lines(&pr.cards[0], Palette { no_color: true }, 40)
            .iter()
            .map(plain)
            .collect();
        assert!(narrow.iter().all(|s| s.len() <= 40), "{narrow:?}");
        assert!(narrow.join(" ").contains("ETA 7d"), "{narrow:?}");
    }

    fn a_page() -> Page {
        Page {
            project: "garden".into(),
            flow_line: Some(
                "ideas 3 | briefs 1 | plans 1 | epics 2 | rows 5 | landed 1 | verified 0".into(),
            ),
            needs: vec!["verify: Saves (4 of 4 rows landed, no live proof)".into()],
            systems: vec![hub_core::page::System {
                id: "ui".into(),
                head: "ui  criteria 5 of 7".into(),
                epics: vec![hub_core::page::EpicLine {
                    line: "Menus  [rows]  brief yes  plan 1 of 3  rows 2 of 4  behind".into(),
                    behind: true,
                }],
                closed: "+1 closed, 1 verified".into(),
            }],
            systems_says: "1 systems, 1 open epics (2 rows with no epic)".into(),
            next_says: "beta  4 of 12 met, 1 failing, 1 human, 6 not checkable yet".into(),
            next_rows: vec![hub_core::page::Requirement {
                stage: "beta".into(),
                result: "FAIL".into(),
                requirement: "a soak test".into(),
            }],
            shipped_says: "none yet".into(),
            shipped: vec![],
            errors: vec!["project-stage-check --systems: exited 2".into()],
        }
    }

    #[test]
    fn the_opened_card_puts_needs_you_open_and_folds_the_rest_to_heads_with_counts() {
        let pr = fixture();
        let np = Palette { no_color: true };
        let draw = |pg: Option<&Page>, folds: bool| -> Vec<String> {
            open_lines(&pr.cards[0], pg, folds, np, 200)
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
                "NEEDS YOU  1",
                "  verify: Saves (4 of 4 rows landed, no live proof)",
                "BUILD BY SYSTEM  1 systems, 1 open epics (2 rows with no epic)  f opens it",
                "NEXT STAGE  beta  4 of 12 met, 1 failing, 1 human, 6 not checkable yet  f opens it",
                "SHIPPED  none yet  f opens it",
                "IN FLIGHT  0 running, 0 waiting, 0 queued; 0 rows #requested, 0 in the inbox  f opens it",
                "AGENT NOTE  model-written, 2026-11-05  f opens it",
            ]
        );
        let open = draw(Some(&pg), true).join("\n");
        for s in [
            "  ui  criteria 5 of 7\n    Menus  [rows]",
            "    +1 closed, 1 verified",
            "  FAIL   a soak test (beta)",
            "AGENT NOTE  model-written, 2026-11-05\n  landed the cards",
        ] {
            assert!(open.contains(s), "{s} in {open}");
        }
        assert!(!open.contains("f opens it"));
        let reading = draw(None, true);
        assert_eq!(reading.last().unwrap(), "  reading the page...");
        let mut c = pr.cards[0].clone();
        c.goal.clear();
        let l: Vec<String> = open_lines(&c, None, false, np, 200)
            .iter()
            .map(plain)
            .collect();
        assert_eq!(l[2], "  goal     no goal set");
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
        assert_eq!(
            s[at.unwrap()],
            "GARDEN  personal, alpha  0 running, 0 waiting, 0 queued"
        );
        let tail = s.join("\n");
        assert!(
            tail.contains("NOT ON A CARD  1 active queue items"),
            "{tail}"
        );
        assert!(tail.ends_with("  dotfiles: fix the hook"), "{tail}");
    }
}
