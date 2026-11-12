//! Log's Work table: one superset read (`hub_core::worklog`) kept in the event cache, narrowed
//! here by the URL's day window and the table's view, so a keystroke re-reads nothing.

use crate::cache::EventCache;
use axum::extract::{Query, State};
use axum::Json;
use chrono::NaiveDate;
use hub_core::session_actions::System;
use hub_core::table::View;
use hub_core::worklog::{self, Gathered, Window, Work};
use serde::Deserialize;
use serde_json::{json, Value};
use std::sync::Arc;
use tokio::sync::broadcast;

use crate::Shared;

/// The event kinds that mean the queue or a day-log record was written.
const KINDS: [&str; 2] = ["queue", "log"];
/// The backstop for a read no event outdated, should the watcher be down.
const READ_FOR_SECS: u64 = 30;

/// The view keys carry the table's `w` prefix (table.js), the same in the URL and here.
#[derive(Deserialize, Default)]
pub struct Q {
    #[serde(default)]
    wq: String,
    #[serde(default)]
    ws: String,
    #[serde(default)]
    wsort: String,
    #[serde(default)]
    wdir: String,
    #[serde(default)]
    wday: String,
    #[serde(default)]
    all: Option<String>,
}

pub struct Cache(EventCache<Gathered, READ_FOR_SECS>);

impl Cache {
    pub fn new(events: broadcast::Receiver<String>) -> Self {
        Cache(EventCache::new(events, &KINDS))
    }
}

/// The rows the window and the view keep, past Work's `layout::fold_rows` only when asked for them all.
fn shown(g: &Gathered, q: &Q, today: NaiveDate) -> Value {
    let window = Window::parse(&q.wday, today);
    let inside: Vec<&Work> = g.rows.iter().filter(|r| window.keeps(r)).collect();
    let view = View::new::<&Work>(&q.wq, &q.ws, &q.wsort, &q.wdir);
    let (rows, table) = view.summary(&inside);
    let cap = if q.all.is_some() {
        rows.len()
    } else {
        hub_core::layout::fold_rows("work")
    };
    json!({
        "rows": rows.iter().take(cap).collect::<Vec<_>>(),
        "more": rows.len().saturating_sub(cap),
        "errors": g.errors,
        "today": today.to_string(),
        "items_from": g.items_from,
        "prs_from": g.prs_from,
        "table": table,
    })
}

pub async fn get(State(s): State<Shared>, Query(q): Query<Q>) -> Json<Value> {
    let g = s
        .work
        .0
        // No rows means the queue read failed: show that, and read again on the next request.
        .get_if((), || worklog::read(&System), |g| !g.rows.is_empty())
        .await
        .unwrap_or_else(|e| {
            Arc::new(Gathered {
                errors: vec![e],
                ..Gathered::default()
            })
        });
    Json(shown(&g, &q, chrono::Local::now().date_naive()))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn row(state: &'static str, when: &str, project: &str) -> Work {
        Work {
            state,
            when: Some(when.into()),
            project: project.into(),
            what: "w".into(),
            kind: None,
            pr: None,
            url: None,
            cost: None,
            slug: None,
            unproven: false,
        }
    }

    fn today() -> NaiveDate {
        NaiveDate::from_ymd_opt(2026, 11, 9).unwrap()
    }

    #[test]
    fn the_window_narrows_before_the_view_counts_and_the_chips_follow() {
        let g = Gathered {
            rows: vec![
                row("done", "2026-11-09T01:00", "a"),
                row("done", "2026-10-01T01:00", "a"),
                row("failed", "2026-11-08T01:00", "b"),
            ],
            ..Gathered::default()
        };
        let v = shown(&g, &Q::default(), today());
        assert_eq!(v["table"]["total"], 2, "the default window is a week");
        let q = Q {
            wq: "project:b".into(),
            wday: "all".into(),
            ..Q::default()
        };
        let v = shown(&g, &q, today());
        assert_eq!(v["table"]["shown"], 1);
        assert_eq!(v["rows"][0]["state"], "failed");
    }

    #[test]
    fn past_the_cap_it_says_how_many_more_until_asked_for_them_all() {
        let cap = hub_core::layout::fold_rows("work");
        let g = Gathered {
            rows: (0..cap + 5)
                .map(|_| row("done", "2026-11-09T01:00", "a"))
                .collect(),
            ..Gathered::default()
        };
        let v = shown(&g, &Q::default(), today());
        assert_eq!(v["rows"].as_array().unwrap().len(), cap);
        assert_eq!(v["more"], 5);
        assert_eq!(v["table"]["shown"], cap + 5);
        let q = Q {
            all: Some("1".into()),
            ..Q::default()
        };
        let v = shown(&g, &q, today());
        assert_eq!(v["rows"].as_array().unwrap().len(), cap + 5);
        assert_eq!(v["more"], 0);
    }
}
