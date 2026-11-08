//! The rows under the Projects tab: every project's open rows (human sheet, agent board,
//! playtest, and each profile's Focus, read-only), and add, start, done, drop, move, edit and
//! tag on them.
//!
//! `notes` is the sheets' only writer. The read and the writes go through `hub_core::tasks`,
//! which the hub TUI uses too; a write passes the row's raw line to `notes ptask --exact`, so a
//! row edited since the page read it matches nothing, nothing is written, and the page shows
//! notes' error and re-reads.
//!
//! The rows are `hub_core::table`'s: this applies the view keys and sends the summary beside
//! them. Every read asks `notes` again (it answers in tens of milliseconds), so a write shows
//! at once and nothing here needs a cache to clear.

use axum::extract::Query;
use axum::http::StatusCode;
use axum::Json;
use hub_core::session_actions::System;
use hub_core::table::View;
use hub_core::tasks::{self, Feed, Row, Verb, Write};
use serde::Deserialize;
use serde_json::{json, Value};

use crate::{bad, ApiResult};

/// Whose rows (`scope=<profile>/<project>`, blank for every project) and the table view over
/// them (`q`, `s`, `sort`, `dir`, as hub_core::table reads them).
#[derive(Deserialize, Default)]
#[serde(default)]
pub struct BoardQuery {
    scope: String,
    q: String,
    s: String,
    sort: String,
    dir: String,
}

/// The feed with its rows narrowed to the scope and the view, and the controls that drew them.
fn shown(f: &Feed, q: &BoardQuery) -> Value {
    let rows = f.open_rows(q.scope.split_once('/'));
    let view = View::new::<Row>(&q.q, &q.s, &q.sort, &q.dir);
    let (kept, table) = view.summary(&rows);
    json!({
        "today": f.today,
        "projects": f.projects,
        "rows": kept,
        "focus": f.focus,
        "table": table,
    })
}

pub async fn feed(Query(q): Query<BoardQuery>) -> ApiResult<Json<Value>> {
    if !q.scope.is_empty() && !q.scope.contains('/') {
        let why = format!("scope is <profile>/<project>, not {}", q.scope);
        return Err(bad(StatusCode::BAD_REQUEST, why));
    }
    tokio::task::spawn_blocking(move || tasks::feed(&System).map(|f| shown(&f, &q)))
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
    /// A tag write's words, space separated, `#` optional.
    #[serde(default)]
    add: String,
    #[serde(default)]
    remove: String,
}

fn words(s: &str) -> Vec<String> {
    s.split_whitespace().map(str::to_string).collect()
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
        "tag" => Verb::Tag {
            raw: b.raw,
            add: words(&b.add),
            remove: words(&b.remove),
        },
        _ => return Err("the verb is add, done, start, drop, move, promote, demote, edit or tag"),
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

    fn fixture() -> Feed {
        let row = |project: &str, priority: &str, text: &str| Row {
            profile: "bnb".into(),
            project: Some(project.into()),
            lane: "agent".into(),
            state: "open".into(),
            priority: priority.into(),
            text: text.into(),
            raw: format!("- [ ] {text}"),
            ..Default::default()
        };
        Feed {
            today: "2026-11-06".into(),
            rows: vec![
                row("demo", "low", "tidy"),
                row("demo", "urgent", "ship"),
                row("garden", "high", "water"),
            ],
            ..Default::default()
        }
    }

    fn texts(v: &Value) -> Vec<&str> {
        v["rows"]
            .as_array()
            .unwrap()
            .iter()
            .map(|r| r["text"].as_str().unwrap())
            .collect()
    }

    #[tokio::test]
    async fn a_scope_with_no_profile_is_refused_not_widened_to_every_project() {
        let q = BoardQuery {
            scope: "garden".into(),
            ..Default::default()
        };
        assert!(feed(Query(q)).await.is_err());
    }

    #[test]
    fn the_scope_narrows_before_the_view_and_the_rows_keep_the_tables_order() {
        let f = fixture();
        let all = shown(&f, &BoardQuery::default());
        assert_eq!(texts(&all), ["ship", "water", "tidy"]);
        assert_eq!(all["today"], "2026-11-06");
        assert_eq!(all["table"]["total"], 3);

        let q = BoardQuery {
            scope: "bnb/demo".into(),
            q: "priority:low".into(),
            ..Default::default()
        };
        let one = shown(&f, &q);
        assert_eq!(texts(&one), ["tidy"]);
        assert_eq!(one["table"]["total"], 2, "the total is the scope's");
        assert_eq!(one["table"]["shown"], 1);
        assert_eq!(one["table"]["states"][3]["name"], "urgent");
        assert_eq!(
            one["table"]["states"][3]["n"], 0,
            "the query narrows the chips"
        );
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

    #[test]
    fn a_tag_splits_its_words_and_one_that_is_not_a_tag_is_refused() {
        let w = to_write(body(
            r##"{"verb":"tag","profile":"bnb","project":"demo","lane":"agent","raw":"- [ ] a","add":"#size/s  requested","remove":"ai"}"##,
        ))
        .unwrap();
        assert_eq!(
            tasks::argv(&w).unwrap()[5..],
            [
                "--agent",
                "--exact",
                "tag",
                "--add=size/s",
                "--add=requested",
                "--remove=ai",
                "--",
                "- [ ] a"
            ]
        );
        let w = to_write(body(
            r#"{"verb":"tag","profile":"bnb","project":"demo","lane":"agent","raw":"- [ ] a","add":"v0.2.0"}"#,
        ))
        .unwrap();
        assert!(tasks::argv(&w).is_err(), "a release is move's");
    }
}
