//! The Queue tab: agent-queue's items, and adding, cancelling and re-ranking them.
//!
//! agent-queue is the only writer of `~/.agent/queue` (design: `~/.config/agentctl/QUEUE.md`).
//! The list, add, cancel and bump go through `hub_core::queue`, which the hub TUI uses too.
//! The Candidates section is hub-core's
//! `candidates`; its Promote posts the board's Start (`POST /api/board`). Every call is plain
//! arguments, never a shell, and agent-queue's stderr comes back as the error the page shows.

use axum::http::StatusCode;
use axum::Json;
use std::collections::BTreeMap;

use hub_core::queue::{self as hub_queue, Candidates, DayTotal, Item};
use hub_core::session_actions::System;
use serde::Deserialize;

use crate::{bad, ApiResult};

/// How many days back, today included, the page's Done section reaches.
const DONE_DAYS: i64 = 7;

/// Every active item plus those finished in the last `DONE_DAYS` days, in queue order, read
/// through hub-core, each with the words hub-core gives a row (`item_view`).
pub async fn list() -> ApiResult<Json<Vec<serde_json::Value>>> {
    tokio::task::spawn_blocking(|| {
        hub_queue::list_since(&System, "all", &hub_queue::days_ago(DONE_DAYS - 1))
    })
    .await
    .map_err(|e| bad(StatusCode::INTERNAL_SERVER_ERROR, e.to_string()))?
    .map(|items| {
        let days = hub_queue::done_days(&items);
        let now = chrono::Utc::now();
        Json(items.iter().map(|i| item_view(i, &days, now)).collect())
    })
    .map_err(|e| bad(StatusCode::BAD_REQUEST, e))
}

/// The item as agent-queue printed it plus what a row shows: `harness` (`Item::harness_label`,
/// `claude` when the item names no agent), `cost` (dollars, absent when unknown), the PR's
/// label and link, `pr_merged` (the merge was recorded), `unproven`, and for a done item its
/// `day`, its `day_label` and that day's `day_total` line, so the page sums and words nothing;
/// and its `timing` now (`Item::timing`), so the page does no duration math.
fn item_view(
    i: &Item,
    days: &BTreeMap<String, DayTotal>,
    now: chrono::DateTime<chrono::Utc>,
) -> serde_json::Value {
    let mut v = serde_json::to_value(i).unwrap_or_default();
    v["timing"] = serde_json::to_value(i.timing(now)).unwrap_or_default();
    v["harness"] = i.harness_label().into();
    if let Some(c) = i.cost() {
        v["cost"] = c.into();
        v["cost_label"] = hub_queue::money(c).into();
    }
    if let Some((label, url)) = i.pr_link() {
        v["pr_label"] = label.into();
        v["pr_url"] = url.into();
        v["pr_merged"] = i.merged().into();
    }
    if i.unproven() {
        v["unproven"] = true.into();
    }
    if i.state == hub_queue::State::Done {
        if let Some(d) = i.finished.as_deref().and_then(hub_queue::day_of) {
            if let Some(t) = days.get(&d) {
                v["day_total"] = t.line().into();
            }
            v["day_label"] = hub_queue::day_label(&d).into();
            v["day"] = d.into();
        }
    }
    v
}

/// The window's line and what sits now, worded by hub-core as the hub TUI words them.
pub async fn stats() -> ApiResult<Json<serde_json::Value>> {
    let s = tokio::task::spawn_blocking(|| hub_queue::stats(&System))
        .await
        .map_err(|e| bad(StatusCode::INTERNAL_SERVER_ERROR, e.to_string()))?
        .map_err(|e| bad(StatusCode::BAD_REQUEST, e))?;
    // The prose lines for the folded detail, and the typical times the page's tiles show; the
    // tiles count the items themselves.
    Ok(Json(serde_json::json!({
        "week": s.week(),
        "sitting": s.sitting_line(),
        "wait_minutes_median": s.wait_minutes_median,
        "run_minutes_median": s.run_minutes_median,
        "to_pr_minutes_median": s.to_pr_minutes_median,
    })))
}

