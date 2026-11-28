//! What the waybar and noctalia hovers (the queue and sessions chips) lay out as text: the live
//! sessions worst first, the items ready to start in agent-queue's order, the top cleared board
//! candidates, the drain and each machine's share of the sessions. One document, `hub bar --json`, so the chips only lay it out
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

/// How old a dispatch snapshot (the candidates, the workers' slots) may be before its rows are dropped
/// and named stale. Provisional (2026-11-21): a pass writes both every few minutes (7 min old when
/// measured), so an hour of silence is a stopped dispatch, not a quiet one; revisit when a held
/// dispatch shows this line wrongly.
pub const SNAPSHOT_STALE_SECS: i64 = 3600;

/// The bucket a session is stuck in, which the Machines line counts per host.
const STUCK: &str = "STALLED";

/// The machine named for a live row with no host when the state document names none (one written
/// before it carried `host`).
const HERE: &str = "local";

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
    /// The machine it runs on: its fleet worker, else the one that wrote the state document.
    pub host: String,
    /// The harness it runs on (`SessionRow::harness`): claude, claude-lazer, codex, agy.
    pub harness: String,
    /// The model it runs (`SessionRow::model`), empty before its first turn.
    pub model: String,
    /// It was started as a trainee run.
    pub trainee: bool,
    /// What it runs on in one word, the key the Machines line counts by and the chip's model column:
    /// `trainee:<model>` for a trainee run, the model for a claude session (`-` before its first
    /// turn), else the harness (codex, agy, claude-lazer).
    pub runs_on: String,
}

/// `BarSession::runs_on`.
fn runs_on(r: &SessionRow) -> String {
    let model = if r.model.is_empty() { "-" } else { &r.model };
    if r.trainee {
        format!("trainee:{model}")
    } else if r.harness.is_empty() || r.harness == queue::HARNESS_DEFAULT {
        model.to_string()
    } else {
        r.harness.clone()
    }
}

