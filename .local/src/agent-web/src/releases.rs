//! The Releases tab: every app with what is deployed where, its channels on open, from hub-core's
//! `releases`. The list is filtered and sorted here by `hub_core::table`, so the page only draws.
//! No read cache for the snapshot: it is one small file, and a new snapshot pushes the `releases`
//! event. The apps' build runs come from the builds read and its cache; their CHECKS cell from
//! `app_status::badges`, two VictoriaMetrics calls kept `CHECKS_SECS` per set of groups, since the
//! page re-reads every minute while it shows (Prometheus has no push); a project page's checks
//! line reads through the same keep.

use axum::extract::Query as UrlQuery;
use axum::http::{header, StatusCode};
use axum::response::{IntoResponse, Response};
use hub_core::queue::Item;
use hub_core::releases::{self, App, Releases, STALE_SECS};
use hub_core::session_actions::{Runner, System};
use hub_core::table::{Summary, View};
use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, HashMap};
use std::sync::Mutex;

/// How long one read of a set of apps' checks answers again.
const CHECKS_SECS: i64 = 30;
type Groups = Vec<(String, Vec<String>)>;
type Checks = Result<HashMap<String, releases::Badge>, String>;
/// Each asked-for set of groups (every app's for the tab, one app's for its project page) with
/// when it was read and what it said.
static CHECKS: Mutex<BTreeMap<Groups, (i64, Checks)>> = Mutex::new(BTreeMap::new());

/// The checks of `groups` (`hub_core::app_status::badges`), from the last read of the same groups
/// while it is under `CHECKS_SECS` old. The lock is held through a read, so requests that arrive
/// together make one read and the rest take its answer.
pub fn checks(groups: &[(String, Vec<String>)]) -> Checks {
    let now = hub_core::jobs::now();
    let mut held = CHECKS
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    if let Some((at, r)) = held.get(groups) {
        if now - at < CHECKS_SECS {
            return r.clone();
        }
    }
    let r = hub_core::app_status::badges(&System, groups, now);
    held.retain(|_, (at, _)| now - *at < CHECKS_SECS);
    held.insert(groups.to_vec(), (now, r.clone()));
    r
}

/// The table view (`q`, `s`, `sort`, `dir`, the keys the page keeps in its URL) and the app whose
/// page is open (`#releases/apps/<name>`, links::Kind::App), read whatever the view hides.
#[derive(Deserialize, Default)]
#[serde(default)]
pub struct Query {
    pub q: String,
    pub s: String,
    pub sort: String,
    pub dir: String,
    pub app: String,
}

/// The read with the view applied: the apps drawn, the channels it could not read, the controls.
#[derive(Serialize)]
struct Shown<'a> {
    at: i64,
    question: &'a str,
    summary: &'a str,
    gaps: &'a str,
    /// `Releases::coverage`: how full each history column is, over every app.
    coverage: &'a str,
    stale_after: i64,
    rows: Vec<&'a App>,
    errors: &'a [String],
    /// `Releases::needs_look`: the count on the Apps inner tab.
    look: bool,
    table: Summary,
    /// The words a cell says when the fact is absent (`releases::BLANKS`), which the page dims.
    blanks: &'static [&'static str],
    /// The app this read was asked for (`Query::app`), so a page can tell a read still on its way
    /// from an app the snapshot does not have.
    #[serde(skip_serializing_if = "str::is_empty")]
    asked: &'a str,
    /// The app `Query::app` names, absent when none is asked or no app has that name, and the
    /// records its cells link to.
    #[serde(skip_serializing_if = "Option::is_none")]
    app: Option<&'a App>,
    #[serde(skip_serializing_if = "Option::is_none")]
    app_links: Option<BTreeMap<&'static str, String>>,
}

fn render(s: &Releases, q: &Query) -> String {
    let view = View::new::<App>(&q.q, &q.s, &q.sort, &q.dir);
    let (rows, table) = view.summary(&s.apps);
    let app = (!q.app.is_empty())
        .then(|| s.apps.iter().find(|a| a.project == q.app))
        .flatten();
    let out = Shown {
        at: s.at,
        question: &s.question,
        summary: &s.summary,
        gaps: &s.gaps,
        coverage: &s.coverage,
        stale_after: STALE_SECS,
        rows,
        errors: &s.errors,
        look: s.needs_look(),
        table,
        blanks: &releases::BLANKS,
        asked: &q.app,
        app,
        app_links: app.map(|a| hub_core::table::links(&[a]).pop().unwrap_or_default()),
    };
    serde_json::to_string(&out).unwrap_or_else(|e| failed(e.to_string()))
}

/// A body the tab can still render when reading itself failed.
fn failed(e: String) -> String {
    serde_json::json!({ "rows": [], "errors": [e] }).to_string()
}

