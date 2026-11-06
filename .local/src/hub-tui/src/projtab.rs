//! The Projects tab: one table row per lab project with its open version's progress, built by
//! `hub_core::projects` (the same rows and words as agent-web's Projects tab), in flight first,
//! on the shared `DataTable`. j/k pick a project, Enter opens its card over its rows (tasktab.rs,
//! every row key works there), `a` opens every project's rows; in the rows Esc clears the view
//! first and then comes back here, as Backspace does at once. `P` steps the selected project's
//! priority (normal, focus, high, low); app.rs runs the write. This file reads and writes
//! nothing.

use hub_core::page::Page;
use hub_core::projects::{self, Card, Projects, Stats};
use hub_core::session_actions::Runner;
use hub_core::tasks::Feed;
use ratatui::crossterm::event::{KeyCode, KeyEvent};
use ratatui::text::{Line, Span};

use crate::datatable::{DataTable, Took};
use crate::fit::{cell, clip_line, wrap, Cell, Table};
use crate::fmt::Palette;
use crate::tasktab::TaskView;

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

/// The list's columns, `Card`'s `Row::COLUMNS` in order, so the sort's mark lands on its header.
const HEADER: [&str; 13] = [
    "PROJECT", "PROFILE", "STAGE", "VERSION", "PRIO", "OPEN", "DONE", "PCT", "PACE/WK", "ETA",
    "RUN", "WAIT", "QUEUED",
];

#[derive(Debug, Default)]
pub struct ProjView {
    /// The selected row of the list, an index into what the view keeps.
    pub card: usize,
    /// The list's search, chip and sort.
    pub table: DataTable,
    /// The rows are open (tasktab), for one project or for every project.
    pub open: bool,
    /// A `hub tab projects <name>` that came before the cards: opened when they arrive.
    pub want: Option<String>,
    /// The opened card's folded sections are open (`F`).
    pub folds: bool,
}

