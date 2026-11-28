//! The Queue tab: agent-queue's items as one table (`render`), and adding, cancelling and re-ranking them.
//!
//! agent-queue is the only writer of `~/.agent/queue` (design: `~/.config/agentctl/QUEUE.md`).
//! The list, add, cancel and bump go through `hub_core::queue`, which the hub TUI uses too.
//! The Candidates section is hub-core's `candidates` on the shared table under its own key
//! prefix; its Promote posts the board's Start (`POST /api/board`). Every call is plain
//! arguments, never a shell, and agent-queue's stderr comes back as the error the page shows.

use axum::extract::{Query, State};
use axum::http::StatusCode;
use axum::Json;
use hub_core::layout;
use hub_core::queue::{self as hub_queue, Candidate, Candidates, Item, QueueRow, Section, Stats};
use hub_core::queue_verdict::{worst_first, BANNER_LINES};
use hub_core::session_actions::System;
use hub_core::table::{self, View};
use serde::Deserialize;
use std::sync::Arc;
use std::time::SystemTime;
use tokio::sync::broadcast;

use crate::cache::{EventCache, ReadCache};
use crate::{bad, ApiResult, Shared};

/// How many days back, today included, the list reads finished items (a link to one opens it).
const DONE_DAYS: i64 = 7;
/// A queue change is an event, so this only bounds a read kept while the watcher is down.
const QUEUE_SECS: u64 = 60;
const KINDS: [&str; 1] = ["queue"];

type Read<T> = Result<T, String>;

/// Every agent-queue read the pages make, kept until the queue changes. Home, the pipeline
/// line, this tab's list, the sessions table and its stats each ran agent-queue (one to four
/// seconds apiece on a loaded machine) on every queue event, once per open page. Now one list
/// read, every active item and each finished in the last `DONE_DAYS` days, is filtered in this
/// process for today's list, the tab's and the active items, so none runs its own. `stats` stays
/// a read of its own, because its medians and rates are agent-queue's to compute. A failed read
/// is shown and not kept.
pub struct Cache {
    /// `list --state all --since <the oldest day the tab shows>`, kept for that day, so a new
    /// day reads again.
    list: EventCache<Read<Vec<Item>>, QUEUE_SECS, String>,
    stats: EventCache<Read<Stats>, QUEUE_SECS>,
}

impl Cache {
    pub fn new(events: &broadcast::Sender<String>) -> Self {
        Cache {
            list: EventCache::new(events.subscribe(), &KINDS, "queue"),
            stats: EventCache::new(events.subscribe(), &KINDS, "queue-stats"),
        }
    }

    async fn stats(&self) -> Read<Stats> {
        let r = self
            .stats
            .get_if((), || hub_queue::stats(&System), Result::is_ok);
        r.await.and_then(|s| (*s).clone())
    }

    /// What `pick` takes from the kept list, which is read once for every view of it.
    async fn pick(&self, pick: impl FnOnce(&[Item]) -> Vec<Item>) -> Read<Vec<Item>> {
        let since = hub_queue::days_ago(DONE_DAYS - 1);
        let key = since.clone();
        let read = move || hub_queue::list_since(&System, "all", &since);
        let got = self.list.get_if(key, read, Result::is_ok).await?;
        match &*got {
            Ok(items) => Ok(pick(items)),
            Err(e) => Err(e.clone()),
        }
    }

    /// Every active item and today's finished ones, what `agent-queue list --state all` prints.
    async fn all(&self) -> Read<Vec<Item>> {
        let today = hub_queue::days_ago(0);
        self.pick(move |items| hub_queue::done_since(items, &today))
            .await
    }

    /// The items the release graph joins on, with no stats read, and why there are none when
    /// agent-queue failed (`hub_core::actions::queue_items`'s shape).
    pub async fn items(&self) -> (Vec<Item>, Option<String>) {
        match self.all().await {
            Ok(items) => (items, None),
            Err(e) => (vec![], Some(format!("agent-queue list: {e}"))),
        }
    }

    /// `all` as `session_table::feed_with` takes it.
    pub(crate) async fn feed_items(&self) -> Read<Vec<Item>> {
        self.all().await
    }

    /// The queued, running, waiting and review items, what `agent-queue list --state active`
    /// prints; none when agent-queue failed, as a session's items are then simply not offered.
    pub(crate) async fn active(&self) -> Vec<Item> {
        self.pick(hub_queue::active).await.unwrap_or_default()
    }

    /// `hub_queue::Queue::read` with no flow verdict, as Home and the pipeline line draw it; the
    /// cards add theirs (`verdict`).
    pub async fn queue(&self) -> hub_queue::Queue {
        let (all, stats) = tokio::join!(self.all(), self.stats());
        hub_queue::Queue::from_reads(all, stats)
    }

