//! The Home tab: what needs you, what changed since last night, what analysis proposes, what is
//! running (with the session counts), the spend, the vitals and the health strip, from `hub_core::home` and `hub_core::briefing`
//! (the readers agent-web's Home uses too). The machines, pools and CI that sat
//! under it until phase 4 are the Infra tab's (docs/dashboards.md "Hub layout").

use std::collections::BTreeMap;

use hub_core::briefing::{self, Fix, Night};
use hub_core::home::{Chip, Home, Level, Need, Running};
use hub_core::vitals::Vitals;
use ratatui::text::{Line, Span};

use crate::datatable::DataTable;
use crate::fit::{cell, clip_line, Table};
use crate::fmt::{clock, dur, Palette};

/// Home's two tables and which has the keys: Needs you, or Running once Tab moves them there.
#[derive(Debug, Default)]
pub struct HomeView {
    pub needs: DataTable,
    pub running: DataTable,
    /// Running has the keys: j/k pick a row and Enter opens it.
    pub on_running: bool,
    /// A key moved Running's selection, so the next draw keeps it in view.
    pub follow: bool,
}

impl HomeView {
    /// A query is being typed into either table.
    pub fn typing(&self) -> bool {
        self.needs.typing.is_some() || self.running.typing.is_some()
    }

    /// Running's rows as drawn: its view over them, at most `h.shown`.
    pub fn running_rows<'a>(&self, h: &'a Home) -> Vec<&'a Running> {
        let mut rows = self.running.view.apply(&h.running);
        rows.truncate(h.shown);
        rows
    }
}

pub(crate) fn age(since: Option<i64>, now: i64) -> String {
    since.map_or("-".into(), |t| dur((now - t).max(0) as f64))
}

/// The Home sections, top to bottom; the caller adds the infra body under them.
/// The "+N ..." line under a capped list, when rows were left out.
fn more(out: &mut Vec<Line<'static>>, len: usize, shown: usize, what: &str, p: Palette) {
    if len > shown {
        out.push(Line::styled(format!("+{} {what}", len - shown), p.dim()));
    }
}

/// NEEDS YOU under `view`, which says only what shows here: everything else that reads Home's
/// needs keeps the whole list, and the rows keep their rank unless a sort is asked for.
fn needs(h: &Home, view: &DataTable, p: Palette, now: i64, w: usize) -> Vec<Line<'static>> {
    let mut out = vec![];
    if h.needs.is_empty() {
        out.push(Line::from(vec![
            Span::styled("NEEDS YOU  ", p.head()),
            Span::styled("nothing waits on you", p.dim()),
        ]));
        return out;
    }
    let rows = view.view.apply(&h.needs);
    let count = if rows.len() == h.needs.len() {
        rows.len().to_string()
    } else {
        format!("{} of {}", rows.len(), h.needs.len())
    };
    out.push(Line::styled(format!("NEEDS YOU ({count})"), p.head()));
    out.push(clip_line(Line::from(view.chips::<Need>(&h.needs, p)), w));
    let asked = view.asked::<Need>(p);
    if !asked.is_empty() {
        out.push(clip_line(Line::from(asked), w));
    }
    if rows.is_empty() {
        out.push(Line::styled(
            "no need matches (/ query, f state, x clears)",
            p.dim(),
        ));
        return out;
    }
    let t = Table {
        // No sort asked for: the rank is the order.
        mark: view.mark::<Need>().or(Some((0, " ^"))),
        // `hub_core::table::Row::COLUMNS` for Need, then the id the row acts on, which this
        // surface has no opened record to show.
        header: vec!["RANK", "KIND", "PROJECT", "WAITED", "HOLDS", "WHAT", "ID"],
        rows: rows
            .iter()
            .take(h.shown)
            .map(|n| {
                // A row the judge said a machine can answer is dim and marked `~` (it ranks
                // below every row only the human can act on).
                let machine = n.score.as_ref().is_some_and(|s| !s.human);
                let (mark, style) = match n.kind {
                    // A condition: no score, nothing a wait counted.
                    _ if n.score.is_none() => ("", p.bad()),
                    _ if machine => ("~", p.dim()),
                    _ => ("", ratatui::style::Style::new()),
                };
                let or_dash = |s: String| if s.is_empty() { "-".to_string() } else { s };
                vec![
                    n.rank.to_string().into(),
                    cell(format!("{mark}{}", n.need.label()), style),
                    or_dash(n.project.clone()).into(),
                    age(n.since, now).into(),
                    or_dash(n.holds()).into(),
                    if machine {
                        cell(n.text.clone(), p.dim())
                    } else {
                        n.text.clone().into()
                    },
                    // A red or nightly row is its own id: say it once.
                    if n.id == n.text {
                        "".into()
                    } else {
                        n.id.clone().into()
                    },
                ]
            })
            .collect(),
        // The rank's two factors (WAITED, HOLDS) outlast PROJECT as the page narrows.
        keep: vec![1, 5, 3, 4, 2, 0, 6],
        flex: Some(5),
        // WHAT wraps, so this is the width it reads at: narrow pages drop ID and RANK first.
        flexmin: 40,
        flexkeep: true,
        right: vec![0, 3],
        cap: vec![(2, 22), (4, 20), (6, 34)],
    };
    out.extend(t.fit_wrapped(w, p.dim()).0);
    more(&mut out, rows.len(), h.shown, "more", p);
    out
}

