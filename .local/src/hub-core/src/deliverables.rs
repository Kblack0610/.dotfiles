//! The Deliverables section at the top of the Projects tab, both surfaces: one row per open
//! feature epic across every project, how far it is by size, its ETA and whether it is on track,
//! then a coverage line (how many open rows hang under an epic, and which projects have no
//! feature epic). `fleet-bench epics --json` owns the join, the ETA and the track; this module
//! only picks the rows, orders them and words the lines, so the TUI and the web print the same
//! and compute nothing (dashboards rules 6 and 8). A standing epic (`<system> to standard`) is
//! upkeep, not a deliverable, so it is left out; `page::is_standing` is the one test for it.

use serde::Serialize;

use crate::epics::{self, Chain, Epic};
use crate::session_actions::Runner;
use crate::table::{Row, Val};

/// How many projects with no feature epic the coverage line names before it says `+N more`.
pub const NAMED: usize = 6;

/// What the percent and the done cell mean, printed under the table on both surfaces.
pub const LEGEND: &str =
    "percent is the epic's rows by size (#size/s 1, m 3, l 8), then rows done/all";

/// The track word of an epic whose every task has landed and waits on proof of its outcome.
pub const VERIFY: &str = "verify";

/// One open feature epic.
#[derive(Clone, Debug, Default, PartialEq, Serialize)]
pub struct Deliverable {
    pub project: String,
    pub profile: String,
    pub id: String,
    pub title: String,
    pub system: String,
    /// Rows done and all rows under the epic.
    pub done: u32,
    pub total: u32,
    /// Done over all by size (`#size/s` 1, `m` 3, `l` 8), whole percent; None for an epic with no rows.
    pub percent: Option<u32>,
    /// The finish estimate, epoch seconds, and the day it falls on (`MM-DD`) in the reader's zone.
    pub eta: Option<i64>,
    pub eta_day: String,
    /// The done cell as both surfaces print it: `60% 8/19`, `-` for the percent of an epic with no rows.
    pub done_says: String,
    /// `behind` or `on track` against the frozen baseline, `verify` when every task has landed,
    /// blank when the epic has neither.
    pub track: String,
}

impl Deliverable {
    /// The key a surface opens the project's card by: `<profile>/<project>`.
    pub fn key(&self) -> String {
        format!("{}/{}", self.profile, self.project)
    }

    /// Worst first: behind, then the ones waiting on proof, then on track, then none.
    fn track_rank(&self) -> u8 {
        match self.track.as_str() {
            "behind" => 0,
            VERIFY => 1,
            "on track" => 2,
            _ => 3,
        }
    }
}

fn word(s: &str) -> Val {
    if s.is_empty() {
        Val::None
    } else {
        Val::Text(s.to_string())
    }
}

/// The table's own order is worst first (`track_rank`), then the soonest ETA, so no column is
/// sorted until asked.
impl Row for Deliverable {
    const COLUMNS: &'static [&'static str] = &["project", "epic", "sys", "done", "eta", "track"];
    const STATES: &'static [&'static str] = &["all", "behind", "on track", VERIFY];
    const FACETS: &'static [&'static str] = &["project", "sys"];
    const LEAD: &'static str = "epic";
    const GLANCE: &'static [&'static str] = &["project", "done", "track"];

    fn val(&self, col: &str) -> Val {
        match col {
            "project" => word(&self.project),
            "epic" => word(&self.title),
            "sys" => word(&self.system),
            "done" => self.percent.map_or(Val::None, |p| Val::Num(f64::from(p))),
            "eta" => self.eta.map_or(Val::None, |e| Val::Num(e as f64)),
            "track" => word(&self.track),
            _ => Val::None,
        }
    }

    fn in_state(&self, s: &str) -> bool {
        self.track == s
    }

    fn text(&self) -> String {
        format!(
            "{}\n{}\n{}\n{}\n{}",
            self.project, self.id, self.title, self.system, self.track
        )
        .to_lowercase()
    }

    fn rank(&self, col: &str) -> Val {
        match col {
            "track" => Val::Num(f64::from(self.track_rank())),
            _ => self.val(col),
        }
    }
}