    /// Every item active or finished since `DONE_DAYS` ago, the tab's list.
    pub(crate) async fn recent(&self) -> Read<Vec<Item>> {
        self.pick(<[Item]>::to_vec).await
    }

    /// After a write from this page or the board (a start queues an item), so its own refresh
    /// shows it.
    pub(crate) fn clear(&self) {
        self.list.clear();
        self.stats.clear();
        crate::epics::clear();
    }
}

/// The view over the list: the keys the page keeps in its URL (`#queue?q=&s=`) filter every
/// section alike, each section sorts and pages on its own prefixed keys (`Section::pre`: `nxsort`,
/// `nxdir`, `nxpg`), and `sel`, an item a link opens: with no `pg` for its section, the page that
/// holds it is the one served.
#[derive(Deserialize, Default)]
#[serde(default)]
pub struct QueueQuery {
    pub q: String,
    pub s: String,
    pub sel: String,
    #[serde(flatten)]
    keys: std::collections::HashMap<String, String>,
}

impl QueueQuery {
    /// A section's own view key (`sort`, `dir` or `pg`), blank when the URL has none.
    fn key(&self, sec: Section, k: &str) -> &str {
        self.keys
            .get(&format!("{}{k}", sec.pre()))
            .map_or("", String::as_str)
    }
}

/// The flow verdict now, off the async workers and beside the items' read (a Prometheus call); a
/// read that died says so in its one line, so the items still show. The tab and the Queue card read it.
pub(crate) async fn verdict() -> hub_core::queue_verdict::Verdict {
    let now = chrono::Utc::now().timestamp();
    tokio::task::spawn_blocking(move || hub_core::queue_verdict::Verdict::read(now))
        .await
        .unwrap_or_else(|e| hub_core::queue_verdict::Verdict {
            error: Some(format!("the verdict read died: {e}")),
            ..Default::default()
        })
}

/// Every active item plus those finished in the last `DONE_DAYS` days, read through hub-core,
/// then filtered, sorted and cut into sections by `hub_core::table` so the page only draws
/// (`render`), and the flow verdict's worst three lines (`flow`: each its sentence, level and the
/// page that shows the cause) over them. The Candidates counts are their own read
/// (`candidates?counts=1`), so the items never wait on the snapshot's parse.
pub async fn list(
    State(s): State<Shared>,
    Query(q): Query<QueueQuery>,
) -> ApiResult<Json<serde_json::Value>> {
    let now = chrono::Utc::now();
    let (items, verdict) = tokio::join!(s.queue.recent(), verdict());
    let hq = hub_queue::Queue {
        items: items.map_err(|e| bad(StatusCode::BAD_REQUEST, e))?,
        ..Default::default()
    };
    let lines = verdict.lines(|| hub_core::bar::ready(&hq, now.timestamp()));
    let flow: Vec<serde_json::Value> = worst_first(lines, BANNER_LINES)
        .iter()
        .map(|l| serde_json::json!({ "line": l.said(), "level": l.level, "to": l.to }))
        .collect();
    let mut v = render(hq.items, &q, now);
    v["flow"] = flow.into();
    Ok(Json(v))
}