/// VITALS: the head, then a row per question unless all are on target (dashboards rule 4). A row
/// too wide for the screen stacks its clauses under the question.
fn vitals(v: &Vitals, p: Palette, w: usize) -> Vec<Line<'static>> {
    let head = if v.all_ok { p.good() } else { p.warn() };
    let mut out = vec![Line::from(vec![
        Span::styled("VITALS    ", p.head()),
        Span::styled(v.head.clone(), head),
    ])];
    if v.all_ok {
        return out;
    }
    for r in &v.rows {
        let style = if r.level == Level::Warn {
            p.warn()
        } else {
            p.dim()
        };
        let lead = format!("  {:<8}{}  ", r.question, r.mark());
        let room = w.saturating_sub(lead.len());
        let parts = if r.text().len() <= room {
            vec![r.text()]
        } else {
            r.parts.clone()
        };
        for (i, part) in parts.into_iter().enumerate() {
            let label = if i == 0 {
                lead.clone()
            } else {
                " ".repeat(lead.len())
            };
            out.push(clip_line(
                Line::from(vec![Span::styled(label, style), Span::raw(part)]),
                w,
            ));
        }
    }
    out
}

/// Queue a fix per area name: None while it runs, then what agent-queue answered.
pub type Fixes = BTreeMap<String, Option<Result<String, String>>>;

/// Since last night as Home draws it: the read (None until it answers) and the fixes queued.
pub struct NightView<'a> {
    pub night: Option<&'a Night>,
    pub fixes: &'a Fixes,
}

/// The row `F` queues a fix for: the first bad area with no fix in the queue, or whose
/// queueing failed here.
pub fn next_fix<'a>(n: &'a Night, fixes: &Fixes) -> Option<(&'static str, &'a Fix)> {
    n.rows.iter().find_map(|r| {
        let f = r.fix.as_ref()?;
        let open = match fixes.get(r.area.name) {
            None => f.queued.is_none(),
            Some(local) => matches!(local, Some(Err(_))),
        };
        open.then_some((r.area.name, f))
    })
}

/// SINCE LAST NIGHT: the areas that are not ok, the ok ones in one dim line (dashboards rule 4).
fn night_section(out: &mut Vec<Line<'static>>, v: &NightView, p: Palette, w: usize) {
    let Some(n) = v.night else {
        out.push(Line::from(vec![
            Span::styled("SINCE LAST NIGHT  ", p.head()),
            Span::styled("reading", p.dim()),
        ]));
        return;
    };
    out.push(Line::from(vec![
        Span::styled("SINCE LAST NIGHT  ", p.head()),
        Span::styled(format!("since {}", n.since_label), p.dim()),
    ]));
    for e in &n.errors {
        out.push(clip_line(Line::styled(e.clone(), p.warn()), w));
    }
    let next = next_fix(n, v.fixes).map(|(name, _)| name);
    if !n.rows.is_empty() {
        let t = Table {
            mark: None,
            header: vec!["AREA", "LEVEL", "WHAT", "FIX"],
            rows: n
                .rows
                .iter()
                .map(|r| {
                    let a = &r.area;
                    let level = match a.level {
                        briefing::Level::Bad => cell(a.level.word(), p.bad()),
                        _ => cell(a.level.word(), p.warn()),
                    };
                    let fix = match (&r.fix, v.fixes.get(a.name)) {
                        (None, _) => "".into(),
                        (_, Some(None)) => cell("queueing", p.dim()),
                        (_, Some(Some(Ok(slug)))) => cell(format!("queued {slug}"), p.dim()),
                        (_, Some(Some(Err(e)))) if next == Some(a.name) => {
                            cell(format!("F retry: {e}"), p.warn())
                        }
                        (_, Some(Some(Err(e)))) => cell(format!("failed: {e}"), p.warn()),
                        (
                            Some(Fix {
                                queued: Some(slug), ..
                            }),
                            None,
                        ) => cell(format!("queued {slug}"), p.dim()),
                        _ if next == Some(a.name) => "F queue a fix".into(),
                        _ => cell("queue a fix", p.dim()),
                    };
                    let what = if a.details.is_empty() {
                        a.line.clone()
                    } else {
                        format!("{} ({})", a.line, a.details.join("; "))
                    };
                    vec![a.name.into(), level, what.into(), fix]
                })
                .collect(),
            keep: vec![0, 2, 1, 3],
            flex: Some(2),
            flexmin: 20,
            flexkeep: true,
            right: vec![],
            cap: vec![(3, 34)],
        };
        out.extend(t.fit_wrapped(w, p.dim()).0);
    }
    if !n.ok_line.is_empty() {
        out.push(clip_line(Line::styled(n.ok_line.clone(), p.dim()), w));
    }
}

