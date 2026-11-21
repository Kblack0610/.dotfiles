//! The rows under the Projects tab: every project's rows (human sheet, agent board, playtest,
//! open under their sheet sections then the closed ones, and each profile's Focus, read-only),
//! and add, start, done, drop, move, edit and tag on the open ones.
//!
//! `notes` is the sheets' only writer. The read and the writes go through `hub_core::tasks`,
//! which the hub TUI uses too; a write passes the row's raw line to `notes ptask --exact`, so a
//! row edited since the page read it matches nothing, nothing is written, and the page shows
//! notes' error and re-reads.
//!
//! The rows are `hub_core::table`'s: this applies the view keys and sends the summary beside
//! them. Every read asks `notes` again (it answers in about 100 ms), so a write's row shows at
//! once. Each row's queue word comes from the kept queue read (`queue::Cache`), never a fresh
//! `agent-queue` run (two of those took 4 to 19 s a request), and a write clears that read.

use axum::extract::{Query, State};
use axum::http::StatusCode;
use axum::Json;
use hub_core::layout;
use hub_core::session_actions::System;
use hub_core::table::{self, View};
use hub_core::tasks::{self, Feed, Row, Verb, Write};
use serde::Deserialize;
use serde_json::{json, Value};

use crate::{bad, ApiResult, Shared};

/// Whose rows (`scope=<profile>/<project>`, blank for every project) and the table view over
/// them (`q`, `s`, `sort`, `dir`, `pg`, as hub_core::table reads them).
#[derive(Deserialize, Default)]
#[serde(default)]
pub struct BoardQuery {
    scope: String,
    q: String,
    s: String,
    sort: String,
    dir: String,
    pg: String,
}

/// The feed with its rows narrowed to the scope and the view, one page of them (`layout`'s
/// `board` size), and the controls that drew them. Each row carries the hub's words for it:
/// `label`, its section cell (`NEXT UP (10)` over a section's first row, and over a page's first
/// row so a later page still names its section), and `when`, its queue state and forecast or its
/// close day and PRs. `rows` is the page and nothing else, so a write's row index is into it.
/// `tiers` is the scope's agent board and backlog counts, the words the hub's Board heading shows.
/// `sprints` is the scope's release windows, one line each in the CLI's words.
fn shown(f: &Feed, q: &BoardQuery) -> Value {
    let rows = f.board_rows(q.scope.split_once('/'));
    let view = View::new::<Row>(&q.q, &q.s, &q.sort, &q.dir);
    let (mut kept, mut table) = view.summary(&rows);
    let all: Vec<&Row> = kept.iter().map(|r| **r).collect();
    let mut labels = tasks::section_labels(&all, !q.sort.is_empty());
    let page = q.pg.parse().unwrap_or(1);
    table::page(&mut kept, &mut table, page, layout::page_rows("board"));
    if let Some(p) = table.pager {
        let from = (p.page - 1) * p.per;
        let head = labels[..=from]
            .iter()
            .rev()
            .find(|l| !l.is_empty())
            .cloned();
        labels.drain(..from);
        if let (Some(first), Some(head)) = (labels.first_mut(), head) {
            *first = head;
        }
    }
    let kept: Vec<&Row> = kept.into_iter().copied().collect();
    let rows: Vec<Value> = kept
        .iter()
        .zip(labels)
        .map(|(r, label)| {
            let mut v = json!(r);
            v["label"] = json!(label);
            v["when"] = json!(r.when());
            v
        })
        .collect();
    json!({
        "today": f.today,
        "projects": f.projects,
        "rows": rows,
        "focus": f.focus,
        "errors": f.errors,
        "totals": f.totals,
        "tiers": f.agent_tiers(q.scope.split_once('/')),
        "sprints": sprints(f, q),
        "table": table,
    })
}