/// The tab's rows in sections (`Section::ALL`, worst first): each the rows its state holds under
/// the shared view, sorted and paged on its own keys, with the controls that drew them (`table`).
/// `table` is the one search bar over them all (its states and sort are the sections' own).
/// `needs_you` counts every item whatever the view, for the tab's badge; `done_today` and
/// `cancelled_today` are the line that links to Log, where finished work lives; `sel` is the item a
/// link opened, a finished one included.
fn render(
    items: Vec<Item>,
    q: &QueueQuery,
    now: chrono::DateTime<chrono::Utc>,
) -> serde_json::Value {
    let needs_you = items
        .iter()
        .filter(|i| i.state == hub_queue::State::Waiting)
        .count();
    let midnight = hub_core::text::local_day_start(now.timestamp());
    let (mut done_today, mut cancelled_today) = (0, 0);
    for i in items.iter().filter(|i| i.state == hub_queue::State::Done) {
        if i.finished_at().is_some_and(|f| f.timestamp() >= midnight) {
            if i.cancelled() {
                cancelled_today += 1;
            } else {
                done_today += 1;
            }
        }
    }
    let queue = hub_queue::Queue {
        items,
        sessions: hub_queue::sessions(&hub_core::boards::fleet_state(), now.timestamp()),
        ..Default::default()
    };
    let rows = queue.rows(now);
    let sel = rows
        .iter()
        .find(|r| !q.sel.is_empty() && r.item.slug == q.sel);
    // No section holds finished work, so an old `?s=done` link narrows nothing.
    let s = if ["done", "cancelled"]
        .iter()
        .any(|f| q.s.eq_ignore_ascii_case(f))
    {
        ""
    } else {
        q.s.as_str()
    };
    let (_, mut bar) = View::new::<QueueRow>(&q.q, s, "", "").summary(&rows);
    // The sections are the states and sort apart, so the bar keeps the search and the facets.
    (bar.states, bar.columns, bar.links, bar.legend) = Default::default();
    let sections: Vec<serde_json::Value> = Section::ALL
        .iter()
        .map(|&sec| {
            let view = View::new::<QueueRow>(&q.q, s, q.key(sec, "sort"), q.key(sec, "dir"));
            let (mut shown, mut table) = view.summary(&rows);
            shown.retain(|r| r.section() == Some(sec));
            table.total = rows.iter().filter(|r| r.section() == Some(sec)).count();
            table.shown = shown.len();
            table.states.clear();
            table.facets.clear();
            table.legend = None;
            table.links = table::links(&shown);
            let per = layout::page_rows(&format!("queue/{}", sec.id()));
            let page = q.key(sec, "pg").parse().unwrap_or_else(|_| {
                let at = shown
                    .iter()
                    .position(|r| !q.sel.is_empty() && r.item.slug == q.sel);
                at.map_or(1, |at| at / per + 1)
            });
            table::page(&mut shown, &mut table, page, per);
            serde_json::json!({
                "id": sec.id(), "title": sec.title(), "pre": sec.pre(),
                "items": shown.iter().map(|r| row_view(r, now)).collect::<Vec<_>>(),
                "table": table,
            })
        })
        .collect();
    serde_json::json!({
        "at": now.timestamp(),
        "table": bar,
        "sections": sections,
        "needs_you": needs_you,
        "done_today": done_today,
        "cancelled_today": cancelled_today,
        "finished_at": "#log/work",
        "sel": sel.map(|r| row_view(r, now)),
    })
}

