//! The Projects tab: one card per lab project with its open version's progress and what is in
//! flight on it, from `hub_core::projects::gather`, the join the hub TUI's Projects tab, the
//! waybar chip and the phone read. Each card carries `summary`, the one progress line every
//! surface prints word for word. `/api/projects/{name}/epics` is one project's chain from idea
//! to verified (`hub_core::epics`), for a card to read when it is opened, never for every card.

use axum::extract::Path;
use axum::http::StatusCode;
use axum::Json;
use hub_core::{epics, projects};
use serde_json::Value;

use crate::{bad, ApiResult};

pub async fn get() -> ApiResult<Json<Value>> {
    tokio::task::spawn_blocking(|| projects::to_json(&projects::gather()))
        .await
        .map(Json)
        .map_err(|e| bad(StatusCode::INTERNAL_SERVER_ERROR, e.to_string()))
}

pub async fn epics(Path(name): Path<String>) -> ApiResult<Json<Value>> {
    let c = tokio::task::spawn_blocking(move || {
        epics::chain(&hub_core::session_actions::System, &name)
    })
    .await
    .map_err(|e| bad(StatusCode::INTERNAL_SERVER_ERROR, e.to_string()))?
    .map_err(|e| bad(StatusCode::BAD_GATEWAY, e))?;
    Ok(Json(epics::to_json(&c)))
}
