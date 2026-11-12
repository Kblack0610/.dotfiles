//! Infra's CI Tests section: the suites of one finished run of a repo's declared test workflow
//! (`testWorkflows` in the registry), from hub-core's `junit`, and the Quarantine table, one row
//! per quarantined test of every repo, from hub-core's `quarantine`. The run is the newest
//! finished one of the repo the page names (`trepo`, else the repo of the newest finished run)
//! unless the page names another run (`trun`); each repo offers its own last `PICK_RUNS`, and
//! `repos` lists the repos a picker can switch to. Its artifacts are fetched when it is first
//! read and kept, so only the first look at a run waits on GitHub. A failure of a test the run's
//! repo holds in quarantine counts as quarantined, applied on each read so a quarantine change
//! shows without a re-fetch. Both tables are filtered and sorted here by `hub_core::table`, so the
//! page only draws. The suites' view keys carry a `t` prefix (`tq`, `ts`, `tsort`, `tdir`), the
//! Quarantine's a `q` (`qq`, `qs`, `qsort`, `qdir`). An opened suite reads its tests from
//! `/api/tests/cases`, which uses the same kept read. The quarantine rides the builds read, so its
//! file's change pushes the `builds` event the section already listens to.

use std::sync::Arc;

use axum::http::StatusCode;
use hub_core::builds::{Builds, STALE_SECS};
use hub_core::jobs;
use hub_core::junit::{self, Case, Loaded, PickRun, Suite, Totals};
use hub_core::quarantine::{self, Entry, Lane};
use hub_core::queue::Item;
use hub_core::releases::Level;
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
    /// The repo whose runs the picker offers: its slug or project name.
    pub trepo: String,
    pub qq: String,
    pub qs: String,
    pub qsort: String,
    pub qdir: String,
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
    /// The repos with runs to pick from, the one with the newest run first.
    repos: Vec<&'a str>,
    /// The repo whose runs `runs` are.
    repo: Option<&'a str>,
    runs: Vec<&'a PickRun>,
    run: Option<&'a PickRun>,
    summary: String,
    totals: Totals,
    rows: Vec<&'a Suite>,
    more: usize,
    fold: Option<String>,
    note: Option<String>,
    errors: Vec<String>,
    table: Summary,
    quarantine: Held<'a>,
}

/// The Quarantine table: each lane's line over one row per quarantined test.
#[derive(Serialize)]
struct Held<'a> {
    lanes: Vec<HeldLane<'a>>,
    rows: Vec<&'a Entry>,
    more: usize,
    /// Why quarantine.json did not parse: the table's red line.
    error: Option<&'a str>,
    table: Summary,
}

#[derive(Serialize)]
struct HeldLane<'a> {
    repo: String,
    says: String,
    level: Level,
    /// The nightly the counts came from.
    url: Option<&'a str>,
}

fn held<'a>(b: &'a Builds, entries: &'a [Entry], q: &Query) -> Held<'a> {
    let view = View::new::<Entry>(&q.qq, &q.qs, &q.qsort, &q.qdir);
    let (mut rows, mut table) = view.summary(entries);
    let more = rows.len().saturating_sub(junit::LIST_ROWS);
    rows.truncate(junit::LIST_ROWS);
    table.links = hub_core::table::links(&rows);
    Held {
        lanes: b
            .quarantine
            .iter()
            .map(|l| HeldLane {
                repo: project_map::canonical(&l.repo),
                says: l.says(),
                level: l.level(),
                url: l.url(),
            })
            .collect(),
        rows,
        more,
        error: b.quarantine_error.as_deref(),
        table,
    }
}

