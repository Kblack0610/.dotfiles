//! Log's Actions section: everything the fleet's machinery did (shepherd, dispatch, pages, failed
//! runs, the queue), read by `hub_core::actions`, the same reader as `hub actions` and the
//! briefing's digest.

use axum::extract::Query;
use axum::Json;
use hub_core::actions::{self, Action, Gathered};
use hub_core::table::View;
use serde::Deserialize;
use serde_json::{json, Value};

const HOURS_DEFAULT: i64 = 24;
/// A week: the shepherd log's busiest days hold about 1000 entries.
const HOURS_MAX: i64 = 168;

#[derive(Deserialize)]
pub struct Q {
    hours: Option<i64>,
    /// The table's view, as hub_core::table reads it.
    #[serde(default)]
    q: String,
    #[serde(default)]
    s: String,
    #[serde(default)]
    sort: String,
    #[serde(default)]
    dir: String,
}

fn window(hours: Option<i64>) -> i64 {
    hours.unwrap_or(HOURS_DEFAULT).clamp(1, HOURS_MAX) * 3600
}

/// The rows `q`'s view keeps and the table's summary; `counts` still covers the whole window.
fn shown(g: &Gathered, q: &Q) -> Value {
    let view = View::new::<Action>(&q.q, &q.s, &q.sort, &q.dir);
    let (rows, table) = view.summary(&g.actions);
    json!({ "actions": rows, "counts": g.counts, "errors": g.errors, "table": table })
}

pub async fn get(Query(q): Query<Q>) -> Json<Value> {
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
    Json(shown(&out, &q))
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

    #[test]
    fn the_view_narrows_the_rows_and_not_the_window_counts() {
        let row = |at, actor: &str| Action {
            at,
            actor: actor.into(),
            verb: "nudge".into(),
            text: "t".into(),
            priority: None,
            reference: None,
            source: "shepherd".into(),
        };
        let actions = vec![row(2, "shepherd"), row(1, "dispatch")];
        let g = Gathered {
            counts: actions::counts(&actions),
            actions,
            ..Gathered::default()
        };
        let q = Q {
            hours: None,
            q: "actor:shepherd".into(),
            s: String::new(),
            sort: String::new(),
            dir: String::new(),
        };
        let v = shown(&g, &q);
        assert_eq!(v["actions"].as_array().unwrap().len(), 1);
        assert_eq!(v["table"]["shown"], 1);
        assert_eq!(v["table"]["total"], 2);
        assert_eq!(v["counts"]["dispatch"]["nudge"], 1);
    }
}
