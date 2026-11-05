//! The Outbox tab: `GET /api/outbox` is `hub_core::outbox::read` (the hub TUI's reader), and
//! `PUT /api/outbox {base, text}` hands the page's text to `notes outbox put --base`, the one
//! writer. The CLI compares `base` with the file's hash under its lock, so a sweep that took
//! lines since the page last read comes back as 409 with the current doc for the page to merge.

use std::io::Write;
use std::process::{Command, Stdio};

use axum::http::StatusCode;
use axum::response::{IntoResponse, Response};
use axum::Json;
use hub_core::outbox::{self, Doc, View};
use hub_core::session_actions::System;
use serde::Deserialize;

use crate::{bad, ApiResult};

/// The most text the page may save; the outbox holds asks waiting a sweep, not documents.
const MAX_TEXT: usize = 64 * 1024;
/// `notes outbox put`'s exit when the hash moved.
const STALE: i32 = 3;

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

/// The text as the CLI takes it: CRLF folded, and no control character but newline and tab, so
/// the page cannot write anything a hand edit could not.
fn text(t: &str) -> Result<String, &'static str> {
    let t = t.replace("\r\n", "\n");
    if t.len() > MAX_TEXT || t.chars().any(|c| c.is_control() && c != '\n' && c != '\t') {
        return Err("the outbox takes plain lines, under 64 KB");
    }
    Ok(t)
}

/// What a finished `put` means for the page: the new doc, the current doc on a stale base, or
/// the CLI's own error.
#[derive(Debug, PartialEq)]
enum Outcome {
    Written(Doc),
    Stale(Doc),
    Failed(String),
}

fn outcome(code: Option<i32>, stdout: &str, stderr: &str) -> Outcome {
    let doc = || outbox::parse_doc(stdout.trim());
    match code {
        Some(0) => doc().map_or_else(Outcome::Failed, Outcome::Written),
        Some(STALE) => doc().map_or_else(Outcome::Failed, Outcome::Stale),
        _ if stderr.trim().is_empty() => {
            Outcome::Failed(format!("notes outbox put: exit {code:?}"))
        }
        _ => Outcome::Failed(stderr.trim().to_string()),
    }
}

fn put(base: &str, text: &str) -> Outcome {
    let child = Command::new("notes")
        .args(["outbox", "put", "--base", base])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn();
    let mut child = match child {
        Ok(c) => c,
        Err(e) => return Outcome::Failed(format!("notes: {e}")),
    };
    if let Some(mut stdin) = child.stdin.take() {
        if let Err(e) = stdin.write_all(text.as_bytes()) {
            return Outcome::Failed(format!("notes outbox put: {e}"));
        }
    }
    match child.wait_with_output() {
        Ok(o) => outcome(
            o.status.code(),
            &String::from_utf8_lossy(&o.stdout),
            &String::from_utf8_lossy(&o.stderr),
        ),
        Err(e) => Outcome::Failed(format!("notes outbox put: {e}")),
    }
}

pub async fn save(Json(b): Json<Body>) -> Response {
    let t = match text(&b.text) {
        Ok(t) => t,
        Err(e) => return bad(StatusCode::BAD_REQUEST, e).into_response(),
    };
    let base = b.base;
    if base.is_empty() || !base.chars().all(|c| c.is_ascii_hexdigit()) {
        return bad(
            StatusCode::BAD_REQUEST,
            "base is the hash the page last read",
        )
        .into_response();
    }
    match tokio::task::spawn_blocking(move || put(&base, &t)).await {
        Ok(o) => respond(o),
        Err(e) => bad(StatusCode::INTERNAL_SERVER_ERROR, e.to_string()).into_response(),
    }
}

fn respond(o: Outcome) -> Response {
    match o {
        Outcome::Written(d) => Json(d).into_response(),
        Outcome::Stale(d) => (StatusCode::CONFLICT, Json(d)).into_response(),
        Outcome::Failed(e) => bad(StatusCode::BAD_GATEWAY, e).into_response(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const DOC: &str = r#"{"path":"/n/outbox.md","hash":"00ff","text":"- [ ] one","waiting":1}"#;

    #[test]
    fn the_text_is_plain_lines() {
        assert_eq!(text("a\r\nb\tc\n").unwrap(), "a\nb\tc\n");
        assert!(text("a\u{1b}[2J").is_err(), "an escape is not a line");
        assert!(text(&"x".repeat(MAX_TEXT + 1)).is_err());
    }

    #[test]
    fn a_stale_base_is_the_current_doc_and_a_failure_says_why() {
        let doc = outbox::parse_doc(DOC).unwrap();
        assert_eq!(outcome(Some(0), DOC, ""), Outcome::Written(doc.clone()));
        assert_eq!(
            outcome(
                Some(STALE),
                DOC,
                "the outbox changed since ab; nothing written"
            ),
            Outcome::Stale(doc)
        );
        assert_eq!(
            outcome(Some(1), "", "error: no profile\n"),
            Outcome::Failed("error: no profile".into())
        );
        assert!(matches!(outcome(None, "", ""), Outcome::Failed(e) if e.contains("exit None")));
        assert!(matches!(outcome(Some(0), "nope", ""), Outcome::Failed(_)));
    }

    #[test]
    fn a_stale_base_answers_409_and_a_cli_error_502() {
        assert_eq!(respond(outcome(Some(0), DOC, "")).status(), StatusCode::OK);
        assert_eq!(
            respond(outcome(Some(STALE), DOC, "")).status(),
            StatusCode::CONFLICT
        );
        assert_eq!(
            respond(outcome(Some(2), "", "boom")).status(),
            StatusCode::BAD_GATEWAY
        );
    }
}