/// How much of the open work hangs under an epic.
#[derive(Clone, Debug, Default, PartialEq, Serialize)]
pub struct Coverage {
    /// Open rows linked to an epic, and every open row (those plus the ones linked to none).
    pub linked: u32,
    pub open_rows: u32,
    /// Projects with open rows and no open feature epic, the most rows first.
    pub none: Vec<String>,
}

#[derive(Clone, Debug, Default, PartialEq, Serialize)]
pub struct Deliverables {
    pub rows: Vec<Deliverable>,
    pub verify: usize,
    pub on_track: usize,
    pub behind: usize,
    pub coverage: Coverage,
    /// The section's head, `Deliverables (25 open, 7 ready to verify, 1 on track)`, and its
    /// coverage line: every surface prints them word for word.
    pub says: String,
    pub coverage_says: String,
    pub legend: &'static str,
}

/// `fleet-bench epics --json` over every project, read for the section. A failed read is an
/// error that says so, never an empty table.
pub fn read(runner: &dyn Runner) -> Result<Deliverables, String> {
    let zone = *chrono::Local::now().offset();
    Ok(build(&epics::all(runner)?, zone))
}

/// `epoch` as `MM-DD` in `zone`.
pub fn day(epoch: i64, zone: chrono::FixedOffset) -> String {
    chrono::DateTime::from_timestamp(epoch, 0)
        .map(|t| t.with_timezone(&zone).format("%m-%d").to_string())
        .unwrap_or_default()
}

fn deliverable(c: &Chain, e: &Epic, zone: chrono::FixedOffset) -> Deliverable {
    let eta = e
        .eta
        .as_ref()
        .map(|t| t.cal_p50.unwrap_or(t.p50))
        .filter(|t| *t > 0);
    let total_weight = e.done_weight + e.open_weight;
    let percent = (total_weight > 0)
        .then(|| (f64::from(e.done_weight) * 100.0 / f64::from(total_weight)).round() as u32);
    let track = if e.step == "landed" {
        VERIFY.to_string()
    } else {
        e.track.clone().unwrap_or_default()
    };
    Deliverable {
        project: c.project.clone(),
        profile: c.profile.clone(),
        id: e.id.clone(),
        title: e.title.clone(),
        system: e.system.clone(),
        done: e.done,
        total: e.done + e.open,
        percent,
        done_says: format!(
            "{} {}/{}",
            percent.map_or("-".to_string(), |v| format!("{v}%")),
            e.done,
            e.done + e.open
        ),
        eta,
        eta_day: eta.map(|t| day(t, zone)).unwrap_or_default(),
        track,
    }
}

/// `1013` as `1,013`.
fn grouped(n: u32) -> String {
    let s = n.to_string();
    let mut out = String::new();
    for (i, c) in s.chars().enumerate() {
        if i > 0 && (s.len() - i).is_multiple_of(3) {
            out.push(',');
        }
        out.push(c);
    }
    out
}

/// The rows and lines from every project's chain.
pub fn build(chains: &[Chain], zone: chrono::FixedOffset) -> Deliverables {
    let mut rows = vec![];
    let mut cov = Coverage::default();
    let mut bare: Vec<(u32, String)> = vec![];
    for c in chains {
        let linked: u32 = c.epics.iter().map(|e| e.open).sum();
        let open = linked + c.unlinked.rows.len() as u32;
        cov.linked += linked;
        cov.open_rows += open;
        let before = rows.len();
        rows.extend(
            c.epics
                .iter()
                .filter(|e| e.state == "open" && !crate::page::is_standing(e))
                .map(|e| deliverable(c, e, zone)),
        );
        if rows.len() == before && open > 0 {
            bare.push((open, c.project.clone()));
        }
    }
    rows.sort_by(|a, b| {
        let eta = |d: &Deliverable| d.eta.unwrap_or(i64::MAX);
        (a.track_rank(), eta(a), &a.project, &a.id).cmp(&(
            b.track_rank(),
            eta(b),
            &b.project,
            &b.id,
        ))
    });
    bare.sort_by(|a, b| b.0.cmp(&a.0).then_with(|| a.1.cmp(&b.1)));
    cov.none = bare.into_iter().map(|(_, p)| p).collect();
    let count = |t: &str| rows.iter().filter(|d| d.track == t).count();
    let (verify, on_track, behind) = (count(VERIFY), count("on track"), count("behind"));
    let says = format!(
        "Deliverables ({} open, {verify} ready to verify, {on_track} on track, {behind} behind)",
        rows.len()
    );
    let coverage_says = coverage_line(&cov);
    Deliverables {
        rows,
        verify,
        on_track,
        behind,
        coverage: cov,
        says,
        coverage_says,
        legend: LEGEND,
    }
}

