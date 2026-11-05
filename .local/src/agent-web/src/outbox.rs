//! The Outbox tab: `GET /api/outbox` is `hub_core::outbox::read` (the hub TUI's reader), and
//! `PUT /api/outbox {base, text}` hands the page's text to `notes outbox put --base`, the one
//! writer. The CLI compares `base` with the file's hash under its lock, so a sweep that took
//! lines since the page last read comes back as 409 with the current doc for the page to merge.

use axum::http::StatusCode;
use axum::response::{IntoResponse, Response};
use axum::Json;
use hub_core::outbox::{self, View};
use hub_core::session_actions::System;
use serde::Deserialize;

use crate::{bad, cli, ApiResult};

/// The most text the page may save; the outbox holds asks waiting a sweep, not documents.
const MAX_TEXT: usize = 64 * 1024;

pub async fn get() -> ApiResult<Json<View>> {
    let today = chrono::Local::now().format("%Y-%m-%d").to_string();
    tokio::task::spawn_blocking(move || outbox::read(&System, &today))
        .await
        .map_err(|e| bad(StatusCode::INTERNAL_SERVER_ERROR, e.to_string()))?
        .map(Json)
        .map_err(|e| bad(StatusCode::BAD_GATEWAY, e))
}

#[derive(Deserialize)]
pub struct Body {
    base: String,
    text: String,
}

pub async fn save(Json(b): Json<Body>) -> Response {
    let Some(t) = cli::plain_text(&b.text, MAX_TEXT) else {
        return bad(
            StatusCode::BAD_REQUEST,
            "the outbox takes plain lines, under 64 KB",
        )
        .into_response();
    };
    if !cli::is_base(&b.base) {
        return bad(
            StatusCode::BAD_REQUEST,
            "base is the hash the page last read",
        )
        .into_response();
    }
    let base = b.base;
    match tokio::task::spawn_blocking(move || {
        cli::put(
            "notes outbox put",
            &["outbox", "put", "--base", &base],
            &t,
            outbox::parse_doc,
        )
    })
    .await
    {
        Ok(o) => cli::respond(o),
        Err(e) => bad(StatusCode::INTERNAL_SERVER_ERROR, e.to_string()).into_response(),
    }
}
