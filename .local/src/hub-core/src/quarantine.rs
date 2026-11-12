//! Infra's CI Tests, its Quarantine part, both surfaces: for each repo whose base branch carries a
//! test quarantine, its `quarantine.py report --json` (entries per owner row and, when the report
//! lists them, each quarantined test with its end and owner row) and the last nightly's KNOWN and
//! now-passing counts. `schedules-sync` writes it beside the run ledger (`quarantine.json`) each
//! pass, so it rides the builds read and its file event; this only reads it. A repo with no
//! quarantine has no lane, and no file means no Quarantine table. The Tests suites read
//! `Lane::tests` too: a failure of a test named there counts as quarantined, not failed.

use std::collections::HashSet;

use serde::{Deserialize, Serialize};

use crate::links::{Kind, Link};
use crate::releases::Level;
use crate::table::{Row, Val};
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
    /// Each quarantined test; absent from a report older than the list, so such a lane has no
    /// per-test rows.
    pub tests: Vec<Held>,
}

/// One quarantined test as the report lists it.
#[derive(Serialize, Deserialize, Debug, Default, Clone, PartialEq)]
#[serde(default)]
pub struct Held {
    /// The NUnit fullname, as a results file names the test-case.
    pub test: String,
    pub ends: String,
    /// The board row id that owns the fix (`ucp-1450`).
    pub row: String,
    /// The owner field as the quarantine file has it, the row id and its title.
    pub owner: String,
    pub days_left: i64,
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

/// The last finished nightly's counts.
#[derive(Serialize, Deserialize, Debug, Default, Clone, PartialEq)]
#[serde(default)]
pub struct Nightly {
    pub url: Option<String>,
    pub created_at: Option<String>,
    /// summary.txt's "N known red", every class summed.
    pub known: u64,
    /// Quarantined tests that passed; None when the run kept no suite logs to count them from.
    pub now_passing: Option<u64>,
    /// The full names behind `now_passing`.
    pub now_passing_tests: Vec<String>,
    /// Quarantined tests the run marked KNOWN (failed); None in a file written before
    /// schedules-sync read them, so a test in neither list there cannot be told "not run".
    pub known_tests: Option<Vec<String>>,
}

/// A day count's level: red once ended (its tests count as red again), amber within
/// `SOON_DAYS` of its end.
fn level_of(days_left: i64) -> Level {
    if days_left <= 0 {
        Level::Bad
    } else if days_left <= SOON_DAYS {
        Level::Warn
    } else {
        Level::Ok
    }
}

/// Days left as a row draws them: `ended`, else `Nd`.
fn left_of(days_left: i64) -> String {
    if days_left <= 0 {
        "ended".into()
    } else {
        format!("{days_left}d")
    }
}

impl OwnerRow {
    pub fn level(&self) -> Level {
        level_of(self.days_left)
    }