/// The Sprints table in scope, its times read now, with its column heads.
fn sprints(f: &Feed, q: &BoardQuery) -> Value {
    let rows = f.sprint_rows(q.scope.split_once('/'), chrono::Local::now().naive_local());
    let (kept, table) = View::new::<tasks::SprintRow>("", "", "", "").summary(&rows);
    let heads: serde_json::Map<String, Value> = tasks::SPRINT_HEADS
        .iter()
        .map(|(k, h)| ((*k).to_string(), json!(h)))
        .collect();
    json!({ "rows": kept, "table": table, "heads": heads })
}

fn scope_ok(q: &BoardQuery) -> ApiResult<()> {
    if !q.scope.is_empty() && !q.scope.contains('/') {
        let why = format!("scope is <profile>/<project>, not {}", q.scope);
        return Err(bad(StatusCode::BAD_REQUEST, why));
    }
    Ok(())
}

pub async fn feed(State(s): State<Shared>, Query(q): Query<BoardQuery>) -> ApiResult<Json<Value>> {
    scope_ok(&q)?;
    let queue = s.queue.queue().await;
    let read = move || hub_core::sheet_view::feed_with(&System, &queue).map(|f| shown(&f, &q));
    tokio::task::spawn_blocking(read)
        .await
        .map_err(|e| bad(StatusCode::INTERNAL_SERVER_ERROR, e.to_string()))?
        .map(Json)
        .map_err(|e| bad(StatusCode::BAD_GATEWAY, e))
}

/// One write as the page sends it: `verb` names which of the other fields count.
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
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

/// The audit line a board write records: the same one the hub TUI writes for it
/// (`tasks::Write::audit_entry`). None when the body is not a write.
pub fn audit_entry(
    actor: &str,
    fields: &serde_json::Map<String, serde_json::Value>,
) -> Option<hub_core::audit::Entry> {
    let b: WriteBody = serde_json::from_value(fields.clone().into()).ok()?;
    Some(to_write(b).ok()?.audit_entry(actor, "web"))
}

