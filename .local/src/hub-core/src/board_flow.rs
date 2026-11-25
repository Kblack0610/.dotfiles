//! The agent board's flow over the last week, per project and for the fleet, read from the
//! day-log records (`work.board`, which `day-log snapshot` writes in points from `notes board
//! --weigh`). One reader for every surface: the Projects table's `net7d` column and the
//! Projects card's Growing part.
//!
//! The headline is growth, not size: net is points filed minus done minus dropped, summed over
//! the days. It is never the change in `open_pts`, which also moves when an open row is sized or
//! re-pointed. A cleanup lands in `dropped`, so it never reads as burn.

use std::collections::BTreeMap;
use std::path::Path;

use chrono::NaiveDate;
use serde::Serialize;
use serde_json::Value;

/// How many days the flow sums, ending today and counting today's live record: the window the
/// human reads growth over (2026-11-24). The one constant to change.
pub const DAYS: i64 = 7;

/// Board points over the window.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize)]
pub struct BoardFlow {
    /// Points filed.
    #[serde(rename = "in")]
    pub opened: i64,
    /// Points of rows closed as delivered.
    pub done: i64,
    /// Points of rows closed undelivered or removed while open.
    pub dropped: i64,
    /// `opened - done - dropped`: above zero is a board that grew.
    pub net: i64,
}

impl BoardFlow {
    fn add(&mut self, opened: i64, done: i64, dropped: i64) {
        self.opened += opened;
        self.done += done;
        self.dropped += dropped;
        self.net = self.opened - self.done - self.dropped;
    }

    /// The board grew: the one condition any surface paints amber.
    pub fn growing(&self) -> bool {
        self.net > 0
    }
}

/// The window's flow for the fleet and for each project that had rows move.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Flows {
    pub fleet: Option<BoardFlow>,
    pub by_project: BTreeMap<String, BoardFlow>,
}

impl Flows {
    /// A project's flow: zero when the fleet has a reading and the project had no row move, None
    /// when no day in the window carries points (the record predates them, or none is written).
    pub fn of(&self, project: &str) -> Option<BoardFlow> {
        self.fleet?;
        Some(self.by_project.get(project).copied().unwrap_or_default())
    }
}

/// The flow from the records in `dir` for the [`DAYS`] ending `today`.
pub fn read(dir: &Path, today: NaiveDate) -> Flows {
    let days: Vec<(NaiveDate, Value)> = crate::boards::days(dir)
        .into_iter()
        .filter_map(|d| {
            let date = NaiveDate::parse_from_str(&d, "%Y-%m-%d").ok()?;
            in_window(date, today).then_some(())?;
            Some((date, crate::boards::record(dir, Some(&d))?))
        })
        .collect();
    flows(&days, today)
}

fn in_window(date: NaiveDate, today: NaiveDate) -> bool {
    let age = (today - date).num_days();
    (0..DAYS).contains(&age)
}

/// Sum the days' `work.board` flow. A day whose points are null (no ids on the sheets the day
/// before, or no notes history) adds nothing and is not a zero.
pub fn flows(days: &[(NaiveDate, Value)], today: NaiveDate) -> Flows {
    let mut out = Flows::default();
    for (_, rec) in days.iter().filter(|(d, _)| in_window(*d, today)) {
        let board = &rec["work"]["board"];
        let Some(fleet) = points(board) else {
            continue;
        };
        out.fleet
            .get_or_insert_with(Default::default)
            .add(fleet.0, fleet.1, fleet.2);
        for p in board["by_project"].as_array().into_iter().flatten() {
            let (Some(name), Some(f)) = (p["project"].as_str(), points(p)) else {
                continue;
            };
            out.by_project
                .entry(name.to_string())
                .or_default()
                .add(f.0, f.1, f.2);
        }
    }
    out
}