/// The run's results with the failures its repo's quarantine holds marked quarantined.
fn applied(b: &Builds, run: &PickRun, l: &Loaded) -> Loaded {
    let lane = b
        .quarantine
        .iter()
        .find(|l| l.repo.eq_ignore_ascii_case(&run.repo));
    l.quarantined(&lane.map(Lane::held).unwrap_or_default())
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
    let applied = match (r.run, r.loaded) {
        (Some(run), Some(l)) => Some(applied(r.builds, run, l)),
        _ => None,
    };
    let suites: &[Suite] = applied.as_ref().map_or(&[], |l| &l.suites);
    let (rows, table) = view.summary(suites);
    let totals = junit::totals(suites);
    let (rows, fold) = junit::fold(&view, rows, &totals);
    let (rows, more) = junit::cap(rows);
    let summary = match (r.run, r.loaded) {
        (Some(run), Some(l)) if !l.suites.is_empty() => {
            format!("{} {}: {}", run.branch, run.sha, totals.says())
        }
        (Some(run), _) => format!("{} {}: no results", run.branch, run.sha),
        _ => "no finished run of a declared test workflow in the ledger".to_string(),
    };
    let entries = quarantine::entries(&r.builds.quarantine);
    let mut errors = r.errors.clone();
    errors.extend(r.loaded.iter().flat_map(|l| l.errors.clone()));
    let repo = r.run.map(|p| p.repo.as_str());
    let out = Shown {
        at: r.builds.at,
        stale_after: STALE_SECS,
        repos: junit::repos(r.runs),
        repo,
        runs: r
            .runs
            .iter()
            .filter(|p| Some(p.repo.as_str()) == repo)
            .collect(),
        run: r.run,
        summary,
        totals,
        rows,
        more,
        fold,
        note: r.loaded.and_then(|l| l.note.clone()),
        errors,
        table,
        quarantine: held(r.builds, &entries, q),
    };
    serde_json::to_string(&out).unwrap_or_else(|e| failed(e.to_string()))
}

/// A body the section can still render when reading itself failed.
fn failed(e: String) -> String {
    serde_json::json!({ "rows": [], "runs": [], "errors": [e] }).to_string()
}

