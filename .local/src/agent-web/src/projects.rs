//! The Projects tab: one card per lab project with its open version's progress and what is in
//! flight on it, from `hub_core::projects::gather`, the join the hub TUI's Projects tab, the
//! waybar chip and the phone read. Each card carries `summary`, the one progress line every
//! surface prints word for word. `/api/projects` takes the table's `q`, `s`, `sort` and `dir`
//! (`impl table::Row for projects::Card`) and answers the cards the view keeps with `table`.
//! `/api/projects/{name}/page` is one project's page (`hub_core::page`: its flow, what needs the
//! human, epics by system, next stage and shipped versions), for a card to read when it is
//! opened, never for every card.

use axum::extract::{Path, Query};
use axum::http::StatusCode;
use axum::Json;
use hub_core::projects::{Card, Projects};
use hub_core::table::View;
use hub_core::{page, projects};
use serde_json::{json, Value};

use crate::sessions::TableQuery;
use crate::{bad, ApiResult};

/// The cards the view keeps, in its order, with the controls that drew them. What no card
/// claims and what failed are the whole tab's, so no view narrows them.
fn shown(p: &Projects, q: &TableQuery) -> Value {
    let view = View::new::<Card>(&q.q, &q.s, &q.sort, &q.dir);
    let (cards, table) = view.summary(&p.cards);
    let mut out = projects::to_json(&Projects {
        cards: cards.into_iter().cloned().collect(),
        unlinked: p.unlinked.clone(),
        errors: p.errors.clone(),
    });
    out["table"] = json!(table);
    out
}

pub async fn get(Query(q): Query<TableQuery>) -> ApiResult<Json<Value>> {
    tokio::task::spawn_blocking(move || shown(&projects::gather(), &q))
        .await
        .map(Json)
        .map_err(|e| bad(StatusCode::INTERNAL_SERVER_ERROR, e.to_string()))
}

pub async fn page(Path(name): Path<String>) -> ApiResult<Json<Value>> {
    let p = tokio::task::spawn_blocking(move || {
        page::named(
            &hub_core::session_actions::System,
            &name,
            hub_core::jobs::now(),
        )
    })
    .await
    .map_err(|e| bad(StatusCode::INTERNAL_SERVER_ERROR, e.to_string()))?
    .map_err(|e| bad(StatusCode::BAD_GATEWAY, e))?;
    Ok(Json(page::to_json(&p)))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn cards() -> Projects {
        let card = |name: &str, stage: &str, waiting: usize| Card {
            profile: "personal".into(),
            name: name.into(),
            stage: stage.into(),
            waiting,
            ..Default::default()
        };
        Projects {
            cards: vec![card("garden", "alpha", 1), card("demo", "beta", 0)],
            unlinked: vec!["dotfiles: tidy".into()],
            errors: vec!["notes projects failed".into()],
        }
    }

    #[test]
    fn the_view_keeps_cards_and_never_narrows_what_no_card_claims() {
        let q = TableQuery {
            q: "stage:beta".into(),
            ..Default::default()
        };
        let got = shown(&cards(), &q);
        assert_eq!(got["cards"].as_array().unwrap().len(), 1);
        assert_eq!(got["cards"][0]["name"], "demo");
        assert_eq!(got["cards"][0]["pace"], 0.0);
        assert_eq!(got["table"]["total"], 2);
        assert_eq!(got["table"]["shown"], 1);
        assert_eq!(got["unlinked"][0], "dotfiles: tidy");
        assert_eq!(got["errors"][0], "notes projects failed");
    }

    #[test]
    fn a_plain_read_is_every_card_in_its_own_order_with_the_chips_counted() {
        let got = shown(&cards(), &TableQuery::default());
        assert_eq!(got["cards"][0]["name"], "garden");
        assert_eq!(got["cards"][1]["name"], "demo");
        let chips = got["table"]["states"].as_array().unwrap();
        assert_eq!(chips[0]["n"], 2);
        assert_eq!(chips[1]["name"], "in flight");
        assert_eq!(chips[1]["n"], 1);
        assert_eq!(chips[2]["name"], "waiting");
        assert_eq!(chips[2]["n"], 1);
    }
}
