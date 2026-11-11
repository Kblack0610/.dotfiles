//! The Builds section's Quarantine fold, both surfaces: for each repo whose base branch carries a
//! test quarantine, its `quarantine.py report --json` (entries per owner row, the day each ends,
//! days left) and the last nightly's KNOWN and now-passing counts. `schedules-sync` writes it
//! beside the run ledger (`quarantine.json`) each pass; this only reads it. A repo with no
//! quarantine has no lane, and no file means no fold.

use serde::{Deserialize, Serialize};

use crate::releases::Level;
use crate::text::short_day;

/// An entry this many days from its end is amber: time to fix it or extend it.
pub const SOON_DAYS: i64 = 3;

/// The file `schedules-sync` writes: one lane per repo.
#[derive(Serialize, Deserialize, Debug, Default, Clone, PartialEq)]
#[serde(default)]
pub struct File {
    pub repos: Vec<Lane>,
}

/// One repo's quarantine on its base branch.
#[derive(Serialize, Deserialize, Debug, Default, Clone, PartialEq)]
#[serde(default)]
pub struct Lane {
    pub repo: String,
    /// Why the last read failed; the lane keeps the numbers of the read before it.
    pub error: Option<String>,
    pub report: Option<Report>,
    /// None until a finished nightly on the base uploaded its summary.
    pub nightly: Option<Nightly>,
}

/// `quarantine.py report --json`, as of the collector's local date.
#[derive(Serialize, Deserialize, Debug, Default, Clone, PartialEq)]
#[serde(default)]
pub struct Report {
    pub entries: u64,
    /// Grouped by (end date, owner row), the soonest end first.
    pub rows: Vec<OwnerRow>,
}

#[derive(Serialize, Deserialize, Debug, Default, Clone, PartialEq)]
#[serde(default)]
pub struct OwnerRow {
    /// The board row that owns the fix, as the quarantine file names it.
    pub row: String,
    pub entries: u64,
    /// The ISO date the entries stop being quarantined.
    pub ends: String,
    /// Zero or less: ended, and the tests count as red again.
    pub days_left: i64,
}

/// The last finished nightly's counts. The test names behind `now_passing` stay in the file.
#[derive(Serialize, Deserialize, Debug, Default, Clone, PartialEq)]
#[serde(default)]
pub struct Nightly {
    pub url: Option<String>,
    pub created_at: Option<String>,
    /// summary.txt's "N known red", every class summed.
    pub known: u64,
    /// Quarantined tests that passed; None when the run kept no suite logs to count them from.
    pub now_passing: Option<u64>,
}

impl OwnerRow {
    /// Red once ended (its tests count as red again), amber within `SOON_DAYS` of its end.
    pub fn level(&self) -> Level {
        if self.days_left <= 0 {
            Level::Bad
        } else if self.days_left <= SOON_DAYS {
            Level::Warn
        } else {
            Level::Ok
        }
    }

    /// Its days left as a row draws them: `ended`, else `Nd`.
    pub fn left(&self) -> String {
        if self.days_left <= 0 {
            "ended".into()
        } else {
            format!("{}d", self.days_left)
        }
    }
}

impl Lane {
    fn entries_where(&self, f: impl Fn(&OwnerRow) -> bool) -> u64 {
        self.rows().iter().filter(|r| f(r)).map(|r| r.entries).sum()
    }

    /// Entries whose end date has passed.
    fn ended(&self) -> u64 {
        self.entries_where(|r| r.days_left <= 0)
    }

    /// Entries ending within `SOON_DAYS`, not yet ended.
    fn soon(&self) -> u64 {
        self.entries_where(|r| r.days_left > 0 && r.days_left <= SOON_DAYS)
    }

    pub fn rows(&self) -> &[OwnerRow] {
        self.report.as_ref().map_or(&[], |r| &r.rows)
    }

    /// Red when the last read failed, else its worst owner row's.
    pub fn level(&self) -> Level {
        if self.error.is_some() {
            return Level::Bad;
        }
        self.rows()
            .iter()
            .map(OwnerRow::level)
            .min()
            .unwrap_or(Level::Ok)
    }

    /// One line: the count and its nearest end, then the nightly.
    pub fn says(&self) -> String {
        let name = project_map::canonical(&self.repo);
        let mut out = match &self.report {
            Some(r) => format!(
                "{name}: {} quarantined over {} owner rows",
                r.entries,
                r.rows.len()
            ),
            None => format!("{name}: no report yet"),
        };
        let (ended, soon) = (self.ended(), self.soon());
        if ended > 0 {
            out.push_str(&format!(", {ended} ended"));
        }
        if soon > 0 {
            out.push_str(&format!(", {soon} end within {SOON_DAYS}d"));
        }
        if let Some(next) = self.rows().iter().find(|r| r.days_left > 0) {
            out.push_str(&format!(
                ", next end {} ({})",
                short_day(&next.ends),
                next.left()
            ));
        }
        out.push_str("; ");
        out.push_str(&match &self.nightly {
            Some(n) => {
                let day = n
                    .created_at
                    .as_deref()
                    .map_or("?", |c| short_day(c.get(..10).unwrap_or(c)));
                let now = n.now_passing.map_or("now passing unread".to_string(), |p| {
                    format!("{p} now pass")
                });
                format!("nightly {day}: {} known red, {now}", n.known)
            }
            None => "no finished nightly with a summary".into(),
        });
        if let Some(e) = &self.error {
            out.push_str(&format!("; last read failed: {e}"));
        }
        out
    }
}