/// The run `id` names among `repo`'s runs, else that repo's newest. No repo, or one with no runs,
/// is the repo of the run `id` names, else of the newest run. The second value says when the repo
/// or run asked for was not there.
fn choose<'a>(runs: &'a [PickRun], repo: &str, id: &str) -> (Option<&'a PickRun>, Option<String>) {
    let want = id.parse::<u64>().ok();
    let mine =
        |r: &&PickRun| r.repo.eq_ignore_ascii_case(repo) || project_map::canonical(&r.repo) == repo;
    let asked = want.and_then(|w| runs.iter().find(|r| r.id == w));
    let mut why = None;
    let of_repo: Vec<&PickRun> = if repo.is_empty() {
        vec![]
    } else {
        runs.iter().filter(mine).collect()
    };
    let pool: Vec<&PickRun> = match (of_repo.is_empty(), asked) {
        (false, _) => of_repo,
        (true, Some(r)) => runs.iter().filter(|o| o.repo == r.repo).collect(),
        (true, None) => {
            if !repo.is_empty() {
                why = Some(format!(
                    "{repo} has no finished test runs; showing the newest"
                ));
            }
            let first = runs.first().map(|r| r.repo.as_str());
            runs.iter()
                .filter(|r| Some(r.repo.as_str()) == first)
                .collect()
        }
    };
    let Some(want) = want else {
        return (pool.first().copied(), why);
    };
    match pool.iter().find(|r| r.id == want) {
        Some(r) => (Some(r), why),
        None => (
            pool.first().copied(),
            Some(format!(
                "run {want} is not among the last {} finished runs of its repo; showing the newest",
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
pub async fn get(q: Query, items: (Vec<Item>, Option<String>)) -> String {
    let b = match builds::current(items).await {
        Ok(b) => b,
        Err(e) => return failed(e),
    };
    let runs = junit::pickable(&b, project_map::cached().as_deref());
    let (run, missing) = choose(&runs, &q.trepo, &q.trun);
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
pub async fn cases(
    q: CasesQuery,
    items: (Vec<Item>, Option<String>),
) -> Result<String, (StatusCode, String)> {
    let bad = |e: String| (StatusCode::BAD_GATEWAY, e);
    let none = |e: &str| (StatusCode::NOT_FOUND, e.to_string());
    let b = builds::current(items).await.map_err(bad)?;
    let runs = junit::pickable(&b, project_map::cached().as_deref());
    let run = runs.iter().find(|r| r.id == q.run).ok_or_else(|| {
        none("that run is not among the finished runs of a declared test workflow")
    })?;
    let l = applied(&b, run, &*loaded(run).await.map_err(bad)?);
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
            artifacts: vec![],
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
            "no finished run of a declared test workflow in the ledger"
        );
        assert_eq!(v["table"]["total"], 0);
    }

    #[test]
    fn the_run_asked_for_wins_and_one_that_aged_out_falls_back_with_a_word() {
        let runs = [pick(7), pick(6)];
        assert_eq!(choose(&runs, "", "6").0.unwrap().id, 6);
        assert_eq!(choose(&runs, "", "").0.unwrap().id, 7);
        let (r, why) = choose(&runs, "", "99");
        assert_eq!(r.unwrap().id, 7);
        assert!(why.unwrap().contains("run 99"));
        assert!(choose(&[], "", "5").0.is_none());
    }

    #[test]
    fn the_repo_asked_for_scopes_the_picker_else_the_newest_runs_repo() {
        let mut quiet = pick(3);
        quiet.repo = "Org/quiet".into();
        let runs = [pick(7), pick(6), quiet];
        assert_eq!(choose(&runs, "org/QUIET", "").0.unwrap().id, 3);
        assert_eq!(
            choose(&runs, "", "3").0.unwrap().id,
            3,
            "a run names its repo"
        );
        let (r, why) = choose(&runs, "Org/quiet", "7");
        assert_eq!(r.unwrap().id, 3, "a run of another repo is not this repo's");
        assert!(why.unwrap().contains("run 7"));
        let (r, why) = choose(&runs, "Org/gone", "");
        assert_eq!(r.unwrap().id, 7);
        assert!(why.unwrap().contains("Org/gone has no finished test runs"));
        // the body offers every repo and only the chosen repo's runs
        let b = Builds::default();
        let r = Read {
            builds: &b,
            runs: &runs,
            run: Some(&runs[2]),
            loaded: None,
            errors: vec![],
        };
        let v: serde_json::Value = serde_json::from_str(&render(&r, &Query::default())).unwrap();
        assert_eq!(v["repos"], serde_json::json!(["Org/app", "Org/quiet"]));
        assert_eq!(v["repo"], "Org/quiet");
        assert_eq!(v["runs"].as_array().unwrap().len(), 1);
    }

    fn quarantined_builds() -> Builds {
        use hub_core::quarantine::{Held, Nightly, OwnerRow, Report};
        let held = |test: &str, row: &str, days_left: i64| Held {
            test: test.into(),
            ends: "2026-11-20".into(),
            row: row.into(),
            owner: format!("{row} fix: it"),
            days_left,
        };
        Builds {
            at: 300,
            quarantine: vec![Lane {
                repo: "org/APP".into(),
                report: Some(Report {
                    entries: 3,
                    rows: vec![OwnerRow {
                        row: "ucp-2".into(),
                        entries: 1,
                        ends: "2026-11-11".into(),
                        days_left: -1,
                    }],
                    tests: vec![
                        held("A.t1", "ucp-1", 8),
                        held("A.gone", "ucp-2", -1),
                        held("B.t0", "", 2),
                    ],
                }),
                nightly: Some(Nightly {
                    url: Some("https://github.com/org/APP/actions/runs/9".into()),
                    known: 2,
                    now_passing: Some(1),
                    now_passing_tests: vec!["B.t0".into()],
                    ..Default::default()
                }),
                ..Default::default()
            }],
            ..Default::default()
        }
    }

    fn held_body(l: &Loaded, q: Query) -> serde_json::Value {
        let b = quarantined_builds();
        let runs = [pick(7)];
        let r = Read {
            builds: &b,
            runs: &runs,
            run: Some(&runs[0]),
            loaded: Some(l),
            errors: vec![],
        };
        serde_json::from_str(&render(&r, &q)).unwrap()
    }

    #[test]
    fn a_failure_the_runs_repo_holds_in_quarantine_is_amber_not_red() {
        let mut a = suite("playmode", "A", &["passed", "failed"]);
        a.cases[1].fullname = "A.t1".into();
        let mut gone = suite("playmode", "G", &["failed"]);
        gone.cases[0].fullname = "A.gone".into();
        let l = Loaded {
            suites: vec![
                Suite::new("playmode", "A", a.cases),
                Suite::new("playmode", "G", gone.cases),
            ],
            ..Default::default()
        };
        let v = held_body(&l, Query::default());
        let row = |name: &str| {
            v["rows"]
                .as_array()
                .unwrap()
                .iter()
                .find(|r| r["suite"] == name)
                .cloned()
                .unwrap()
        };
        assert_eq!(row("A")["state"], "quarantined");
        assert_eq!(row("A")["level"], "warn");
        assert_eq!(row("A")["quarantined"], 1);
        assert_eq!(
            row("G")["state"],
            "failed",
            "a test past its end is red again"
        );
        assert_eq!(v["totals"]["failed"], 1);
        assert_eq!(v["totals"]["quarantined"], 1);
        assert_eq!(v["totals"]["failed_suites"], 1);
        assert!(v["summary"]
            .as_str()
            .unwrap()
            .contains("1 failed, 1 quarantined"));
        let chip = v["table"]["states"]
            .as_array()
            .unwrap()
            .iter()
            .find(|c| c["name"] == "quarantined")
            .cloned()
            .unwrap();
        assert_eq!(chip["n"], 1);
        // negative control: the same results with no quarantine are both red
        let v = body(Some(&l), Query::default());
        assert_eq!(v["totals"]["failed"], 2);
        assert_eq!(v["totals"]["quarantined"], 0);
    }

    #[test]
    fn the_quarantine_table_lists_each_held_test_with_its_lane_line() {
        let v = held_body(&Loaded::default(), Query::default());
        let q = &v["quarantine"];
        assert_eq!(
            q["lanes"][0]["url"],
            "https://github.com/org/APP/actions/runs/9"
        );
        assert_eq!(q["lanes"][0]["level"], "bad");
        assert!(q["lanes"][0]["says"]
            .as_str()
            .unwrap()
            .contains("2 known red"));
        let tests: Vec<&str> = q["rows"]
            .as_array()
            .unwrap()
            .iter()
            .map(|r| r["test"].as_str().unwrap())
            .collect();
        assert_eq!(tests, ["A.gone", "B.t0", "A.t1"], "the soonest end first");
        assert_eq!(q["rows"][1]["nightly"], "now passing");
        assert_eq!(q["rows"][0]["left"], "ended");
        assert_eq!(q["table"]["total"], 3);
        assert_eq!(q["table"]["links"][0]["row"], "#board?q=id:=ucp-2");
        let v = held_body(
            &Loaded::default(),
            Query {
                qs: "ended".into(),
                ..Default::default()
            },
        );
        assert_eq!(v["quarantine"]["rows"].as_array().unwrap().len(), 1);
        let v = held_body(
            &Loaded::default(),
            Query {
                qq: "nightly:failing".into(),
                ..Default::default()
            },
        );
        assert_eq!(v["quarantine"]["rows"].as_array().unwrap().len(), 2);
        // the suites' view keys leave the Quarantine table alone
        let v = held_body(
            &Loaded::default(),
            Query {
                ts: "failed".into(),
                ..Default::default()
            },
        );
        assert_eq!(v["quarantine"]["rows"].as_array().unwrap().len(), 3);
        // no file: no lanes, no rows, no error
        let v = body(None, Query::default());
        assert!(v["quarantine"]["lanes"].as_array().unwrap().is_empty());
        assert_eq!(v["quarantine"]["error"], serde_json::Value::Null);
    }

    #[test]
    fn a_failed_read_still_gives_the_section_a_body() {
        let v: serde_json::Value = serde_json::from_str(&failed("gone".into())).unwrap();
        assert_eq!(v["errors"][0], "gone");
    }
}