    pub fn left(&self) -> String {
        left_of(self.days_left)
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

    /// Each quarantined test, when the report lists them.
    pub fn tests(&self) -> &[Held] {
        self.report.as_ref().map_or(&[], |r| &r.tests)
    }

    /// The names a run's failures are matched against: a test past its end is red again.
    pub fn held(&self) -> HashSet<&str> {
        self.tests()
            .iter()
            .filter(|t| t.days_left > 0)
            .map(|t| t.test.as_str())
            .collect()
    }

    /// The nightly the counts came from, when its URL is GitHub's.
    pub fn url(&self) -> Option<&str> {
        self.nightly
            .as_ref()
            .and_then(|n| n.url.as_deref())
            .filter(|u| u.starts_with("https://"))
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

/// One quarantined test: a row of Tests' Quarantine table.
#[derive(Serialize, Debug, Default, Clone, PartialEq)]
pub struct Entry {
    pub test: String,
    pub repo: String,
    pub row: String,
    pub owner: String,
    pub ends: String,
    pub days_left: i64,
    pub left: String,
    pub level: Level,
    /// `failing` when the last nightly marked it KNOWN, `now passing` when it passed it, `not
    /// run` when it did neither (a UI mutes it), `unread` when no nightly kept the logs to tell.
    /// A nightly read before KNOWN was recorded says `failing` for anything not passing.
    pub nightly: String,
}

/// The last nightly's word sets: the tests it passed, and the ones it failed when they were read.
struct Seen<'a> {
    passing: HashSet<&'a str>,
    failing: Option<HashSet<&'a str>>,
}

impl Entry {
    fn of(lane: &Lane, t: &Held, seen: Option<&Seen>) -> Entry {
        Entry {
            test: t.test.clone(),
            repo: project_map::canonical(&lane.repo),
            row: t.row.clone(),
            owner: t.owner.clone(),
            ends: t.ends.clone(),
            days_left: t.days_left,
            left: left_of(t.days_left),
            level: level_of(t.days_left),
            nightly: match seen {
                None => "unread",
                Some(s) => match &s.failing {
                    Some(f) if f.contains(t.test.as_str()) => "failing",
                    _ if s.passing.contains(t.test.as_str()) => "now passing",
                    Some(_) => "not run",
                    None => "failing",
                },
            }
            .into(),
        }
    }

    /// The chip a row is under: `ended`, `ending` (within `SOON_DAYS`) or `held`.
    pub fn chip(&self) -> &'static str {
        match self.level {
            Level::Bad => "ended",
            Level::Warn => "ending",
            Level::Ok => "held",
        }
    }
}

impl Row for Entry {
    const COLUMNS: &'static [&'static str] = &["test", "repo", "row", "ends", "left", "nightly"];
    const STATES: &'static [&'static str] = &["all", "ended", "ending", "held"];
    const FACETS: &'static [&'static str] = &["repo", "row", "nightly"];
    const LEAD: &'static str = "test";
    const GLANCE: &'static [&'static str] = &["row", "left", "nightly"];

    fn val(&self, col: &str) -> Val {
        let text = |s: &str| match s {
            "" => Val::None,
            s => Val::Text(s.to_string()),
        };
        match col {
            "test" => text(&self.test),
            "repo" => text(&self.repo),
            "row" => text(&self.row),
            "ends" => text(&self.ends),
            "left" => Val::Num(self.days_left as f64),
            "nightly" => text(&self.nightly),
            _ => Val::None,
        }
    }

    fn in_state(&self, state: &str) -> bool {
        state == "all" || self.chip() == state
    }

    /// The owner's title is searched too, not only its row id.
    fn text(&self) -> String {
        [&self.test, &self.repo, &self.owner, &self.nightly]
            .map(|s| s.as_str())
            .join("\n")
            .to_lowercase()
    }

    /// The row opens the board at it, the repo its project.
    fn link(&self, col: &str) -> Option<Link> {
        match col {
            "row" if !self.row.is_empty() => Some(Link::to(Kind::Row, &self.row)),
            "repo" => Some(Link::to(Kind::Project, &self.repo)),
            _ => None,
        }
    }
}

