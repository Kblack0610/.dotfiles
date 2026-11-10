//! The Releases tab's Tests section: the suites of one finished `tests.yml` run, from hub-core's
//! `junit`. The run is the newest finished one unless the page names another (`trun`); its
//! artifacts are fetched when it is first read and kept, so only the first look at a run waits
//! on GitHub. The suites are filtered and sorted here by `hub_core::table`, so the page only
//! draws. The view keys carry a `t` prefix (`tq`, `ts`, `tsort`, `tdir`). An opened suite reads
//! its tests from `/api/tests/cases`, which uses the same kept read.

use std::sync::Arc;

use axum::http::StatusCode;
use hub_core::builds::{Builds, STALE_SECS};
use hub_core::jobs;
use hub_core::junit::{self, Case, Loaded, PickRun, Suite, Totals};
use hub_core::table::{Summary, View};
use serde::{Deserialize, Serialize};

use crate::builds;
use crate::cache::{off, ReadCache};

/// A finished run's results never change; this only bounds how long a stale `Loaded` (a failed
/// report fixed by a re-fetch) could be kept.
const CACHE_SECS: u64 = 600;
static LOADED: ReadCache<Loaded, CACHE_SECS, (u64, u32)> = ReadCache::new();

/// The table view, under the section's own key prefix, and the run to show (a run id).
#[derive(Deserialize, Default)]
#[serde(default)]
pub struct Query {
    pub tq: String,
    pub ts: String,
    pub tsort: String,
    pub tdir: String,
    pub trun: String,
}

/// An opened suite: its tier and file name.
#[derive(Deserialize, Default)]
#[serde(default)]
pub struct CasesQuery {
    pub run: u64,
    pub tier: String,
    pub suite: String,
}

#[derive(Serialize)]
struct Shown<'a> {
    at: i64,
    stale_after: i64,
    runs: &'a [PickRun],
    run: Option<&'a PickRun>,
    summary: String,
    totals: Totals,
    rows: Vec<&'a Suite>,
    more: usize,
    fold: Option<String>,
    note: Option<String>,
    errors: Vec<String>,
    table: Summary,
}

/// What a read of the ledger and one run produced.
struct Read<'a> {
    builds: &'a Builds,
    runs: &'a [PickRun],
    run: Option<&'a PickRun>,
    loaded: Option<&'a Loaded>,
    errors: Vec<String>,
}

fn render(r: &Read, q: &Query) -> String {
    let view = View::new::<Suite>(&q.tq, &q.ts, &q.tsort, &q.tdir);
    let suites: &[Suite] = r.loaded.map_or(&[], |l| &l.suites);
    let (rows, table) = view.summary(suites);
    let totals = junit::totals(suites);
    let (rows, fold) = junit::fold(&view, rows, &totals);
    let (rows, more) = junit::cap(rows);
    let summary = match (r.run, r.loaded) {
        (Some(run), Some(l)) if !l.suites.is_empty() => {
            format!("{} {}: {}", run.branch, run.sha, totals.says())
        }
        (Some(run), _) => format!("{} {}: no results", run.branch, run.sha),
        _ => "no finished run of the tests workflow in the ledger".to_string(),
    };
    let mut errors = r.errors.clone();
    errors.extend(r.loaded.iter().flat_map(|l| l.errors.clone()));
    let out = Shown {
        at: r.builds.at,
        stale_after: STALE_SECS,
        runs: r.runs,
        run: r.run,
        summary,
        totals,
        rows,
        more,
        fold,
        note: r.loaded.and_then(|l| l.note.clone()),
        errors,
        table,
    };
    serde_json::to_string(&out).unwrap_or_else(|e| failed(e.to_string()))
}

/// A body the section can still render when reading itself failed.
fn failed(e: String) -> String {
    serde_json::json!({ "rows": [], "runs": [], "errors": [e] }).to_string()
}