pub async fn write(
    State(s): State<Shared>,
    Json(b): Json<WriteBody>,
) -> ApiResult<Json<serde_json::Value>> {
    let w = to_write(b).map_err(|m| bad(StatusCode::BAD_REQUEST, m))?;
    // A malformed write is the page's fault (400); a refused one is the sheet's answer (409).
    tasks::argv(&w).map_err(|m| bad(StatusCode::BAD_REQUEST, m))?;
    let out = tokio::task::spawn_blocking(move || tasks::apply(&System, &w))
        .await
        .map_err(|e| bad(StatusCode::INTERNAL_SERVER_ERROR, e.to_string()))?
        .map_err(|e| bad(StatusCode::CONFLICT, e))?;
    // A start, done or drop moves the queue too, so the re-read shows its word at once.
    s.queue.clear();
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
            section: Some(if priority == "low" { "board" } else { "next" }.into()),
            rank: text.len() as u64,
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
            done: vec![Row {
                state: "done".into(),
                section: Some("done".into()),
                closed: Some("2026-11-05".into()),
                prs: vec!["63".into()],
                ..row("demo", "high", "lint")
            }],
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

    #[test]
    fn a_scope_with_no_profile_is_refused_not_widened_to_every_project() {
        let q = |scope: &str| BoardQuery {
            scope: scope.into(),
            ..Default::default()
        };
        assert!(scope_ok(&q("garden")).is_err());
        assert!(scope_ok(&q("bnb/demo")).is_ok() && scope_ok(&q("")).is_ok());
    }

    #[test]
    fn the_scope_narrows_before_the_view_and_the_rows_keep_the_tables_order() {
        let f = fixture();
        let all = shown(&f, &BoardQuery::default());
        // The agent sheet's order: Next up by rank, Board, then the closed rows.
        assert_eq!(texts(&all), ["ship", "water", "tidy", "lint"]);
        let labels: Vec<&str> = all["rows"]
            .as_array()
            .unwrap()
            .iter()
            .map(|r| r["label"].as_str().unwrap())
            .collect();
        assert_eq!(labels, ["NEXT UP (2)", "", "BOARD (1)", "DONE 11-05 (1)"]);
        assert_eq!(all["rows"][3]["when"], "11-05  pr 63");
        assert_eq!(all["today"], "2026-11-06");
        assert_eq!(all["table"]["total"], 4);
        assert!(
            all["tiers"].is_null(),
            "no totals, no tiers line, never a 0"
        );
        let tiered = Feed {
            totals: Some(hub_core::tasks::Totals {
                agent: 3,
                backlog: 5,
                ..Default::default()
            }),
            ..f.clone()
        };
        assert_eq!(
            shown(&tiered, &BoardQuery::default())["tiers"],
            "Today 3 | Backlog 5 | Epics 0 | Epic backlog 0"
        );
        assert_eq!(
            all["sprints"]["rows"],
            serde_json::json!([]),
            "no window, no row"
        );
        assert_eq!(all["sprints"]["heads"]["finish"], "FINISH (7d rate)");
        let windowed = Feed {
            sprints: vec![hub_core::tasks::SprintLine {
                profile: "bnb".into(),
                project: "demo".into(),
                version: "v0.3.0".into(),
                done: 1,
                committed: 2,
                cut: Some("2026-01-01T14:00".into()),
                build: "held".into(),
                ..Default::default()
            }],
            ..f.clone()
        };
        let row = &shown(&windowed, &BoardQuery::default())["sprints"]["rows"][0];
        assert_eq!(
            (&row["project"], &row["done"], &row["left"], &row["build"]),
            (
                &serde_json::json!("demo"),
                &serde_json::json!("1/2"),
                &serde_json::json!("over"),
                &serde_json::json!("held")
            )
        );
        let other = BoardQuery {
            scope: "bnb/other".into(),
            ..Default::default()
        };
        assert_eq!(
            shown(&windowed, &other)["sprints"]["rows"],
            serde_json::json!([])
        );

        let q = BoardQuery {
            scope: "bnb/demo".into(),
            q: "priority:low".into(),
            ..Default::default()
        };
        let one = shown(&f, &q);
        assert_eq!(texts(&one), ["tidy"]);
        assert_eq!(one["table"]["total"], 3, "the total is the scope's");
        assert_eq!(one["table"]["shown"], 1);
        assert_eq!(one["table"]["states"][3]["name"], "urgent");
        assert_eq!(
            one["table"]["states"][3]["n"], 0,
            "the query narrows the chips"
        );
    }

    #[test]
    fn the_board_pages_at_its_layout_size_and_a_later_page_names_its_section() {
        let per = layout::page_rows("board");
        let mut f = fixture();
        f.done.clear();
        f.rows = (0..per + 5)
            .map(|i| Row {
                rank: i as u64,
                text: format!("row {i}"),
                raw: format!("- [ ] row {i}"),
                ..f.rows[1].clone()
            })
            .collect();
        let one = shown(&f, &BoardQuery::default());
        assert_eq!(texts(&one).len(), per);
        assert_eq!(one["table"]["pager"]["page"], 1);
        assert_eq!(one["table"]["shown"], per + 5, "the count is every page's");

        let q = BoardQuery {
            pg: "2".into(),
            ..Default::default()
        };
        let two = shown(&f, &q);
        let rest: Vec<String> = (per..per + 5).map(|i| format!("row {i}")).collect();
        assert_eq!(texts(&two), rest);
        assert_eq!(two["table"]["pager"]["pages"], 2);
        let n = format!("NEXT UP ({})", per + 5);
        assert_eq!(two["rows"][0]["label"], n.as_str());
        assert_eq!(two["rows"][1]["label"], "");

        let small = shown(&fixture(), &q);
        assert!(small["table"].get("pager").is_none(), "one page is unpaged");
        assert_eq!(texts(&small).len(), 4);
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
