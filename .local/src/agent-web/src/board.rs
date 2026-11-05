//! The Board tab: every project's open rows (human sheet, agent board, playtest, and each
//! profile's Focus, read-only), and add, start, done and remove on them.
//!
//! `notes` is the sheets' only writer. The read and the writes go through `hub_core::tasks`,
//! which the hub TUI uses too; a write passes the row's raw line to `notes ptask --exact`, so a
//! row edited since the page read it matches nothing, nothing is written, and the page shows
//! notes' error and re-reads.

use axum::http::StatusCode;
use axum::Json;
use hub_core::session_actions::System;
use hub_core::tasks::{self, Feed, Verb, Write};
use serde::Deserialize;

use crate::{bad, ApiResult};

pub async fn feed() -> ApiResult<Json<Feed>> {
    tokio::task::spawn_blocking(|| tasks::feed(&System))
        .await
        .map_err(|e| bad(StatusCode::INTERNAL_SERVER_ERROR, e.to_string()))?
        .map(Json)
        .map_err(|e| bad(StatusCode::BAD_GATEWAY, e))
}

/// One write as the page sends it: `verb` names which of the other fields count.
#[derive(Deserialize)]
pub struct WriteBody {
    verb: String,
    profile: String,
    project: String,
    lane: String,
    #[serde(default)]
    raw: String,
    #[serde(default)]
    text: String,
    #[serde(default)]
    priority: String,
    #[serde(default)]
    to: String,
    #[serde(default)]
    game: String,
    #[serde(default)]
    proof: String,
    #[serde(default)]
    unverified: String,
    #[serde(default)]
    why: String,
    #[serde(default)]
    dup: String,
    /// A move's destination project; blank keeps the row on its own sheet.
    #[serde(default)]
    dest: String,
}

fn some(s: String) -> Option<String> {
    Some(s).filter(|s| !s.trim().is_empty())
}

fn to_write(b: WriteBody) -> Result<Write, &'static str> {
    let verb = match b.verb.as_str() {
        "add" => Verb::Add {
            text: b.text,
            priority: if b.priority.is_empty() {
                "high".into()
            } else {
                b.priority
            },
            to: some(b.to),
            game: some(b.game),
        },
        "done" => Verb::Done {
            raw: b.raw,
            proof: some(b.proof),
            unverified: some(b.unverified),
        },
        "start" => Verb::Start { raw: b.raw },
        "drop" => Verb::Drop {
            raw: b.raw,
            why: some(b.why),
            dup: some(b.dup),
        },
        "move" => Verb::Move {
            raw: b.raw,
            project: some(b.dest),
            to: some(b.to),
        },
        "promote" => Verb::Promote { raw: b.raw },
        "demote" => Verb::Demote { raw: b.raw },
        "edit" => Verb::Edit {
            raw: b.raw,
            text: b.text,
        },
        _ => return Err("the verb is add, done, start, drop, move, promote, demote or edit"),
    };
    Ok(Write {
        profile: b.profile,
        project: b.project,
        lane: b.lane,
        verb,
    })
}

pub async fn write(Json(b): Json<WriteBody>) -> ApiResult<Json<serde_json::Value>> {
    let w = to_write(b).map_err(|m| bad(StatusCode::BAD_REQUEST, m))?;
    // A malformed write is the page's fault (400); a refused one is the sheet's answer (409).
    tasks::argv(&w).map_err(|m| bad(StatusCode::BAD_REQUEST, m))?;
    let out = tokio::task::spawn_blocking(move || tasks::apply(&System, &w))
        .await
        .map_err(|e| bad(StatusCode::INTERNAL_SERVER_ERROR, e.to_string()))?
        .map_err(|e| bad(StatusCode::CONFLICT, e))?;
    Ok(Json(serde_json::json!({ "out": out.trim() })))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn body(json: &str) -> WriteBody {
        serde_json::from_str(json).unwrap()
    }

    #[test]
    fn an_add_defaults_to_high_and_blank_fields_are_absent() {
        let w = to_write(body(
            r#"{"verb":"add","profile":"bnb","project":"demo","lane":"human","text":"x","to":" ","game":""}"#,
        ))
        .unwrap();
        assert_eq!(
            w.verb,
            Verb::Add {
                text: "x".into(),
                priority: "high".into(),
                to: None,
                game: None
            }
        );
    }

    #[test]
    fn a_done_carries_its_raw_line_and_an_unknown_verb_is_refused() {
        let w = to_write(body(
            r#"{"verb":"done","profile":"bnb","project":"demo","lane":"agent","raw":"- [ ] a","proof":"pr:3"}"#,
        ))
        .unwrap();
        assert_eq!(
            tasks::argv(&w).unwrap()[5..],
            ["--agent", "--exact", "done", "--proof", "pr:3", "--", "- [ ] a"]
        );
        assert!(to_write(body(
            r#"{"verb":"sweep","profile":"bnb","project":"demo","lane":"human"}"#
        ))
        .is_err());
        assert!(
            to_write(body(
                r#"{"verb":"rm","profile":"bnb","project":"demo","lane":"human","raw":"- [ ] a"}"#
            ))
            .is_err(),
            "rm is gone: a row is dropped with a reason"
        );
    }

    #[test]
    fn a_drop_carries_its_reason() {
        let w = to_write(body(
            r#"{"verb":"drop","profile":"bnb","project":"demo","lane":"human","raw":"- [ ] a","why":"stale","dup":" "}"#,
        ))
        .unwrap();
        assert_eq!(
            tasks::argv(&w).unwrap()[5..],
            ["--exact", "drop", "--why", "stale", "--", "- [ ] a"]
        );
    }

    #[test]
    fn a_move_names_its_dest_apart_from_the_rows_own_project() {
        let w = to_write(body(
            r#"{"verb":"move","profile":"bnb","project":"demo","lane":"human","raw":"- [ ] a","dest":"other","to":""}"#,
        ))
        .unwrap();
        assert_eq!(
            tasks::argv(&w).unwrap()[2..],
            [
                "demo",
                "--profile",
                "bnb",
                "--exact",
                "move",
                "--project",
                "other",
                "--",
                "- [ ] a"
            ]
        );
        let w = to_write(body(
            r#"{"verb":"edit","profile":"bnb","project":"demo","lane":"agent","raw":"- [ ] a","text":"b"}"#,
        ))
        .unwrap();
        assert_eq!(
            tasks::argv(&w).unwrap()[5..],
            ["--agent", "--exact", "edit", "--text", "b", "--", "- [ ] a"]
        );
    }
}