/// The keys that open a flow chip's view from Home, and the chip each opens: the Queue on that
/// chip's state, or Projects for the board. The inbox is a count with no view of its own.
pub const FLOW_KEYS: [(char, &str); 6] = [
    ('u', "queued"),
    ('w', "running"),
    ('n', "needs"),
    ('e', "done"),
    ('m', "drain"),
    ('b', "board"),
];

/// Home as lines, and the line Running's selected row starts on while Running has the keys.
/// `flow` is (the snapshot has not been read yet, the `o graph` hint applies).
pub fn page(
    h: &Home,
    view: &HomeView,
    night: &NightView,
    p: Palette,
    now: i64,
    w: usize,
    flow: (bool, bool),
) -> (Vec<Line<'static>>, Option<usize>) {
    let mut out = vec![];
    for e in &h.errors {
        out.push(clip_line(Line::styled(e.clone(), p.warn()), w));
    }

    // The flow strip leads, then health and spend (dashboards rule 3).
    out.extend(crate::flowstrip::lines(&h.flow, flow.0, flow.1, p, w));

    out.push(health_line(&h.health, p, w));
    if let Some(spend) = &h.spend {
        // One line that points at Costs, where the spend is broken down (dashboards rule 2).
        out.push(clip_line(
            Line::from(vec![
                Span::styled("SPEND     ", p.head()),
                Span::raw(format!("{spend}  -> Costs")),
            ]),
            w,
        ));
    }
    if let Some(v) = &h.vitals {
        out.extend(vitals(v, p, w));
    }
    out.push(Line::raw(""));

    out.extend(needs(h, &view.needs, p, now, w));

    out.push(Line::raw(""));
    night_section(&mut out, night, p, w);

    out.push(Line::raw(""));
    if h.proposals.is_empty() {
        out.push(Line::from(vec![
            Span::styled("PROPOSALS  ", p.head()),
            Span::styled(
                if h.proposals_failed {
                    "could not read them, see above"
                } else if h.proposals_unread {
                    "reading"
                } else {
                    "nothing proposed"
                },
                p.dim(),
            ),
        ]));
    } else {
        out.push(Line::styled(
            format!("PROPOSALS ({})", h.proposals_head),
            p.head(),
        ));
        let t = Table {
            mark: None,
            header: vec!["STREAM", "PROJECT", "AGE", "PROPOSAL"],
            rows: h
                .proposals
                .iter()
                .take(h.shown)
                .map(|r| {
                    vec![
                        r.stream.clone().into(),
                        r.project.clone().into(),
                        age(r.at(), now).into(),
                        r.title.clone().into(),
                    ]
                })
                .collect(),
            keep: vec![3, 2, 0, 1],
            flex: Some(3),
            flexmin: 20,
            flexkeep: true,
            right: vec![2],
            cap: vec![(0, 18), (1, 18)],
        };
        out.extend(t.fit_wrapped(w, p.dim()).0);
        more(&mut out, h.proposals.len(), h.shown, "more", p);
    }

    out.push(Line::raw(""));
    // The session counts head the list they count: beside the heading when they fit, else on a
    // line under it (clipping would cut the counts that matter, need you and stalled).
    let counts = if h.sessions.is_empty() {
        String::new()
    } else {
        format!("sessions: {}", h.sessions)
    };
    let running_head = |head: Vec<Span<'static>>, out: &mut Vec<Line<'static>>| {
        let n: usize = head.iter().map(|s| s.content.chars().count()).sum();
        if counts.is_empty() {
            out.push(Line::from(head));
        } else if n + 3 + counts.chars().count() <= w {
            let mut line = head;
            line.push(Span::styled(format!("   {counts}"), p.dim()));
            out.push(Line::from(line));
        } else {
            out.push(clip_line(Line::from(head), w));
            out.push(clip_line(Line::styled(format!("  {counts}"), p.dim()), w));
        }
    };
    let mut sel = None;
    if h.running.is_empty() {
        running_head(
            vec![
                Span::styled("RUNNING  ", p.head()),
                Span::styled("nothing running from the queue", p.dim()),
            ],
            &mut out,
        );
    } else {
        let rv = &view.running;
        let kept = rv.view.apply(&h.running);
        let all = kept.len();
        let count = if all == h.running.len() {
            all.to_string()
        } else {
            format!("{all} of {}", h.running.len())
        };
        running_head(
            vec![Span::styled(format!("RUNNING ({count})"), p.head())],
            &mut out,
        );
        out.push(clip_line(Line::from(rv.chips::<Running>(&h.running, p)), w));
        let asked = rv.asked::<Running>(p);
        if !asked.is_empty() {
            out.push(clip_line(Line::from(asked), w));
        }
        let rows = &kept[..all.min(h.shown)];
        if rows.is_empty() {
            out.push(Line::styled(
                "no running item matches (/ query, f state, x clears)",
                p.dim(),
            ));
            return (out, None);
        }
        let t = Table {
            // The sort column in `Row::COLUMNS` order, moved past NEXT; SINCE is not drawn.
            mark: rv.mark::<Running>().and_then(|(i, m)| match i {
                0..=4 => Some((i, m)),
                5..=7 => Some((i + 1, m)),
                _ => None,
            }),
            // `hub_core::table::Row::COLUMNS` for Running, with NEXT after PHASE (the web prints it
            // under the item) and without SINCE, which the session page carries.
            header: vec![
                "ITEM", "PROJECT", "ROW", "EPIC", "PHASE", "NEXT", "ETA", "PR", "CI",
            ],
            rows: rows
                .iter()
                .map(|r| {
                    let ph = r.phases.as_ref();
                    // Late by `overdue`, the clock the web's Overdue chip counts by.
                    let eta = ph.and_then(|x| x.eta_epoch).map_or("-".into(), |e| {
                        let s = clock(e, now);
                        if r.overdue {
                            cell(format!("{s} late"), p.warn())
                        } else {
                            s.into()
                        }
                    });
                    let or_dash = |s: Option<&String>| s.cloned().unwrap_or("-".into());
                    let ci = match r.ci.as_deref() {
                        Some(c) if r.ci_failing() => cell(c.to_string(), p.bad()),
                        Some(c) => c.to_string().into(),
                        None => "-".into(),
                    };
                    vec![
                        r.title.clone().into(),
                        r.project.clone().into(),
                        or_dash(r.row.as_ref()).into(),
                        or_dash(r.epic.as_ref()).into(),
                        ph.map_or("-".into(), |x| format!("{}/{}", x.done, x.total))
                            .into(),
                        ph.and_then(|x| x.next.clone()).unwrap_or("-".into()).into(),
                        eta,
                        or_dash(r.pr.as_ref()).into(),
                        ci,
                    ]
                })
                .collect(),
            // ITEM, then what is late or red, then where it sits; NEXT goes first.
            keep: vec![0, 6, 8, 4, 7, 1, 2, 3, 5],
            flex: Some(0),
            flexmin: 20,
            flexkeep: true,
            right: vec![4],
            cap: vec![(1, 22), (3, 12), (5, 40)],
        };
        let (mut lines, starts) = t.fit_wrapped(w, p.dim());
        // While Running has the keys its selected row is marked, every line it wraps onto.
        if view.on_running {
            let i = rv.sel.min(starts.len() - 1);
            let end = starts.get(i + 1).copied().unwrap_or(lines.len());
            for l in &mut lines[starts[i]..end] {
                l.style = p.sel();
            }
            sel = Some(out.len() + starts[i]);
        }
        out.extend(lines);
        more(&mut out, all, h.shown, "more on the Queue tab", p);
    }

    (out, sel)
}

