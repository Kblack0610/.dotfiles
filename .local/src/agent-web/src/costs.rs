//! The Costs tab: `hub_core::costs`, the reader and view the hub TUI draws too. The view (cut,
//! window, query, sort) is in the request, so a URL such as `#costs?by=model&w=7d&q=harness:codex`
//! is the whole state.
//!
//! One read shells out twice and parses calls.jsonl and a month of snapshots (about 1s), and
//! every figure in it moves nightly or per call, so every open tab and view shares one read for
//! `COSTS_SECS`. The lock is held across the read, so tabs that refresh together wait on one.

use axum::extract::Query;
use axum::http::StatusCode;
use axum::Json;
use hub_core::costs::{self, Board, Costs};
use hub_core::session_actions::System;
use serde::Deserialize;

use crate::cache::{off, ReadCache};
use crate::{bad, ApiResult};

const COSTS_SECS: u64 = 120;

static LAST: ReadCache<Costs, COSTS_SECS> = ReadCache::new();

#[derive(Deserialize, Default)]
#[serde(default)]
pub struct CostsQuery {
    pub by: String,
    pub w: String,
    pub q: String,
    pub sort: String,
    pub dir: String,
    /// The Sections block's own sort, which a click on its headers sets.
    pub ssort: String,
    pub sdir: String,
}

pub async fn get(Query(q): Query<CostsQuery>) -> ApiResult<Json<Board>> {
    let read = off(|| {
        let now = chrono::Utc::now().timestamp();
        costs::read(&System, &costs::Paths::from_env(), now)
    });
    // A read with no outcomes is not kept: the next refresh tries again.
    let c = LAST
        .get_if((), read, |c| !c.sessions.is_empty() || c.errors.is_empty())
        .await
        .map_err(|e| bad(StatusCode::INTERNAL_SERVER_ERROR, e))?;
    Ok(Json(costs::board(
        &c,
        &q.by,
        &q.w,
        &q.q,
        &q.sort,
        &q.dir,
        (&q.ssort, &q.sdir),
    )))
}
