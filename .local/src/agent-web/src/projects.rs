//! The Projects tab: one card per lab project with its open version's progress and what is in
//! flight on it, from `hub_core::projects`, the join the hub TUI's Projects tab draws. Each card
//! carries `summary`, the one progress line both surfaces print word for word.

use axum::http::StatusCode;
use axum::Json;
use hub_core::boards;
use hub_core::projects::{self, Projects};
use hub_core::queue::Queue;
use hub_core::session_actions::System;
use hub_core::tasks;
use serde_json::Value;

use crate::{bad, ApiResult};

pub async fn get() -> ApiResult<Json<Value>> {
    tokio::task::spawn_blocking(|| {
        let repos = std::fs::read_to_string(projects::map_path())
            .map(|t| projects::repos(&t))
            .unwrap_or_default();
        let state = std::fs::read_to_string(boards::fleet_state())
            .ok()
            .and_then(|t| serde_json::from_str(&t).ok())
            .unwrap_or(Value::Null);
        let queue = Queue::read(&System);
        let feed = tasks::feed(&System).ok();
        let out = match projects::stats(&System) {
            Ok(stats) => projects::build(&stats, feed.as_ref(), &state, Some(&queue), &repos),
            Err(e) => Projects {
                errors: vec![e],
                ..Default::default()
            },
        };
        with_summaries(&out)
    })
    .await
    .map(Json)
    .map_err(|e| bad(StatusCode::INTERNAL_SERVER_ERROR, e.to_string()))
}

fn with_summaries(p: &Projects) -> Value {
    let mut v = serde_json::to_value(p).unwrap_or_default();
    if let Some(cards) = v["cards"].as_array_mut() {
        for (j, c) in cards.iter_mut().zip(&p.cards) {
            j["summary"] = projects::summary(c).into();
            j["in_flight"] = c.in_flight().into();
        }
    }
    v
}

#[cfg(test)]
mod tests {
    use super::*;
    use hub_core::projects::{Card, Progress};

    #[test]
    fn each_card_carries_the_summary_the_tui_prints() {
        let c = Card {
            name: "demo".into(),
            version: Some("v0.1.0".into()),
            progress: Progress {
                open: 1,
                done: 1,
                open_weight: 3,
                done_weight: 1,
                ..Default::default()
            },
            percent: Some(25),
            ..Default::default()
        };
        let v = with_summaries(&Projects {
            cards: vec![c.clone()],
            ..Default::default()
        });
        assert_eq!(v["cards"][0]["summary"], projects::summary(&c));
        assert!(v["cards"][0]["summary"]
            .as_str()
            .unwrap()
            .starts_with("v0.1.0 25% (1 of 4 by size)"));
        assert_eq!(v["cards"][0]["in_flight"], false);
    }
}
