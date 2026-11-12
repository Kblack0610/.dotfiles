//! Log's sections that only this tab draws: the Work table (`hub_core::worklog`, what agent-web's
//! Log leads with), the machinery's actions (`hub_core::actions`, the ledger agent-web's Actions
//! section reads) and the shepherd's kept rundowns (`hub_core::boards::rundowns`). Each list stops
//! at its cap and says how many it left out.

use hub_core::actions::{Action, Gathered};
use hub_core::boards::Rundown;
use hub_core::layout::FOLD_ROWS;
use hub_core::worklog::{self, Window, Work};
use ratatui::text::{Line, Span};

use crate::datatable::DataTable;
use crate::fit::{cell, clip_line, Cell, Table};
use crate::fmt::{clock, older, Palette};

/// What `d` steps Work's window through, the values `worklog::Window::parse` takes.
pub const WORK_WINDOWS: [&str; 4] = ["", "today", "30d", "all"];
/// `Work::COLUMNS` in capitals, in its order: the sort mark is placed by that index.
const WORK_HEADER: [&str; 9] = [
    "STATE", "WHEN", "PROJECT", "WHAT", "PLAN", "KIND", "CI", "PR", "COST",
];

/// A time today reads as its clock; an older one keeps its month and day.
fn work_when(when: &str, today: &str) -> String {
    match (when.get(5..10), when.get(11..)) {
        (Some(_), Some(t)) if when.starts_with(today) => t.to_string(),
        (Some(d), Some(t)) => format!("{d} {t}"),
        _ => when.to_string(),
    }
}

fn work_row(r: &Work, today: &str, p: Palette) -> Vec<Cell> {
    let st = match r.state {
        "failed" => p.bad(),
        "waiting" => p.warn(),
        "done" => p.good(),
        _ => p.dim(),
    };
    let pr = match &r.pr {
        Some(pr) => pr.as_str().into(),
        None if r.unproven => cell("no proof", p.warn()),
        None => "".into(),
    };
    vec![
        cell(r.state, st),
        cell(work_when(r.when.as_deref().unwrap_or(""), today), p.dim()),
        r.project.as_str().into(),
        r.what.replace(['\t', '\n'], " ").into(),
        cell(r.plan.as_deref().unwrap_or(""), p.dim()),
        cell(r.kind.as_deref().unwrap_or(""), p.dim()),
        cell(r.ci.as_deref().unwrap_or(""), p.dim()),
        pr,
        r.cost
            .map_or(String::new(), |c| crate::day::money(Some(c)))
            .into(),
    ]
}

/// The Work table on the shared table: what `window` keeps, attention first until a sort is asked
/// for, stopping at `cap`, then how far back each source goes.
pub fn work(
    g: &worklog::Gathered,
    window: &Window,
    t: &DataTable,
    cap: usize,
    today: &str,
    p: Palette,
    w: usize,
) -> Vec<Line<'static>> {
    let mut out: Vec<Line<'static>> = g
        .errors
        .iter()
        .map(|e| clip_line(Line::styled(format!("  unread: {e}"), p.warn()), w))
        .collect();
    let inside: Vec<&Work> = g.rows.iter().filter(|r| window.keeps(r)).collect();
    if inside.is_empty() {
        out.push(Line::styled(
            "  nothing in this window (d steps it)",
            p.dim(),
        ));
        return out;
    }
    out.push(clip_line(Line::from(t.status(&inside, p)), w));
    let rows = t.view.apply(&inside);
    if rows.is_empty() {
        out.push(Line::styled(
            "  no work matches (/ query, f state, x clears)",
            p.dim(),
        ));
        return out;
    }
    out.extend(
        Table {
            header: WORK_HEADER.to_vec(),
            rows: rows
                .iter()
                .take(cap)
                .map(|r| work_row(r, today, p))
                .collect(),
            keep: vec![0, 2, 1, 5, 6, 4],
            flex: Some(3),
            flexmin: 20,
            flexkeep: true,
            mark: t.mark::<Work>(),
            cap: vec![(2, 22), (5, 24)],
            ..Default::default()
        }
        .fit(w, p.head()),
    );
    out.extend(older(rows.len(), cap, p));
    let from = [
        g.items_from
            .as_ref()
            .map(|d| format!("queue items from {d}")),
        g.prs_from.as_ref().map(|d| format!("merged PRs from {d}")),
    ];
    let from: Vec<String> = from.into_iter().flatten().collect();
    if !from.is_empty() {
        out.push(clip_line(
            Line::styled(format!("  {}", from.join(", ")), p.dim()),
            w,
        ));
    }
    out
}

