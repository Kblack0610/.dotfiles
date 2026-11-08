//! The Releases tab: every channel, what is pinned there and what is live, from hub-core's
//! `releases`. The list is filtered and sorted here by `hub_core::table`, so the page only draws.
//! No read cache: the read is one small file, and a new snapshot pushes the `releases` event.

use axum::extract::Query as UrlQuery;
use axum::http::{header, StatusCode};
use axum::response::{IntoResponse, Response};
use hub_core::releases::{self, fold, Release, Releases, STALE_SECS};
use hub_core::session_actions::{Runner, System};
use hub_core::table::{Summary, View};
use serde::{Deserialize, Serialize};

use crate::schedules::Query;

/// The read with the view applied: the rows drawn, the green ones folded, the controls.
#[derive(Serialize)]
struct Shown<'a> {
    at: i64,
    question: &'a str,
    summary: &'a str,
    stale_after: i64,
    rows: Vec<&'a Release>,
    fold: Option<String>,
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

/// Which tag of which project; no tag is the project's newest release.
#[derive(Deserialize, Default)]
#[serde(default)]
pub struct ChangelogQuery {
    pub project: String,
    pub tag: String,
}

/// The body for one tag's changelog, or the status and words of why there is none: 400 for a
/// query the collector is never asked, 502 for its own failure.
fn changelog_body(runner: &dyn Runner, q: &ChangelogQuery) -> Result<String, (StatusCode, String)> {
    let tag = Some(q.tag.as_str()).filter(|t| !t.is_empty());
    if !releases::askable(&q.project, tag) {
        return Err((StatusCode::BAD_REQUEST, "a project and a tag name are required".into()));
    }
    let c = releases::changelog(runner, &q.project, tag).map_err(|e| (StatusCode::BAD_GATEWAY, e))?;
    serde_json::to_string(&c).map_err(|e| (StatusCode::INTERNAL_SERVER_ERROR, e.to_string()))
}

/// What `tag` of `project` shipped, with the tags to pick from (docs/operations/release-state.md).
pub async fn changelog(UrlQuery(q): UrlQuery<ChangelogQuery>) -> Response {
    match tokio::task::spawn_blocking(move || changelog_body(&System, &q)).await {
        Ok(Ok(body)) => ([(header::CONTENT_TYPE, "application/json")], body).into_response(),
        Ok(Err(e)) => e.into_response(),
        Err(e) => (StatusCode::INTERNAL_SERVER_ERROR, e.to_string()).into_response(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    struct Says(Result<String, String>);
    impl Runner for Says {
        fn run(&self, _: &[String]) -> Result<String, String> {
            self.0.clone()
        }
    }

    fn ask(project: &str, tag: &str) -> ChangelogQuery {
        ChangelogQuery {
            project: project.into(),
            tag: tag.into(),
        }
    }

    #[test]
    fn a_changelog_body_is_the_collectors_answer_and_its_failure_is_said() {
        let ok = Says(Ok(r#"{"project":"p","tag":"p-v1","tags":["p-v1"],"text":"- a"}"#.into()));
        let v: serde_json::Value =
            serde_json::from_str(&changelog_body(&ok, &ask("p", "")).unwrap()).unwrap();
        assert_eq!((v["tag"].as_str(), v["tags"][0].as_str()), (Some("p-v1"), Some("p-v1")));
        let no = Says(Err("release-state: x is not a release tag of p".into()));
        let (status, words) = changelog_body(&no, &ask("p", "x")).unwrap_err();
        assert!(status == StatusCode::BAD_GATEWAY && words.contains("not a release tag"));
        for (p, t) in [("", ""), ("-h", ""), ("p", "-h")] {
            let (status, _) = changelog_body(&ok, &ask(p, t)).unwrap_err();
            assert_eq!(status, StatusCode::BAD_REQUEST, "{p:?} {t:?}");
        }
    }

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
        assert!(v["fold"].as_str().unwrap().starts_with("1 channel green"));
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
