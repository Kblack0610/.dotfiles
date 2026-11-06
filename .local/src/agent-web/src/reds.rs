//! Infra's "Red fixes" section: each red the triage queued as a fix in the last week, open ones
//! worst first, and the summary line. `hub_core::reds` reads and words it for the hub TUI too.

use axum::http::StatusCode;
use axum::Json;
use hub_core::reds::{self, Reds};
use hub_core::session_actions::System;

use crate::{bad, ApiResult};

pub async fn get() -> ApiResult<Json<Reds>> {
    tokio::task::spawn_blocking(|| reds::read(&System))
        .await
        .map_err(|e| bad(StatusCode::INTERNAL_SERVER_ERROR, e.to_string()))?
        .map(Json)
        .map_err(|e| bad(StatusCode::BAD_GATEWAY, e))
}
