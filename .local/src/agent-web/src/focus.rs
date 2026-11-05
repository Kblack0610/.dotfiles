//! The Focus tab: one note through `hub_core::focus` (the same reader as the hub TUI's Focus
//! tab), today's daily note by default. The page sends a link target (`daily:2026-11-04`,
//! `outbox`, `status/inbox`), never a path: `notes show` resolves it and refuses anything
//! outside the notes, so this handler never touches the filesystem itself. Writing to the outbox
//! is the Outbox tab's (`outbox.rs`).

use axum::extract::Query;
use axum::http::StatusCode;
use axum::Json;
use hub_core::focus::{self, View};
use hub_core::session_actions::System;
use serde::Deserialize;

use crate::{bad, ApiResult};

/// The longest target a page may ask for; a wikilink target is a short vault-relative name.
const MAX_TARGET: usize = 300;

#[derive(Deserialize)]
pub struct Q {
    #[serde(default)]
    t: String,
}

/// The target as `notes show` takes it: blank is today, and a control character never reaches
/// the CLI.
fn target(t: &str) -> Result<String, &'static str> {
    let t = t.trim();
    if t.len() > MAX_TARGET || t.chars().any(char::is_control) {
        return Err("not a note name");
    }
    Ok(if t.is_empty() {
        "daily".into()
    } else {
        t.into()
    })
}

pub async fn get(Query(q): Query<Q>) -> ApiResult<Json<View>> {
    let t = target(&q.t).map_err(|e| bad(StatusCode::BAD_REQUEST, e))?;
    tokio::task::spawn_blocking(move || focus::read(&System, &t))
        .await
        .map_err(|e| bad(StatusCode::INTERNAL_SERVER_ERROR, e.to_string()))?
        .map(Json)
        .map_err(|e| bad(StatusCode::BAD_GATEWAY, e))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_blank_target_is_today_and_a_strange_one_never_reaches_the_cli() {
        assert_eq!(target("").unwrap(), "daily");
        assert_eq!(target(" outbox ").unwrap(), "outbox");
        assert!(target("a\nb").is_err());
        assert!(target(&"x".repeat(MAX_TARGET + 1)).is_err());
    }
}
