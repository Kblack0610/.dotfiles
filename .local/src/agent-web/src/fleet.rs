//! Sessions' Runners inner tab: hub-core's `fleet`, shared with the TUI. It is all files, read on
//! every request, so a file event shows at once. A runner's page (`/api/fleet/runner?name=`) is
//! read only when it is opened. The accounts, tokens and Langfuse are the Costs tab's (costs.rs).
//! The answer judge's verdicts are a table of their own under the `v` key prefix (`vq`, `vs`,
//! `vsort`, `vdir`), on Log's Judges section and on the ask-judge runner page alike.

use hub_core::fleet::{self, who::Who, AskVerdict, Fleet, Paths};
use hub_core::table::View;
use serde::Deserialize;

use crate::cache::off;

/// The table view the page keeps in its URL. Runners shares `#sessions?...` with the Sessions
/// table, so its keys carry the `r` prefix (`rq`, `rs`, `rsort`, `rdir`; table.js `pre`).
#[derive(Deserialize, Default)]
#[serde(default)]
pub struct FleetQuery {
    pub rq: String,
    pub rs: String,
    pub rsort: String,
    pub rdir: String,
    #[serde(flatten)]
    pub verdicts: VerdictQuery,
}

/// The answer judge's verdicts' view, under the `v` prefix.
#[derive(Deserialize, Default)]
#[serde(default)]
pub struct VerdictQuery {
    pub vq: String,
    pub vs: String,
    pub vsort: String,
    pub vdir: String,
    /// Set by the list's "+N older": every verdict the view keeps, not the first `verdicts_shown`.
    pub vall: Option<String>,
}

impl VerdictQuery {
    fn view(&self) -> View {
        View::new::<AskVerdict>(&self.vq, &self.vs, &self.vsort, &self.vdir)
    }
}

/// A runner's page: its name, required (a request without one is a 400), and the verdicts' view
/// when it is the answer judge's.
#[derive(Deserialize)]
pub struct RunnerQuery {
    pub name: String,
    #[serde(flatten)]
    pub verdicts: VerdictQuery,
}

/// A runners read. The files are read afresh each time, so there is nothing to keep.
pub async fn get(q: FleetQuery) -> String {
    let f = off(|| fleet::files(&Paths::from_env()))
        .await
        .unwrap_or_else(|e| Fleet {
            errors: vec![e],
            ..Default::default()
        });
    render(f, &q)
}

/// The Fleet with its `who` rows cut to the view, the controls that drew them (`table`), and the
/// verdicts Log lists.
fn render(mut f: Fleet, q: &FleetQuery) -> String {
    let cap = match q.verdicts.vall {
        Some(_) => usize::MAX,
        None => hub_core::layout::fold_rows("verdicts"),
    };
    f.judge.view(&q.verdicts.view(), cap);
    let view = View::new::<Who>(&q.rq, &q.rs, &q.rsort, &q.rdir);
    let all = std::mem::take(&mut f.who);
    let (rows, table) = view.summary(&all);
    let out = serde_json::to_value(&f).map(|mut v| {
        v["who"] = serde_json::json!(rows);
        v["table"] = serde_json::json!(table);
        // How many rows each of Log's verdict lists shows before "+N older", so the page holds no copy.
        v["verdicts_shown"] = hub_core::layout::fold_rows("verdicts").into();
        v
    });
    out.and_then(|v| serde_json::to_string(&v))
        .unwrap_or_else(|e| {
            serde_json::json!({"errors": [e.to_string()], "workers": [], "who": []}).to_string()
        })
}

/// How many rows each list on a runner's page draws before its "+N more": the runs, the
/// activity, the calls, the per-rule eval, the extras block's rows (the answer judge's cells too)
/// and the conf. The reader keeps its own caps (hub-core `fleet::runner`: 20 runs, activity lines
/// and calls), so "+N more" draws the rest with no read; the answer judge's verdicts are cut here
/// too, so theirs is "+N older". Holds a runner page under three screens at 1400x900
/// (tests/agent-web/phone/fixtures.mjs reads this line). Live data, 2026-11-15, every list drawn:
/// inbox-triage 4,955 px, shepherd 3,310; at 3 the fixtures read ask-judge 2,380 (the tallest),
/// at 4 it was 2,606, too close to 2,700. Revisit when a list's row height or the page's sections
/// change. Web only: the hub TUI scrolls the whole page.
pub const RUNNER_ROWS: usize = 3;

/// One runner's page, read only when `#sessions/runners/<name>` opens, with `shown`, its lists'
/// cap. An unknown name is the caller's 404.
pub async fn runner(q: RunnerQuery) -> Result<String, String> {
    let name = q.name.clone();
    let mut r = off(move || fleet::runner::read(&Paths::from_env(), &name)).await??;
    if let fleet::runner::Extras::AskJudge { judge } = &mut r.extras {
        let cap = match q.verdicts.vall {
            Some(_) => usize::MAX,
            None => RUNNER_ROWS,
        };
        judge.view(&q.verdicts.view(), cap);
    }
    page(&r)
}