/// `Coverage: 1,013 linked / 2,600 open rows (39%); no feature epic: a, b (+2 more)`.
pub fn coverage_line(c: &Coverage) -> String {
    let pct = if c.open_rows == 0 {
        String::new()
    } else {
        format!(
            " ({}%)",
            (f64::from(c.linked) * 100.0 / f64::from(c.open_rows)).round() as u32
        )
    };
    let mut s = format!(
        "Coverage: {} linked / {} open rows{pct}",
        grouped(c.linked),
        grouped(c.open_rows)
    );
    if !c.none.is_empty() {
        let named = c
            .none
            .iter()
            .take(NAMED)
            .cloned()
            .collect::<Vec<_>>()
            .join(", ");
        s += &format!("; no feature epic: {named}");
        if c.none.len() > NAMED {
            s += &format!(" (+{} more)", c.none.len() - NAMED);
        }
    }
    s
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::table::View;

    struct Fixed(&'static str);
    impl Runner for Fixed {
        fn run(&self, argv: &[String]) -> Result<String, String> {
            assert_eq!(argv, ["fleet-bench", "epics", "--json"]);
            Ok(self.0.into())
        }
    }

    // Trimmed from a live `fleet-bench epics --json`: two projects with feature epics (one behind,
    // one landed and waiting on proof), a standing epic, a closed epic, and two with none.
    const OUT: &str = r#"{"made_epoch":1,"projects":[
      {"project":"dodginballs","profile":"personal","unlinked":{"rows":["a","b"],"plans":[]},"epics":[
        {"id":"db-230","title":"school days","system":"gameplay","state":"open","open":11,"done":8,"open_weight":23,"done_weight":34,
         "step":"rows","eta":{"p50":1794537535,"slow":1794537535,"basis":"pace","cal_p50":null},"track":"behind"},
        {"id":"db-276","title":"gameplay to standard","system":"gameplay","state":"open","open":54,"done":0,"open_weight":174,"done_weight":0,
         "step":"rows","eta":{"p50":1794721135,"slow":1,"basis":"pace"},"track":"on track"},
        {"id":"db-1","title":"old","system":"ui","state":"closed","open":0,"done":3,"open_weight":0,"done_weight":9,"step":"verified"}]},
      {"project":"ucp","profile":"personal","unlinked":{"rows":[],"plans":[]},"epics":[
        {"id":"u-1","title":"Home: player room","system":"save","state":"open","open":0,"done":4,"open_weight":0,"done_weight":12,
         "step":"landed","eta":null,"no_eta":"nothing open","track":null},
        {"id":"u-2","title":"Lobby","system":"netcode","state":"open","open":2,"done":2,"open_weight":6,"done_weight":6,
         "step":"rows","eta":{"p50":1794400000,"slow":1,"basis":"b","cal_p50":1794500000},"track":"on track"}]},
      {"project":"home-config","profile":"work","unlinked":{"rows":["x","y","z"],"plans":[]},"epics":[
        {"id":"h-1","title":"k8s to standard","system":"k8s","state":"open","open":7,"done":0,"open_weight":7,"done_weight":0,"step":"rows"}]},
      {"project":"empty","profile":"personal","unlinked":{"rows":[],"plans":[]},"epics":[]}]}"#;

    fn utc() -> chrono::FixedOffset {
        chrono::FixedOffset::east_opt(0).unwrap()
    }

    fn got() -> Deliverables {
        build(&epics::all(&Fixed(OUT)).unwrap(), utc())
    }

    #[test]
    fn one_row_per_open_feature_epic_with_the_standing_and_closed_ones_left_out() {
        let d = got();
        let ids: Vec<_> = d.rows.iter().map(|r| r.id.as_str()).collect();
        // worst first: behind, verify, on track; NEGATIVE CONTROL: db-276 (standing), db-1
        // (closed) and h-1 (standing) never appear.
        assert_eq!(ids, ["db-230", "u-1", "u-2"]);
        assert_eq!((d.behind, d.verify, d.on_track), (1, 1, 1));
        assert_eq!(
            d.says,
            "Deliverables (3 open, 1 ready to verify, 1 on track, 1 behind)"
        );
    }

    #[test]
    fn a_row_has_its_percent_by_size_its_counts_and_its_eta_day() {
        let d = got();
        let r = &d.rows[0];
        assert_eq!((r.percent, r.done, r.total), (Some(60), 8, 19));
        assert_eq!(r.eta_day, "11-13");
        assert_eq!(r.done_says, "60% 8/19");
        assert_eq!(r.key(), "personal/dodginballs");
        // the calibrated ETA wins when its basis has scored epics; no ETA is a blank, not today
        assert_eq!(d.rows[2].eta, Some(1794500000));
        assert_eq!(d.rows[1].eta, None);
        assert_eq!(d.rows[1].eta_day, "");
        assert_eq!(
            d.rows[1].track, VERIFY,
            "every task landed reads as waiting on proof"
        );
    }

    #[test]
    fn coverage_counts_linked_over_open_rows_and_names_projects_with_no_feature_epic() {
        let c = got().coverage;
        // linked: 11 + 54 + 0 + 2 + 7 = 74; unlinked 2 + 3
        assert_eq!((c.linked, c.open_rows), (74, 79));
        assert_eq!(
            c.none,
            ["home-config"],
            "no rows and no epic is not a gap to name"
        );
        assert_eq!(
            got().coverage_says,
            "Coverage: 74 linked / 79 open rows (94%); no feature epic: home-config"
        );
    }

    #[test]
    fn the_coverage_line_groups_thousands_and_folds_a_long_list() {
        let c = Coverage {
            linked: 1013,
            open_rows: 2600,
            none: (1..=8).map(|n| format!("p{n}")).collect(),
        };
        assert_eq!(
            coverage_line(&c),
            "Coverage: 1,013 linked / 2,600 open rows (39%); no feature epic: p1, p2, p3, p4, p5, p6 (+2 more)"
        );
        assert_eq!(
            coverage_line(&Coverage::default()),
            "Coverage: 0 linked / 0 open rows"
        );
    }

    #[test]
    fn the_table_filters_by_chip_and_query_and_sorts_by_track_rank() {
        let d = got();
        let v = View::new::<Deliverable>("", "verify", "", "");
        assert_eq!(v.apply(&d.rows).len(), 1);
        let v = View::new::<Deliverable>("sys:net", "", "", "");
        assert_eq!(v.apply(&d.rows)[0].id, "u-2");
        let v = View::new::<Deliverable>("db-230", "", "", "");
        assert_eq!(v.apply(&d.rows).len(), 1, "a bare word finds the epic's id");
        let v = View::new::<Deliverable>("", "", "track", "asc");
        let ids: Vec<_> = v.apply(&d.rows).iter().map(|r| r.id.clone()).collect();
        assert_eq!(
            ids,
            ["db-230", "u-1", "u-2"],
            "behind sorts before verify before on track"
        );
    }

    #[test]
    fn a_failed_read_is_an_error_and_not_an_empty_table() {
        struct Bad;
        impl Runner for Bad {
            fn run(&self, _: &[String]) -> Result<String, String> {
                Err("fleet-bench: not found".into())
            }
        }
        assert!(read(&Bad).unwrap_err().contains("not found"));
        assert!(read(&Fixed("nope"))
            .unwrap_err()
            .contains("fleet-bench epics"));
    }
}
