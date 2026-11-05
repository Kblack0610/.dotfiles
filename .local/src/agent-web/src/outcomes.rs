//! The "Ranked sessions" fold at the bottom of Sessions: the week's sessions worst first, and a
//! session's card when its row is opened. Both go through `hub_core::outcomes`, which the hub
//! TUI reads too, so the list and the card read the same on both surfaces.

use axum::extract::Query;
use axum::http::StatusCode;
use axum::Json;
use hub_core::outcomes::{self, Ranked};
use hub_core::session_actions::System;
use serde::Deserialize;

use crate::{bad, ApiResult};

pub async fn ranked() -> ApiResult<Json<Vec<Ranked>>> {
    tokio::task::spawn_blocking(|| outcomes::ranked(&System))
        .await
        .map_err(|e| bad(StatusCode::INTERNAL_SERVER_ERROR, e.to_string()))?
        .map(Json)
        .map_err(|e| bad(StatusCode::BAD_GATEWAY, e))
}

#[derive(Deserialize)]
pub struct CardQuery {
    sid: String,
}

/// The card is read on open, never for every row (dashboards rule 10).
pub async fn card(Query(q): Query<CardQuery>) -> ApiResult<String> {
    tokio::task::spawn_blocking(move || outcomes::card(&System, &q.sid))
        .await
        .map_err(|e| bad(StatusCode::INTERNAL_SERVER_ERROR, e.to_string()))?
        .map_err(|e| bad(StatusCode::BAD_REQUEST, e))
}
