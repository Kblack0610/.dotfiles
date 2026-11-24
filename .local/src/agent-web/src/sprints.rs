//! Projects' Sprints inner tab and an opened project's Sprint inner tab (`/api/sprints`): the
//! open and queued release windows with their times worked out now (`hub_core::tasks::SprintRow`,
//! once Board's table) and, unscoped, each project's last score from the kept projects read. A
//! project's scored past rides its page (`hub_core::page::Page::sprint_past`), and its By area
//! across sprints table is `/api/sprints/across` (`hub_core::sprint_page::read_across`), kept
//! apart so the open window never waits on one notes read per window. `/api/sprints/page`
//! is one window's own page (`hub_core::sprint_page`), its rows under the table's `sp`-prefixed
//! view. The words are hub-core's, so the TUI's tab says the same.

use axum::extract::{Query, State};
use axum::http::StatusCode;
use axum::Json;
use hub_core::session_actions::System;
use hub_core::table::View;
use hub_core::tasks::{self, Feed};
use hub_core::{project_sprints, projects, sprint_page};
use serde::Deserialize;
use serde_json::{json, Value};

use crate::cache::ReadCache;
use crate::{bad, ApiResult, Shared};

/// Whose windows: `scope=<profile>/<project>`, blank for every project's.
#[derive(Deserialize, Default)]
#[serde(default)]
pub struct SprintsQuery {
    scope: String,
}

/// The windows in scope at `now`, soonest cut first, with the table's column heads; `queued`
/// is each row's own flag, so a surface splits open from queued without reading `left`.
fn shown(f: &Feed, scope: Option<(&str, &str)>, now: chrono::NaiveDateTime) -> Value {
    let rows = f.sprint_rows(scope, now);
    let (kept, table) = View::new::<tasks::SprintRow>("", "", "", "").summary(&rows);
    let heads: serde_json::Map<String, Value> = tasks::SPRINT_HEADS
        .iter()
        .map(|(k, h)| ((*k).to_string(), json!(h)))
        .collect();
    json!({ "rows": kept, "table": table, "heads": heads })
}

pub async fn get(State(s): State<Shared>, Query(q): Query<SprintsQuery>) -> ApiResult<Json<Value>> {
    if !q.scope.is_empty() && !q.scope.contains('/') {
        let why = format!("scope is <profile>/<project>, not {}", q.scope);
        return Err(bad(StatusCode::BAD_REQUEST, why));
    }
    let queue = s.queue.queue().await;
    let scope = q.scope.clone();
    let read = move || {
        let f = hub_core::sheet_view::feed_with(&System, &queue)?;
        let one = scope.split_once('/');
        let now = chrono::Local::now().naive_local();
        Ok::<_, String>(shown(&f, one, now))
    };
    let mut out = tokio::task::spawn_blocking(read)
        .await
        .map_err(|e| bad(StatusCode::INTERNAL_SERVER_ERROR, e.to_string()))?
        .map_err(|e| bad(StatusCode::BAD_GATEWAY, e))?;
    if q.scope.is_empty() {
        let cards = crate::projects::GATHERED
            .get((), crate::cache::off(projects::gather))
            .await
            .map_err(|e| bad(StatusCode::INTERNAL_SERVER_ERROR, e))?;
        out["last"] = json!(project_sprints::last_scores(&cards.cards));
    }
    Ok(Json(out))
}

/// The last By area across sprints table, for the one project whose Sprint tab is open: it reads
/// every window, so a resync or queue change answers it from memory and refreshes it behind.
static ACROSS: ReadCache<sprint_page::Across, 60, String> = ReadCache::new("sprints-across");

/// `scope=<profile>/<project>`'s By area across sprints table: its scored history plus the open
/// window the feed names (a queued one has no row done yet). A feed that fails is said in its errors.
pub async fn across(
    State(s): State<Shared>,
    Query(q): Query<SprintsQuery>,
) -> ApiResult<Json<Value>> {
    let Some((profile, project)) = q.scope.split_once('/') else {
        let why = format!("scope is <profile>/<project>, not {}", q.scope);
        return Err(bad(StatusCode::BAD_REQUEST, why));
    };
    let (profile, project) = (profile.to_string(), project.to_string());
    let queue = s.queue.queue().await;
    let read = move || {
        let now = chrono::Local::now().naive_local();
        let (open, note) = match hub_core::sheet_view::feed_with(&System, &queue) {
            Ok(f) => (sprint_page::open_windows(&f, &profile, &project, now), None),
            Err(e) => (Vec::new(), Some(e)),
        };
        let areas = hub_core::areas::Areas::load();
        let mut a = sprint_page::read_across(&System, areas, &profile, &project, &open);
        a.errors.extend(note);
        a
    };
    let a = ACROSS
        .get(q.scope.clone(), crate::cache::off(read))
        .await
        .map_err(|e| bad(StatusCode::INTERNAL_SERVER_ERROR, e))?;
    Ok(Json(json!(*a)))
}

/// One window's page: whose it is, and the rows' view under the `sp` key prefix so it never
/// reads the Rows tab's (`q`, `s`, `sort`, `dir`).
#[derive(Deserialize, Default)]
#[serde(default)]
pub struct PageQuery {
    profile: String,
    project: String,
    version: String,
    spq: String,
    sps: String,
    spsort: String,
    spdir: String,
}

