//! Log's Actions section: everything the fleet's machinery did (shepherd, dispatch, pages, failed
//! runs, the queue), read by `hub_core::actions`, the same reader as `hub actions` and the
//! briefing's digest.

use axum::extract::Query;
use axum::Json;
use hub_core::actions::{self, Gathered};
use serde::Deserialize;

const HOURS_DEFAULT: i64 = 24;
/// A week: the shepherd log's busiest days hold about 1000 entries.
const HOURS_MAX: i64 = 168;

#[derive(Deserialize)]
pub struct Q {
    hours: Option<i64>,
}

fn window(hours: Option<i64>) -> i64 {
    hours.unwrap_or(HOURS_DEFAULT).clamp(1, HOURS_MAX) * 3600
}

pub async fn get(Query(q): Query<Q>) -> Json<Gathered> {
    let span = window(q.hours);
    let out = tokio::task::spawn_blocking(move || {
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map_or(0, |d| d.as_secs() as i64);
        actions::read(now - span)
    })
    .await
    .unwrap_or_else(|e| Gathered {
        errors: vec![e.to_string()],
        ..Gathered::default()
    });
    Json(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_window_defaults_to_a_day_and_is_clamped_to_a_week() {
        assert_eq!(window(None), 24 * 3600);
        assert_eq!(window(Some(0)), 3600);
        assert_eq!(window(Some(-5)), 3600);
        assert_eq!(window(Some(72)), 72 * 3600);
        assert_eq!(window(Some(10_000)), 168 * 3600);
    }
}
