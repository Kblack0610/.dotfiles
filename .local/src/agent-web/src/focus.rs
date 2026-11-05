//! The Focus tab: one note through `hub_core::focus` (the same reader as the hub TUI's Focus
//! tab), today's daily note by default. The page sends a link target (`daily:2026-11-04`,
//! `outbox`, `status/inbox`), never a path: `notes show` resolves it and refuses anything
//! outside the notes, so this handler never touches the filesystem itself. `POST /api/outbox`
//! adds one line to the outbox through `notes outbox add`, which wakes the triager that files it.

use axum::extract::Query;
use axum::http::StatusCode;
use axum::Json;
use hub_core::focus::{self, View};
use hub_core::session_actions::{Runner, System};
use serde::Deserialize;

use crate::{bad, ApiResult};

/// The longest target a page may ask for; a wikilink target is a short vault-relative name.
const MAX_TARGET: usize = 300;
/// The longest outbox line the page may send; the outbox holds one-line asks, not documents.
const MAX_LINE: usize = 2000;

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

#[derive(Deserialize)]
pub struct OutboxBody {
    text: String,
}

/// The line as the outbox takes it: one line, so the page can never add two rows or a heading.
fn line(t: &str) -> Result<String, &'static str> {
    let t = t.trim();
    if t.is_empty() {
        return Err("nothing to send");
    }
    if t.len() > MAX_LINE || t.chars().any(char::is_control) {
        return Err("send one line, under 2000 characters");
    }
    Ok(t.into())
}

fn outbox_add(runner: &dyn Runner, text: &str) -> Result<String, String> {
    let argv = ["notes", "outbox", "add", "--", text].map(String::from);
    runner.run(&argv).map(|out| out.trim().to_string())
}

pub async fn outbox(Json(b): Json<OutboxBody>) -> ApiResult<Json<serde_json::Value>> {
    let t = line(&b.text).map_err(|e| bad(StatusCode::BAD_REQUEST, e))?;
    let said = tokio::task::spawn_blocking(move || outbox_add(&System, &t))
        .await
        .map_err(|e| bad(StatusCode::INTERNAL_SERVER_ERROR, e.to_string()))?
        .map_err(|e| bad(StatusCode::BAD_GATEWAY, e))?;
    Ok(Json(serde_json::json!({ "said": said })))
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

    #[test]
    fn an_outbox_line_is_one_line_and_reaches_the_cli_as_one_argument() {
        assert_eq!(
            line("  ask the triager #p:demo ").unwrap(),
            "ask the triager #p:demo"
        );
        assert!(line("  ").is_err());
        assert!(
            line("one\n## Heading").is_err(),
            "a newline could add a second row"
        );
        assert!(line(&"x".repeat(MAX_LINE + 1)).is_err());

        struct Fake;
        impl Runner for Fake {
            fn run(&self, argv: &[String]) -> Result<String, String> {
                assert_eq!(argv, ["notes", "outbox", "add", "--", "--json -x"]);
                Ok("outbox: - [ ] --json -x\n".into())
            }
        }
        assert_eq!(
            outbox_add(&Fake, "--json -x").unwrap(),
            "outbox: - [ ] --json -x",
            "a line that looks like a flag is still the text"
        );
    }
}
