//! Infra's "Red fixes" section: each red the triage queued as a fix in the last week, open ones
//! worst first, and the summary line. `hub_core::reds` reads and words it for the hub TUI too.
//!
//! One `fleet-bench reds` read takes about 2s and a fix moves in minutes, so every open tab
//! shares one answer for `REDS_TTL`. The lock is held across the read, so tabs that refresh
//! together wait on one read instead of starting one each.

use std::sync::Mutex;
use std::time::{Duration, Instant};

use axum::http::StatusCode;
use axum::Json;
use hub_core::reds::{self, Reds};
use hub_core::session_actions::System;

use crate::{bad, ApiResult};

const REDS_TTL: Duration = Duration::from_secs(120);

static LAST: Mutex<Option<(Instant, Reds)>> = Mutex::new(None);

fn cached() -> Result<Reds, String> {
    let mut last = LAST.lock().unwrap_or_else(|e| e.into_inner());
    if let Some((at, r)) = last.as_ref() {
        if at.elapsed() < REDS_TTL {
            return Ok(r.clone());
        }
    }
    // A failed read is not cached: the next refresh tries again.
    let r = reds::read(&System)?;
    *last = Some((Instant::now(), r.clone()));
    Ok(r)
}

pub async fn get() -> ApiResult<Json<Reds>> {
    tokio::task::spawn_blocking(cached)
        .await
        .map_err(|e| bad(StatusCode::INTERNAL_SERVER_ERROR, e.to_string()))?
        .map(Json)
        .map_err(|e| bad(StatusCode::BAD_GATEWAY, e))
}
