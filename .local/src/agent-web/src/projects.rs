//! The Projects tab: one card per lab project with its open version's progress and what is in
//! flight on it, from `hub_core::projects::gather`, the join the hub TUI's Projects tab, the
//! waybar chip and the phone read. Each card carries `summary`, the one progress line every
//! surface prints word for word. `/api/projects/{name}/page` is one project's page
//! (`hub_core::page`: its flow, what needs the human, epics by system, next stage and shipped
//! versions), for a card to read when it is opened, never for every card.

use axum::extract::Path;
use axum::http::StatusCode;
use axum::Json;
use hub_core::{page, projects};
use serde_json::Value;

use crate::{bad, ApiResult};

pub async fn get() -> ApiResult<Json<Value>> {
    tokio::task::spawn_blocking(|| projects::to_json(&projects::gather()))
        .await
        .map(Json)
        .map_err(|e| bad(StatusCode::INTERNAL_SERVER_ERROR, e.to_string()))
}

pub async fn page(Path(name): Path<String>) -> ApiResult<Json<Value>> {
    let p = tokio::task::spawn_blocking(move || {
        page::named(
            &hub_core::session_actions::System,
            &name,
            hub_core::jobs::now(),
        )
    })
    .await
    .map_err(|e| bad(StatusCode::INTERNAL_SERVER_ERROR, e.to_string()))?
    .map_err(|e| bad(StatusCode::BAD_GATEWAY, e))?;
    Ok(Json(page::to_json(&p)))
}