/// Every lane's quarantined tests, the soonest end first, then by repo and name.
pub fn entries(lanes: &[Lane]) -> Vec<Entry> {
    let mut out: Vec<Entry> = vec![];
    for l in lanes {
        let seen = l
            .nightly
            .as_ref()
            .filter(|n| n.now_passing.is_some())
            .map(|n| Seen {
                passing: n.now_passing_tests.iter().map(String::as_str).collect(),
                failing: n
                    .known_tests
                    .as_ref()
                    .map(|k| k.iter().map(String::as_str).collect()),
            });
        out.extend(l.tests().iter().map(|t| Entry::of(l, t, seen.as_ref())));
    }
    out.sort_by(|a, b| (a.days_left, &a.repo, &a.test).cmp(&(b.days_left, &b.repo, &b.test)));
    out
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
    use crate::table::View;

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
                ..Default::default()
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

    fn held(test: &str, row: &str, days_left: i64) -> Held {
        Held {
            test: test.into(),
            ends: "2026-11-20".into(),
            row: row.into(),
            owner: format!("{row} fix(yard): stand the games up"),
            days_left,
        }
    }

    #[test]
    fn each_quarantined_test_is_a_row_with_its_owner_its_end_and_the_nightlys_word() {
        let text = r#"{"repos":[{"repo":"acme/yard","report":{"today":"2026-11-12","entries":3,
            "rows":[{"row":"db-265","entries":3,"ends":"2026-11-20","days_left":8}],
            "tests":[{"test":"P.Yard.Each(\"a\")","ends":"2026-11-20","row":"db-265","owner":"db-265 fix(yard): x","days_left":8}]},
            "nightly":{"known":3,"now_passing":1,"now_passing_tests":["P.Yard.Each(\"a\")"]}}]}"#;
        let lanes = parse(text).unwrap();
        let e = entries(&lanes);
        assert_eq!(e.len(), 1);
        assert_eq!(e[0].test, "P.Yard.Each(\"a\")");
        assert_eq!(e[0].repo, project_map::canonical("acme/yard"));
        assert_eq!(
            (e[0].left.as_str(), e[0].nightly.as_str()),
            ("8d", "now passing")
        );
        assert_eq!(e[0].link("row"), Some(Link::to(Kind::Row, "db-265")));
        assert!(lanes[0].held().contains("P.Yard.Each(\"a\")"));

        let mut l = lane(vec![]);
        l.report.as_mut().unwrap().tests = vec![
            held("A.late", "ucp-3", 19),
            held("A.gone", "ucp-1", -1),
            held("A.soon", "", 2),
        ];
        l.nightly.as_mut().unwrap().now_passing_tests = vec!["A.late".into()];
        let rows = entries(std::slice::from_ref(&l));
        let order: Vec<(&str, &str, &str)> = rows
            .iter()
            .map(|r| (r.test.as_str(), r.left.as_str(), r.nightly.as_str()))
            .collect();
        assert_eq!(
            order,
            [
                ("A.gone", "ended", "failing"),
                ("A.soon", "2d", "failing"),
                ("A.late", "19d", "now passing")
            ],
            "the soonest end first"
        );
        let levels: Vec<Level> = rows.iter().map(|r| r.level).collect();
        assert_eq!(levels, [Level::Bad, Level::Warn, Level::Ok]);
        assert_eq!(rows[1].link("row"), None, "no owner row, no link");
        // an ended test is red again, so a run's failure of it is not held
        assert!(!l.held().contains("A.gone") && l.held().contains("A.soon"));
        let n = |st: &str| View::new::<Entry>("", st, "", "").apply(&rows).len();
        assert_eq!((n("ended"), n("ending"), n("held")), (1, 1, 1));
        assert_eq!(
            View::new::<Entry>("nightly:failing", "", "", "")
                .apply(&rows)
                .len(),
            2
        );
        assert_eq!(
            View::new::<Entry>("stand", "", "", "").apply(&rows).len(),
            3,
            "the owner title is searched"
        );
        // with KNOWN read, a test in neither list did not run, and one in both failed somewhere
        l.nightly.as_mut().unwrap().known_tests = Some(vec!["A.gone".into(), "A.late".into()]);
        let words: Vec<String> = entries(std::slice::from_ref(&l))
            .into_iter()
            .map(|r| r.nightly)
            .collect();
        assert_eq!(words, ["failing", "not run", "failing"]);
        l.nightly.as_mut().unwrap().known_tests = Some(vec![]);
        let words: Vec<String> = entries(std::slice::from_ref(&l))
            .into_iter()
            .map(|r| r.nightly)
            .collect();
        assert_eq!(words, ["not run", "not run", "now passing"]);
        // negative control: a nightly that kept no logs says unread, not failing
        l.nightly.as_mut().unwrap().now_passing = None;
        assert!(entries(&[l]).iter().all(|r| r.nightly == "unread"));
    }

    #[test]
    fn a_report_without_a_test_list_has_no_rows_but_keeps_its_counts() {
        let l = lane(vec![row("ucp-1", 4, "2026-11-30", 19)]);
        assert!(entries(std::slice::from_ref(&l)).is_empty());
        assert!(l.held().is_empty());
        assert!(l.says().contains("4 quarantined"));
    }

    #[test]
    fn a_file_that_does_not_parse_says_which_file() {
        assert!(parse("{").unwrap_err().starts_with("quarantine.json:"));
    }
}
