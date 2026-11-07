//! Home's Proposals section: hub_core::proposals filtered and sorted here by `hub_core::table`,
//! so the page only draws, and the accept and reject buttons.

use axum::extract::Query;
use axum::http::StatusCode;
use axum::Json;
use hub_core::home::Home;
use hub_core::proposals::{self, Proposal};
use hub_core::table::{Summary, View};
use serde::{Deserialize, Serialize};

use crate::queue::act;
use crate::{bad, ApiResult};

/// The table view, the same keys the page keeps in its URL.
#[derive(Deserialize, Default)]
#[serde(default)]
pub struct ViewQuery {
    q: String,
    s: String,
    sort: String,
    dir: String,
}

/// Home with `proposals` cut to the rows the view keeps, and the controls that drew them.
#[derive(Serialize)]
pub struct HomePage {
    #[serde(flatten)]
    home: Home,
    proposals_table: Summary,
    /// Grafana's base for the flow strip's graph link, as `/api/flow` sends it.
    grafana: Option<String>,
}

pub fn page(mut home: Home, q: &ViewQuery) -> HomePage {
    let view = View::new::<Proposal>(&q.q, &q.s, &q.sort, &q.dir);
    let (rows, proposals_table) = view.summary(&home.proposals);
    let rows: Vec<Proposal> = rows.into_iter().cloned().collect();
    home.proposals = rows;
    HomePage {
        home,
        proposals_table,
        grafana: hub_core::infra::grafana(),
    }
}

/// Just the Proposals section of `/api/home`: the rows the view keeps, their heading and the
/// controls, flat under the same keys, so the page can lay it over the Home it already holds.
#[derive(Serialize)]
pub struct ProposalsPage {
    proposals: Vec<Proposal>,
    proposals_head: String,
    proposals_table: Summary,
}

pub fn rows(open: Vec<Proposal>, q: &ViewQuery) -> ProposalsPage {
    let view = View::new::<Proposal>(&q.q, &q.s, &q.sort, &q.dir);
    let (kept, proposals_table) = view.summary(&open);
    ProposalsPage {
        proposals_head: hub_core::proposals::heading(&open),
        proposals: kept.into_iter().cloned().collect(),
        proposals_table,
    }
}

/// `GET /api/home/proposals`: a search keystroke or a sort changes only this section, and
/// `/api/home` reads the fleet state, the queue and its stats, the board and Prometheus to
/// answer it (about 1.6s at load 20, agent-queue's two reads being 1.5s of it). This reads
/// agent-propose alone.
pub async fn list(Query(q): Query<ViewQuery>) -> ApiResult<Json<ProposalsPage>> {
    let open = tokio::task::spawn_blocking(|| proposals::read(&hub_core::session_actions::System))
        .await
        .map_err(|e| bad(StatusCode::INTERNAL_SERVER_ERROR, e.to_string()))?
        .map_err(|e| bad(StatusCode::BAD_GATEWAY, e))?;
    Ok(Json(rows(open, &q)))
}

#[derive(Deserialize)]
pub struct IdBody {
    id: String,
}

pub async fn accept(Json(b): Json<IdBody>) -> ApiResult<StatusCode> {
    act(move || proposals::accept(&hub_core::session_actions::System, &b.id)).await
}

pub async fn reject(Json(b): Json<IdBody>) -> ApiResult<StatusCode> {
    act(move || proposals::reject(&hub_core::session_actions::System, &b.id)).await
}

#[cfg(test)]
mod tests {
    use super::*;

    fn home() -> Home {
        let row = |id: &str, verb: &str| Proposal {
            id: id.into(),
            verb: verb.into(),
            ..Proposal::default()
        };
        Home {
            proposals: vec![row("aa", "queue"), row("bb", "none")],
            proposals_head: "2 from 1 stream".into(),
            ..Home::default()
        }
    }

    #[test]
    fn the_view_cuts_the_rows_and_keeps_the_totals() {
        let q = ViewQuery {
            s: "none".into(),
            ..ViewQuery::default()
        };
        let p = page(home(), &q);
        assert_eq!(p.home.proposals.len(), 1);
        assert_eq!(p.home.proposals[0].id, "bb");
        assert_eq!((p.proposals_table.shown, p.proposals_table.total), (1, 2));
        assert_eq!(p.home.proposals_head, "2 from 1 stream");
    }

    #[test]
    fn the_section_alone_matches_what_home_draws() {
        let q = ViewQuery {
            s: "none".into(),
            ..ViewQuery::default()
        };
        let open = home().proposals;
        let v = serde_json::to_value(rows(open, &q)).unwrap();
        let full = serde_json::to_value(page(home(), &q)).unwrap();
        for k in ["proposals", "proposals_head", "proposals_table"] {
            assert_eq!(v[k], full[k], "{k}");
        }
        assert_eq!(v.as_object().unwrap().len(), 3);
    }

    #[test]
    fn the_page_is_home_flat_with_the_table_beside_it() {
        let v = serde_json::to_value(page(home(), &ViewQuery::default())).unwrap();
        assert_eq!(v["proposals"].as_array().unwrap().len(), 2);
        assert_eq!(v["proposals_table"]["total"], 2);
        assert!(v["needs"].is_array());
    }
}