/// How far back the Actions section reads, as agent-web's default window.
pub const ACTIONS_HOURS: i64 = 24;

/// `Action::COLUMNS` in capitals, in its order: the sort mark is placed by that index.
const HEADER: [&str; 6] = ["WHEN", "ACTOR", "VERB", "PRIO", "SOURCE", "TEXT"];

fn row(a: &Action, p: Palette, now: i64) -> Vec<Cell> {
    vec![
        cell(clock(a.at, now), p.dim()),
        a.actor.as_str().into(),
        cell(a.verb.as_str(), p.head()),
        a.priority.as_deref().unwrap_or("").into(),
        cell(a.source.as_str(), p.dim()),
        a.text.replace(['\t', '\n'], " ").into(),
    ]
}

/// The actions on the shared table, newest first until a sort is asked for: the view's chips,
/// then the rows it keeps, stopping at `FOLD_ROWS`.
pub fn actions(g: &Gathered, t: &DataTable, p: Palette, now: i64, w: usize) -> Vec<Line<'static>> {
    let mut out: Vec<Line<'static>> = g
        .errors
        .iter()
        .map(|e| clip_line(Line::styled(format!("  unread: {e}"), p.warn()), w))
        .collect();
    if g.actions.is_empty() {
        out.push(Line::styled(
            format!("  nothing in the last {ACTIONS_HOURS}h"),
            p.dim(),
        ));
        return out;
    }
    out.push(clip_line(Line::from(t.status(&g.actions, p)), w));
    let rows = t.view.apply(&g.actions);
    if rows.is_empty() {
        out.push(Line::styled(
            "  no action matches (/ query, f state, x clears)",
            p.dim(),
        ));
        return out;
    }
    out.extend(
        Table {
            header: HEADER.to_vec(),
            rows: rows
                .iter()
                .take(FOLD_ROWS)
                .map(|a| row(a, p, now))
                .collect(),
            keep: vec![0, 2, 1, 3, 4],
            flex: Some(5),
            flexmin: 20,
            flexkeep: true,
            mark: t.mark::<Action>(),
            ..Default::default()
        }
        .fit(w, p.head()),
    );
    out.extend(older(rows.len(), FOLD_ROWS, p));
    out
}

