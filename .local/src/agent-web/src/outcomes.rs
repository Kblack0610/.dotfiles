//! The "Ranked sessions" fold at the bottom of Sessions: the week's sessions worst first, and a
//! session's card when its row is opened. Both go through `hub_core::outcomes`, which the hub
//! TUI reads too, so the list and the card read the same on both surfaces.

use axum::extract::Query;
use axum::http::StatusCode;
use axum::Json;
use hub_core::outcomes::{self, Ranked};
use hub_core::session_actions::System;
use serde::Deserialize;
use std::sync::Arc;

use crate::cache::{off, ReadCache};
use crate::{bad, ApiResult};

/// The week's ranking, kept: `agentctl-session-outcomes worst` takes a second or more, and a new
/// outcome row moves a week's order little, so a minute is fresh enough for Log's Ranked.
static RANKED: ReadCache<Vec<Ranked>, 60> = ReadCache::new("ranked");

/// The kept ranking; `warm` fills it at start. A failed read is not kept.
pub async fn kept() -> Result<Arc<Vec<Ranked>>, String> {
    RANKED
        .get((), async { off(|| outcomes::ranked(&System)).await? })
        .await
}

pub async fn ranked() -> ApiResult<Json<Vec<Ranked>>> {
    kept()
        .await
        .map(|r| Json(Vec::clone(&r)))
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
