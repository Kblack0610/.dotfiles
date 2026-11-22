//! What the waybar and noctalia hovers (the queue and sessions chips) lay out as text: the live
//! sessions worst first, the items ready to start in agent-queue's order, the top cleared board
//! candidates and the drain. One document, `hub bar --json`, so the chips only lay it out
//! (dashboards.md rule 8); `agent-mqtt-publish` sends it retained as `agents/<host>/summary/bar`
//! from the lease holder, the one host whose state files are current. The counts stay on
//! Prometheus: nothing here restates them.

use serde::Serialize;
use serde_json::Value;

use crate::flow;
use crate::home::FLEET_STATE_STALE_SECS;
use crate::queue::{self, Candidates, Queue, Stats};
use crate::reading::State as Reading;
use crate::session_table::{self, is_live, is_machine, Feed, SessionRow, Source};
use crate::vocab::Vocab;

/// The ready items sent, from the front of the start order; `ready.total` counts them all.
pub const READY_SENT: usize = 12;

/// How old the dispatch snapshot may be before its candidates are dropped and named stale. Provisional
/// (2026-11-21): a pass writes it every few minutes (7 min old when measured), so an hour of silence
/// is a stopped dispatch, not a quiet one; revisit when a held dispatch shows this line wrongly.
pub const CANDIDATES_STALE_SECS: i64 = 3600;

/// The cleared board candidates sent: what dispatch would promote after the ready items.
pub const CANDIDATES_SENT: usize = 3;

/// One live session, the fields of its `SessionRow` a hover line needs.
#[derive(Clone, Debug, Default, PartialEq, Serialize)]
pub struct BarSession {
    pub bucket: String,
    pub project: String,
    /// The queue item's title, else the session's topic.
    pub task: String,
    /// Why it is in its bucket (`1 pending ask(s)`, `PR #3076 CI red`).
    pub reason: String,
    /// What it is doing now (`Bash: run bats tests`).
    pub activity: String,
    pub target: String,
    pub item: String,
    pub pr: Option<String>,
    pub pr_state: String,
    pub ci: String,
    pub idle_min: Option<i64>,
    /// Its bucket is one the vocabulary calls finished (landed, done): ready to close.
    pub done: bool,
}

impl From<SessionRow> for BarSession {
    fn from(r: SessionRow) -> BarSession {
        BarSession {
            bucket: r.bucket,
            project: r.project,
            task: r.task,
            reason: r.reason,
            activity: r.activity,
            target: r.target,
            item: r.item,
            pr: r.pr,
            pr_state: r.pr_state,
            ci: r.ci,
            idle_min: r.idle_min,
            done: r.done,
        }
    }
}

/// One item ready to start. `title` is its subject, with the `type(area):` prefix in `kind` and
/// `area`, so a chip can word the line either way.
#[derive(Clone, Debug, Default, PartialEq, Serialize)]
pub struct BarItem {
    pub slug: String,
    pub project: String,
    pub priority: String,
    pub kind: String,
    pub area: String,
    pub title: String,
    /// Minutes it has been able to start.
    pub ready_min: Option<i64>,
}

/// The queued items in agent-queue's start order, the first `READY_SENT` of them. They are the
/// items the store says can start; dispatch may still pass one over (a held area, load, a lane's
/// tier), which this does not model.
#[derive(Clone, Debug, Default, PartialEq, Serialize)]
pub struct Ready {
    pub total: usize,
    pub urgent: usize,
    pub high: usize,
    pub items: Vec<BarItem>,
}

/// A board row dispatch would start next that no worker, judge or held area stops.
#[derive(Clone, Debug, Default, PartialEq, Serialize)]
pub struct BarCandidate {
    pub project: String,
    pub key: String,
    pub priority: String,
    pub title: String,
}

