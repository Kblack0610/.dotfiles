//! Home's Proposals section: hub_core::proposals filtered and sorted here by `hub_core::table`,
//! so the page only draws, and the accept and reject buttons.

use axum::http::StatusCode;
use axum::Json;
use hub_core::home::Home;
use hub_core::proposals::{self, Proposal};
use hub_core::table::{Summary, View};
use serde::{Deserialize, Serialize};

use crate::queue::act;
use crate::ApiResult;

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
}

pub fn page(mut home: Home, q: &ViewQuery) -> HomePage {
    let view = View::new::<Proposal>(&q.q, &q.s, &q.sort, &q.dir);
    let (rows, proposals_table) = view.summary(&home.proposals);
    let rows: Vec<Proposal> = rows.into_iter().cloned().collect();
    home.proposals = rows;
    HomePage {
        home,
        proposals_table,
    }
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
    fn the_page_is_home_flat_with_the_table_beside_it() {
        let v = serde_json::to_value(page(home(), &ViewQuery::default())).unwrap();
        assert_eq!(v["proposals"].as_array().unwrap().len(), 2);
        assert_eq!(v["proposals_table"]["total"], 2);
        assert!(v["needs"].is_array());
    }
}