/// The HEALTH line, Home's and Infra's: green collapses to one line, and only the chips that
/// are not green are drawn, then how many are green.
pub fn health_line(chips: &[Chip], p: Palette, w: usize) -> Line<'static> {
    let mut strip = vec![Span::styled("HEALTH   ", p.head())];
    let bad: Vec<&Chip> = chips.iter().filter(|c| c.level != Level::Ok).collect();
    if chips.is_empty() {
        strip.push(Span::styled("no data", p.dim()));
    } else if bad.is_empty() {
        strip.push(Span::styled(
            format!("all green ({})", chips.len()),
            p.good(),
        ));
    } else {
        for c in &bad {
            let v = match c.level {
                Level::Ok => Some(0.0),
                Level::Warn => Some(1.0),
                Level::Red => Some(2.0),
                Level::Nodata => None,
            };
            let (style, word) = p.status(v);
            strip.push(Span::styled(format!(" {} {word} ", c.name), style));
            strip.push(Span::raw(" "));
        }
        strip.push(Span::styled(
            format!("{} green", chips.len() - bad.len()),
            p.dim(),
        ));
    }
    clip_line(Line::from(strip), w)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::fit::plain;
    use hub_core::briefing::NightRow;
    use hub_core::flow::Strip;
    use hub_core::home::{Chip, Kind, Need, NeedKind, Score};
    use ratatui::crossterm::event::KeyCode;

    fn home() -> Home {
        Home {
            needs: vec![Need {
                kind: Kind::Ask,
                need: NeedKind::Ask,
                rank: 1,
                project: "dodginballs".into(),
                text: "Which lobby?".into(),
                id: "a1".into(),
                target: None,
                since: Some(1_000 - 120),
                recommend: None,
                score: Some(Score::new(true, true, 3, 0, 2)),
            }],
            flow: Strip::build(Some(&crate::queuetab::tests::fixture())),
            sessions: "3 working, 1 need you, 0 stalled".into(),
            spend: Some("claude $573 in 24h".into()),
            health: vec![
                Chip {
                    name: "k3s".into(),
                    level: Level::Ok,
                },
                Chip {
                    name: "ci".into(),
                    level: Level::Warn,
                },
            ],
            shown: hub_core::home::SHOWN,
            ..Default::default()
        }
    }

    fn text(h: &Home) -> String {
        night_text(h, None, &Fixes::new())
    }

    fn night_text(h: &Home, n: Option<&Night>, fixes: &Fixes) -> String {
        viewed_at(h, &HomeView::default(), n, fixes, 120)
    }

    fn viewed(h: &Home, view: &HomeView, w: usize) -> String {
        viewed_at(h, view, None, &Fixes::new(), w)
    }

    fn viewed_at(h: &Home, view: &HomeView, n: Option<&Night>, fixes: &Fixes, w: usize) -> String {
        let v = NightView { night: n, fixes };
        page(
            h,
            view,
            &v,
            Palette { no_color: true },
            1_000,
            w,
            (false, false),
        )
        .0
        .iter()
        .map(plain)
        .collect::<Vec<_>>()
        .join("\n")
    }

    /// Three rows: a question on `dodginballs`, your turn on `hub`, a failing `repo`.
    fn three() -> Home {
        let mut h = home();
        let mut turn = h.needs[0].clone();
        (turn.need, turn.rank, turn.kind) = (NeedKind::Turn, 2, Kind::Session);
        (turn.project, turn.id, turn.text) = ("hub".into(), "hub/x:1".into(), "Go on?".into());
        turn.since = Some(1_000 - 3_900);
        let mut red = h.needs[0].clone();
        (red.need, red.rank, red.kind) = (NeedKind::Red, 3, Kind::Nightly);
        (red.project, red.id, red.text) = ("repo".into(), "repo".into(), "red: Tests".into());
        (red.since, red.score) = (None, None);
        h.needs.extend([turn, red]);
        h
    }

    fn typed(view: &mut DataTable, q: &str) {
        view.key::<Need>(KeyCode::Char('/'));
        view.typing = Some(String::new());
        for c in q.chars() {
            view.key::<Need>(KeyCode::Char(c));
        }
        view.key::<Need>(KeyCode::Enter);
    }

    #[test]
    fn needs_draw_in_rank_with_the_columns_of_the_shared_table() {
        let out = text(&three());
        assert!(
            out.contains("RANK ^") && out.contains("KIND") && out.contains("WAITED"),
            "{out}"
        );
        assert!(
            out.contains("all 3  Question 1  Your turn 1  Failing 1"),
            "{out}"
        );
        assert!(
            !out.contains("Permission"),
            "an empty chip is left out: {out}"
        );
        assert!(out.find("Which lobby?") < out.find("Go on?"), "{out}");
        assert!(out.find("Go on?") < out.find("red: Tests"), "{out}");
        assert!(out.contains("1h05m"), "the wait is exact: {out}");
    }

    #[test]
    fn a_view_narrows_the_rows_and_says_how_many_of_how_many() {
        let h = three();
        let mut v = HomeView::default();
        typed(&mut v.needs, "project:hub");
        let out = viewed(&h, &v, 120);
        assert!(out.contains("NEEDS YOU (1 of 3)"), "{out}");
        assert!(
            out.contains("Go on?") && !out.contains("Which lobby?"),
            "{out}"
        );
        assert!(out.contains("/project:hub"), "{out}");
        typed(&mut v.needs, "nothing-here");
        let out = viewed(&h, &v, 120);
        assert!(out.contains("no need matches"), "{out}");
    }

    #[test]
    fn a_sort_is_asked_for_and_marks_its_header() {
        let h = three();
        let mut v = HomeView::default();
        for _ in 0..4 {
            v.needs.key::<Need>(KeyCode::Char('s'));
        }
        let out = viewed(&h, &v, 120);
        assert!(out.contains("WAITED v") && !out.contains("RANK v"), "{out}");
        assert!(out.find("Go on?") < out.find("Which lobby?"), "{out}");
    }

    #[test]
    fn what_is_typed_shows_at_eighty_columns_however_many_chips_there_are() {
        let mut h = three();
        for need in NeedKind::ALL {
            let mut n = h.needs[0].clone();
            n.need = need;
            h.needs.push(n);
        }
        let mut v = HomeView::default();
        v.needs.key::<Need>(KeyCode::Char('/'));
        v.needs.key::<Need>(KeyCode::Char('k'));
        let out = viewed(&h, &v, 80);
        assert!(out.lines().all(|l| l.chars().count() <= 80), "{out}");
        assert!(out.contains("/k_"), "{out}");
        assert!(out.contains("KIND") && out.contains("WHAT"), "{out}");
    }

    #[test]
    fn the_summary_leads_and_only_the_chips_that_are_not_green_are_drawn() {
        let out = text(&home());
        // The flow strip leads, then health and spend; the queue's counts are the strip's.
        assert!(
            out.starts_with(
                "FLOW  inbox - | board - | up next 1 ready, 1 held | running 1 | on a PR 0 | needs you 1"
            ),
            "{out}"
        );
        assert!(!out.contains("NUMBERS"), "{out}");
        assert!(
            out.contains("\nSPEND     claude $573 in 24h  -> Costs"),
            "{out}"
        );
        let head =
            "RUNNING  nothing running from the queue   sessions: 3 working, 1 need you, 0 stalled";
        assert!(out.contains(head), "the session counts head Running: {out}");
        assert!(
            !out.contains("queue 1 running") && !out.contains("done today"),
            "{out}"
        );
        let (health, spend, need) = (
            out.find("HEALTH").unwrap(),
            out.find("SPEND").unwrap(),
            out.find("NEEDS YOU (1)").unwrap(),
        );
        assert!(
            health < spend && spend < need,
            "health and spend sit above the lists: {out}"
        );
        assert!(out.contains("Question") && out.contains("dodginballs") && out.contains("2m"));
        assert!(
            out.contains(" ci WARN ") && out.contains("1 green"),
            "{out}"
        );
        assert!(!out.contains("k3s"), "green chips collapse: {out}");
    }

    #[test]
    fn narrow_session_counts_drop_under_the_running_heading_whole() {
        let out = viewed(&home(), &HomeView::default(), 60);
        assert!(
            out.contains("RUNNING  nothing running from the queue\n  sessions: 3 working, 1 need you, 0 stalled"),
            "{out}"
        );
        assert!(out.lines().all(|l| l.chars().count() <= 60), "{out}");
    }

    #[test]
    fn a_running_row_shows_its_row_epic_pr_and_ci_and_narrows_to_what_is_late_or_red() {
        let mut h = home();
        h.running = vec![hub_core::home::Running {
            slug: "s1".into(),
            title: "fix(x): the thing".into(),
            project: "dotfiles".into(),
            row: Some("ar-1494".into()),
            epic: Some("ar-1292".into()),
            pr: Some("#1871".into()),
            ci: Some("fail".into()),
            ..Default::default()
        }];
        let out = viewed(&h, &HomeView::default(), 160);
        assert!(
            out.contains("ROW")
                && out.contains("EPIC")
                && out.contains(" PR ")
                && out.contains(" CI"),
            "{out}"
        );
        assert!(
            ["ar-1494", "ar-1292", "#1871", "fail"]
                .iter()
                .all(|s| out.contains(s)),
            "{out}"
        );
        let narrow = viewed(&h, &HomeView::default(), 50);
        assert!(
            narrow.contains("fail") && !narrow.contains("ar-1292"),
            "{narrow}"
        );
        // A title wider than the page wraps under ITEM instead of pushing CI off.
        h.running[0].title = "fix(red): ".to_string() + &"word ".repeat(30);
        let long = viewed(&h, &HomeView::default(), 80);
        assert!(long.contains("fail") && long.contains("#1871"), "{long}");
    }

    #[test]
    fn running_marks_its_selected_row_only_while_it_has_the_keys() {
        let mut h = home();
        h.running = ["fix(a): one", "fix(b): two"]
            .iter()
            .map(|t| hub_core::home::Running {
                slug: t.to_string(),
                title: t.to_string(),
                project: "dotfiles".into(),
                ..Default::default()
            })
            .collect();
        let at = |v: &HomeView| {
            let (lines, sel) = page(
                &h,
                v,
                &NightView {
                    night: None,
                    fixes: &Fixes::new(),
                },
                Palette { no_color: true },
                1_000,
                120,
                (false, false),
            );
            sel.map(|i| (plain(&lines[i]), lines[i].style))
        };
        let mut v = HomeView::default();
        assert_eq!(at(&v), None, "Needs you has the keys: no row is marked");
        v.on_running = true;
        v.running.sel = 1;
        let (line, style) = at(&v).unwrap();
        assert!(line.contains("fix(b): two"), "{line}");
        assert_eq!(style, Palette { no_color: true }.sel());
        // A selection past the rows a re-read left is drawn on the last.
        v.running.sel = 9;
        assert!(at(&v).unwrap().0.contains("fix(b): two"));
    }

    #[test]
    fn an_all_green_strip_is_one_line_and_nothing_waiting_says_so() {
        let mut h = home();
        h.needs.clear();
        h.health.retain(|c| c.level == Level::Ok);
        let out = text(&h);
        assert!(out.contains("NEEDS YOU  nothing waits on you"));
        assert!(out.contains("HEALTH   all green (1)"));
    }

    #[test]
    fn a_long_needs_list_shows_the_cap_and_counts_the_rest() {
        let mut h = home();
        let one = h.needs[0].clone();
        h.needs = (0..h.shown + 3).map(|_| one.clone()).collect();
        let out = text(&h);
        assert_eq!(out.matches("Which lobby?").count(), h.shown, "{out}");
        assert!(out.contains("+3 more"), "{out}");
    }

    #[test]
    fn a_row_says_what_it_holds_and_a_machine_answerable_one_is_marked() {
        let mut h = home();
        let mut auto = h.needs[0].clone();
        auto.id = "b2".into();
        auto.text = "Keep the alias?".into();
        auto.score = Some(Score::new(false, false, 0, 0, 2));
        h.needs.push(auto);
        let out = text(&h);
        assert!(out.contains("HOLDS"), "{out}");
        assert!(out.contains("session, 3 phases"), "{out}");
        let line = out.lines().find(|l| l.contains("Keep the alias?")).unwrap();
        assert!(line.contains("~Question") && line.contains(" - "), "{out}");
        // The server's order is kept: the human's row first.
        assert!(
            out.find("Which lobby?") < out.find("Keep the alias?"),
            "{out}"
        );
    }

    fn night() -> Night {
        let area = |name, level, line: &str| briefing::Area {
            name,
            level,
            line: line.into(),
            details: vec![],
            link: "#fleet",
        };
        let fix = |task: &str| {
            Some(briefing::Fix {
                project: briefing::FIX_PROJECT,
                task: task.into(),
                queued: None,
            })
        };
        Night {
            since_label: "Thu 18:00".into(),
            rows: vec![
                NightRow {
                    area: briefing::Area {
                        details: vec!["shepherd failed 02:10".into()],
                        ..area(
                            "Workers overnight",
                            briefing::Level::Bad,
                            "21 of 23 ok, $77",
                        )
                    },
                    fix: fix("fix workers"),
                },
                NightRow {
                    area: area("Nightly", briefing::Level::Bad, "playground Tests red"),
                    fix: fix("fix nightly"),
                },
                NightRow {
                    area: area("Sessions", briefing::Level::Warn, "2 stalled over 2h"),
                    fix: None,
                },
            ],
            ok_line: "Infra, Delivery, Costs ok".into(),
            errors: vec!["watches: no such dir".into()],
            ..Default::default()
        }
    }

    #[test]
    fn since_last_night_sits_under_needs_you_and_only_names_what_is_not_ok() {
        let n = night();
        let out = night_text(&home(), Some(&n), &Fixes::new());
        let at = |t: &str| out.find(t).unwrap_or_else(|| panic!("{t} missing: {out}"));
        assert!(
            at("NEEDS YOU") < at("SINCE LAST NIGHT  since Thu 18:00"),
            "{out}"
        );
        assert!(at("SINCE LAST NIGHT") < at("PROPOSALS"), "{out}");
        assert!(out.contains("watches: no such dir"), "{out}");
        let row = |t: &str| out.lines().find(|l| l.contains(t)).unwrap().to_string();
        let w = row("Workers overnight");
        assert!(
            w.contains("bad")
                && w.contains("21 of 23 ok, $77 (shepherd failed 02:10)")
                && w.contains("F queue a fix"),
            "{out}"
        );
        let nl = row("playground Tests red");
        assert!(
            nl.contains("queue a fix") && !nl.contains("F queue"),
            "only the next one is F: {out}"
        );
        assert!(
            !row("2 stalled").contains("queue a fix"),
            "a warn row has no fix: {out}"
        );
        assert!(out.contains("Infra, Delivery, Costs ok"), "{out}");

        // Not read yet: it says so, never an all-clear.
        let out = night_text(&home(), None, &Fixes::new());
        assert!(out.contains("SINCE LAST NIGHT  reading"), "{out}");
    }

    #[test]
    fn a_queued_fix_moves_f_to_the_next_bad_row_and_a_failed_one_takes_it_back() {
        let n = night();
        let mut fixes = Fixes::new();
        fixes.insert(
            "Workers overnight".into(),
            Some(Ok("2026-fix-workers".into())),
        );
        assert_eq!(next_fix(&n, &fixes).unwrap().0, "Nightly");
        let out = night_text(&home(), Some(&n), &fixes);
        assert!(out.contains("queued 2026-fix-workers"), "{out}");
        fixes.insert("Nightly".into(), None);
        assert!(
            next_fix(&n, &fixes).is_none(),
            "one in flight is not queued twice"
        );
        assert!(night_text(&home(), Some(&n), &fixes).contains("queueing"));
        fixes.insert(
            "Workers overnight".into(),
            Some(Err("no such project".into())),
        );
        assert_eq!(next_fix(&n, &fixes).unwrap().0, "Workers overnight");
        assert!(night_text(&home(), Some(&n), &fixes).contains("F retry: no such project"));
    }

    #[test]
    fn every_flow_key_names_a_chip_of_the_strip() {
        let strip = Strip::build(None);
        for (key, chip) in FLOW_KEYS {
            let c = strip.chips.iter().find(|c| c.key == chip);
            let c = c.unwrap_or_else(|| panic!("{key}: no chip {chip}"));
            assert!(c.to.is_some(), "{key}: chip {chip} opens nothing");
        }
    }

    #[test]
    fn a_fix_the_queue_already_holds_is_shown_queued_and_not_offered() {
        let mut n = night();
        n.rows[0].fix.as_mut().unwrap().queued = Some("2026-fix-from-web".into());
        let fixes = Fixes::new();
        assert_eq!(next_fix(&n, &fixes).unwrap().0, "Nightly");
        let out = night_text(&home(), Some(&n), &fixes);
        assert!(out.contains("queued 2026-fix-from-web"), "{out}");
    }

    fn fleet_vitals() -> Vitals {
        use hub_core::vitals::Row;
        let row = |q: &str, level, parts: &[&str]| Row {
            question: q.into(),
            level,
            parts: parts.iter().map(|s| s.to_string()).collect(),
        };
        Vitals {
            head: "1 of 2 off target".into(),
            line: "1 of 2 off target: Outcome".into(),
            all_ok: false,
            rows: vec![
                row("Cost", Level::Ok, &["$12.54 per merged PR"]),
                row(
                    "Outcome",
                    Level::Warn,
                    &["Oldest request 340h, limit 72h", "12 unverified, limit 0"],
                ),
            ],
        }
    }

    fn drawn(v: &Vitals, w: usize) -> String {
        vitals(v, Palette { no_color: true }, w)
            .iter()
            .map(plain)
            .collect::<Vec<_>>()
            .join("\n")
    }

    #[test]
    fn vitals_is_the_mockup_at_80_columns() {
        assert_eq!(
            drawn(&fleet_vitals(), 80),
            "VITALS    1 of 2 off target\n  \
             Cost       $12.54 per merged PR\n  \
             Outcome !  Oldest request 340h, limit 72h; 12 unverified, limit 0"
        );
    }

    #[test]
    fn a_vitals_row_too_wide_stacks_its_clauses_and_loses_none() {
        let out = drawn(&fleet_vitals(), 50);
        assert!(
            out.contains("  Outcome !  Oldest request 340h, limit 72h\n"),
            "{out}"
        );
        assert!(
            out.ends_with("\n             12 unverified, limit 0"),
            "{out}"
        );
    }

    #[test]
    fn vitals_all_on_target_is_one_line() {
        let v = Vitals {
            head: "2 of 2 on target".into(),
            all_ok: true,
            ..fleet_vitals()
        };
        assert_eq!(drawn(&v, 80), "VITALS    2 of 2 on target");
    }
}