/// `hub bar --json`.
#[derive(Clone, Debug, Default, PartialEq, Serialize)]
pub struct Bar {
    /// Epoch seconds the document was built at; a reader says how old it is from this. It changes on
    /// every build, so the publisher resends the topic each time it reads, which is the heartbeat the
    /// chips' "N old" check needs.
    pub as_of: i64,
    /// Live sessions, worst bucket first, then the longest idle first. The shepherd's pane and
    /// the NIGHTLY and SHARED rows are the fleet's own, not anyone's task, and are left out.
    pub sessions: Vec<BarSession>,
    pub ready: Ready,
    /// The first `CANDIDATES_SENT` cleared candidates, in dispatch's rank order.
    pub candidates: Vec<BarCandidate>,
    /// Whether the queue shrinks or grows (`flow::drain`), None without the stats read.
    pub drain: Option<String>,
    /// `<source>: <why>` for each source that could not be read or is stale: a reader shows
    /// the rows it has and says what is missing (dashboards.md rule 6).
    pub errors: Vec<String>,
}

/// The document from what was read. `state` is fleet-sessions' state document (Null when it
/// could not be read), `items` and `stats` agent-queue's, `candidates` the last dispatch pass's
/// snapshot; a source that failed is named in `errors` and leaves its part empty.
pub fn build(
    state: &Value,
    items: Result<Vec<queue::Item>, String>,
    stats: Result<Stats, String>,
    candidates: Result<Candidates, String>,
    now: i64,
) -> Bar {
    let mut bar = Bar {
        as_of: now,
        ..Bar::default()
    };
    let queue = Queue::from_reads(items, stats);
    bar.errors.extend(queue.errors.iter().cloned());
    bar.drain = queue
        .stats
        .as_ref()
        .and_then(|s| s.recent.as_ref())
        .map(flow::drain);

    let fresh = Reading::of_age(
        state["generated_epoch"].as_i64(),
        now,
        FLEET_STATE_STALE_SECS,
    );
    match fresh {
        Reading::Live => bar.sessions = sessions(state, &queue),
        other => bar.errors.push(other.words("fleet state")),
    }
    bar.errors.extend(session_table::silent(state));

    bar.ready = ready(&queue, now);
    match candidates {
        Ok(c) if stale(&c, now) => bar.errors.push(format!(
            "dispatch candidates: the snapshot was written {} ago, so its rows are not shown",
            crate::display::fmt::age(now - c.written_epoch().unwrap_or(0))
        )),
        Ok(c) => {
            bar.candidates = c
                .rows
                .iter()
                .filter(|r| r.blocked.is_empty())
                .take(CANDIDATES_SENT)
                .map(|r| BarCandidate {
                    project: r.project.clone(),
                    key: r.key.clone(),
                    priority: r.priority.clone(),
                    title: r.title(),
                })
                .collect()
        }
        Err(e) => bar.errors.push(format!("dispatch candidates: {e}")),
    }
    bar
}

/// A snapshot older than `CANDIDATES_STALE_SECS` at `now`; one with no mtime counts as current, since
/// its rows came from no file.
fn stale(c: &Candidates, now: i64) -> bool {
    c.written_epoch()
        .is_some_and(|t| now - t > CANDIDATES_STALE_SECS)
}

fn sessions(state: &Value, queue: &Queue) -> Vec<BarSession> {
    let vocab = Vocab::from_state(state);
    let docs: Vec<Value> = state["sessions"]
        .as_array()
        .into_iter()
        .flatten()
        .filter(|s| is_live(s) && !is_machine(s))
        .cloned()
        .collect();
    let feed = Feed {
        items: queue.items.clone(),
        ..Feed::default()
    };
    let mut rows: Vec<SessionRow> = session_table::rows(&docs, &vocab, &feed, &[])
        .into_iter()
        .filter(|r| r.source == Source::Live)
        .collect();
    // rows() orders by bucket then target; within a bucket the session waiting longest is worst.
    rows.sort_by_key(|r| {
        (
            vocab.rank(&r.bucket),
            std::cmp::Reverse(r.idle_min.unwrap_or(-1)),
        )
    });
    rows.into_iter().map(BarSession::from).collect()
}