/// The view `q` asks for, over a read of its own joined to the queue `items`, each app with its
/// build runs from the builds read Release runs lists (`builds::current`, kept a few seconds).
pub async fn get(q: Query, (items, queue_error): (Vec<Item>, Option<String>)) -> String {
    let runs = crate::builds::current((items.clone(), None)).await;
    let read = move || {
        let mut r = releases::read(&System, &items);
        r.errors.extend(queue_error);
        r.with_checks(&checks(&r.check_groups()));
        match runs {
            Ok(b) => r.with_builds(&b.rows),
            Err(e) => r.errors.push(format!("build runs: {e}")),
        }
        r
    };
    match tokio::task::spawn_blocking(read).await {
        Ok(s) => render(&s, &q),
        Err(e) => failed(e.to_string()),
    }
}

impl crate::infra::Pages {
    /// `#releases/apps/<app>`'s read (`hub_core::app_status`): release-state and eight
    /// VictoriaMetrics queries, so it is kept `CACHE_SECS` like a machine's page.
    pub async fn app(&self, app: String) -> Result<String, (StatusCode, String)> {
        let a = app.clone();
        self.get(app, async move {
            let now = hub_core::jobs::now();
            move || {
                hub_core::app_status::read(&System, &a, now)
                    .and_then(|p| serde_json::to_string(&p).map_err(|e| e.to_string()))
            }
        })
        .await
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
        return Err((
            StatusCode::BAD_REQUEST,
            "a project and a tag name are required".into(),
        ));
    }
    let c =
        releases::changelog(runner, &q.project, tag).map_err(|e| (StatusCode::BAD_GATEWAY, e))?;
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
        let ok = Says(Ok(
            r#"{"project":"p","tag":"p-v1","tags":["p-v1"],"text":"- a"}"#.into(),
        ));
        let v: serde_json::Value =
            serde_json::from_str(&changelog_body(&ok, &ask("p", "")).unwrap()).unwrap();
        assert_eq!(
            (v["tag"].as_str(), v["tags"][0].as_str()),
            (Some("p-v1"), Some("p-v1"))
        );
        let no = Says(Err("release-state: x is not a release tag of p".into()));
        let (status, words) = changelog_body(&no, &ask("p", "x")).unwrap_err();
        assert!(status == StatusCode::BAD_GATEWAY && words.contains("not a release tag"));
        for (p, t) in [("", ""), ("-h", ""), ("p", "-h")] {
            let (status, _) = changelog_body(&ok, &ask(p, t)).unwrap_err();
            assert_eq!(status, StatusCode::BAD_REQUEST, "{p:?} {t:?}");
        }
    }

    fn app(project: &str, level: releases::Level) -> App {
        App {
            project: project.into(),
            status: "ok".into(),
            level,
            ..Default::default()
        }
    }

    fn sample() -> Releases {
        Releases {
            at: 300,
            question: "What is deployed where?".into(),
            summary: "2 apps: 1 drift, 1 ok".into(),
            gaps: "1 channel not read: steam 403 (1)".into(),
            coverage: "coverage: prev 2/2, deployed 1/2".into(),
            apps: vec![
                app("game", releases::Level::Bad),
                app("site", releases::Level::Ok),
            ],
            ..Default::default()
        }
    }

    fn body(q: Query) -> serde_json::Value {
        serde_json::from_str(&render(&sample(), &q)).unwrap()
    }

    #[test]
    fn the_plain_view_lists_every_app_and_says_what_it_could_not_read() {
        let v = body(Query::default());
        let rows: Vec<&str> = v["rows"]
            .as_array()
            .unwrap()
            .iter()
            .map(|r| r["project"].as_str().unwrap())
            .collect();
        assert_eq!(
            rows,
            ["game", "site"],
            "nothing folded: the green app shows too"
        );
        assert!(v.get("fold").is_none());
        assert_eq!(v["gaps"], "1 channel not read: steam 403 (1)");
        assert_eq!(v["coverage"], "coverage: prev 2/2, deployed 1/2");
        assert_eq!(v["table"]["total"], 2);
        assert_eq!(v["question"], "What is deployed where?");
        assert_eq!(v["stale_after"], STALE_SECS);
    }

    #[test]
    fn a_chip_keeps_the_apps_under_it() {
        let v = body(Query {
            s: "ok".into(),
            ..Default::default()
        });
        assert_eq!(v["rows"].as_array().unwrap().len(), 1);
        assert_eq!(v["rows"][0]["project"], "site");
    }

    #[test]
    fn an_app_page_reads_its_app_whatever_the_view_hides_and_links_its_project() {
        let v = body(Query {
            s: "ok".into(),
            app: "game".into(),
            ..Default::default()
        });
        assert_eq!(
            v["rows"].as_array().unwrap().len(),
            1,
            "the view still applies"
        );
        assert_eq!(v["app"]["project"], "game");
        assert_eq!(v["app_links"]["project"], "#projects/game");
        assert_eq!(v["blanks"][0], "none declared");
        let none = body(Query {
            app: "nope".into(),
            ..Default::default()
        });
        assert!(none.get("app").is_none() && body(Query::default()).get("app").is_none());
        assert_eq!(
            none["asked"], "nope",
            "an unknown app's read says what it was asked"
        );
        assert!(body(Query::default()).get("asked").is_none());
    }

    #[test]
    fn a_failed_read_still_gives_the_tab_a_body() {
        let v: serde_json::Value = serde_json::from_str(&failed("gone".into())).unwrap();
        assert_eq!(v["errors"][0], "gone");
    }
}