/// The kept rundowns, newest first: when and its title; agent-web shows the body.
pub fn rundowns(rs: &[Rundown], total: usize, p: Palette, w: usize) -> Vec<Line<'static>> {
    if rs.is_empty() {
        return vec![Line::styled(
            "  none kept yet: fleet-shepherd log --rundown writes one",
            p.dim(),
        )];
    }
    let mut out: Vec<Line<'static>> = rs
        .iter()
        .take(FOLD_ROWS)
        .map(|r| {
            clip_line(
                Line::from(vec![
                    Span::styled(format!("  {}  ", r.stamp), p.dim()),
                    Span::raw(r.title.clone()),
                ]),
                w,
            )
        })
        .collect();
    out.extend(older(total, FOLD_ROWS.min(rs.len()), p));
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use hub_core::actions::Action;

    fn text(l: &[Line]) -> String {
        l.iter()
            .map(|l| {
                l.spans
                    .iter()
                    .map(|s| s.content.as_ref())
                    .collect::<String>()
            })
            .collect::<Vec<_>>()
            .join("\n")
    }

    fn act(at: i64, verb: &str) -> Action {
        Action {
            at,
            actor: "shepherd".into(),
            verb: verb.into(),
            text: "agent-3\tstalled".into(),
            priority: None,
            reference: None,
            source: "shepherd".into(),
        }
    }

    #[test]
    fn the_header_is_hub_cores_columns() {
        use hub_core::table::Row;
        let lower: Vec<String> = HEADER.iter().map(|h| h.to_lowercase()).collect();
        assert_eq!(lower, Action::COLUMNS);
    }

    fn work_row_of(state: &'static str, when: &str, what: &str) -> Work {
        Work {
            state,
            when: Some(when.into()),
            project: "notes".into(),
            what: what.into(),
            plan: None,
            ci: None,
            kind: Some("fix".into()),
            pr: Some("notes#7".into()),
            url: None,
            cost: Some(1.5),
            slug: None,
            unproven: false,
        }
    }

    #[test]
    fn work_narrows_to_the_window_reads_todays_clock_and_stops_at_its_cap() {
        let g = worklog::Gathered {
            rows: vec![
                work_row_of("failed", "2026-11-09T08:05", "broke"),
                work_row_of("done", "2026-11-08T09:30", "shipped"),
                work_row_of("done", "2026-01-02T09:30", "ancient"),
            ],
            items_from: Some("2026-11-04".into()),
            ..Default::default()
        };
        let today = chrono::NaiveDate::from_ymd_opt(2026, 11, 9).unwrap();
        let p = Palette { no_color: true };
        let text = |window: &str, cap| {
            work(
                &g,
                &Window::parse(window, today),
                &DataTable::default(),
                cap,
                "2026-11-09",
                p,
                120,
            )
            .iter()
            .map(|l| {
                l.spans
                    .iter()
                    .map(|s| s.content.as_ref())
                    .collect::<String>()
            })
            .collect::<Vec<_>>()
            .join("\n")
        };
        let week = text("", 10);
        assert!(
            week.contains("08:05") && week.contains("11-08 09:30"),
            "{week}"
        );
        assert!(!week.contains("ancient"), "{week}");
        assert!(text("all", 10).contains("ancient"));
        assert!(!text("2026-11-08", 10).contains("ancient"));
        assert!(
            week.find("broke").unwrap() < week.find("shipped").unwrap(),
            "attention first"
        );
        assert!(week.contains("queue items from 2026-11-04"), "{week}");
        assert!(text("", 1).contains("+1 older"));
    }

    #[test]
    fn actions_stop_at_the_fold_cap_and_count_the_rest() {
        let p = Palette { no_color: true };
        let g = Gathered {
            actions: (0..FOLD_ROWS as i64 + 3)
                .map(|i| act(1000 - i, "nudge"))
                .collect(),
            errors: vec!["dispatch.log: denied".into()],
            ..Gathered::default()
        };
        let t = text(&actions(&g, &DataTable::default(), p, 1000, 120));
        assert!(t.contains("unread: dispatch.log: denied"), "{t}");
        assert!(t.contains("WHEN") && t.contains("agent-3 stalled"), "{t}");
        assert_eq!(t.matches("nudge").count(), FOLD_ROWS);
        assert!(t.ends_with("+3 older"), "{t}");
        let none = text(&actions(
            &Gathered::default(),
            &DataTable::default(),
            p,
            1000,
            120,
        ));
        assert!(none.contains("nothing in the last 24h"), "{none}");
    }

    #[test]
    fn rundowns_list_stamp_and_title_and_count_the_rest() {
        let p = Palette { no_color: true };
        let r = |n: usize| Rundown {
            file: format!("2026-11-05T12{n:02}Z.md"),
            title: format!("what needs me {n}"),
            stamp: format!("2026-11-05 12:{n:02} UTC"),
            body: "x".into(),
        };
        let t = text(&rundowns(&[r(1), r(0)], 4, p, 120));
        assert!(t.find("12:01 UTC  what needs me 1") < t.find("12:00 UTC  what needs me 0"));
        assert!(t.ends_with("+2 older"), "{t}");
        assert!(text(&rundowns(&[], 0, p, 120)).contains("none kept yet"));
    }
}