fn ready(queue: &Queue, now: i64) -> Ready {
    let at = chrono::DateTime::from_timestamp(now, 0).unwrap_or_default();
    let ready: Vec<&queue::Item> = queue
        .rows(at)
        .into_iter()
        .filter(|r| r.start.is_some())
        .map(|r| r.item)
        .collect();
    let n = |p: &str| ready.iter().filter(|i| i.priority.trim() == p).count();
    Ready {
        total: ready.len(),
        urgent: n("urgent"),
        high: n("high"),
        items: ready
            .iter()
            .take(READY_SENT)
            .map(|i| {
                // An item added with no `type` header still has its `type(area):` in the task.
                let said = crate::text::clean(&i.task);
                BarItem {
                    slug: i.slug.clone(),
                    project: i.project.clone(),
                    priority: i.priority.trim().to_string(),
                    kind: i.kind.clone().or(said.kind).unwrap_or_default(),
                    area: i.area.clone().or(said.area).unwrap_or_default(),
                    title: i.title(),
                    ready_min: i.ready_min(at),
                }
            })
            .collect(),
    }
}

/// Read every source and build the document. The queue reads and the candidates file are cheap;
/// the whole run is a few `agent-queue` calls and no Prometheus read.
pub fn gather() -> Bar {
    use crate::session_actions::System;
    let (items, stats) = std::thread::scope(|s| {
        let stats = s.spawn(|| queue::stats(&System));
        (
            queue::list(&System, "all"),
            stats
                .join()
                .unwrap_or_else(|_| Err("agent-queue stats: panicked".into())),
        )
    });
    let state: Value = std::fs::read_to_string(crate::boards::fleet_state())
        .ok()
        .and_then(|t| serde_json::from_str(&t).ok())
        .unwrap_or_default();
    build(
        &state,
        items,
        stats,
        queue::candidates(&crate::boards::candidates_file()),
        chrono::Utc::now().timestamp(),
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    const NOW: i64 = 1_794_000_000;

    fn state(sessions: Value) -> Value {
        json!({"generated_epoch": NOW - 30, "vocab": {"buckets": [
            "NEEDS", "STALLED", "DONE", "LANDED", "CHAT", "WORKING", "PARKED"],
            "finished": ["DONE", "LANDED"]}, "sessions": sessions})
    }

    fn sess(target: &str, bucket: &str, idle: i64, reason: &str) -> Value {
        json!({"target": target, "bucket": bucket, "session_id": target, "project": "dotfiles",
            "topic": format!("topic of {target}"), "idle_min": idle, "reason": reason, "pr": "-",
            "item": null})
    }

    fn item(slug: &str, state: &str, priority: &str, task: &str) -> queue::Item {
        queue::parse(
            &json!({"slug": slug, "state": state, "priority": priority, "project": "dotfiles",
                "task": task, "queued": "2026-11-21T10:00:00Z"})
            .to_string(),
        )
        .remove(0)
    }

    fn cand(key: &str, blocked: &[&str]) -> String {
        json!({"project": "playground", "key": key, "text": format!("- [ ] chore(tests): {key} #high"),
            "priority": "high", "blocked": blocked})
        .to_string()
    }

    fn built(sessions: Value, items: Vec<queue::Item>) -> Bar {
        build(
            &state(sessions),
            Ok(items),
            Ok(Stats::default()),
            Ok(queue::parse_candidates("")),
            NOW,
        )
    }

    #[test]
    fn sessions_come_worst_bucket_first_then_the_longest_idle() {
        let bar = built(
            json!([
                sess("lab/a:1", "WORKING", 1, "idle 1m"),
                sess("lab/b:1", "NEEDS", 5, "1 pending ask(s)"),
                sess("lab/c:1", "STALLED", 90, "PR #1 CI red"),
                sess("lab/d:1", "NEEDS", 30, "1 pending ask(s)"),
            ]),
            vec![],
        );
        let order: Vec<&str> = bar.sessions.iter().map(|s| s.target.as_str()).collect();
        assert_eq!(order, ["lab/d:1", "lab/b:1", "lab/c:1", "lab/a:1"]);
        assert_eq!(bar.sessions[0].reason, "1 pending ask(s)");
        assert_eq!(bar.sessions[0].task, "topic of lab/d:1");
    }

    #[test]
    fn the_fleets_own_panes_and_parked_sessions_are_not_rows() {
        let mut shepherd = sess("lab/s:1", "WORKING", 0, "");
        shepherd["labels"] = json!(["shepherd"]);
        let bar = built(
            json!([
                shepherd,
                sess("lab/n:1", "NIGHTLY", 0, ""),
                sess("lab/p:1", "PARKED", 0, ""),
                sess("lab/a:1", "LANDED", 4, "PR merged"),
            ]),
            vec![],
        );
        assert_eq!(bar.sessions.len(), 1);
        assert!(bar.sessions[0].done);
    }

    #[test]
    fn a_session_is_titled_by_its_queue_item() {
        let mut s = sess("lab/a:1", "WORKING", 2, "idle 2m");
        s["item"] = json!({"slug": "w1", "is": "own"});
        let bar = built(
            json!([s]),
            vec![item("w1", "running", "high", "feat(hub): the item words")],
        );
        assert_eq!(bar.sessions[0].task, "the item words");
        assert_eq!(bar.sessions[0].item, "w1");
    }

    #[test]
    fn a_stale_state_document_sends_no_sessions_and_says_so() {
        let mut st = state(json!([sess("lab/a:1", "NEEDS", 5, "")]));
        st["generated_epoch"] = json!(NOW - 3 * FLEET_STATE_STALE_SECS);
        let bar = build(
            &st,
            Ok(vec![]),
            Ok(Stats::default()),
            Ok(Candidates::default()),
            NOW,
        );
        assert!(bar.sessions.is_empty());
        assert!(
            bar.errors
                .iter()
                .any(|e| e.contains("fleet state stopped reporting")),
            "{:?}",
            bar.errors
        );
    }

    #[test]
    fn a_silent_worker_is_named_beside_the_rows_that_remain() {
        let mut st = state(json!([sess("lab/a:1", "NEEDS", 5, "")]));
        st["silent"] = json!([{"host": "razer-laptop", "why": "ssh timed out"}]);
        let bar = build(
            &st,
            Ok(vec![]),
            Ok(Stats::default()),
            Ok(Candidates::default()),
            NOW,
        );
        assert_eq!(bar.sessions.len(), 1);
        assert!(bar.errors.iter().any(|e| e.contains("razer-laptop")));
    }

    #[test]
    fn ready_items_keep_agent_queues_order_and_count_by_priority() {
        let items = vec![
            item(
                "u",
                "queued",
                "urgent",
                "check(alert): HomelabCronJobFailed freqtrade",
            ),
            item("h", "queued", "high", "chore(tests): finish fix-skip"),
            item("r", "running", "urgent", "not ready"),
            item("l", "queued", "low", "docs: low one"),
        ];
        let bar = built(json!([]), items);
        assert_eq!(bar.ready.total, 3);
        assert_eq!((bar.ready.urgent, bar.ready.high), (1, 1));
        let slugs: Vec<&str> = bar.ready.items.iter().map(|i| i.slug.as_str()).collect();
        assert_eq!(slugs, ["u", "h", "l"]);
        assert_eq!(bar.ready.items[0].title, "HomelabCronJobFailed freqtrade");
        assert_eq!(bar.ready.items[0].kind, "check");
        assert_eq!(bar.ready.items[0].area, "alert");
        assert!(bar.ready.items[0].ready_min.is_some());
    }

    #[test]
    fn only_the_first_ready_items_are_sent_but_all_are_counted() {
        let items: Vec<_> = (0..READY_SENT + 5)
            .map(|n| item(&format!("i{n}"), "queued", "high", "fix(x): a thing"))
            .collect();
        let bar = built(json!([]), items);
        assert_eq!(bar.ready.total, READY_SENT + 5);
        assert_eq!(bar.ready.items.len(), READY_SENT);
    }

    #[test]
    fn candidates_are_the_first_cleared_rows_only() {
        let body = [
            cand("blocked-1", &["no worker covers trader"]),
            cand("clear-1", &[]),
            cand("clear-2", &[]),
            cand("clear-3", &[]),
            cand("clear-4", &[]),
        ]
        .join("\n");
        let bar = build(
            &state(json!([])),
            Ok(vec![]),
            Ok(Stats::default()),
            Ok(queue::parse_candidates(&body)),
            NOW,
        );
        let keys: Vec<&str> = bar.candidates.iter().map(|c| c.key.as_str()).collect();
        assert_eq!(keys, ["clear-1", "clear-2", "clear-3"]);
        assert_eq!(bar.candidates[0].title, "clear-1");
    }

    #[test]
    fn a_stale_candidates_snapshot_is_named_and_its_rows_are_not_shown() {
        let at = |age: i64| {
            let mut c = queue::parse_candidates(&cand("clear-1", &[]));
            c.written =
                Some(std::time::UNIX_EPOCH + std::time::Duration::from_secs((NOW - age) as u64));
            c
        };
        let st = state(json!([]));
        let run = |c| build(&st, Ok(vec![]), Ok(Stats::default()), Ok(c), NOW);
        let old = run(at(2 * CANDIDATES_STALE_SECS));
        assert!(old.candidates.is_empty());
        assert!(
            old.errors
                .iter()
                .any(|e| e.contains("snapshot was written")),
            "{:?}",
            old.errors
        );
        // Negative control: a fresh snapshot shows its rows and says nothing.
        let fresh = run(at(60));
        assert_eq!(fresh.candidates.len(), 1);
        assert!(fresh.errors.is_empty(), "{:?}", fresh.errors);
    }

    #[test]
    fn a_source_that_failed_is_named_and_leaves_its_part_empty() {
        let bar = build(
            &state(json!([sess("lab/a:1", "NEEDS", 5, "")])),
            Err("boom".into()),
            Err("agent-queue stats: boom".into()),
            Err("no snapshot yet".into()),
            NOW,
        );
        assert_eq!(bar.sessions.len(), 1);
        assert_eq!(bar.ready.total, 0);
        assert!(bar.candidates.is_empty());
        assert!(bar.drain.is_none());
        assert_eq!(bar.errors.len(), 3, "{:?}", bar.errors);
    }

    #[test]
    fn the_drain_is_the_flow_rule_over_the_recent_counts() {
        let stats = Stats {
            recent: Some(queue::Recent {
                added_6h: 9,
                done_6h: 4,
                ..queue::Recent::default()
            }),
            ..Stats::default()
        };
        let bar = build(
            &state(json!([])),
            Ok(vec![]),
            Ok(stats),
            Ok(Candidates::default()),
            NOW,
        );
        assert_eq!(bar.drain.as_deref(), Some("6h +9/-4 growing"));
    }

    #[test]
    fn the_document_is_one_line_of_json_with_every_part() {
        let bar = built(json!([sess("lab/a:1", "NEEDS", 5, "x")]), vec![]);
        let line = serde_json::to_string(&bar).unwrap();
        assert!(!line.contains('\n'));
        let v: Value = serde_json::from_str(&line).unwrap();
        for k in [
            "as_of",
            "sessions",
            "ready",
            "candidates",
            "drain",
            "errors",
        ] {
            assert!(v.get(k).is_some(), "missing {k}");
        }
    }
}