impl ProjView {
    /// The cards the view keeps, in its order.
    pub fn shown<'a>(&self, cards: &'a [Card]) -> Vec<&'a Card> {
        self.table.view.apply(cards)
    }

    /// The selected row of `n`: a re-read can leave `card` past what the view now keeps.
    fn at(&self, n: usize) -> usize {
        self.card.min(n.saturating_sub(1))
    }

    /// The selected project, when the view keeps one.
    pub fn selected<'a>(&self, cards: &'a [Card]) -> Option<&'a Card> {
        let shown = self.shown(cards);
        shown.get(self.at(shown.len())).copied()
    }

    /// Open one project's rows, or with None every project's.
    pub fn open(&mut self, tv: &mut TaskView, c: Option<&Card>) {
        tv.project = c.map(|c| (c.profile.clone(), c.name.clone()));
        tv.table.clear();
        tv.said = None;
        tv.sel = 0;
        self.open = true;
    }

    /// Back to the list, the selection on the row it was on.
    pub fn close(&mut self, tv: &mut TaskView) {
        self.open = false;
        tv.prompt = None;
        tv.said = None;
    }

    /// `hub tab projects <name>`: the project of that name, whatever the list's view keeps, else
    /// every project's rows searched for it.
    pub fn go(&mut self, tv: &mut TaskView, cards: &[Card], name: &str) {
        let named = |c: &Card| {
            c.name.eq_ignore_ascii_case(name)
                || format!("{}/{}", c.profile, c.name).eq_ignore_ascii_case(name)
        };
        match cards.iter().find(|c| named(c)) {
            Some(c) => {
                if let Some(i) = self.shown(cards).iter().position(|s| named(s)) {
                    self.card = i;
                }
                self.open(tv, Some(c));
            }
            None => {
                self.open(tv, None);
                tv.table.view.q = name.to_string();
            }
        }
    }

    /// The list's keys; false for one it does not take.
    pub fn key(&mut self, tv: &mut TaskView, k: KeyEvent, cards: &[Card], page: usize) -> bool {
        match self.table.key::<Card>(k.code) {
            Took::Typing => return true,
            Took::View => {
                self.card = 0;
                return true;
            }
            Took::No => {}
        }
        let n = self.shown(cards).len();
        let last = n.saturating_sub(1);
        self.card = self.at(n);
        match k.code {
            KeyCode::Char('j') | KeyCode::Down => self.card = (self.card + 1).min(last),
            KeyCode::Char('k') | KeyCode::Up => self.card = self.card.saturating_sub(1),
            KeyCode::PageDown | KeyCode::Char(' ') => {
                self.card = (self.card + page.max(1)).min(last)
            }
            KeyCode::PageUp => self.card = self.card.saturating_sub(page.max(1)),
            KeyCode::Char('g') | KeyCode::Home => self.card = 0,
            KeyCode::Char('G') | KeyCode::End => self.card = last,
            KeyCode::Enter => {
                if let Some(c) = self.selected(cards) {
                    self.open(tv, Some(c));
                }
            }
            KeyCode::Char('a') => self.open(tv, None),
            KeyCode::Esc if !self.table.is_default() => {
                self.table.clear();
                self.card = 0;
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

/// The opened card's first line: name, profile, stage, priority.
fn head(c: &Card, p: Palette, w: usize) -> Line<'static> {
    let spans = vec![
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

/// A folded section's head: `TITLE  what it holds`, then the key when it is folded.
fn fold_head(title: &str, says: &str, folds: bool, p: Palette, w: usize) -> Line<'static> {
    let mut spans = vec![
        Span::styled(title.to_string(), p.head()),
        Span::styled(format!("  {says}"), p.dim()),
    ];
    if !folds {
        spans.push(Span::styled("  F opens it", p.dim()));
    }
    clip_line(Line::from(spans), w)
}

/// The opened card, over its rows: the card, its goal and Flow, what needs the human (always
/// open), then Build by system, Next stage, Shipped, In flight and the Agent note as folded
/// heads with their counts, which `F` opens together. `page` is None while it is read.
pub fn open_lines(
    c: &Card,
    page: Option<&Page>,
    folds: bool,
    p: Palette,
    w: usize,
) -> Vec<Line<'static>> {
    let mut out = vec![head(c, p, w)];
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

/// One line of the list: `Card`'s columns, a blank word as `-`.
fn row(c: &Card, p: Palette) -> Vec<Cell> {
    let dash = |s: &str| if s.is_empty() { "-" } else { s }.to_string();
    let or_dash = |n: Option<u32>, unit: &str| n.map_or("-".to_string(), |n| format!("{n}{unit}"));
    let lit = |n: usize, on| {
        let style = if n > 0 { on } else { p.dim() };
        cell(n.to_string(), style)
    };
    vec![
        c.name.clone().into(),
        c.profile.clone().into(),
        dash(&c.stage).into(),
        dash(c.version.as_deref().unwrap_or_default()).into(),
        cell(
            dash(&c.prio),
            if c.prio == "focus" { p.head() } else { p.dim() },
        ),
        c.progress.open.to_string().into(),
        c.progress.done.to_string().into(),
        or_dash(c.percent, "%").into(),
        format!("{:.1}", c.pace()).into(),
        or_dash(c.eta_days, "d").into(),
        lit(c.running.len(), p.good()),
        lit(c.waiting, p.warn()),
        c.queued.to_string().into(),
    ]
}

/// The list, and the line the selected row is on (the app keeps it in view).
pub fn page(
    pr: &Projects,
    feed: Option<&Feed>,
    pv: &ProjView,
    p: Palette,
    w: usize,
) -> (Vec<Line<'static>>, Option<usize>) {
    let shown = pv.shown(&pr.cards);
    let total = pr.cards.len();
    let count = if shown.len() == total {
        total.to_string()
    } else {
        format!("{} of {total}", shown.len())
    };
    let flying = pv
        .table
        .view
        .states(&pr.cards)
        .iter()
        .find(|c| c.name == "in flight")
        .map_or(0, |c| c.n);
    let mut out = vec![clip_line(
        Line::from(vec![
            Span::styled("PROJECTS", p.head()),
            Span::styled(
                format!(
                    "  {count} projects, {flying} in flight; progress is the open version's rows by size (#size/s 1, m 3, l 8)"
                ),
                p.dim(),
            ),
        ]),
        w,
    )];
    for e in &pr.errors {
        out.extend(wrapped("", e, p.warn(), p, w));
    }
    out.push(clip_line(Line::from(pv.table.status(&pr.cards, p)), w));
    let rows = feed.map_or("reading notes board".to_string(), |f| {
        format!("{} open rows", f.open_rows(None).len())
    });
    out.push(clip_line(
        Line::from(vec![
            Span::styled("ALL ROWS", p.head()),
            Span::styled(format!("  {rows}; a opens them"), p.dim()),
        ]),
        w,
    ));
    out.push(Line::raw(""));
    let mut at = None;
    if shown.is_empty() {
        let none = if total > 0 {
            "No project matches."
        } else {
            "No projects."
        };
        out.push(Line::styled(none, p.dim()));
    } else {
        let (mut t, starts) = Table {
            header: HEADER.to_vec(),
            rows: shown.iter().map(|c| row(c, p)).collect(),
            keep: vec![0, 7, 10, 11, 2, 9, 5, 6, 8, 12, 3, 4, 1],
            right: (5..HEADER.len()).collect(),
            mark: pv.table.mark::<Card>(),
            ..Default::default()
        }
        .fit_wrapped(w, p.head());
        if let Some(&start) = starts.get(pv.at(shown.len())) {
            t[start].style = p.sel();
            at = Some(out.len() + start);
        }
        out.append(&mut t);
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
                "BUILD BY SYSTEM  1 systems, 1 open epics (2 rows with no epic)  F opens it",
                "NEXT STAGE  beta  4 of 12 met, 1 failing, 1 human, 6 not checkable yet  F opens it",
                "SHIPPED  none yet  F opens it",
                "IN FLIGHT  0 running, 0 waiting, 0 queued; 0 rows #requested, 0 in the inbox  F opens it",
                "AGENT NOTE  model-written, 2026-11-05  F opens it",
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
        assert!(!open.contains("F opens it"));
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

    fn key(c: char) -> KeyEvent {
        KeyEvent::from(KeyCode::Char(c))
    }

    fn enter() -> KeyEvent {
        KeyEvent::from(KeyCode::Enter)
    }

    #[test]
    fn enter_opens_the_selected_project_a_opens_every_row_and_a_name_opens_its_project() {
        let pr = fixture();
        let (mut pv, mut tv) = (ProjView::default(), TaskView::default());
        for _ in 0..3 {
            assert!(pv.key(&mut tv, key('j'), &pr.cards, 10));
        }
        assert_eq!(pv.card, 1, "j stops at the last row");
        pv.key(&mut tv, enter(), &pr.cards, 10);
        assert!(pv.open);
        assert_eq!(tv.project, Some(("personal".into(), "demo".into())));
        pv.close(&mut tv);
        assert!(!pv.open);
        assert_eq!(pv.card, 1, "back on the row it opened");
        pv.key(&mut tv, key('a'), &pr.cards, 10);
        assert!(pv.open && tv.project.is_none());
        assert_eq!(pv.card, 1, "All leaves the selection where it was");
        assert!(!pv.key(&mut tv, key('z'), &pr.cards, 10));

        pv.go(&mut tv, &pr.cards, "personal/Garden");
        assert_eq!(
            (pv.card, tv.project.clone()),
            (0, Some(("personal".into(), "garden".into())))
        );
        pv.go(&mut tv, &pr.cards, "menu");
        assert_eq!(
            (tv.project.clone(), tv.table.view.q.as_str()),
            (None, "menu")
        );
    }

    #[test]
    fn the_header_is_cards_columns_in_order() {
        use hub_core::table::Row as _;
        assert_eq!(HEADER.len(), Card::COLUMNS.len());
        for (h, c) in HEADER.iter().zip(Card::COLUMNS) {
            assert!(h.to_lowercase().starts_with(c), "{h} is not {c}");
        }
    }

    #[test]
    fn a_re_read_that_shrinks_the_view_leaves_the_last_row_selected() {
        let pr = fixture();
        let (mut pv, mut tv) = (
            ProjView {
                card: 5,
                ..Default::default()
            },
            TaskView::default(),
        );
        assert_eq!(pv.selected(&pr.cards).unwrap().name, "demo");
        let (l, at) = page(&pr, None, &pv, Palette { no_color: true }, 200);
        assert!(plain(&l[at.unwrap()]).starts_with("demo"));
        pv.key(&mut tv, key('k'), &pr.cards, 10);
        assert_eq!(pv.card, 0, "k moves from the row on screen");
    }

    #[test]
    fn the_shared_keys_narrow_the_list_and_enter_opens_the_row_on_screen() {
        let pr = fixture();
        let (mut pv, mut tv) = (ProjView::default(), TaskView::default());
        pv.key(&mut tv, key('j'), &pr.cards, 10);
        for c in "/demo".chars() {
            assert!(pv.key(&mut tv, key(c), &pr.cards, 10), "{c} is typed");
        }
        assert!(pv.table.typing.is_some());
        assert_eq!(pv.shown(&pr.cards).len(), 2, "nothing applies until Enter");
        pv.key(&mut tv, enter(), &pr.cards, 10);
        assert!(!pv.open, "Enter ends the search, it opens nothing");
        assert_eq!(
            pv.card, 0,
            "the view changed, so the selection is back on top"
        );
        assert_eq!(pv.shown(&pr.cards).len(), 1);
        pv.key(&mut tv, enter(), &pr.cards, 10);
        assert_eq!(tv.project, Some(("personal".into(), "demo".into())));
        pv.close(&mut tv);

        // A project the view hides still opens by name, and Back keeps the selection.
        pv.go(&mut tv, &pr.cards, "garden");
        assert_eq!(pv.card, 0);
        pv.close(&mut tv);

        assert!(pv.key(&mut tv, KeyEvent::from(KeyCode::Esc), &pr.cards, 10));
        assert!(pv.table.is_default(), "Esc clears the view");
        assert!(!pv.key(&mut tv, KeyEvent::from(KeyCode::Esc), &pr.cards, 10));

        pv.key(&mut tv, key('s'), &pr.cards, 10);
        assert_eq!(pv.table.view.sort, "project");
        let (l, _) = page(&pr, None, &pv, Palette { no_color: true }, 200);
        let s: Vec<String> = l.iter().map(plain).collect();
        assert!(s.iter().any(|l| l.starts_with("PROJECT v")), "{s:?}");
        pv.key(&mut tv, key('f'), &pr.cards, 10);
        assert_eq!(pv.shown(&pr.cards).len(), 0, "none is in flight");
        let (l, at) = page(&pr, None, &pv, Palette { no_color: true }, 200);
        let s = l.iter().map(plain).collect::<Vec<_>>().join("\n");
        assert!(s.contains("0 of 2 projects"), "{s}");
        assert!(s.contains("No project matches."), "{s}");
        assert_eq!(at, None);
    }

    #[test]
    fn the_list_is_one_row_a_project_and_names_what_no_card_claims() {
        let mut pr = fixture();
        pr.cards[0].prio = "focus".into();
        pr.cards[0].waiting = 1;
        pr.cards[1].version = None;
        pr.cards[1].eta_days = None;
        let pv = ProjView {
            card: 1,
            ..Default::default()
        };
        let (l, at) = page(&pr, None, &pv, Palette { no_color: true }, 200);
        let s: Vec<String> = l.iter().map(plain).collect();
        assert!(
            s[0].starts_with("PROJECTS  2 projects, 1 in flight"),
            "{s:?}"
        );
        assert_eq!(s[1], "all 2  in flight 1  waiting 1");
        assert!(s[2].starts_with("ALL ROWS  reading notes board"), "{s:?}");
        assert_eq!(s[4].split_whitespace().collect::<Vec<_>>(), HEADER.to_vec());
        assert_eq!(
            s[5].split_whitespace().collect::<Vec<_>>(),
            [
                "garden", "personal", "alpha", "v0.0.1", "focus", "1", "3", "75%", "1.0", "7d",
                "0", "1", "0"
            ]
        );
        assert_eq!(
            s[at.unwrap()].split_whitespace().collect::<Vec<_>>(),
            ["demo", "personal", "alpha", "-", "-", "2", "0", "0%", "1.0", "-", "0", "0", "0"]
        );
        let tail = s.join("\n");
        assert!(
            tail.contains("NOT ON A CARD  1 active queue items"),
            "{tail}"
        );
        assert!(tail.ends_with("  dotfiles: fix the hook"), "{tail}");

        let narrow = page(&pr, None, &pv, Palette { no_color: true }, 40).0;
        assert!(narrow.iter().all(|l| plain(l).len() <= 40));
        let head = narrow.iter().map(plain).find(|l| l.starts_with("PROJECT "));
        let head = head.expect("the header stays");
        assert!(head.contains("PCT"), "{head}");
    }
}