/// The runner page's JSON: the reader's fields and `shown` (`RUNNER_ROWS`), so the page holds no
/// copy of the cap.
#[derive(serde::Serialize)]
struct Page<'a> {
    #[serde(flatten)]
    runner: &'a fleet::runner::Runner,
    shown: usize,
}

fn page(r: &fleet::runner::Runner) -> Result<String, String> {
    serde_json::to_string(&Page {
        runner: r,
        shown: RUNNER_ROWS,
    })
    .map_err(|e| e.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn row(tier: u8, who: &str, state: &str) -> Who {
        Who {
            tier,
            kind: if tier == 1 { "lead" } else { "observe" }.into(),
            who: who.into(),
            state: state.into(),
            since: None,
            cost_24h: None,
            cost_estimated: false,
            purpose: String::new(),
            doing: String::new(),
            under: String::new(),
        }
    }

    fn fleet() -> Fleet {
        Fleet {
            who: vec![row(1, "shepherd", "working"), row(2, "briefing", "failed")],
            ..Fleet::default()
        }
    }

    fn who_of(s: &str) -> serde_json::Value {
        serde_json::from_str(s).unwrap()
    }

    fn read(q: &FleetQuery) -> serde_json::Value {
        who_of(&render(fleet(), q))
    }

    #[test]
    fn each_row_links_its_runner_page_on_sessions_runners() {
        let v = read(&FleetQuery::default());
        assert_eq!(v["who"].as_array().unwrap().len(), 2);
        assert_eq!(v["table"]["shown"], 2);
        assert_eq!(v["verdicts_shown"], hub_core::layout::fold_rows("verdicts"));
        assert_eq!(
            v["table"]["links"],
            serde_json::json!([{"who": "#sessions/runners/shepherd"}, {"who": "#sessions/runners/briefing"}])
        );
    }

    #[test]
    fn the_verdicts_view_rides_the_fleet_read_and_counts_every_verdict() {
        let uri = "/api/fleet?rq=lab&vs=wrong&vq=ship".parse().unwrap();
        let axum::extract::Query(q) =
            axum::extract::Query::<FleetQuery>::try_from_uri(&uri).unwrap();
        assert_eq!((q.rq.as_str(), q.verdicts.vs.as_str()), ("lab", "wrong"));
        let wrong = |question: &str| AskVerdict {
            question: question.into(),
            score: "wrong".into(),
            ..Default::default()
        };
        let cap = hub_core::layout::fold_rows("verdicts");
        let mut f = fleet();
        f.judge.verdicts = (0..cap + 5).map(|_| wrong("ship it?")).collect();
        f.judge.verdicts.push(wrong("which login?"));
        let v = who_of(&render(f.clone(), &q));
        assert_eq!(
            v["judge"]["verdicts"].as_array().unwrap().len(),
            cap,
            "Log's rows, then +N older"
        );
        assert_eq!(v["judge"]["table"]["shown"], cap + 5);
        assert_eq!(v["judge"]["table"]["total"], cap + 6);
        let uri = "/api/fleet?vs=wrong&vq=ship&vall=1".parse().unwrap();
        let axum::extract::Query(all) =
            axum::extract::Query::<FleetQuery>::try_from_uri(&uri).unwrap();
        let v = who_of(&render(f, &all));
        assert_eq!(
            v["judge"]["verdicts"].as_array().unwrap().len(),
            cap + 5,
            "+N older reads them all"
        );
        let uri = "/api/fleet/runner?name=ask-judge&vs=passed"
            .parse()
            .unwrap();
        let axum::extract::Query(r) =
            axum::extract::Query::<RunnerQuery>::try_from_uri(&uri).unwrap();
        assert_eq!(
            (r.name.as_str(), r.verdicts.vs.as_str()),
            ("ask-judge", "passed")
        );
        let bare = "/api/fleet/runner?vs=passed"
            .parse::<axum::http::Uri>()
            .unwrap();
        assert!(
            axum::extract::Query::<RunnerQuery>::try_from_uri(&bare).is_err(),
            "no name is a bad request, not a lookup of the empty name"
        );
    }

    #[test]
    fn the_view_is_read_from_the_r_prefixed_keys() {
        let v = read(&FleetQuery {
            rs: "failed".into(),
            ..FleetQuery::default()
        });
        assert_eq!(v["who"].as_array().unwrap().len(), 1);
        assert_eq!(v["who"][0]["who"], "briefing");
        assert_eq!(v["table"]["links"][0]["who"], "#sessions/runners/briefing");
        let v = read(&FleetQuery {
            rq: "shep".into(),
            ..FleetQuery::default()
        });
        assert_eq!(v["who"][0]["who"], "shepherd");
    }

    #[test]
    fn a_runner_page_sends_its_lists_cap_beside_every_row_the_reader_kept() {
        let r = fleet::runner::Runner {
            name: "inbox-triage".into(),
            activity: vec![Default::default(); 20],
            ..Default::default()
        };
        let v: serde_json::Value = serde_json::from_str(&page(&r).unwrap()).unwrap();
        assert_eq!(v["shown"], RUNNER_ROWS);
        assert_eq!(
            v["activity"].as_array().unwrap().len(),
            20,
            "the page cuts, not the server"
        );
        assert_eq!(v["name"], "inbox-triage");
    }
}