/// One scope's `(opened_pts, done_pts, dropped_pts)`, None when any is not a number.
fn points(scope: &Value) -> Option<(i64, i64, i64)> {
    Some((
        scope["opened_pts"].as_i64()?,
        scope["done_pts"].as_i64()?,
        scope["dropped_pts"].as_i64()?,
    ))
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn day(s: &str) -> NaiveDate {
        NaiveDate::parse_from_str(s, "%Y-%m-%d").unwrap()
    }

    fn rec(o: i64, d: i64, r: i64, by: Value) -> Value {
        json!({"work": {"board": {"opened_pts": o, "done_pts": d, "dropped_pts": r, "by_project": by}}})
    }

    #[test]
    fn net_is_filed_minus_done_minus_dropped_over_the_days_and_a_cleanup_is_not_burn() {
        let days = [
            (
                day("2026-11-24"),
                rec(
                    100,
                    40,
                    300,
                    json!([{"project": "a", "opened_pts": 100, "done_pts": 40, "dropped_pts": 300}]),
                ),
            ),
            (
                day("2026-11-25"),
                rec(
                    50,
                    10,
                    0,
                    json!([
                        {"project": "a", "opened_pts": 20, "done_pts": 10, "dropped_pts": 0},
                        {"project": "b", "opened_pts": 30, "done_pts": 0, "dropped_pts": 0}
                    ]),
                ),
            ),
        ];
        let f = flows(&days, day("2026-11-25"));
        let fleet = f.fleet.unwrap();
        assert_eq!(
            (fleet.opened, fleet.done, fleet.dropped, fleet.net),
            (150, 50, 300, -200)
        );
        let a = f.of("a").unwrap();
        assert_eq!((a.opened, a.done, a.dropped, a.net), (120, 50, 300, -230));
        assert!(!a.growing());
        let b = f.of("b").unwrap();
        assert_eq!(b.net, 30);
        assert!(b.growing());
        // A project with no row moving in the window reads zero, not unread.
        assert_eq!(f.of("quiet"), Some(BoardFlow::default()));
    }

    #[test]
    fn net_zero_does_not_grow() {
        let days = [(day("2026-11-25"), rec(10, 10, 0, json!([])))];
        let f = flows(&days, day("2026-11-25")).fleet.unwrap();
        assert_eq!(f.net, 0);
        assert!(!f.growing());
    }

    #[test]
    fn a_null_day_adds_nothing_and_no_points_anywhere_is_unread_never_zero() {
        let null = json!({"work": {"board": {"opened_pts": null, "done_pts": null, "dropped_pts": null, "open_end": 3}}});
        let none = json!({"work": {}});
        let days = [(day("2026-11-24"), null), (day("2026-11-25"), none)];
        let f = flows(&days, day("2026-11-25"));
        assert_eq!(f.fleet, None);
        assert_eq!(f.of("a"), None);
        // One real day beside a null one counts only the real one.
        let days = [
            (
                day("2026-11-24"),
                json!({"work": {"board": {"opened_pts": null}}}),
            ),
            (day("2026-11-25"), rec(5, 0, 0, json!([]))),
        ];
        assert_eq!(flows(&days, day("2026-11-25")).fleet.unwrap().net, 5);
    }

    #[test]
    fn only_the_seven_days_ending_today_count() {
        let days = [
            (day("2026-11-18"), rec(1000, 0, 0, json!([]))),
            (day("2026-11-19"), rec(7, 0, 0, json!([]))),
            (day("2026-11-25"), rec(3, 0, 0, json!([]))),
            (day("2026-11-26"), rec(900, 0, 0, json!([]))),
        ];
        // 11-18 is 7 days back: out; 11-19 is 6 back: in; a day after today never counts.
        assert_eq!(flows(&days, day("2026-11-25")).fleet.unwrap().opened, 10);
    }

    #[test]
    fn read_takes_the_records_in_the_directory() {
        let dir = std::env::temp_dir().join(format!("hub-core-board-flow-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(
            dir.join("2026-11-25.json"),
            rec(
                9,
                2,
                1,
                json!([{"project": "a", "opened_pts": 9, "done_pts": 2, "dropped_pts": 1}]),
            )
            .to_string(),
        )
        .unwrap();
        std::fs::write(
            dir.join("2026-11-01.json"),
            rec(500, 0, 0, json!([])).to_string(),
        )
        .unwrap();
        let f = read(&dir, day("2026-11-25"));
        std::fs::remove_dir_all(&dir).ok();
        assert_eq!(f.of("a").unwrap().net, 6);
        assert_eq!(f.fleet.unwrap().opened, 9);
    }
}
