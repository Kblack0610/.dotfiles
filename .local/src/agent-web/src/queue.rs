//! The Queue tab: agent-queue's items as one table (`render`), and adding, cancelling and re-ranking them.
//!
//! agent-queue is the only writer of `~/.agent/queue` (design: `~/.config/agentctl/QUEUE.md`).
//! The list, add, cancel and bump go through `hub_core::queue`, which the hub TUI uses too.
//! The Candidates section is hub-core's
//! `candidates`; its Promote posts the board's Start (`POST /api/board`). Every call is plain
//! arguments, never a shell, and agent-queue's stderr comes back as the error the page shows.

use axum::extract::{Query, State};
use axum::http::StatusCode;
use axum::Json;
use hub_core::queue::{self as hub_queue, Candidates, Item, QueueRow, Stats};
use hub_core::session_actions::System;
use hub_core::table::View;
use serde::Deserialize;
use tokio::sync::broadcast;

use crate::cache::EventCache;
use crate::{bad, ApiResult, Shared};

/// How many days back, today included, the page's Done section reaches.
const DONE_DAYS: i64 = 7;
/// A queue change is an event, so this only bounds a read kept while the watcher is down.
const QUEUE_SECS: u64 = 60;
const KINDS: [&str; 1] = ["queue"];

type Read<T> = Result<T, String>;

/// Every agent-queue read the pages make, kept until the queue changes. Home, the pipeline
/// line, this tab's list and its stats each ran agent-queue (one to four seconds apiece on a
/// loaded machine) on every queue event, once per open page; now one read per change serves
/// them all. A failed read is shown and not kept.
pub struct Cache {
    all: EventCache<Read<Vec<Item>>, QUEUE_SECS>,
    since: EventCache<Read<Vec<Item>>, QUEUE_SECS, String>,
    stats: EventCache<Read<Stats>, QUEUE_SECS>,
}

impl Cache {
    pub fn new(events: &broadcast::Sender<String>) -> Self {
        Cache {
            all: EventCache::new(events.subscribe(), &KINDS),
            since: EventCache::new(events.subscribe(), &KINDS),
            stats: EventCache::new(events.subscribe(), &KINDS),
        }
    }

    async fn stats(&self) -> Read<Stats> {
        let r = self
            .stats
            .get_if((), || hub_queue::stats(&System), Result::is_ok);
        r.await.and_then(|s| (*s).clone())
    }

    /// Every item, the cached `agent-queue list all`.
    async fn all(&self) -> Read<Vec<Item>> {
        let r = self
            .all
            .get_if((), || hub_queue::list(&System, "all"), Result::is_ok);
        r.await.and_then(|l| (*l).clone())
    }

    /// The items the release graph joins on, with no stats read, and why there are none when
    /// agent-queue failed (`hub_core::actions::queue_items`'s shape).
    pub async fn items(&self) -> (Vec<Item>, Option<String>) {
        match self.all().await {
            Ok(items) => (items, None),
            Err(e) => (vec![], Some(format!("agent-queue list: {e}"))),
        }
    }

    /// `hub_queue::Queue::read`, as Home and the pipeline line draw it.
    pub async fn queue(&self) -> hub_queue::Queue {
        let (all, stats) = tokio::join!(self.all(), self.stats());
        hub_queue::Queue::from_reads(all, stats)
    }

    /// Every item active or finished since `DONE_DAYS` ago, the tab's list.
    async fn recent(&self) -> Read<Vec<Item>> {
        let since = hub_queue::days_ago(DONE_DAYS - 1);
        let key = since.clone();
        let read = move || hub_queue::list_since(&System, "all", &since);
        self.since
            .get_if(key, read, Result::is_ok)
            .await
            .and_then(|l| (*l).clone())
    }

    /// After a write from this page, so its own refresh shows it.
    async fn clear(&self) {
        self.all.clear().await;
        self.since.clear().await;
        self.stats.clear().await;
        crate::epics::clear().await;
    }
}

/// The table view over the list: the same keys the page keeps in its URL (`#queue?q=&s=&sort=&dir=`).
#[derive(Deserialize, Default)]
#[serde(default)]
pub struct QueueQuery {
    pub q: String,
    pub s: String,
    pub sort: String,
    pub dir: String,
}

/// Every active item plus those finished in the last `DONE_DAYS` days, read through hub-core,
/// then filtered and sorted by `hub_core::table` so the page only draws (`render`).
pub async fn list(
    State(s): State<Shared>,
    Query(q): Query<QueueQuery>,
) -> ApiResult<Json<serde_json::Value>> {
    s.queue
        .recent()
        .await
        .map(|items| Json(render(items, &q, chrono::Utc::now())))
        .map_err(|e| bad(StatusCode::BAD_REQUEST, e))
}