/// A table row: its item (`item_view`) plus `start` (its place in the start order, ready items
/// only), the state cell (`state_word`, `stuck` for amber, `state_why` for its hover) and the cells the row's own columns hold (`Row::val`, what a filter on them matches):
/// `waits_for`, `source` and `row_id`.
fn row_view(r: &QueueRow, now: chrono::DateTime<chrono::Utc>) -> serde_json::Value {
    use hub_core::table::Row;
    let mut v = item_view(r.item, now);
    if let Some(n) = r.start {
        v["start"] = n.into();
    }
    v["state_word"] = r.state_word().into();
    if r.stuck() {
        v["stuck"] = true.into();
    }
    if let Some(why) = r.state_why() {
        v["state_why"] = why.into();
    }
    for (key, col) in [("waits_for", "hold"), ("source", "from"), ("row_id", "row")] {
        if let Some(t) = r.val(col).shown() {
            v[key] = t.into();
        }
    }
    v
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
        v["cost_label"] = hub_core::display::fmt::usd(c).into();
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

/// The window as the one line the Pipeline head carries, worded by hub-core as the hub TUI words it.
pub async fn stats(State(s): State<Shared>) -> ApiResult<Json<serde_json::Value>> {
    let s = s
        .queue
        .stats()
        .await
        .map_err(|e| bad(StatusCode::BAD_REQUEST, e))?;
    Ok(Json(serde_json::json!({ "line": s.line() })))
}

/// One page of the rows the view keeps (`layout`'s `candidates` size; a search narrows on the
/// server), each with the title and start label hub-core words; the controls that drew them
/// (`table`), and the head's facts over every row.
fn candidates_view(
    c: &Candidates,
    q: &CandQuery,
    now: chrono::DateTime<chrono::Local>,
) -> serde_json::Value {
    let view = View::new::<Candidate>(&q.cq, &q.cs, &q.csort, &q.cdir);
    let (mut rows, mut table) = view.summary(&c.rows);
    let page = q.cpg.parse().unwrap_or(1);
    table::page(&mut rows, &mut table, page, layout::page_rows("candidates"));
    let rows: Vec<serde_json::Value> = rows
        .iter()
        .map(|r| {
            let mut v = serde_json::to_value(r).unwrap_or_default();
            v["title"] = r.title().into();
            v["start_label"] = r.start_label().into();
            v
        })
        .collect();
    serde_json::json!({
        "rows": rows, "table": table, "auto": c.auto,
        "urgent_blocked": c.urgent_blocked, "uncovered": c.uncovered, "as_of": c.as_of(now),
    })
}

/// The counts the shut Candidates heading shows, not the rows: how many the snapshot ranks, how
/// many a worker takes, how many urgent ones something blocks (red while any are), and its time.
fn cand_counts(c: &Candidates, now: chrono::DateTime<chrono::Local>) -> serde_json::Value {
    serde_json::json!({
        "total": c.rows.len(), "auto": c.auto, "urgent_blocked": c.urgent_blocked, "as_of": c.as_of(now),
    })
}

/// The snapshot stays the same until fleet-dispatch rewrites it, so a read is kept by `snapshot_key`;
/// this only bounds how long one is kept at all. The kept parse holds the raw write time and
/// `as_of` is worded per answer, so it names the day once the snapshot is old.
const CANDIDATES_SECS: u64 = 3600;
static CANDIDATES: ReadCache<Candidates, CANDIDATES_SECS, Option<(SystemTime, u64)>> =
    ReadCache::new("queue-candidates");

/// fleet-dispatch's snapshot through hub-core, parsed once per write (it runs to megabytes) and
/// shared by the counts and the rows. A file that cannot be read is a 400 with hub-core's words;
/// a parse task that died is a 500.
async fn read_candidates() -> ApiResult<Arc<Candidates>> {
    let path = hub_core::boards::candidates_file();
    let at = hub_queue::snapshot_key(&path);
    let read = async move {
        tokio::task::spawn_blocking(move || hub_queue::candidates(&path))
            .await
            .map_err(|e| bad(StatusCode::INTERNAL_SERVER_ERROR, e.to_string()))?
            .map_err(|e| bad(StatusCode::BAD_REQUEST, e))
    };
    CANDIDATES.get(at, read).await
}

/// The Candidates table's view keys, under its own prefix in the URL and the API (`cq`, `cs`,
/// `csort`, `cdir`, `cpg`), since the Queue table holds the plain ones, and `counts=1` asks for
/// the heading's counts only (`cand_counts`), not the rows.
#[derive(Deserialize, Default)]
#[serde(default)]
pub struct CandQuery {
    pub cq: String,
    pub cs: String,
    pub csort: String,
    pub cdir: String,
    pub cpg: String,
    pub counts: String,
}

/// The ranked board rows of fleet-dispatch's snapshot (`suggest --write`, each real pass), read
/// through hub-core and filtered and sorted by `hub_core::table`: the page asks for the counts once its table has painted and when the
/// snapshot changes, and for the rows while its Candidates fold is open.
pub async fn candidates(Query(q): Query<CandQuery>) -> ApiResult<Json<serde_json::Value>> {
    let c = read_candidates().await?;
    let now = chrono::Local::now();
    Ok(Json(if q.counts.is_empty() {
        candidates_view(&c, &q, now)
    } else {
        cand_counts(&c, now)
    }))
}

#[derive(Deserialize)]
pub struct HistoryQuery {
    slug: String,
}

/// One item's history (hub-core `item_history`), read when its row's History fold opens.
pub async fn history(
    Query(q): Query<HistoryQuery>,
) -> ApiResult<Json<hub_core::item_history::History>> {
    if !hub_queue::is_slug(&q.slug) {
        return Err(bad(
            StatusCode::BAD_REQUEST,
            format!("not a queue slug: {}", q.slug),
        ));
    }
    tokio::task::spawn_blocking(move || hub_core::item_history::read(&System, &q.slug))
        .await
        .map_err(|e| bad(StatusCode::INTERNAL_SERVER_ERROR, e.to_string()))?
        .map(Json)
        .map_err(|e| bad(StatusCode::BAD_GATEWAY, e))
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
    s.queue.clear();
    Ok(Json(serde_json::json!({ "out": out.trim() })))
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct SlugBody {
    slug: String,
    #[serde(default)]
    priority: String,
}

pub async fn cancel(State(s): State<Shared>, Json(b): Json<SlugBody>) -> ApiResult<StatusCode> {
    let r = act(move || hub_queue::cancel(&System, &b.slug)).await;
    if r.is_ok() {
        s.queue.clear();
    }
    r
}

pub async fn bump(State(s): State<Shared>, Json(b): Json<SlugBody>) -> ApiResult<StatusCode> {
    let r = act(move || hub_queue::bump(&System, &b.slug, &b.priority)).await;
    if r.is_ok() {
        s.queue.clear();
    }
    r
}

/// The projects a task may be queued for: the names in project-map.json, which is also what
/// agent-queue checks `--project` against, less the work projects this machine does not list.
pub async fn projects() -> Json<Vec<String>> {
    let names = tokio::task::spawn_blocking(|| hub_core::projects::queueable_here(&System));
    Json(names.await.unwrap_or_default())
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The reads that run `agent-queue` (seconds apiece on a loaded machine) live only here, so a
    /// tab reads `Cache` and never waits on the CLI. `/api/board` once called
    /// `sheet_view::feed`, which runs `agent-queue list` and `stats` per request: 4 to 19 s.
    /// The hub-core calls that run `agent-queue list` or `stats`, under any `use` alias
    /// (`hub_queue::list(` and `hub_core::queue::list(` both hold `queue::list(`).
    const RUNS_AGENT_QUEUE: [&str; 8] = [
        "Queue::read(",
        "sheet_view::feed(",
        "queue::list(",
        "queue::list_since(",
        "queue::stats(",
        "queue_items(",
        "actions::read(",
        "session_table::feed(",
    ];

    fn runs_agent_queue(text: &str) -> Vec<&'static str> {
        RUNS_AGENT_QUEUE
            .into_iter()
            .filter(|b| text.contains(b))
            .collect()
    }

    fn rust_files(dir: &std::path::Path, out: &mut Vec<std::path::PathBuf>) {
        for e in std::fs::read_dir(dir).unwrap() {
            let path = e.unwrap().path();
            if path.is_dir() {
                rust_files(&path, out);
            } else if path.extension().is_some_and(|x| x == "rs") {
                out.push(path);
            }
        }
    }

    #[test]
    fn only_this_cache_runs_agent_queue_reads() {
        let mut files = Vec::new();
        rust_files(
            std::path::Path::new(concat!(env!("CARGO_MANIFEST_DIR"), "/src")),
            &mut files,
        );
        assert!(files.len() > 10, "the scan found the sources: {files:?}");
        let found: Vec<String> = files
            .iter()
            .filter(|p| !p.ends_with("src/queue.rs"))
            .flat_map(|p| {
                let text = std::fs::read_to_string(p).unwrap();
                let hits = runs_agent_queue(&text);
                hits.into_iter()
                    .map(move |b| format!("{}: {b}", p.display()))
            })
            .collect();
        assert!(
            found.is_empty(),
            "read through queue::Cache instead: {found:?}"
        );
        // Negative control: the two calls that once ran it per read are seen, aliased or not.
        let old_board = "hub_core::sheet_view::feed(&System).map(|f| shown(&f, &q))";
        assert_eq!(runs_agent_queue(old_board), ["sheet_view::feed("]);
        assert_eq!(
            runs_agent_queue("hub_core::actions::read(now - span)"),
            ["actions::read("]
        );
        assert!(runs_agent_queue("sheet_view::feed_with(&System, &queue)").is_empty());
        // The sessions table once ran its own list through `feed`.
        assert_eq!(
            runs_agent_queue("session_table::feed(&System, &registry)"),
            ["session_table::feed("]
        );
        assert!(runs_agent_queue("session_table::feed_with(&System, &r, items)").is_empty());
    }

    #[test]
    fn a_row_view_adds_cost_pr_flag_and_the_days_total() {
        let items = hub_queue::parse(concat!(
            r#"{"slug":"a","state":"done","status":"ok","outcome":"landed","pr":"o/r#7","merged":"abc","cost_usd":"6.1","started":"2026-11-06T11:00:00Z","finished":"2026-11-06T12:00:00Z","task":"t"}"#,
            "\n",
            r#"{"slug":"b","state":"done","status":"ok","outcome":"no-pr","cost_usd":"0","finished":"2026-11-06T12:05:00Z","task":"t"}"#,
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

    /// A query string as the page sends it, the way axum's `Query` reads it.
    fn qs(text: &str) -> QueueQuery {
        let mut q = QueueQuery::default();
        for (k, v) in text.split('&').filter_map(|p| p.split_once('=')) {
            match k {
                "q" => q.q = v.into(),
                "s" => q.s = v.into(),
                "sel" => q.sel = v.into(),
                _ => {
                    q.keys.insert(k.into(), v.into());
                }
            }
        }
        q
    }

    fn at(t: &str) -> chrono::DateTime<chrono::Utc> {
        chrono::DateTime::parse_from_rfc3339(t)
            .unwrap()
            .with_timezone(&chrono::Utc)
    }

    /// The slugs of one section's rows, and the section itself.
    fn section<'a>(v: &'a serde_json::Value, id: &str) -> &'a serde_json::Value {
        v["sections"]
            .as_array()
            .unwrap()
            .iter()
            .find(|s| s["id"] == id)
            .unwrap_or_else(|| panic!("no section {id}"))
    }

    fn slugs(v: &serde_json::Value, id: &str) -> Vec<String> {
        section(v, id)["items"]
            .as_array()
            .unwrap()
            .iter()
            .map(|i| i["slug"].as_str().unwrap().to_string())
            .collect()
    }

    fn mixed() -> Vec<Item> {
        hub_queue::parse(concat!(
            r#"{"slug":"d1","state":"done","status":"ok","project":"dotfiles","finished":"2026-11-06T10:00:00Z","task":"fix(a): done"}"#,
            "\n",
            r#"{"slug":"c1","state":"done","status":"cancelled","project":"dotfiles","finished":"2026-11-06T10:30:00Z","task":"fix(a): dropped"}"#,
            "\n",
            r#"{"slug":"q1","state":"queued","project":"dotfiles","queued":"2026-11-06T09:00:00Z","task":"feat(b): up"}"#,
            "\n",
            r#"{"slug":"w1","state":"waiting","project":"playground","waiting":"2026-11-06T10:00:00Z","task":"fix(c): ask"}"#,
            "\n",
            r#"{"slug":"r1","state":"running","project":"dotfiles","started":"2026-11-06T09:30:00Z","task":"fix(d): run"}"#,
            "\n",
            r#"{"slug":"p1","state":"review","project":"dotfiles","started":"2026-11-06T08:30:00Z","pr":"o/r#4","task":"fix(e): pr"}"#,
        ))
    }

    #[test]
    fn the_list_is_one_section_per_state_worst_first_with_finished_work_as_a_count() {
        let now = at("2026-11-06T12:00:00Z");
        let v = render(mixed(), &QueueQuery::default(), now);
        let ids: Vec<&str> = v["sections"]
            .as_array()
            .unwrap()
            .iter()
            .map(|s| s["id"].as_str().unwrap())
            .collect();
        assert_eq!(ids, ["needs", "stuck", "running", "pr", "next"]);
        assert_eq!(slugs(&v, "needs"), ["w1"]);
        assert_eq!(slugs(&v, "running"), ["r1"]);
        assert_eq!(slugs(&v, "pr"), ["p1"]);
        assert_eq!(slugs(&v, "next"), ["q1"]);
        assert_eq!(
            section(&v, "next")["items"][0]["start"],
            1,
            "q1 starts first"
        );
        assert!(
            section(&v, "running")["items"][0]["start"].is_null(),
            "only a ready item has a place"
        );
        assert_eq!(
            section(&v, "running")["items"][0]["timing"]["run"],
            150,
            "the page draws hub-core's minutes"
        );
        // Done leaves the sections for a count, split from the cancelled ones.
        for id in ["needs", "stuck", "running", "pr", "next"] {
            assert!(
                !slugs(&v, id).iter().any(|s| s == "d1" || s == "c1"),
                "{id}"
            );
        }
        assert_eq!(
            (&v["done_today"], &v["cancelled_today"]),
            (&1.into(), &1.into())
        );
        assert_eq!(v["needs_you"], 1);
        assert_eq!(
            v["finished_at"], "#log/work",
            "where the finished count links"
        );
        assert!(v.get("section_aliases").is_none() && v["sel"].is_null());
        // The sections are the states: the bar keeps search and facets, no chips or sort of its own.
        assert!(v["table"]["states"].as_array().unwrap().is_empty());
        assert!(!v["table"]["facets"].as_array().unwrap().is_empty());
        assert!(
            v["table"].get("legend").is_none()
                && section(&v, "next")["table"].get("legend").is_none(),
            "no chip, so no legend of chips"
        );
        // An old `?s=done` link narrows nothing: no section holds finished work.
        let old = render(mixed(), &qs("s=done"), now);
        assert_eq!(slugs(&old, "needs"), ["w1"]);
        assert_eq!(slugs(&old, "next"), ["q1"]);
        // NEGATIVE CONTROL: a section with no rows is still sent, with its head's zero and no pager.
        let none = render(vec![], &QueueQuery::default(), now);
        assert_eq!(section(&none, "stuck")["table"]["shown"], 0);
        assert!(section(&none, "stuck")["table"].get("pager").is_none());
        assert_eq!(none["needs_you"], 0);
    }

    #[test]
    fn a_filter_reaches_every_section_and_a_sort_only_its_own() {
        let now = at("2026-11-06T12:00:00Z");
        let by = |q: &str| QueueQuery {
            q: q.into(),
            ..Default::default()
        };
        let v = render(mixed(), &by("project:playground"), now);
        assert_eq!(slugs(&v, "needs"), ["w1"]);
        assert!(slugs(&v, "running").is_empty() && slugs(&v, "next").is_empty());
        assert_eq!(
            section(&v, "next")["table"]["total"],
            1,
            "the head counts the section's rows"
        );
        let chip = QueueQuery {
            s: "running".into(),
            ..Default::default()
        };
        let v = render(mixed(), &chip, now);
        assert_eq!(
            slugs(&v, "running"),
            ["r1"],
            "an old ?s= chip still narrows"
        );
        assert!(slugs(&v, "needs").is_empty());
        let items = hub_queue::parse(concat!(
            r#"{"slug":"a","state":"queued","project":"x","queued":"2026-11-06T09:00:00Z","task":"feat: a"}"#,
            "\n",
            r#"{"slug":"b","state":"queued","project":"y","queued":"2026-11-06T09:05:00Z","task":"feat: b"}"#,
            "\n",
            r#"{"slug":"r","state":"running","project":"y","started":"2026-11-06T09:05:00Z","task":"feat: r"}"#,
        ));
        let sorted = |dir: &str| {
            let q = qs(&format!("nxsort=project&nxdir={dir}"));
            render(items.clone(), &q, now)
        };
        assert_eq!(slugs(&sorted("desc"), "next"), ["b", "a"]);
        assert_eq!(slugs(&sorted("asc"), "next"), ["a", "b"]);
        assert_eq!(section(&sorted("desc"), "next")["table"]["sort"], "project");
        assert_eq!(
            section(&sorted("desc"), "running")["table"]["sort"],
            "",
            "NEGATIVE CONTROL: another section's sort key leaves this one alone"
        );
    }

    #[test]
    fn a_section_pages_at_its_layout_size_and_a_linked_item_opens_on_its_page() {
        let per = layout::page_rows("queue/next");
        let lines: Vec<String> = (0..per + 4)
            .map(|i| format!(r#"{{"slug":"q{i}","state":"queued","project":"dotfiles","queued":"2026-11-06T09:{:02}:00Z","task":"feat(b): up"}}"#, i % 60))
            .collect();
        let items = hub_queue::parse(&lines.join("\n"));
        let now = at("2026-11-06T12:00:00Z");
        let n = |v: &serde_json::Value| slugs(v, "next").len();
        let one = render(items.clone(), &QueueQuery::default(), now);
        let t = &section(&one, "next")["table"];
        assert_eq!((n(&one), &t["pager"]["page"]), (per, &1.into()));
        assert_eq!(t["shown"], per + 4, "the count is every page's");
        let last = slugs(&one, "next")[0].clone();
        let get = |text: &str| render(items.clone(), &qs(text), now);
        let v = get("nxpg=2");
        assert_eq!(
            (n(&v), &section(&v, "next")["table"]["pager"]["page"]),
            (4, &2.into())
        );
        let tail = slugs(&v, "next")[3].clone();
        let v = get(&format!("sel={tail}"));
        assert_eq!(
            section(&v, "next")["table"]["pager"]["page"],
            2,
            "the page that holds it"
        );
        assert!(slugs(&v, "next").contains(&tail));
        assert_eq!(v["sel"]["slug"], tail.as_str());
        let v = get(&format!("sel={tail}&nxpg=1"));
        assert_eq!(
            section(&v, "next")["table"]["pager"]["page"],
            1,
            "a page asked for wins"
        );
        let v = get(&format!("sel={last}"));
        assert_eq!(section(&v, "next")["table"]["pager"]["page"], 1);
    }

    #[test]
    fn a_linked_finished_item_comes_back_as_sel_though_no_section_holds_it() {
        let v = render(mixed(), &qs("sel=d1"), at("2026-11-06T12:00:00Z"));
        assert_eq!(v["sel"]["slug"], "d1");
        assert_eq!(v["sel"]["state"], "done");
        for id in ["needs", "stuck", "running", "pr", "next"] {
            assert!(!slugs(&v, id).contains(&"d1".to_string()), "{id}");
        }
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
        let v = candidates_view(&c, &CandQuery::default(), chrono::Local::now());
        assert_eq!(
            (v["table"]["total"].as_u64(), v["auto"].as_u64()),
            (Some(2), Some(1))
        );
        let rows = v["rows"].as_array().unwrap();
        assert_eq!(rows[0]["key"], "k-0");
        assert_eq!(rows[0]["rank"], 1);
        assert_eq!(rows[0]["title"], "row 0");
        assert_eq!(rows[0]["start_label"], "auto dispatch");
        assert_eq!(rows[1]["start_label"], "man held");
        assert!(v["table"].get("pager").is_none(), "one page is unpaged");
        let b = candidates_view(
            &hub_queue::parse_candidates(
                r##"{"key":"k-2","prio":0,"blocked":["judge: skip, vague"],"active":true,"project":"ar"}"##,
            ),
            &CandQuery::default(),
            chrono::Local::now(),
        );
        let facet = |v: &serde_json::Value, key: &str| -> Vec<(String, u64)> {
            v["table"]["facets"]
                .as_array()
                .unwrap()
                .iter()
                .find(|f| f["key"] == key)
                .unwrap()["values"]
                .as_array()
                .unwrap()
                .iter()
                .map(|x| {
                    (
                        x["value"].as_str().unwrap().into(),
                        x["n"].as_u64().unwrap(),
                    )
                })
                .collect()
        };
        assert_eq!(facet(&b, "blocked"), [("judge: skip".to_string(), 1)]);
        assert_eq!(b["table"]["states"][2]["name"], "blocked");
        assert_eq!(b["table"]["states"][2]["n"], 1);
        assert_eq!(b["urgent_blocked"], 1);
        assert_eq!(b["table"]["links"][0]["project"], "#projects/ar");
        assert_eq!(
            b["uncovered"].as_array().unwrap().len(),
            0,
            "a skip is not a gap in cover"
        );
        use chrono::TimeZone;
        let at = |d, h| {
            chrono::Local
                .with_ymd_and_hms(2026, 11, d, h, 7, 0)
                .unwrap()
        };
        let kept = Candidates {
            written: Some(at(9, 8).into()),
            ..Candidates::default()
        };
        let none = candidates_view(&kept, &CandQuery::default(), at(9, 9));
        assert_eq!(none["rows"].as_array().unwrap().len(), 0);
        assert_eq!(none["as_of"], "08:07", "the page stamps the fold with it");
        assert_eq!(
            candidates_view(&kept, &CandQuery::default(), at(10, 9))["as_of"],
            "Nov 9 08:07",
            "the same kept parse names its day the next morning"
        );
    }

    #[test]
    fn the_counts_read_carries_the_heading_and_no_row() {
        let c = hub_queue::parse_candidates(
            r##"{"key":"k-2","prio":0,"blocked":["judge: skip, vague"],"auto":true}"##,
        );
        let v = cand_counts(&c, chrono::Local::now());
        assert_eq!(
            (&v["total"], &v["auto"], &v["urgent_blocked"]),
            (&1.into(), &1.into(), &1.into())
        );
        assert!(v.get("rows").is_none() && v.get("blocked_rows").is_none());
    }

    #[test]
    fn a_candidates_search_finds_rows_past_the_first_page_on_the_server() {
        let per = layout::page_rows("candidates");
        let lines: Vec<String> = (0..per + 20)
            .map(|i| {
                format!(
                    r#"{{"key":"k-{i}","project":"p{}","text":"- [ ] row {i}"}}"#,
                    i % 2
                )
            })
            .collect();
        let c = hub_queue::parse_candidates(&lines.join("\n"));
        let keys = |v: &serde_json::Value| -> Vec<String> {
            v["rows"]
                .as_array()
                .unwrap()
                .iter()
                .map(|r| r["key"].as_str().unwrap().to_string())
                .collect()
        };
        let all = candidates_view(&c, &CandQuery::default(), chrono::Local::now());
        assert_eq!(keys(&all).len(), per);
        assert_eq!(all["table"]["pager"]["pages"], 2);
        assert!(
            !keys(&all).contains(&"k-45".to_string()),
            "the control: past the first page"
        );
        let q = CandQuery {
            cq: "key:=k-45".into(),
            ..Default::default()
        };
        let one = candidates_view(&c, &q, chrono::Local::now());
        assert_eq!(keys(&one), ["k-45"]);
        assert_eq!(one["table"]["shown"], 1);
        assert!(one["table"].get("pager").is_none(), "one page is unpaged");
        assert_eq!(one["table"]["links"].as_array().unwrap().len(), 1);
        let p1 = CandQuery {
            cq: "project:p1".into(),
            csort: "rank".into(),
            ..Default::default()
        };
        let v = candidates_view(&c, &p1, chrono::Local::now());
        assert_eq!(keys(&v)[0], "k-49", "biggest rank first");
        assert!(v["table"].get("pager").is_none(), "25 rows fit on one page");
        let two = CandQuery {
            cpg: "2".into(),
            ..Default::default()
        };
        let v = candidates_view(&c, &two, chrono::Local::now());
        assert_eq!(keys(&v).len(), 20);
        assert_eq!(keys(&v)[0], format!("k-{per}"));
        assert_eq!(v["table"]["pager"]["page"], 2);
        assert_eq!(v["table"]["links"].as_array().unwrap().len(), 20);
        assert!(v.get("more").is_none());
    }
}