/// The lanes in `text`, or why the file did not parse.
pub fn parse(text: &str) -> Result<Vec<Lane>, String> {
    serde_json::from_str::<File>(text)
        .map(|f| f.repos)
        .map_err(|e| format!("quarantine.json: {e}"))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn row(row: &str, entries: u64, ends: &str, days_left: i64) -> OwnerRow {
        OwnerRow {
            row: row.into(),
            entries,
            ends: ends.into(),
            days_left,
        }
    }

    fn lane(rows: Vec<OwnerRow>) -> Lane {
        Lane {
            repo: "Org/playground".into(),
            report: Some(Report {
                entries: rows.iter().map(|r| r.entries).sum(),
                rows,
            }),
            nightly: Some(Nightly {
                created_at: Some("2026-11-11T08:00:00Z".into()),
                known: 12,
                now_passing: Some(627),
                ..Default::default()
            }),
            ..Default::default()
        }
    }

    #[test]
    fn a_lane_reads_from_the_collectors_file_and_says_its_counts_and_nightly() {
        let text = r#"{"generated_at":"2026-11-11T18:00:00Z","absent":{"Org/x":"2026-11-11T18:00:00Z"},
          "repos":[{"repo":"Org/playground","base":"main","etag":"W/\"e\"","files":{},
            "report":{"today":"2026-11-11","entries":5,"rows":[
              {"row":"ucp-1","entries":4,"ends":"2026-11-17","days_left":6},
              {"row":"ucp-2","entries":1,"ends":"2026-11-24","days_left":13}]},
            "nightly":{"run_id":9,"attempt":1,"created_at":"2026-11-11T08:00:00Z","known":12,
              "now_passing":2,"now_passing_tests":["A","B"],"logs":3},
            "no_summary":[],"synced_at":"2026-11-11T18:00:00Z","error":null}]}"#;
        let lanes = parse(text).unwrap();
        assert_eq!(lanes.len(), 1);
        let l = &lanes[0];
        assert_eq!(l.rows()[1].row, "ucp-2");
        assert_eq!(l.level(), Level::Ok);
        assert_eq!(
            l.says(),
            "playground: 5 quarantined over 2 owner rows, next end 11-17 (6d); nightly 11-11: 12 known red, 2 now pass"
        );
    }

    #[test]
    fn an_entry_past_its_end_is_red_one_near_it_amber_and_both_are_counted() {
        let mut l = lane(vec![
            row("ucp-1", 2, "2026-11-10", -1),
            row("ucp-2", 3, "2026-11-13", 2),
            row("ucp-3", 4, "2026-11-30", 19),
        ]);
        assert_eq!((l.ended(), l.soon()), (2, 3));
        assert_eq!(l.level(), Level::Bad);
        let levels: Vec<Level> = l.rows().iter().map(OwnerRow::level).collect();
        assert_eq!(levels, [Level::Bad, Level::Warn, Level::Ok]);
        let left: Vec<String> = l.rows().iter().map(OwnerRow::left).collect();
        assert_eq!(left, ["ended", "2d", "19d"]);
        assert!(
            l.says().contains(
                "9 quarantined over 3 owner rows, 2 ended, 3 end within 3d, next end 11-13 (2d)"
            ),
            "{}",
            l.says()
        );
        l.report.as_mut().unwrap().rows.remove(0);
        assert_eq!(l.level(), Level::Warn, "near its end, not past it");
        let calm = lane(vec![row("ucp-3", 4, "2026-11-30", 19)]);
        assert_eq!(calm.level(), Level::Ok, "an end weeks away is no warning");
    }

    #[test]
    fn a_failed_read_is_red_and_keeps_its_last_numbers() {
        let mut l = lane(vec![row("ucp-1", 1, "2026-11-30", 19)]);
        l.error = Some("gh: HTTP 502".into());
        assert_eq!(l.level(), Level::Bad);
        assert!(l.says().starts_with("playground: 1 quarantined"));
        assert!(l.says().ends_with("; last read failed: gh: HTTP 502"));
    }

    #[test]
    fn a_nightly_without_suite_logs_says_so_rather_than_zero() {
        let mut l = lane(vec![]);
        l.nightly.as_mut().unwrap().now_passing = None;
        assert!(
            l.says().ends_with("12 known red, now passing unread"),
            "{}",
            l.says()
        );
        l.nightly = None;
        assert!(l.says().ends_with("no finished nightly with a summary"));
    }

    #[test]
    fn a_file_that_does_not_parse_says_which_file() {
        assert!(parse("{").unwrap_err().starts_with("quarantine.json:"));
    }
}
