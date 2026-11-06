//! Log's folded sections that only this tab draws: the machinery's actions (`hub_core::actions`,
//! the ledger agent-web's Actions section reads) and the shepherd's kept rundowns
//! (`hub_core::boards::rundowns`). Each list stops at `FOLD_ROWS` and says how many it left out.

use hub_core::actions::{Action, Gathered};
use hub_core::boards::Rundown;
use hub_core::layout::FOLD_ROWS;
use ratatui::text::{Line, Span};

use crate::datatable::DataTable;
use crate::fit::{cell, clip_line, Cell, Table};
use crate::fmt::{clock, older, Palette};

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
