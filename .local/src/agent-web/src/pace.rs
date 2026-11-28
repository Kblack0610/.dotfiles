//! Set and end a pace.conf key from Costs > Limits. The page reads the config with the rest of
//! Costs (`hub_core::costs`); these two routes are the writers, and each runs `pace-conf` through
//! `hub_core::pace_conf`, which checks the key against the CLI's own list of editable keys and
//! the value and times before any argv is built. What the CLI says on a refusal is the 400's body.

use axum::http::StatusCode;
use axum::Json;
use hub_core::pace_conf::{self, End, Set};
use hub_core::session_actions::System;

use crate::queue::act;
use crate::ApiResult;

/// A standing override or a window for an editable key.
pub async fn set(Json(b): Json<Set>) -> ApiResult<StatusCode> {
    let r = act(move || pace_conf::set(&System, &b)).await;
    if r.is_ok() {
        crate::costs::outdate();
    }
    r
}

/// End a window (by its start) or the standing override.
pub async fn end(Json(b): Json<End>) -> ApiResult<StatusCode> {
    let r = act(move || pace_conf::end(&System, &b)).await;
    if r.is_ok() {
        crate::costs::outdate();
    }
    r
}
