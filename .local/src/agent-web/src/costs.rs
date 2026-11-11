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
    /// The Spend day table: the day shown, its own query and sort, and the session opened.
    pub day: String,
    pub dq: String,
    pub dsort: String,
    pub ddir: String,
    pub sid: String,
    /// The Consumers table's own sort, which a click on its headers sets.
    pub csort: String,
    pub cdir: String,
}

/// Drop the kept read, so the refresh a new token snapshot asks for reads it.
pub async fn forget() {
    LAST.clear().await;
}

/// A read that failed to find any outcome is not kept: the next refresh tries again.
fn kept(c: &Costs) -> bool {
    !c.sessions.is_empty() || c.errors.is_empty()
}

pub async fn get(Query(q): Query<CostsQuery>) -> ApiResult<Json<Board>> {
    let read = off(|| {
        let now = chrono::Utc::now().timestamp();
        costs::read(&System, &costs::Paths::from_env(), now)
    });
    let c = LAST
        .get_if((), read, kept)
        .await
        .map_err(|e| bad(StatusCode::INTERNAL_SERVER_ERROR, e))?;
    let mut b = costs::board(
        &c,
        &q.by,
        &q.w,
        &q.q,
        &q.sort,
        &q.dir,
        (&q.ssort, &q.sdir),
        &hub_core::spend_history::Pick {
            day: &q.day,
            q: &q.dq,
            sort: &q.dsort,
            dir: &q.ddir,
            sid: &q.sid,
        },
    );
    b.consumers = costs::consumers(&c, &q.csort, &q.cdir);
    Ok(Json(b))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_read_that_found_no_outcome_is_not_kept() {
        let failed = Costs {
            errors: vec!["no outcomes".into()],
            ..Costs::default()
        };
        assert!(!kept(&failed));
        assert!(kept(&Costs::default()), "a quiet day is kept");
    }
}