/// The counts and the rows hub-core keeps, each with the title and start label it words.
fn candidates_view(c: &Candidates) -> serde_json::Value {
    let view = |rows: &[hub_queue::Candidate]| -> Vec<serde_json::Value> {
        rows.iter()
            .map(|r| {
                let mut v = serde_json::to_value(r).unwrap_or_default();
                v["title"] = r.title().into();
                v["start_label"] = r.start_label().into();
                v["reasons"] = r.reasons().into();
                v
            })
            .collect()
    };
    let reasons: Vec<serde_json::Value> = c
        .reasons
        .iter()
        .map(|(r, n)| serde_json::json!({ "reason": r, "rows": n }))
        .collect();
    serde_json::json!({
        "total": c.total, "auto": c.auto, "rows": view(&c.rows),
        "blocked_rows": view(&c.blocked_rows), "reasons": reasons,
        "urgent_blocked": c.urgent_blocked, "uncovered": c.uncovered, "clear": c.clear,
    })
}

/// The ranked board rows `fleet-dispatch suggest` prints, read through hub-core. Slow (every
/// board), so the page asks for it on showing the tab and after a promote, not on queue events.
pub async fn candidates() -> ApiResult<Json<serde_json::Value>> {
    tokio::task::spawn_blocking(|| hub_queue::candidates(&System))
        .await
        .map_err(|e| bad(StatusCode::INTERNAL_SERVER_ERROR, e.to_string()))?
        .map(|c| Json(candidates_view(&c)))
        .map_err(|e| bad(StatusCode::BAD_REQUEST, e))
}

/// One hub-core action off the async workers: hub-core checks the input and runs the CLI, and
/// what the CLI says on failure is the answer.
pub async fn act(
    f: impl FnOnce() -> Result<String, String> + Send + 'static,
) -> ApiResult<StatusCode> {
    tokio::task::spawn_blocking(f)
        .await
        .map_err(|e| bad(StatusCode::INTERNAL_SERVER_ERROR, e.to_string()))?
        .map(|_| StatusCode::NO_CONTENT)
        .map_err(|e| bad(StatusCode::BAD_REQUEST, e))
}

/// Queue a task; a plan item starts its session at once (agent-queue does that, not this).
pub async fn add(Json(b): Json<hub_queue::Add>) -> ApiResult<Json<serde_json::Value>> {
    // A refusal is the request's fault; agent-queue failing to run is the server's.
    hub_queue::add_argv(&b).map_err(|e| bad(StatusCode::BAD_REQUEST, e))?;
    let out = tokio::task::spawn_blocking(move || hub_queue::add(&System, &b))
        .await
        .map_err(|e| bad(StatusCode::INTERNAL_SERVER_ERROR, e.to_string()))?
        .map_err(|e| bad(StatusCode::INTERNAL_SERVER_ERROR, e))?;
    Ok(Json(serde_json::json!({ "out": out.trim() })))
}

#[derive(Deserialize)]
pub struct SlugBody {
    slug: String,
    #[serde(default)]
    priority: String,
}

pub async fn cancel(Json(b): Json<SlugBody>) -> ApiResult<StatusCode> {
    act(move || hub_queue::cancel(&System, &b.slug)).await
}

pub async fn bump(Json(b): Json<SlugBody>) -> ApiResult<StatusCode> {
    act(move || hub_queue::bump(&System, &b.slug, &b.priority)).await
}

/// The projects a task may be queued for: the names in project-map.json, which is also what
/// agent-queue checks `--project` against.
pub async fn projects() -> Json<Vec<String>> {
    let text = std::fs::read_to_string(hub_core::projects::map_path()).unwrap_or_default();
    Json(project_names(&text))
}