/// The run `id` names among `runs`, else the newest; the second value says when the one asked
/// for was not there.
fn choose<'a>(runs: &'a [PickRun], id: &str) -> (Option<&'a PickRun>, Option<String>) {
    let Ok(want) = id.parse::<u64>() else {
        return (runs.first(), None);
    };
    match runs.iter().find(|r| r.id == want) {
        Some(r) => (Some(r), None),
        None => (
            runs.first(),
            Some(format!(
                "run {want} is not among the last {} finished runs; showing the newest",
                junit::PICK_RUNS
            )),
        ),
    }
}

/// One run's results, kept once read. Fetching blocks on `gh`, so it runs off the async threads.
async fn loaded(run: &PickRun) -> Result<Arc<Loaded>, String> {
    let r = run.clone();
    LOADED
        .get((run.id, run.attempt), async move {
            off(move || junit::load(&jobs::Paths::from_env().cache, &r))
                .await
                .and_then(|l| l)
        })
        .await
}

/// The view `q` asks for.
pub async fn get(q: Query) -> String {
    let b = match builds::current().await {
        Ok(b) => b,
        Err(e) => return failed(e),
    };
    let runs = junit::pickable(&b);
    let (run, missing) = choose(&runs, &q.trun);
    let mut errors: Vec<String> = missing.into_iter().collect();
    let kept = match run {
        Some(run) => match loaded(run).await {
            Ok(l) => Some(l),
            Err(e) => {
                errors.push(e);
                None
            }
        },
        None => None,
    };
    render(
        &Read {
            builds: &b,
            runs: &runs,
            run,
            loaded: kept.as_deref(),
            errors,
        },
        &q,
    )
}

#[derive(Serialize)]
struct CaseList<'a> {
    cases: Vec<&'a Case>,
    more: usize,
}

