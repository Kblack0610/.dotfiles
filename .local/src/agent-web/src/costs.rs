//! The Costs tab: `hub_core::costs`, the reader and view the hub TUI draws too. The view (cut,
//! window, query, sort) is in the request, so a URL such as `#costs?by=model&w=7d&q=harness:codex`
//! is the whole state.
//!
//! One read shells out twice and parses calls.jsonl and a month of snapshots (about 1s), and
//! every figure in it moves nightly or per call, so every open tab and view shares one read for
//! `COSTS_TTL`. The lock is held across the read, so tabs that refresh together wait on one.

use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use axum::extract::Query;
use axum::http::StatusCode;
use axum::Json;
use hub_core::costs::{self, Board, Costs};
use hub_core::session_actions::System;
use serde::Deserialize;

use crate::{bad, ApiResult};

const COSTS_TTL: Duration = Duration::from_secs(120);

static LAST: Mutex<Option<(Instant, Arc<Costs>)>> = Mutex::new(None);

#[derive(Deserialize, Default)]
#[serde(default)]
pub struct CostsQuery {
    pub by: String,
    pub w: String,
    pub q: String,
    pub sort: String,
    pub dir: String,
}

fn cached() -> Arc<Costs> {
    let mut last = LAST.lock().unwrap_or_else(|e| e.into_inner());
    if let Some((at, c)) = last.as_ref() {
        if at.elapsed() < COSTS_TTL {
            return Arc::clone(c);
        }
    }
    let now = chrono::Utc::now().timestamp();
    let c = Arc::new(costs::read(&System, &costs::Paths::from_env(), now));
    // A read with no outcomes is not kept: the next refresh tries again.
    if c.sessions.is_empty() && !c.errors.is_empty() {
        return c;
    }
    *last = Some((Instant::now(), Arc::clone(&c)));
    c
}

pub async fn get(Query(q): Query<CostsQuery>) -> ApiResult<Json<Board>> {
    let c = tokio::task::spawn_blocking(cached)
        .await
        .map_err(|e| bad(StatusCode::INTERNAL_SERVER_ERROR, e.to_string()))?;
    Ok(Json(costs::board(&c, &q.by, &q.w, &q.q, &q.sort, &q.dir)))
}
