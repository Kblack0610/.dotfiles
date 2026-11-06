//! The Focus tab: one note through `hub_core::focus` (the same reader as the hub TUI's Focus
//! tab), today's daily note by default. The page sends a link target (`daily:2026-11-04`,
//! `outbox`, `status/inbox`), never a path: `notes show` resolves it and refuses anything
//! outside the notes, so this handler never touches the filesystem itself. `PUT /api/focus
//! {t, base, text}` saves an edit through `notes put --base` (`cli.rs`): the CLI writes only when
//! the note's hash is still the one the page read, else the page gets 409 and the note as it is
//! now. Writing to the outbox is the Outbox tab's (`outbox.rs`); `notes put` refuses it.
//! `POST /api/inbox/ack {key, ack}` ticks a Handled-today row of `status/inbox` through
//! `notes inbox ack`, the mark's one writer, and answers with the page as it is after.

use axum::extract::Query;
use axum::http::StatusCode;
use axum::response::{IntoResponse, Response};
use axum::Json;
use hub_core::focus::{self, View};
use hub_core::session_actions::{Runner, System};
use serde::Deserialize;

use crate::{bad, cli, ApiResult};

/// The longest target a page may ask for; a wikilink target is a short vault-relative name.
const MAX_TARGET: usize = 300;
/// The largest note the page may save; the biggest notes in the vault are a few hundred KB.
const MAX_NOTE: usize = 1024 * 1024;

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
pub struct Edit {
    #[serde(default)]
    t: String,
    base: String,
    text: String,
}

/// What a save asks the CLI for, or why it is refused before it gets there.
fn put_args(e: &Edit) -> Result<(Vec<String>, String), &'static str> {
    let t = target(&e.t)?;
    if !cli::is_base(&e.base) {
        return Err("base is the hash the page last read");
    }
    let text = cli::plain_text(&e.text, MAX_NOTE).ok_or("a note is plain text, under 1 MB")?;
    let args = ["put", "--base", &e.base, "--", &t]
        .map(String::from)
        .to_vec();
    Ok((args, text))
}

pub async fn save(Json(e): Json<Edit>) -> Response {
    let (args, text) = match put_args(&e) {
        Ok(a) => a,
        Err(m) => return bad(StatusCode::BAD_REQUEST, m).into_response(),
    };
    match tokio::task::spawn_blocking(move || {
        let args: Vec<&str> = args.iter().map(String::as_str).collect();
        cli::put("notes put", &args, &text, focus::parse)
    })
    .await
    {
        Ok(o) => cli::respond(o),
        Err(e) => bad(StatusCode::INTERNAL_SERVER_ERROR, e.to_string()).into_response(),
    }
}

#[derive(Deserialize)]
pub struct Ack {
    key: String,
    ack: bool,
}

/// The CLI call a tick makes, or why it is refused first: a key is an ingest event's RFC 3339
/// `ts`, so anything else never reaches the CLI.
fn ack_args(a: &Ack) -> Result<Vec<String>, &'static str> {
    let k = a.key.as_str();
    if chrono::DateTime::parse_from_rfc3339(k).is_err() {
        return Err("key is the ts of the row's ingest event");
    }
    let mut args = vec!["notes".to_string(), "inbox".into(), "ack".into()];
    if !a.ack {
        args.push("--undo".into());
    }
    args.extend(["--".to_string(), k.to_string()]);
    Ok(args)
}

pub async fn ack(Json(a): Json<Ack>) -> ApiResult<Json<View>> {
    let args = ack_args(&a).map_err(|m| bad(StatusCode::BAD_REQUEST, m))?;
    tokio::task::spawn_blocking(move || {
        System
            .run(&args)
            .map_err(|e| bad(StatusCode::CONFLICT, e))?;
        focus::read(&System, "status/inbox").map_err(|e| bad(StatusCode::BAD_GATEWAY, e))
    })
    .await
    .map_err(|e| bad(StatusCode::INTERNAL_SERVER_ERROR, e.to_string()))?
    .map(Json)
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
    fn a_save_reaches_the_cli_as_argv_with_the_text_apart() {
        let e = |t: &str, base: &str, text: &str| Edit {
            t: t.into(),
            base: base.into(),
            text: text.into(),
        };
        let (args, text) = put_args(&e("", "00ff", "# Thu\r\n- [x] a\n")).unwrap();
        assert_eq!(args, ["put", "--base", "00ff", "--", "daily"]);
        assert_eq!(text, "# Thu\n- [x] a\n");
        // A target that starts with a dash is still the target, after `--`.
        assert_eq!(put_args(&e("-rf", "1", "")).unwrap().0[4], "-rf");
        assert!(put_args(&e("a\nb", "1", "x")).is_err());
        assert!(put_args(&e("daily", "", "x")).is_err());
        assert!(put_args(&e("daily", "--x", "x")).is_err());
        assert!(put_args(&e("daily", "1", "\u{1b}[2J")).is_err());
        assert!(put_args(&e("daily", "1", &"x".repeat(MAX_NOTE + 1))).is_err());
    }

    #[test]
    fn a_tick_is_one_cli_call_and_a_key_that_is_no_stamp_never_reaches_it() {
        let a = |key: &str, ack: bool| Ack {
            key: key.into(),
            ack,
        };
        let ts = "2026-11-05T16:50:32.881399577-08:00";
        assert_eq!(
            ack_args(&a(ts, true)).unwrap(),
            ["notes", "inbox", "ack", "--", ts]
        );
        assert_eq!(
            ack_args(&a(ts, false)).unwrap(),
            ["notes", "inbox", "ack", "--undo", "--", ts]
        );
        assert!(ack_args(&a("--undo", true)).is_err());
        assert!(ack_args(&a("2026-11-05; rm -rf ~", true)).is_err());
        assert!(ack_args(&a("", true)).is_err());
    }
}
