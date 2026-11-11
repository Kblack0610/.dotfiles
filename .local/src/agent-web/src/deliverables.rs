//! The Deliverables section at the top of the Projects tab: one row per open feature epic across
//! every project, from `hub_core::deliverables` (the same rows and words as the hub TUI's).
//! The view's keys are `d`-prefixed (`dq`, `ds`, `dsort`, `ddir`) because the project list below
//! keeps the plain ones. The view narrows `rows` here and nowhere else: the head line, the
//! coverage line and `table`'s total stay the whole fleet's.
//!
//! The rows are built from the one kept `fleet-bench epics` read (`crate::epics`), which the
//! project pages share.

use axum::extract::Query;
use axum::http::StatusCode;
use axum::Json;
use hub_core::deliverables::{self, Deliverable, Deliverables};
use hub_core::table::{Summary, View};
use serde::{Deserialize, Serialize};

use crate::{bad, ApiResult};

#[derive(Deserialize, Default)]
#[serde(default)]
pub struct DeliverableQuery {
    #[serde(rename = "dq")]
    q: String,
    #[serde(rename = "ds")]
    s: String,
    #[serde(rename = "dsort")]
    sort: String,
    #[serde(rename = "ddir")]
    dir: String,
}

/// The section as the page reads it: the kept rows by reference, every other field the reader's.
#[derive(Serialize)]
struct Shown<'a> {
    rows: Vec<&'a Deliverable>,
    verify: usize,
    on_track: usize,
    behind: usize,
    coverage: &'a hub_core::deliverables::Coverage,
    says: &'a str,
    coverage_says: &'a str,
    legend: &'a str,
    table: Summary,
}

/// The kept rows in the view's order, over the whole section's lines.
fn shown(all: &Deliverables, q: &DeliverableQuery) -> serde_json::Value {
    let view = View::new::<Deliverable>(&q.q, &q.s, &q.sort, &q.dir);
    let (rows, table) = view.summary(&all.rows);
    serde_json::to_value(Shown {
        rows,
        verify: all.verify,
        on_track: all.on_track,
        behind: all.behind,
        coverage: &all.coverage,
        says: &all.says,
        coverage_says: &all.coverage_says,
        legend: all.legend,
        table,
    })
    .unwrap_or_default()
}

/// A failed read is not kept: the next refresh tries again.
pub async fn get(Query(q): Query<DeliverableQuery>) -> ApiResult<Json<serde_json::Value>> {
    let chains = crate::epics::chains()
        .await
        .map_err(|e| bad(StatusCode::BAD_GATEWAY, e))?;
    let all = deliverables::build(&chains, *chrono::Local::now().offset());
    Ok(Json(shown(&all, &q)))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn d(project: &str, track: &str) -> Deliverable {
        Deliverable {
            project: project.into(),
            profile: "personal".into(),
            id: format!("{project}-1"),
            title: "an epic".into(),
            track: track.into(),
            ..Default::default()
        }
    }

    fn all() -> Deliverables {
        Deliverables {
            rows: vec![d("a", "behind"), d("b", "verify")],
            says: "Deliverables (2 open)".into(),
            coverage_says: "Coverage: 1 linked / 2 open rows (50%)".into(),
            ..Default::default()
        }
    }

    #[test]
    fn the_view_narrows_the_rows_and_nothing_else() {
        let q = DeliverableQuery {
            s: "verify".into(),
            ..Default::default()
        };
        let got = shown(&all(), &q);
        assert_eq!(got["rows"].as_array().unwrap().len(), 1);
        assert_eq!(got["rows"][0]["project"], "b");
        assert_eq!(got["table"]["total"], 2);
        assert_eq!(got["says"], "Deliverables (2 open)");
        assert_eq!(
            got["coverage_says"],
            "Coverage: 1 linked / 2 open rows (50%)"
        );
    }

    #[test]
    fn the_view_keys_are_d_prefixed_so_the_project_list_keeps_the_plain_ones() {
        let uri: axum::http::Uri =
            "/api/deliverables?dq=sys:ui&ds=behind&dsort=eta&ddir=asc&q=other"
                .parse()
                .unwrap();
        let Query(q) = Query::<DeliverableQuery>::try_from_uri(&uri).unwrap();
        assert_eq!((q.q.as_str(), q.s.as_str()), ("sys:ui", "behind"));
        assert_eq!((q.sort.as_str(), q.dir.as_str()), ("eta", "asc"));
    }
}