/// The rows the view keeps, each worded by `item_view`, and the controls that drew them
/// (`table`). `needs_you` counts every item whatever the view, for the tab's badge;
/// `open_rows` is how many rows the page draws before "+N older"; `section_aliases` maps an old
/// section id (`#queue/running`) to the state chip it opens.
fn render(
    items: Vec<Item>,
    q: &QueueQuery,
    now: chrono::DateTime<chrono::Utc>,
) -> serde_json::Value {
    let needs_you = items
        .iter()
        .filter(|i| i.state == hub_queue::State::Waiting)
        .count();
    let queue = hub_queue::Queue {
        items,
        ..Default::default()
    };
    let rows = queue.rows(now);
    let view = View::new::<QueueRow>(&q.q, &q.s, &q.sort, &q.dir);
    let (shown, table) = view.summary(&rows);
    let aliases: serde_json::Map<String, serde_json::Value> = hub_queue::SECTION_ALIASES
        .iter()
        .map(|(old, chip)| (old.to_string(), (*chip).into()))
        .collect();
    serde_json::json!({
        "at": now.timestamp(),
        "items": shown.iter().map(|r| item_view(r.item, now)).collect::<Vec<_>>(),
        "table": table,
        "needs_you": needs_you,
        "open_rows": hub_queue::TABLE_OPEN_ROWS,
        "section_aliases": aliases,
    })
}

/// The item as agent-queue printed it plus what a row shows: `harness` (`Item::harness_label`,
/// `claude` when the item names no agent), `cost` (dollars, absent when unknown), the PR's
/// label and link, `pr_merged` (the merge was recorded), `unproven`, `links` (what it names, each
/// to its page: `Item::links`), its `timing` now
/// (`Item::timing`), so the page does no duration math, and its `timeline`.
fn item_view(i: &Item, now: chrono::DateTime<chrono::Utc>) -> serde_json::Value {
    let mut v = serde_json::to_value(i).unwrap_or_default();
    v["timing"] = serde_json::to_value(i.timing(now)).unwrap_or_default();
    v["timeline"] = serde_json::to_value(i.timeline()).unwrap_or_default();
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
    v["links"] = serde_json::to_value(i.links()).unwrap_or_default();
    v
}

/// The window's line and what sits now, worded by hub-core as the hub TUI words them.
pub async fn stats(State(s): State<Shared>) -> ApiResult<Json<serde_json::Value>> {
    let s = s
        .queue
        .stats()
        .await
        .map_err(|e| bad(StatusCode::BAD_REQUEST, e))?;
    // The prose lines for the folded detail, and the typical times for the page's folded
    // detail.
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
        "as_of": c.as_of,
    })
}

