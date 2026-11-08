//! The Releases tab: every channel, what is pinned there and what is live, from hub-core's
//! `releases`. The list is filtered and sorted here by `hub_core::table`, so the page only draws.
//! No read cache: the read is one small file, and a new snapshot pushes the `releases` event.

use hub_core::releases::{self, fold, Fold, Release, Releases, STALE_SECS};
use hub_core::session_actions::System;
use hub_core::table::{Summary, View};
use serde::Serialize;

use crate::schedules::Query;

/// The read with the view applied: the rows drawn, the green ones folded, the controls.
#[derive(Serialize)]
struct Shown<'a> {
    at: i64,
    question: &'a str,
    summary: &'a str,
    stale_after: i64,
    rows: Vec<&'a Release>,
    fold: Option<Fold>,
    errors: &'a [String],
    table: Summary,
}

fn render(s: &Releases, q: &Query) -> String {
    let view = View::new::<Release>(&q.q, &q.s, &q.sort, &q.dir);
    let (rows, table) = view.summary(&s.rows);
    let (rows, fold) = fold(&view, rows);
    let out = Shown {
        at: s.at,
        question: &s.question,
        summary: &s.summary,
        stale_after: STALE_SECS,
        rows,
        fold,
        errors: &s.errors,
        table,
    };
    serde_json::to_string(&out).unwrap_or_else(|e| failed(e.to_string()))
}

/// A body the tab can still render when reading itself failed.
fn failed(e: String) -> String {
    serde_json::json!({ "rows": [], "errors": [e] }).to_string()
}

/// The view `q` asks for, over a read of its own.
pub async fn get(q: Query) -> String {
    match tokio::task::spawn_blocking(|| releases::read(&System)).await {
        Ok(s) => render(&s, &q),
        Err(e) => failed(e.to_string()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn rel(id: &str, level: releases::Level) -> Release {
        Release {
            project: "app".into(),
            id: id.into(),
            status: "ok".into(),
            level,
            ..Default::default()
        }
    }

    fn sample() -> Releases {
        Releases {
            at: 300,
            question: "What is live where?".into(),
            summary: "2 channels: 1 drift, 1 ok".into(),
            rows: vec![
                rel("app-prod", releases::Level::Bad),
                rel("app-preview", releases::Level::Ok),
            ],
            errors: vec![],
        }
    }

    fn body(q: Query) -> serde_json::Value {
        serde_json::from_str(&render(&sample(), &q)).unwrap()
    }

    #[test]
    fn the_plain_view_folds_green_and_the_table_still_counts_every_row() {
        let v = body(Query::default());
        assert_eq!(v["rows"].as_array().unwrap().len(), 1);
        assert_eq!(v["rows"][0]["id"], "app-prod");
        assert_eq!(v["fold"]["n"], 1);
        assert_eq!(v["table"]["total"], 2);
        assert_eq!(v["question"], "What is live where?");
        assert_eq!(v["stale_after"], STALE_SECS);
    }

    #[test]
    fn a_chip_lists_what_the_fold_hid() {
        let v = body(Query {
            s: "green".into(),
            ..Default::default()
        });
        assert_eq!(v["rows"][0]["id"], "app-preview");
        assert!(v["fold"].is_null());
    }

    #[test]
    fn a_failed_read_still_gives_the_tab_a_body() {
        let v: serde_json::Value = serde_json::from_str(&failed("gone".into())).unwrap();
        assert_eq!(v["errors"][0], "gone");
    }
}