fn project_names(map: &str) -> Vec<String> {
    let v: serde_json::Value = serde_json::from_str(map).unwrap_or_default();
    let mut names: Vec<String> = v
        .get("paths")
        .and_then(serde_json::Value::as_object)
        .into_iter()
        .flat_map(|m| m.values())
        .filter_map(|p| p.as_str().map(String::from))
        .filter(|p| hub_queue::is_slug(p))
        .collect();
    names.sort();
    names.dedup();
    names
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_row_view_adds_cost_pr_flag_and_the_days_total() {
        let items = hub_queue::parse(concat!(
            r#"{"slug":"a","state":"done","status":"ok","pr":"o/r#7","merged":"abc","cost_usd":"6.1","started":"2026-11-06T11:00:00Z","finished":"2026-11-06T12:00:00Z","task":"t"}"#,
            "\n",
            r#"{"slug":"b","state":"done","status":"ok","cost_usd":"0","finished":"2026-11-06T12:05:00Z","task":"t"}"#,
            "\n",
            r#"{"slug":"c","state":"queued","agent":"codex","model":"sol","task":"t"}"#,
            "\n",
        ));
        let days = hub_queue::done_days(&items);
        let [a, b, c] = [0, 1, 2].map(|n| item_view(&items[n], &days, chrono::Utc::now()));
        assert_eq!(
            (a["cost"].as_f64(), a["cost_label"].as_str()),
            (Some(6.1), Some("$6.10"))
        );
        assert_eq!(
            (a["pr_label"].as_str(), a["pr_merged"].as_bool()),
            (Some("r#7"), Some(true))
        );
        assert_eq!(a["pr_url"], "https://github.com/o/r/pull/7");
        assert_eq!(a["merged"], "abc", "the ledger's own key is left alone");
        assert_eq!(a["timing"]["run"], 60, "the page renders hub-core's timing");
        assert!(b["timing"]["run"].is_null(), "no started, no run");
        assert_eq!(a["day_total"], "2 done, $6.10, 1 unpriced");
        assert_eq!(a["day_total"], b["day_total"]);
        assert_eq!(
            a["day_label"],
            hub_queue::day_label(a["day"].as_str().unwrap())
        );
        assert!(a.get("unproven").is_none());
        assert_eq!(b["unproven"], true, "no PR and no report");
        assert!(b.get("cost").is_none(), "a ledger 0 is not a price");
        assert!(c.get("day").is_none() && c.get("unproven").is_none());
        assert_eq!(
            (a["harness"].as_str(), c["harness"].as_str()),
            (Some("claude"), Some("codex sol"))
        );
    }

    #[test]
    fn candidates_carry_the_counts_and_each_rows_title_and_label() {
        let c = hub_queue::parse_candidates(concat!(
            r##"{"key":"k-0","text":"- [ ] row 0 #high <!-- id:k-0 -->","auto":true,"verdict":"dispatch"}"##,
            "\n",
            r##"{"key":"k-1","text":"- [ ] row 1","held":true}"##,
        ));
        let v = candidates_view(&c);
        assert_eq!(
            (v["total"].as_u64(), v["auto"].as_u64()),
            (Some(2), Some(1))
        );
        let rows = v["rows"].as_array().unwrap();
        assert_eq!(rows[0]["key"], "k-0");
        assert_eq!(rows[0]["title"], "row 0");
        assert_eq!(rows[0]["start_label"], "auto dispatch");
        assert_eq!(rows[1]["start_label"], "man held");
        assert_eq!(v["blocked_rows"].as_array().unwrap().len(), 0);
        let b = candidates_view(&hub_queue::parse_candidates(
            r##"{"key":"k-2","prio":0,"blocked":["judge: skip, vague"],"active":true,"project":"ar"}"##,
        ));
        assert_eq!(b["rows"][0]["reasons"][0], "judge: skip");
        assert_eq!(b["reasons"][0]["reason"], "judge: skip");
        assert_eq!(b["reasons"][0]["rows"], 1);
        assert_eq!(b["urgent_blocked"], 1);
        assert_eq!(b["clear"], 0);
        assert_eq!(
            b["uncovered"].as_array().unwrap().len(),
            0,
            "a skip is not a gap in cover"
        );
        let none = candidates_view(&Candidates::default());
        assert_eq!(none["rows"].as_array().unwrap().len(), 0);
    }

    #[test]
    fn projects_are_the_unique_map_values() {
        let map = r#"{"paths":{"/a":"dotfiles","/b":"notes-cockpit","/c":"dotfiles","/d":"-x"},"trackers":{}}"#;
        assert_eq!(project_names(map), ["dotfiles", "notes-cockpit"]);
        assert!(project_names("not json").is_empty());
    }
}
