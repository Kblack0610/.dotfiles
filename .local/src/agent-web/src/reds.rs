//! Infra's "Red fixes" section: each red the triage queued as a fix in the last week, open ones
//! worst first, and the summary line. `hub_core::reds` reads and words it for the hub TUI too.
//!
//! One `fleet-bench reds` read takes about 2s and a fix moves in minutes, so every open tab
//! shares one answer for `REDS_SECS`. The lock is held across the read, so tabs that refresh
//! together wait on one read instead of starting one each.

use axum::http::StatusCode;
use axum::Json;
use hub_core::reds::{self, Reds};
use hub_core::session_actions::System;

use crate::cache::{off, ReadCache};
use crate::{bad, ApiResult};

const REDS_SECS: u64 = 120;

static LAST: ReadCache<Reds, REDS_SECS> = ReadCache::new();

/// A failed read is not cached: the next refresh tries again.
pub async fn get() -> ApiResult<Json<Reds>> {
    let read = async {
        off(|| reds::read(&System))
            .await
            .map_err(|e| bad(StatusCode::INTERNAL_SERVER_ERROR, e))?
            .map_err(|e| bad(StatusCode::BAD_GATEWAY, e))
    };
    LAST.get((), read).await.map(|r| Json((*r).clone()))
}