impl From<SessionRow> for BarSession {
    fn from(r: SessionRow) -> BarSession {
        let runs_on = runs_on(&r);
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
            host: r.host,
            harness: r.harness,
            model: r.model,
            trainee: r.trainee,
            runs_on,
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

/// A name and how many sessions it has, one part of a Machines line.
#[derive(Clone, Debug, Default, PartialEq, Serialize)]
pub struct Count {
    pub name: String,
    pub n: usize,
}

/// One machine's share of the live sessions, a Machines line of the sessions chip. Counted over
/// `Bar::sessions`, so the fleet's own panes are not in it.
#[derive(Clone, Debug, Default, PartialEq, Serialize)]
pub struct BarHost {
    pub name: String,
    pub live: usize,
    /// Per tmux space (the server of its target: `lab`, `hub`), most first.
    pub spaces: Vec<Count>,
    /// Per `BarSession::runs_on`, most first.
    pub models: Vec<Count>,
    /// Its sessions in the STALLED bucket.
    pub stuck: usize,
    /// A fleet worker's session cap and its free slots, from the last dispatch pass's snapshot
    /// (`fleet-dispatch hosts --json`); None for a machine that is no worker, or while the snapshot
    /// is stale or unread (named in `errors`).
    pub max_live: Option<i64>,
    pub free: Option<i64>,
}

/// The workers' slots as the last dispatch pass read them (`fleet-dispatch` `hosts_write`).
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Workers {
    /// (name, max_live, free) per worker in the roster.
    pub rows: Vec<(String, Option<i64>, Option<i64>)>,
    /// The file's mtime, None when the rows came from no file.
    pub written: Option<std::time::SystemTime>,
}

impl Workers {
    /// The `hosts.json` body: one JSON array of `hosts --json` rows. A row with no name is skipped.
    pub fn parse(body: &str) -> Result<Workers, String> {
        let v: Vec<Value> =
            serde_json::from_str(body).map_err(|e| format!("not a JSON array: {e}"))?;
        let rows = v
            .iter()
            .filter_map(|h| {
                let name = h["name"].as_str().filter(|n| !n.is_empty())?;
                Some((name.to_string(), h["max_live"].as_i64(), h["free"].as_i64()))
            })
            .collect();
        Ok(Workers {
            rows,
            written: None,
        })
    }

    fn written_epoch(&self) -> Option<i64> {
        self.written
            .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
            .map(|d| d.as_secs() as i64)
    }
}

/// Read the workers' snapshot at `path`.
pub fn workers(path: &std::path::Path) -> Result<Workers, String> {
    let body = std::fs::read_to_string(path).map_err(|e| match e.kind() {
        std::io::ErrorKind::NotFound => format!(
            "no snapshot yet at {}, the next dispatch pass writes one",
            path.display()
        ),
        _ => format!("{}: {e}", path.display()),
    })?;
    let mut w = Workers::parse(&body).map_err(|e| format!("{}: {e}", path.display()))?;
    w.written = std::fs::metadata(path).and_then(|m| m.modified()).ok();
    Ok(w)
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
    /// Each machine with a live session or a worker slot, most sessions first, then by name.
    pub hosts: Vec<BarHost>,
    /// `<source>: <why>` for each source that could not be read or is stale: a reader shows
    /// the rows it has and says what is missing (dashboards.md rule 6).
    pub errors: Vec<String>,
}

/// The document from what was read. `state` is fleet-sessions' state document (Null when it
/// could not be read), `items` and `stats` agent-queue's, `candidates` and `workers` the last
/// dispatch pass's snapshots; a source that failed is named in `errors` and leaves its part empty.
pub fn build(
    state: &Value,
    items: Result<Vec<queue::Item>, String>,
    stats: Result<Stats, String>,
    candidates: Result<Candidates, String>,
    workers: Result<Workers, String>,
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
        Ok(c) if stale(c.written_epoch(), now) => bar.errors.push(format!(
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
    let slots = match workers {
        Ok(w) if stale(w.written_epoch(), now) => {
            bar.errors.push(format!(
                "dispatch hosts: the snapshot was written {} ago, so the workers' slots are not shown",
                crate::display::fmt::age(now - w.written_epoch().unwrap_or(0))
            ));
            vec![]
        }
        Ok(w) => w.rows,
        Err(e) => {
            bar.errors.push(format!("dispatch hosts: {e}"));
            vec![]
        }
    };
    bar.hosts = hosts(&bar.sessions, &slots);
    bar
}

/// The tmux space of a target, `[<host>@]<server>/<session>:<window>`: its server.
fn space(target: &str) -> &str {
    let t = target.split_once('@').map_or(target, |(_, t)| t);
    t.split_once('/').map_or("-", |(server, _)| server)
}

/// Each name and its count, most first, then by name.
fn counts<'a>(names: impl Iterator<Item = &'a str>) -> Vec<Count> {
    let mut by: std::collections::BTreeMap<&str, usize> = std::collections::BTreeMap::new();
    for n in names {
        *by.entry(n).or_default() += 1;
    }
    let mut out: Vec<Count> = by
        .into_iter()
        .map(|(name, n)| Count {
            name: name.to_string(),
            n,
        })
        .collect();
    out.sort_by_key(|c| std::cmp::Reverse(c.n));
    out
}

/// The Machines roll-up: every host a session names, and every worker in the slots snapshot, which
/// gives a worker its `max_live` and `free` (a worker with no session still shows its slots).
fn hosts(sessions: &[BarSession], slots: &[(String, Option<i64>, Option<i64>)]) -> Vec<BarHost> {
    let mut names: Vec<&str> = sessions.iter().map(|s| s.host.as_str()).collect();
    names.extend(slots.iter().map(|(n, _, _)| n.as_str()));
    names.sort_unstable();
    names.dedup();
    let mut out: Vec<BarHost> = names
        .into_iter()
        .map(|name| {
            let on: Vec<&BarSession> = sessions.iter().filter(|s| s.host == name).collect();
            let slot = slots.iter().find(|(n, _, _)| n == name);
            BarHost {
                name: name.to_string(),
                live: on.len(),
                spaces: counts(on.iter().map(|s| space(&s.target))),
                models: counts(on.iter().map(|s| s.runs_on.as_str())),
                stuck: on.iter().filter(|s| s.bucket == STUCK).count(),
                max_live: slot.and_then(|s| s.1),
                free: slot.and_then(|s| s.2),
            }
        })
        .collect();
    out.sort_by_key(|h| std::cmp::Reverse(h.live));
    out
}

/// A snapshot older than `SNAPSHOT_STALE_SECS` at `now`; one with no mtime counts as current, since
/// its rows came from no file.
fn stale(written: Option<i64>, now: i64) -> bool {
    written.is_some_and(|t| now - t > SNAPSHOT_STALE_SECS)
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
    // A row with no host runs on the machine that wrote the document.
    let here = state["host"]
        .as_str()
        .filter(|h| !h.is_empty())
        .unwrap_or(HERE);
    rows.into_iter()
        .map(|r| {
            let mut s = BarSession::from(r);
            if s.host.is_empty() {
                s.host = here.to_string();
            }
            s
        })
        .collect()
}

pub fn ready(queue: &Queue, now: i64) -> Ready {
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

/// Read every source and build the document. The queue reads and the snapshot files are cheap;
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
        workers(&crate::boards::dispatch_hosts_file()),
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
            Ok(Workers::default()),
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

    /// A queue item with these extra headers (`agent`, `model`, `trainee`).
    fn item_with(slug: &str, extra: Value) -> queue::Item {
        let mut v = json!({"slug": slug, "state": "running", "priority": "high", "project": "dotfiles",
            "task": "fix(x): a thing", "queued": "2026-11-21T10:00:00Z"});
        v.as_object_mut()
            .unwrap()
            .extend(extra.as_object().unwrap().clone());
        queue::parse(&v.to_string()).remove(0)
    }

    fn workers_at(rows: Value, age: i64) -> Workers {
        let mut w = Workers::parse(&rows.to_string()).unwrap();
        w.written =
            Some(std::time::UNIX_EPOCH + std::time::Duration::from_secs((NOW - age) as u64));
        w
    }

    #[test]
    fn a_session_carries_its_host_harness_model_and_trainee() {
        let mut here = sess("lab/a:1", "WORKING", 1, "");
        here["model"] = json!("claude-opus-5-5");
        let mut codex = sess("razer-laptop@lab/b:1", "WORKING", 2, "");
        codex["host"] = json!("razer-laptop");
        codex["item"] = json!({"slug": "cx", "is": "own"});
        let mut trn = sess("hub/c:1", "WORKING", 3, "");
        trn["item"] = json!({"slug": "tr", "is": "own"});
        let mut ran = sess("lab/d:1", "WORKING", 4, "");
        ran["model"] = json!("claude-sonnet-5-5[1m]");
        ran["item"] = json!({"slug": "op", "is": "own"});
        let fresh = sess("lab/e:1", "WORKING", 5, "");
        let mut st = state(json!([here, codex, trn, ran, fresh]));
        st["host"] = json!("workstation");
        let items = vec![
            item_with("cx", json!({"agent": "codex", "model": "sol"})),
            item_with(
                "tr",
                json!({"agent": "opencode-go", "model": "qwen", "trainee": "opencode-go:qwen"}),
            ),
            item_with("op", json!({"model": "opus"})),
        ];
        let bar = build(
            &st,
            Ok(items),
            Ok(Stats::default()),
            Ok(Candidates::default()),
            Ok(Workers::default()),
            NOW,
        );
        let by = |t: &str| bar.sessions.iter().find(|s| s.target == t).unwrap();
        let a = by("lab/a:1");
        assert_eq!(
            (a.host.as_str(), a.harness.as_str(), a.model.as_str()),
            ("workstation", "claude", "opus")
        );
        assert_eq!(a.runs_on, "opus");
        let b = by("razer-laptop@lab/b:1");
        assert_eq!(
            (b.host.as_str(), b.harness.as_str(), b.model.as_str()),
            ("razer-laptop", "codex", "sol")
        );
        assert_eq!(
            b.runs_on, "codex",
            "a harness that is not claude is named by the harness"
        );
        let c = by("hub/c:1");
        assert!(c.trainee);
        assert_eq!(c.runs_on, "trainee:qwen");
        // The model the transcript names wins over the one the item asked for.
        assert_eq!(by("lab/d:1").model, "sonnet");
        // Negative control: no turn yet and no item model is no model, never a guess.
        let e = by("lab/e:1");
        assert_eq!(
            (e.model.as_str(), e.runs_on.as_str(), e.trainee),
            ("", "-", false)
        );
    }

    #[test]
    fn each_machine_counts_its_sessions_by_space_and_model_with_a_workers_slots() {
        let on = |t: &str, bucket: &str, host: Option<&str>, model: &str| {
            let mut s = sess(t, bucket, 1, "");
            s["model"] = json!(model);
            if let Some(h) = host {
                s["host"] = json!(h);
            }
            s
        };
        let mut st = state(json!([
            on("lab/a:1", "WORKING", None, "opus"),
            on("lab/b:1", "NEEDS", None, "opus"),
            on("hub/c:1", "WORKING", None, "sonnet"),
            on(
                "razer-laptop@lab/d:1",
                "STALLED",
                Some("razer-laptop"),
                "opus"
            ),
            on(
                "razer-laptop@lab/e:1",
                "WORKING",
                Some("razer-laptop"),
                "sonnet"
            ),
        ]));
        st["host"] = json!("workstation");
        let slots = json!([{"name": "razer-laptop", "max_live": 7, "free": 1},
            {"name": "hp-victus", "max_live": 2, "free": 2}]);
        let run = |w| {
            build(
                &st,
                Ok(vec![]),
                Ok(Stats::default()),
                Ok(Candidates::default()),
                w,
                NOW,
            )
        };
        let bar = run(Ok(workers_at(slots.clone(), 60)));
        let names: Vec<&str> = bar.hosts.iter().map(|h| h.name.as_str()).collect();
        assert_eq!(
            names,
            ["workstation", "razer-laptop", "hp-victus"],
            "most sessions first"
        );
        let ws = &bar.hosts[0];
        assert_eq!(
            (ws.live, ws.stuck, ws.max_live, ws.free),
            (3, 0, None, None)
        );
        let c = |v: &[Count]| {
            v.iter()
                .map(|c| format!("{} {}", c.name, c.n))
                .collect::<Vec<_>>()
        };
        assert_eq!(c(&ws.spaces), ["lab 2", "hub 1"]);
        assert_eq!(c(&ws.models), ["opus 2", "sonnet 1"]);
        let rz = &bar.hosts[1];
        assert_eq!(
            (rz.live, rz.stuck, rz.max_live, rz.free),
            (2, 1, Some(7), Some(1))
        );
        assert_eq!(c(&rz.spaces), ["lab 2"], "the host@ prefix is not a space");
        // A worker with no session still shows its slots.
        assert_eq!((bar.hosts[2].live, bar.hosts[2].free), (0, Some(2)));
        // The per-host counts add up to the sessions sent: one count, no second source.
        assert_eq!(
            bar.hosts.iter().map(|h| h.live).sum::<usize>(),
            bar.sessions.len()
        );
        assert!(bar.errors.is_empty(), "{:?}", bar.errors);
        // Negative control: a stale snapshot drops every slot and says so; the live counts stay.
        let old = run(Ok(workers_at(slots, 2 * SNAPSHOT_STALE_SECS)));
        assert!(old
            .hosts
            .iter()
            .all(|h| h.max_live.is_none() && h.free.is_none()));
        assert_eq!(
            old.hosts.len(),
            2,
            "a worker known only from a stale snapshot has no line"
        );
        assert!(
            old.errors
                .iter()
                .any(|e| e.contains("workers' slots are not shown")),
            "{:?}",
            old.errors
        );
    }

    #[test]
    fn a_hosts_snapshot_that_is_not_an_array_is_an_error_not_an_empty_roster() {
        assert!(Workers::parse("{}").is_err());
        assert_eq!(Workers::parse("[]").unwrap().rows, vec![]);
        let w =
            Workers::parse(r#"[{"name":"r","max_live":3,"free":null},{"max_live":1}]"#).unwrap();
        assert_eq!(w.rows, vec![("r".to_string(), Some(3), None)]);
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
            Ok(Workers::default()),
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
            Ok(Workers::default()),
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
            Ok(Workers::default()),
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
        let run = |c| {
            build(
                &st,
                Ok(vec![]),
                Ok(Stats::default()),
                Ok(c),
                Ok(Workers::default()),
                NOW,
            )
        };
        let old = run(at(2 * SNAPSHOT_STALE_SECS));
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
            Err("no snapshot yet".into()),
            NOW,
        );
        assert_eq!(bar.sessions.len(), 1);
        assert_eq!(bar.ready.total, 0);
        assert!(bar.candidates.is_empty());
        assert!(bar.drain.is_none());
        assert_eq!(bar.errors.len(), 4, "{:?}", bar.errors);
        assert!(
            bar.errors.iter().any(|e| e.starts_with("dispatch hosts:")),
            "{:?}",
            bar.errors
        );
        // The machine still has its line from the sessions, with no slots.
        assert_eq!(bar.hosts.len(), 1);
        assert_eq!((bar.hosts[0].live, bar.hosts[0].max_live), (1, None));
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
            Ok(Workers::default()),
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
            "hosts",
            "errors",
        ] {
            assert!(v.get(k).is_some(), "missing {k}");
        }
    }
}
