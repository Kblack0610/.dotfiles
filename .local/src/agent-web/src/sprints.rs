//! Projects' Sprints inner tab and an opened project's Sprint inner tab (`/api/sprints`): the
//! open and queued release windows with their times worked out now (`hub_core::tasks::SprintRow`,
//! once Board's table) and, unscoped, each project's last score from the kept projects read. A
//! project's scored past rides its page (`hub_core::page::Page::sprint_past`). The words are
//! hub-core's, so the TUI's tab says the same.

use axum::extract::{Query, State};
use axum::http::StatusCode;
use axum::Json;
use hub_core::session_actions::System;
use hub_core::table::View;
use hub_core::tasks::{self, Feed};
use hub_core::{project_sprints, projects};
use serde::Deserialize;
use serde_json::{json, Value};

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
        Ok::<_, String>(shown(&f, one, chrono::Local::now().naive_local()))
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
}
