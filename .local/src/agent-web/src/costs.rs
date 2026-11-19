//! The Costs tab: `hub_core::costs`, the reader and view the hub TUI draws too. The view (cut,
//! window, query, sort) is in the request, so a URL such as `#costs?by=model&w=7d&q=harness:codex`
//! is the whole state.
//!
//! One read shells out twice and parses calls.jsonl and a month of snapshots (about 1s), and
//! every figure in it moves nightly or per call, so every open tab and view shares one read for
//! `COSTS_SECS`. The lock is held across the read, so tabs that refresh together wait on one.

use std::sync::Arc;

use axum::extract::Query;
use axum::http::StatusCode;
use axum::Json;
use hub_core::costs::{self, Board, Costs, Line};
use hub_core::layout::page_rows;
use hub_core::session_actions::System;
use hub_core::table::{self, Keys};
use serde::Deserialize;

use crate::cache::{off, ReadCache};
use crate::{bad, ApiResult};

const COSTS_SECS: u64 = 120;

static LAST: ReadCache<Costs, COSTS_SECS> = ReadCache::new("costs");

#[derive(Deserialize, Default)]
#[serde(default)]
pub struct CostsQuery {
    pub by: String,
    pub w: String,
    pub q: String,
    pub sort: String,
    pub dir: String,
    /// The spend table's page.
    pub pg: String,
    /// The Sections block's own view: its query, sort, direction and page (no state but all).
    pub sq: String,
    pub ssort: String,
    pub sdir: String,
    pub spg: String,
    /// The Spend table: the day shown, the cut (`g`) and the group opened (`gv`), the session
    /// table's own sort, and the session opened.
    pub day: String,
    pub dsort: String,
    pub ddir: String,
    pub sid: String,
    pub g: String,
    pub gv: String,
    /// The Consumers table's own view: its query, state, sort and direction.
    pub cq: String,
    pub cs: String,
    pub csort: String,
    pub cdir: String,
}

/// A new token snapshot: the kept read is answered once more and refreshed behind it.
pub fn outdate() {
    LAST.outdate();
}

/// A read that found no spend (no live file, no nightly day) and hit an error is not kept: the
/// next refresh tries again.
fn kept(c: &Costs) -> bool {
    c.live.is_some() || !c.spend_days.is_empty() || c.errors.is_empty()
}

/// The one kept read, the tab's and Home's Costs card's.
pub async fn read() -> Result<Arc<Costs>, String> {
    let read = off(|| {
        let now = chrono::Utc::now().timestamp();
        costs::read(&System, &costs::Paths::from_env(), now)
    });
    LAST.get_if((), read, kept).await
}

pub async fn get(Query(q): Query<CostsQuery>) -> ApiResult<Json<Board>> {
    let c = read()
        .await
        .map_err(|e| bad(StatusCode::INTERNAL_SERVER_ERROR, e))?;
    Ok(Json(board(&c, &q)))
}

/// The board under the request's view. The spend table and Sections send one page of their
/// section's `page_rows`; their `table.shown` still counts every row. Consumers is built again
/// here under its own view.
fn board(c: &Costs, q: &CostsQuery) -> Board {
    let mut b = costs::board(
        c,
        &q.by,
        &q.w,
        &q.q,
        &q.sort,
        &q.dir,
        Keys {
            q: &q.sq,
            sort: &q.ssort,
            dir: &q.sdir,
            ..Keys::default()
        },
        &hub_core::spend_history::Pick {
            day: &q.day,
            sort: &q.dsort,
            dir: &q.ddir,
            sid: &q.sid,
            group: &q.g,
            in_group: &q.gv,
        },
    );
    let mut rows: Vec<&Line> = b.rows.iter().collect();
    table::page(
        &mut rows,
        &mut b.table,
        q.pg.parse().unwrap_or(1),
        page_rows("table"),
    );
    b.rows = rows.into_iter().cloned().collect();
    // Section rows link nothing, so the cut cells need no new `links`.
    if let Some(t) = b.sections.table.as_mut() {
        let page = q.spg.parse().unwrap_or(1);
        t.pager = table::page_of(&mut b.sections.rows, page, page_rows("sections"));
    }
    b.consumers = costs::consumers(
        c,
        Keys {
            q: &q.cq,
            s: &q.cs,
            sort: &q.csort,
            dir: &q.cdir,
        },
    );
    b
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_read_that_found_no_spend_is_not_kept() {
        let failed = Costs {
            errors: vec!["fleet-cost.json: missing".into()],
            ..Costs::default()
        };
        assert!(!kept(&failed));
        assert!(kept(&Costs::default()), "a quiet day is kept");
    }

    #[test]
    fn the_spend_table_and_sections_send_one_page_and_count_every_row() {
        let (per, sper) = (page_rows("table"), page_rows("sections"));
        let c = Costs {
            at: 1_000,
            calls: (0..per + 3)
                .map(|i| costs::Call {
                    runner: format!("r{i}"),
                    at: 1_000,
                    cost: Some(i as f64),
                    ..Default::default()
                })
                .collect(),
            sections: hub_core::sections::Sections {
                days: 7,
                all: hub_core::sections::Section {
                    prs: 1,
                    ..Default::default()
                },
                rows: (0..sper + 2)
                    .map(|i| hub_core::sections::Section {
                        section: format!("s{i}"),
                        ..Default::default()
                    })
                    .collect(),
            },
            ..Costs::default()
        };
        let q = CostsQuery {
            by: "runner".into(),
            pg: "2".into(),
            spg: "2".into(),
            ..CostsQuery::default()
        };
        let b = board(&c, &q);
        assert_eq!(b.rows.len(), 3);
        assert_eq!(b.table.shown, per + 3, "shown counts every page");
        assert_eq!(b.table.pager.map(|p| (p.page, p.pages)), Some((2, 2)));
        let s = b.sections.table.as_ref().unwrap();
        assert_eq!((b.sections.rows.len(), s.shown), (2, sper + 2));
        assert_eq!(s.pager.map(|p| p.page), Some(2));
        let first = board(
            &c,
            &CostsQuery {
                by: "runner".into(),
                ..CostsQuery::default()
            },
        );
        assert_eq!(first.rows.len(), per, "no page asked is the first");
    }
}