/// The page the rows are narrowed on: the header, the By area rollup of every row, then the rows
/// the view keeps. `asked` echoes the version, so a late answer for another page is never drawn.
fn page_json(mut page: sprint_page::Page, q: &PageQuery) -> Value {
    let rows = std::mem::take(&mut page.rows);
    let view = View::new::<sprint_page::SprintRow>(&q.spq, &q.sps, &q.spsort, &q.spdir);
    let (kept, table) = view.summary(&rows);
    let heads: serde_json::Map<String, Value> = sprint_page::area_heads(&page.state)
        .into_iter()
        .map(|(k, h)| (k.to_string(), json!(h)))
        .collect();
    json!({
        "asked": q.version,
        "page": page,
        "rows": kept,
        "table": table,
        "area_heads": heads,
    })
}

pub async fn page(State(s): State<Shared>, Query(q): Query<PageQuery>) -> ApiResult<Json<Value>> {
    if !hub_core::projects::safe_name(&q.profile)
        || !hub_core::projects::safe_name(&q.project)
        || !sprint_page::safe_version(&q.version)
    {
        return Err(bad(
            StatusCode::BAD_REQUEST,
            format!("refusing {}/{}/{}", q.profile, q.project, q.version),
        ));
    }
    let queue = s.queue.queue().await;
    let read = move || {
        // The open and queued windows are the feed's: they are the neighbours a scored history lacks.
        let mut note = None;
        let windows: Vec<String> = match hub_core::sheet_view::feed_with(&System, &queue) {
            Ok(f) => f
                .sprint_rows(
                    Some((&q.profile, &q.project)),
                    chrono::Local::now().naive_local(),
                )
                .into_iter()
                .map(|r| r.version)
                .collect(),
            Err(e) => {
                note = Some(e);
                Vec::new()
            }
        };
        let mut page = sprint_page::read(
            &System,
            hub_core::areas::Areas::load(),
            &q.profile,
            &q.project,
            &q.version,
            &windows,
        )?;
        page.errors.extend(note);
        Ok::<_, String>(page_json(page, &q))
    };
    tokio::task::spawn_blocking(read)
        .await
        .map_err(|e| bad(StatusCode::INTERNAL_SERVER_ERROR, e.to_string()))?
        .map(Json)
        .map_err(|e| bad(StatusCode::BAD_GATEWAY, e))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn windowed() -> Feed {
        Feed {
            sprints: vec![hub_core::tasks::SprintLine {
                profile: "bnb".into(),
                project: "demo".into(),
                version: "v0.3.0".into(),
                done: 1,
                committed: 2,
                cut: Some("2026-01-01T14:00".into()),
                build: "held".into(),
                ..Default::default()
            }],
            ..Default::default()
        }
    }

    fn at(day: u32) -> chrono::NaiveDateTime {
        chrono::NaiveDate::from_ymd_opt(2026, 1, day)
            .unwrap()
            .and_hms_opt(9, 0, 0)
            .unwrap()
    }

    #[test]
    fn a_window_is_a_row_with_its_times_read_now_and_the_scope_narrows_it() {
        let none = shown(&Feed::default(), None, at(2));
        assert_eq!(none["rows"], json!([]), "no window, no row");
        assert_eq!(none["heads"]["finish"], "FINISH (7d rate)");
        let all = shown(&windowed(), None, at(2));
        let row = &all["rows"][0];
        assert_eq!(
            (&row["project"], &row["done"], &row["left"], &row["build"]),
            (
                &json!("demo"),
                &json!("1/2"),
                &json!("over"),
                &json!("held")
            )
        );
        assert_eq!(row["queued"], false);
        assert_eq!(
            shown(&windowed(), Some(("bnb", "other")), at(2))["rows"],
            json!([]),
            "another project's window is not this scope's"
        );
        assert_eq!(
            shown(&windowed(), Some(("bnb", "demo")), at(2))["rows"][0]["version"],
            "v0.3.0"
        );
    }

    #[test]
    fn the_across_table_reads_only_the_scopes_open_window() {
        let mut f = windowed();
        let mut queued = f.sprints[0].clone();
        queued.version = "v0.3.1".into();
        queued.queued = true;
        f.sprints.push(queued);
        assert_eq!(
            sprint_page::open_windows(&f, "bnb", "demo", at(2)),
            ["v0.3.0"],
            "a queued window has no row done yet"
        );
        assert!(sprint_page::open_windows(&f, "bnb", "other", at(2)).is_empty());
    }

    #[test]
    fn a_window_page_sends_the_rollup_of_every_row_and_the_rows_the_view_keeps() {
        let json = r#"{"version":"v0.5.5","state":"open","opened":"2026-11-19","committed":2,
            "delivered":1,"open":1,"dropped":0,"interrupted":0,
            "rows":[{"id":"a-1","type":"fix","area":"ci","title":"x","pts":2,"state":"done","outcome":"delivered","interrupt":false},
                    {"id":"a-2","type":"feat","area":"gameplay","title":"y","pts":3,"state":"open","outcome":"open","interrupt":false}]}"#;
        let areas = hub_core::areas::Areas::parse("ci  Tests\ngameplay  Engine\n");
        let page = sprint_page::build(json, &areas, "bnb", "unity", vec![]).unwrap();
        let q = PageQuery {
            version: "v0.5.5".into(),
            spq: "group:Engine".into(),
            ..Default::default()
        };
        let out = page_json(page, &q);
        assert_eq!(out["asked"], "v0.5.5");
        assert_eq!(
            out["rows"].as_array().unwrap().len(),
            1,
            "the view narrows the rows"
        );
        assert_eq!(
            out["page"]["by_area"].as_array().unwrap().len(),
            2,
            "never the rollup"
        );
        assert_eq!(out["table"]["total"], 2);
        assert_eq!(out["area_heads"]["pending"], "OPEN");
        assert!(out["page"].get("rows").is_none() || out["page"]["rows"] == json!([]));
    }
}