/// The ranked board rows of fleet-dispatch's snapshot (`suggest --write`, each real pass), read
/// through hub-core; the page asks for it on showing the tab and after a promote.
pub async fn candidates() -> ApiResult<Json<serde_json::Value>> {
    tokio::task::spawn_blocking(|| hub_queue::candidates(&hub_core::boards::candidates_file()))
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

/// Queue a task; an urgent or high plan item starts its session at once (agent-queue does that, not this).
pub async fn add(
    State(s): State<Shared>,
    Json(b): Json<hub_queue::Add>,
) -> ApiResult<Json<serde_json::Value>> {
    // A refusal is the request's fault; agent-queue failing to run is the server's.
    hub_queue::add_argv(&b).map_err(|e| bad(StatusCode::BAD_REQUEST, e))?;
    let out = tokio::task::spawn_blocking(move || hub_queue::add(&System, &b))
        .await
        .map_err(|e| bad(StatusCode::INTERNAL_SERVER_ERROR, e.to_string()))?
        .map_err(|e| bad(StatusCode::INTERNAL_SERVER_ERROR, e))?;
    s.queue.clear().await;
    Ok(Json(serde_json::json!({ "out": out.trim() })))
}

#[derive(Deserialize)]
pub struct SlugBody {
    slug: String,
    #[serde(default)]
    priority: String,
}

pub async fn cancel(State(s): State<Shared>, Json(b): Json<SlugBody>) -> ApiResult<StatusCode> {
    let r = act(move || hub_queue::cancel(&System, &b.slug)).await;
    if r.is_ok() {
        s.queue.clear().await;
    }
    r
}

pub async fn bump(State(s): State<Shared>, Json(b): Json<SlugBody>) -> ApiResult<StatusCode> {
    let r = act(move || hub_queue::bump(&System, &b.slug, &b.priority)).await;
    if r.is_ok() {
        s.queue.clear().await;
    }
    r
}

/// The projects a task may be queued for: the names in project-map.json, which is also what
/// agent-queue checks `--project` against, less the work projects this machine does not list.
pub async fn projects() -> Json<Vec<String>> {
    // The machine's profile does not change while the server runs, so notes is asked once.
    static MACHINE: std::sync::OnceLock<String> = std::sync::OnceLock::new();
    let names = tokio::task::spawn_blocking(|| {
        let text = std::fs::read_to_string(hub_core::projects::map_path()).unwrap_or_default();
        project_names(
            &text,
            MACHINE.get_or_init(|| hub_core::projects::machine_profile(&System)),
        )
    });
    Json(names.await.unwrap_or_default())
}

fn project_names(map: &str, machine: &str) -> Vec<String> {
    let v: serde_json::Value = serde_json::from_str(map).unwrap_or_default();
    let reg = project_map::Registry::parse(map);
    let mut names: Vec<String> = v
        .get("paths")
        .and_then(serde_json::Value::as_object)
        .into_iter()
        .flat_map(|m| m.values())
        .filter_map(|p| p.as_str().map(String::from))
        .filter(|p| hub_queue::is_slug(p))
        .filter(|p| reg.as_ref().is_none_or(|r| r.project_visible(p, machine)))
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
        let [a, b, c] = [0, 1, 2].map(|n| item_view(&items[n], chrono::Utc::now()));
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
    fn the_list_is_the_shared_table_in_hub_cores_order_with_its_controls() {
        let items = hub_queue::parse(concat!(
            r#"{"slug":"d1","state":"done","status":"ok","project":"dotfiles","finished":"2026-11-06T10:00:00Z","task":"fix(a): done"}"#,
            "\n",
            r#"{"slug":"q1","state":"queued","project":"dotfiles","queued":"2026-11-06T09:00:00Z","task":"feat(b): up"}"#,
            "\n",
            r#"{"slug":"w1","state":"waiting","project":"playground","waiting":"2026-11-06T10:00:00Z","task":"fix(c): ask"}"#,
            "\n",
            r#"{"slug":"r1","state":"running","project":"dotfiles","started":"2026-11-06T09:30:00Z","task":"fix(d): run"}"#,
        ));
        let now = chrono::DateTime::parse_from_rfc3339("2026-11-06T12:00:00Z")
            .unwrap()
            .with_timezone(&chrono::Utc);
        let slugs = |v: &serde_json::Value| -> Vec<String> {
            v["items"]
                .as_array()
                .unwrap()
                .iter()
                .map(|i| i["slug"].as_str().unwrap().to_string())
                .collect()
        };
        let v = render(items.clone(), &QueueQuery::default(), now);
        assert_eq!(
            slugs(&v),
            ["w1", "r1", "q1", "d1"],
            "needs you, running, up next, done"
        );
        assert_eq!(v["table"]["total"], 4);
        assert_eq!(v["needs_you"], 1);
        assert_eq!(v["open_rows"], hub_queue::TABLE_OPEN_ROWS);
        assert_eq!(v["section_aliases"]["running"], "running");
        assert_eq!(v["section_aliases"]["waiting"], "needs you");
        assert_eq!(
            v["items"][1]["timing"]["run"], 150,
            "the page draws hub-core's minutes"
        );
        let q = QueueQuery {
            q: "project:dotfiles".into(),
            s: "running".into(),
            ..Default::default()
        };
        let v = render(items.clone(), &q, now);
        assert_eq!(slugs(&v), ["r1"]);
        assert_eq!(v["table"]["total"], 4, "the chips count every row");
        assert_eq!(v["needs_you"], 1, "the badge ignores the view");
        let by_in = QueueQuery {
            sort: "in".into(),
            dir: "asc".into(),
            ..Default::default()
        };
        assert_eq!(
            slugs(&render(items, &by_in, now))[..3],
            ["w1", "r1", "q1"].map(String::from),
            "asc, none last"
        );
    }

    #[test]
    fn a_row_view_carries_hub_cores_timeline() {
        let items = hub_queue::parse(
            r#"{"slug":"a","state":"done","queued":"2026-11-06T09:00:00Z","started":"2026-11-06T09:14:00Z","merged":"abc123","task":"t"}"#,
        );
        let v = item_view(&items[0], chrono::Utc::now());
        assert_eq!(v["timeline"][1]["step"], "started");
        assert_eq!(v["timeline"][1]["gap_min"], 14);
        assert_eq!(v["timeline"][2]["sha"], "abc123");
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
        let none = candidates_view(&Candidates {
            as_of: "08:07".into(),
            ..Candidates::default()
        });
        assert_eq!(none["rows"].as_array().unwrap().len(), 0);
        assert_eq!(none["as_of"], "08:07", "the page stamps the fold with it");
    }

    #[test]
    fn projects_are_the_unique_map_values() {
        let map = r#"{"paths":{"/a":"dotfiles","/b":"notes-cockpit","/c":"dotfiles","/d":"-x"},"trackers":{}}"#;
        assert_eq!(
            project_names(map, "personal"),
            ["dotfiles", "notes-cockpit"]
        );
        assert!(project_names("not json", "personal").is_empty());
    }

    #[test]
    fn a_work_repo_is_queueable_only_on_its_work_machine() {
        let map = r#"{"clients":{"acme":{"profile":"acmework"}},
            "paths":{"/a":"dotfiles","/w":"acme-platform"},
            "trackers":{"acme-platform":{"client":"acme"}}}"#;
        assert_eq!(project_names(map, "personal"), ["dotfiles"]);
        assert_eq!(
            project_names(map, "acmework"),
            ["acme-platform", "dotfiles"]
        );
    }
}
