//! The Home tab: what needs you, what is running, the numbers and the health strip, from
//! `hub_core::home` (the reader agent-web's Home uses too). The machines, pools and CI that sat
//! under it until phase 4 are the Infra tab's (docs/dashboards.md "Hub layout").

use hub_core::home::{Chip, Home, Kind, Level, Need};
use ratatui::text::{Line, Span};

use crate::datatable::DataTable;
use crate::fit::{cell, clip_line, wrap, Table};
use crate::fmt::{clock, dur, Palette};

fn age(since: Option<i64>, now: i64) -> String {
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
        mark: view.mark::<Need>().or(Some((0, " v"))),
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
                    Kind::Stopped | Kind::Nightly | Kind::Red => ("", p.bad()),
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
        flexmin: 20,
        flexkeep: true,
        right: vec![0, 3],
        cap: vec![(2, 22), (4, 20), (6, 34)],
    };
    out.extend(t.fit(w, p.dim()));
    more(&mut out, rows.len(), h.shown, "more", p);
    out
}

pub fn page(h: &Home, view: &DataTable, p: Palette, now: i64, w: usize) -> Vec<Line<'static>> {
    let mut out = vec![];
    for e in &h.errors {
        out.push(clip_line(Line::styled(e.clone(), p.warn()), w));
    }

    // The summary leads (dashboards rule 3): two lines, so a long list never buries them.
    let nums: Vec<String> = h
        .numbers
        .iter()
        .map(|n| format!("{} {}", n.label, n.value))
        .collect();
    for (i, l) in wrap(&nums, " | ", w.saturating_sub(9))
        .into_iter()
        .enumerate()
    {
        let head = if i == 0 { "NUMBERS  " } else { "         " };
        out.push(Line::from(vec![Span::styled(head, p.head()), Span::raw(l)]));
    }

    out.push(health_line(&h.health, p, w));
    out.push(Line::raw(""));

    out.extend(needs(h, view, p, now, w));

    out.push(Line::raw(""));
    if h.running.is_empty() {
        out.push(Line::from(vec![
            Span::styled("RUNNING  ", p.head()),
            Span::styled("nothing running from the queue", p.dim()),
        ]));
    } else {
        out.push(Line::styled(
            format!("RUNNING ({})", h.running.len()),
            p.head(),
        ));
        let t = Table {
            mark: None,
            header: vec!["ITEM", "PROJECT", "PHASE", "NEXT", "ETA"],
            rows: h
                .running
                .iter()
                .take(h.shown)
                .map(|r| {
                    let ph = r.phases.as_ref();
                    let eta = ph.and_then(|x| x.eta_epoch).map_or("-".into(), |e| {
                        let s = clock(e, now);
                        if e < now {
                            cell(format!("{s} late"), p.warn())
                        } else {
                            s.into()
                        }
                    });
                    vec![
                        r.title.clone().into(),
                        r.project.clone().into(),
                        ph.map_or("-".into(), |x| format!("{}/{}", x.done, x.total))
                            .into(),
                        ph.and_then(|x| x.next.clone()).unwrap_or("-".into()).into(),
                        eta,
                    ]
                })
                .collect(),
            keep: vec![0, 2, 4, 1, 3],
            flex: Some(0),
            flexmin: 20,
            flexkeep: true,
            right: vec![2],
            cap: vec![(1, 22), (3, 40)],
        };
        out.extend(t.fit(w, p.dim()));
        more(
            &mut out,
            h.running.len(),
            h.shown,
            "more on the Queue tab",
            p,
        );
    }

    out
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
    use hub_core::home::{Chip, Need, NeedKind, Number, Score};
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
            numbers: vec![Number {
                label: "queue",
                value: "1 running, 2 up next".into(),
            }],
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
        viewed(h, &DataTable::default(), 120)
    }

    fn viewed(h: &Home, view: &DataTable, w: usize) -> String {
        page(h, view, Palette { no_color: true }, 1_000, w)
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
            out.contains("RANK v") && out.contains("KIND") && out.contains("WAITED"),
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
        let mut v = DataTable::default();
        typed(&mut v, "project:hub");
        let out = viewed(&h, &v, 120);
        assert!(out.contains("NEEDS YOU (1 of 3)"), "{out}");
        assert!(
            out.contains("Go on?") && !out.contains("Which lobby?"),
            "{out}"
        );
        assert!(out.contains("/project:hub"), "{out}");
        typed(&mut v, "nothing-here");
        let out = viewed(&h, &v, 120);
        assert!(out.contains("no need matches"), "{out}");
    }

    #[test]
    fn a_sort_is_asked_for_and_marks_its_header() {
        let h = three();
        let mut v = DataTable::default();
        for _ in 0..4 {
            v.key::<Need>(KeyCode::Char('s'));
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
        let mut v = DataTable::default();
        v.key::<Need>(KeyCode::Char('/'));
        v.key::<Need>(KeyCode::Char('k'));
        let out = viewed(&h, &v, 80);
        assert!(out.lines().all(|l| l.chars().count() <= 80), "{out}");
        assert!(out.contains("/k_"), "{out}");
        assert!(out.contains("KIND") && out.contains("WHAT"), "{out}");
    }

    #[test]
    fn the_summary_leads_and_only_the_chips_that_are_not_green_are_drawn() {
        let out = text(&home());
        assert!(
            out.starts_with("NUMBERS  queue 1 running, 2 up next"),
            "{out}"
        );
        let (num, need) = (
            out.find("HEALTH").unwrap(),
            out.find("NEEDS YOU (1)").unwrap(),
        );
        assert!(num < need, "health sits above the lists: {out}");
        assert!(out.contains("Question") && out.contains("dodginballs") && out.contains("2m"));
        assert!(out.contains("RUNNING  nothing running from the queue"));
        assert!(out.contains("NUMBERS  queue 1 running, 2 up next"));
        assert!(
            out.contains(" ci WARN ") && out.contains("1 green"),
            "{out}"
        );
        assert!(!out.contains("k3s"), "green chips collapse: {out}");
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
}