/// The tests of the suite `q` names in run `q.run`, failed first. A request that names no run or
/// suite is a 404; a failed read of the ledger or of GitHub is a 502. It never supplies a path
/// or a URL.
pub async fn cases(q: CasesQuery) -> Result<String, (StatusCode, String)> {
    let bad = |e: String| (StatusCode::BAD_GATEWAY, e);
    let none = |e: &str| (StatusCode::NOT_FOUND, e.to_string());
    let b = builds::current().await.map_err(bad)?;
    let runs = junit::pickable(&b);
    let run = runs
        .iter()
        .find(|r| r.id == q.run)
        .ok_or_else(|| none("that run is not among the finished runs of the tests workflow"))?;
    let l = loaded(run).await.map_err(bad)?;
    let (cases, more) = l
        .cases(&q.tier, &q.suite)
        .ok_or_else(|| none("that suite is not in the run's results"))?;
    serde_json::to_string(&CaseList { cases, more }).map_err(|e| bad(e.to_string()))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn suite(tier: &str, name: &str, results: &[&str]) -> Suite {
        let cases = results
            .iter()
            .enumerate()
            .map(|(i, r)| Case {
                name: format!("test {i}"),
                result: r.to_string(),
                ..Default::default()
            })
            .collect();
        Suite::new(tier, name, cases)
    }

    fn pick(id: u64) -> PickRun {
        PickRun {
            repo: "Org/app".into(),
            id,
            attempt: 1,
            branch: "main".into(),
            sha: "abc1234".into(),
            title: String::new(),
            state: "green".into(),
            level: Default::default(),
            started: 0,
            prs: vec![],
            url: String::new(),
        }
    }

    fn body(l: Option<&Loaded>, q: Query) -> serde_json::Value {
        let b = Builds {
            at: 300,
            ..Default::default()
        };
        let runs = [pick(7), pick(6)];
        let r = Read {
            builds: &b,
            runs: &runs,
            run: Some(&runs[0]),
            loaded: l,
            errors: vec![],
        };
        serde_json::from_str(&render(&r, &q)).unwrap()
    }

    fn red() -> Loaded {
        Loaded {
            suites: vec![
                suite("unit", "a.bats", &["passed", "failed"]),
                suite("unit", "b.bats", &["passed"]),
                suite("ui", "c.bats", &["passed", "skipped"]),
            ],
            ..Default::default()
        }
    }

    #[test]
    fn the_plain_view_lists_every_suite_and_says_what_the_run_found() {
        let v = body(Some(&red()), Query::default());
        assert_eq!(v["rows"].as_array().unwrap().len(), 3);
        assert_eq!(v["fold"], serde_json::Value::Null);
        assert_eq!(
            v["summary"],
            "main abc1234: 5 tests in 3 suites: 1 failed, 1 skipped, 3 passed"
        );
        assert_eq!(v["totals"]["failed_suites"], 1);
        assert_eq!(v["runs"].as_array().unwrap().len(), 2);
        assert_eq!(v["stale_after"], STALE_SECS);
    }

    #[test]
    fn a_chip_and_the_tier_filter_keep_the_totals_of_the_whole_run() {
        let v = body(
            Some(&red()),
            Query {
                ts: "failed".into(),
                ..Default::default()
            },
        );
        assert_eq!(v["rows"].as_array().unwrap().len(), 1);
        assert_eq!(v["rows"][0]["suite"], "a.bats");
        assert_eq!(v["table"]["total"], 3);
        let v = body(
            Some(&red()),
            Query {
                tq: "tier:ui".into(),
                ..Default::default()
            },
        );
        assert_eq!(v["rows"][0]["suite"], "c.bats");
        assert_eq!(v["table"]["facets"][0]["key"], "tier");
        assert_eq!(
            v["table"]["facets"][0]["values"].as_array().unwrap().len(),
            2
        );
    }

    #[test]
    fn a_green_run_folds_to_one_line_until_a_chip_asks_for_the_rows() {
        let green = Loaded {
            suites: vec![suite("unit", "a.bats", &["passed"])],
            ..Default::default()
        };
        let v = body(Some(&green), Query::default());
        assert!(v["rows"].as_array().unwrap().is_empty());
        assert_eq!(
            v["fold"],
            "All green: 1 test in 1 suite: 0 failed, 0 skipped, 1 passed"
        );
        let v = body(
            Some(&green),
            Query {
                ts: "passed".into(),
                ..Default::default()
            },
        );
        assert_eq!(v["rows"].as_array().unwrap().len(), 1);
        assert_eq!(v["fold"], serde_json::Value::Null);
    }

    #[test]
    fn the_cap_leaves_the_rest_one_search_away() {
        let l = Loaded {
            suites: (0..junit::LIST_ROWS + 5)
                .map(|i| suite("unit", &format!("s{i}.bats"), &["failed"]))
                .collect(),
            ..Default::default()
        };
        let v = body(Some(&l), Query::default());
        assert_eq!(v["rows"].as_array().unwrap().len(), junit::LIST_ROWS);
        assert_eq!(v["more"], 5);
    }

    #[test]
    fn a_run_without_results_says_why_and_no_run_says_so() {
        let none = Loaded {
            note: Some("no artifacts".into()),
            ..Default::default()
        };
        let v = body(Some(&none), Query::default());
        assert_eq!(v["note"], "no artifacts");
        assert_eq!(v["summary"], "main abc1234: no results");
        let b = Builds::default();
        let r = Read {
            builds: &b,
            runs: &[],
            run: None,
            loaded: None,
            errors: vec![],
        };
        let v: serde_json::Value = serde_json::from_str(&render(&r, &Query::default())).unwrap();
        assert_eq!(
            v["summary"],
            "no finished run of the tests workflow in the ledger"
        );
        assert_eq!(v["table"]["total"], 0);
    }

    #[test]
    fn the_run_asked_for_wins_and_one_that_aged_out_falls_back_with_a_word() {
        let runs = [pick(7), pick(6)];
        assert_eq!(choose(&runs, "6").0.unwrap().id, 6);
        assert_eq!(choose(&runs, "").0.unwrap().id, 7);
        let (r, why) = choose(&runs, "99");
        assert_eq!(r.unwrap().id, 7);
        assert!(why.unwrap().contains("run 99"));
        assert!(choose(&[], "5").0.is_none());
    }

    #[test]
    fn a_failed_read_still_gives_the_section_a_body() {
        let v: serde_json::Value = serde_json::from_str(&failed("gone".into())).unwrap();
        assert_eq!(v["errors"][0], "gone");
    }
}
