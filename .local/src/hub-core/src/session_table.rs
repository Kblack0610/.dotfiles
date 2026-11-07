//! The Sessions table on both surfaces: every session in `fleet-sessions`' state document, then
//! the sessions that ended, so done stays visible after a window closes. An ended row comes from
//! today's finished queue items that ran a session or landed a PR, or from an outcome row
//! (`agentctl-session-outcomes ended`) for a session with no item, which only exists after the
//! nightly run; each row names its source.
//! Filtering, sorting and the chips are `crate::table`'s; this module is the join.

use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};

use agent_panel::chooser::Agent;
use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::fleet::ts;
use crate::home::str_of;
use crate::queue::{self, Item};
use crate::session_actions::{argv, Runner, Session};
use crate::table::{Row, Val};
use crate::text::headline;
use crate::vocab::Vocab;

/// How far back outcome rows go. Outcomes are written once a night, so this reaches over the
/// last run rather than a calendar day, which would be empty for most of it.
pub const ENDED_DAYS: u32 = 1;

/// The shepherd's session and the NIGHTLY and SHARED rows: the fleet's own, not anyone's task.
pub fn is_machine(s: &Value) -> bool {
    let shepherd = s["labels"]
        .as_array()
        .is_some_and(|l| l.iter().any(|x| x == "shepherd"));
    shepherd || matches!(s["bucket"].as_str(), Some("NIGHTLY" | "SHARED"))
}

/// A session the header counts as live: a parked one is in the table but not at work.
pub fn is_live(s: &Value) -> bool {
    s["bucket"].as_str() != Some("PARKED")
}

/// A session that should have a queue item and has none: the `agent_sessions_unlinked` gauge's
/// definition, which `fleet-sessions` publishes from the same document.
pub fn is_unlinked(s: &Value) -> bool {
    !is_machine(s) && s["item"].is_null()
}

/// Where a row came from.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum Source {
    /// A row of the state document: a session alive now.
    #[default]
    Live,
    /// A queue item that finished today.
    Queue,
    /// A nightly outcome row, for a session with no queue item.
    Outcome,
}

impl Source {
    pub fn name(self) -> &'static str {
        match self {
            Source::Live => "live",
            Source::Queue => "queue",
            Source::Outcome => "outcome",
        }
    }
}

/// One row of the table.
#[derive(Clone, Debug, Default, PartialEq, Serialize)]
pub struct SessionRow {
    /// What the selection follows: the target of a live row, else the item or session id.
    pub key: String,
    pub bucket: String,
    pub project: String,
    /// The queue item's title, else the session's topic.
    pub task: String,
    /// The queue item, empty when it has none.
    pub item: String,
    /// `<target>` while the session has one.
    pub target: String,
    pub session_id: String,
    pub pr: Option<String>,
    /// The PR's state word, `open`, `merged` or `closed`.
    pub pr_state: String,
    pub ci: String,
    pub phases_done: Option<i64>,
    pub phases_total: Option<i64>,
    pub idle_min: Option<i64>,
    /// What an ended row's idle column says instead: `ended`, or the item's non-ok status.
    pub ended: String,
    /// When it ended, unix seconds.
    pub finished: Option<i64>,
    pub cost_usd: Option<f64>,
    /// A live row's item across all its sessions, which is what the item's budget holds. A queue
    /// row has none: its `cost_usd` already is that.
    pub item_cost_usd: Option<f64>,
    pub account: String,
    pub source: Source,
    /// This live session counts as having no queue item (`item:none`).
    pub unlinked: bool,
}

impl Row for SessionRow {
    const COLUMNS: &'static [&'static str] = &[
        "bucket", "project", "task", "pr", "phases", "idle", "cost", "acct", "item", "source",
        "session",
    ];
    /// `all` comes first because the first chip keeps every row.
    const STATES: &'static [&'static str] =
        &["all", "running", "needs you", "stalled", "done today"];
    const FACETS: &'static [&'static str] = &["project"];

    fn val(&self, col: &str) -> Val {
        let text = |s: &str| {
            if s.is_empty() {
                Val::None
            } else {
                Val::Text(s.to_string())
            }
        };
        match col {
            "bucket" => text(&self.bucket),
            "project" => text(&self.project),
            "task" => text(&self.task),
            "pr" => text(&self.pr_state),
            "phases" => self.phases_done.map_or(Val::None, |n| Val::Num(n as f64)),
            "idle" => self.idle_min.map_or(Val::None, |n| Val::Num(n as f64)),
            "cost" => self.cost_usd.map_or(Val::None, Val::Num),
            "acct" => text(&self.account),
            "item" if self.unlinked => Val::Text("none".into()),
            "item" => text(&self.item),
            "source" => Val::Text(self.source.name().into()),
            "session" if self.target.is_empty() => text(&self.session_id),
            "session" => text(&self.target),
            _ => Val::None,
        }
    }

    fn in_state(&self, s: &str) -> bool {
        match s {
            "running" => {
                self.source == Source::Live
                    && !matches!(
                        self.bucket.as_str(),
                        "NEEDS" | "STALLED" | "DONE" | "PARKED"
                    )
            }
            "needs you" => self.bucket == "NEEDS",
            "stalled" => self.bucket == "STALLED",
            "done today" => self.bucket == "DONE",
            _ => false,
        }
    }
}

/// One `agentctl-session-outcomes ended` row.
#[derive(Clone, Debug, Default, PartialEq, Deserialize)]
#[serde(default)]
pub struct Ended {
    pub session_id: String,
    pub project: String,
    pub title: String,
    pub account: Option<String>,
    pub cost_usd: Option<f64>,
    pub updated_epoch: Option<i64>,
    pub prs_merged: i64,
    pub prs_open: i64,
}

/// What the table reads beyond the state document.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Feed {
    /// The active items and today's finished ones (`agent-queue list --state all`).
    pub items: Vec<Item>,
    pub ended: Vec<Ended>,
    /// Each session's cost so far, from the session registry.
    pub cost: HashMap<String, f64>,
    /// `<source>: <why>` for each source that could not be read.
    pub errors: Vec<String>,
}

/// The state document's `sessions` and its bucket vocabulary, empty when it is missing or
/// unreadable.
pub fn read_state(path: &Path) -> (Vec<Value>, Vocab) {
    let doc = std::fs::read_to_string(path)
        .ok()
        .and_then(|t| serde_json::from_str::<Value>(&t).ok())
        .unwrap_or_default();
    (
        doc["sessions"].as_array().cloned().unwrap_or_default(),
        Vocab::from_state(&doc),
    )
}

/// The session registry's root, `~/.agent/sessions`.
pub fn registry() -> PathBuf {
    PathBuf::from(std::env::var("HOME").unwrap_or_default()).join(".agent/sessions")
}

/// Every row of `<root>/<project>/sessions.jsonl`, which the Stop hook appends to, oldest first
/// within a project.
fn registry_rows(root: &Path) -> impl Iterator<Item = Value> {
    std::fs::read_dir(root)
        .into_iter()
        .flatten()
        .flatten()
        .filter_map(|d| std::fs::read_to_string(d.path().join("sessions.jsonl")).ok())
        .flat_map(|text| {
            text.lines()
                .filter_map(|l| serde_json::from_str::<Value>(l).ok())
                .collect::<Vec<_>>()
        })
}

/// Each session's cost; a later row for a session replaces an earlier one.
pub fn costs(root: &Path) -> HashMap<String, f64> {
    let mut out = HashMap::new();
    for v in registry_rows(root) {
        if let (Some(id), Some(c)) = (v["session_id"].as_str(), v["cost_usd"].as_f64()) {
            out.insert(id.to_string(), c);
        }
    }
    out
}

/// The transcript the registry names for a session: once a session has ended no other store does.
pub fn transcript(root: &Path, session_id: &str) -> Option<PathBuf> {
    registry_rows(root)
        .filter(|v| v["session_id"] == session_id)
        .filter_map(|v| v["transcript"].as_str().map(PathBuf::from))
        .last()
}

fn ended_argv() -> Vec<String> {
    let days = ENDED_DAYS.to_string();
    argv(&["agentctl-session-outcomes", "ended", "--days", &days])
}

/// Read the feed. A source that fails leaves its part empty and says so in `errors`.
pub fn feed(runner: &dyn Runner, registry: &Path) -> Feed {
    let mut errors = vec![];
    let items = queue::list(runner, "all")
        .map_err(|e| errors.push(format!("agent-queue: {e}")))
        .unwrap_or_default();
    let ended = runner
        .run(&ended_argv())
        .map(|o| {
            o.lines()
                .filter_map(|l| serde_json::from_str(l).ok())
                .collect()
        })
        .map_err(|e| errors.push(format!("session outcomes: {e}")))
        .unwrap_or_default();
    Feed {
        items,
        ended,
        cost: costs(registry),
        errors,
    }
}

fn live_row(s: &Value, feed: &Feed, items: &HashMap<&str, &Item>) -> SessionRow {
    let slug = str_of(&s["item"], "slug");
    let item = items.get(slug);
    let sid = str_of(s, "session_id");
    let topic = str_of(s, "topic");
    SessionRow {
        key: str_of(s, "target").to_string(),
        bucket: str_of(s, "bucket").to_string(),
        project: item.map_or_else(|| str_of(s, "project").to_string(), |i| i.project.clone()),
        task: item.map_or_else(|| headline(topic).0, |i| i.title()),
        item: slug.to_string(),
        target: str_of(s, "target").to_string(),
        session_id: sid.to_string(),
        pr: s["pr"]
            .as_str()
            .map(String::from)
            .or_else(|| s["pr"].as_i64().map(|n| n.to_string()))
            .filter(|p| p != "-"),
        pr_state: str_of(s, "pr_state").to_lowercase(),
        ci: str_of(s, "ci").to_string(),
        phases_done: s["phases_done"].as_i64(),
        phases_total: s["phases_total"].as_i64(),
        idle_min: s["idle_min"].as_i64(),
        cost_usd: feed.cost.get(sid).copied(),
        item_cost_usd: item.and_then(|i| {
            let mut sids = item_sessions(i);
            sids.push(sid.to_string());
            sids.sort();
            sids.dedup();
            item_cost(i, &sids, feed)
        }),
        account: str_of(s, "account").to_string(),
        unlinked: is_live(s) && is_unlinked(s),
        ..SessionRow::default()
    }
}

/// `owner/repo#12` as `12`; a bare number stays as it is.
fn pr_number(pr: &str) -> String {
    pr.rsplit('#').next().unwrap_or(pr).to_string()
}

/// The item's `sessions:` ids; the field holds one or a comma-separated list.
fn item_sessions(i: &Item) -> Vec<String> {
    extra_str(i, "sessions")
        .split([',', ' '])
        .filter(|s| !s.is_empty())
        .map(String::from)
        .collect()
}

fn extra_str(i: &Item, k: &str) -> String {
    i.extra
        .get(k)
        .and_then(Value::as_str)
        .unwrap_or("")
        .to_string()
}

/// An item's own cost once the nightly pass has summed it, else its sessions' registry cost.
fn item_cost(i: &Item, sids: &[String], feed: &Feed) -> Option<f64> {
    let own = ["gateway_cost_usd", "cost_usd"]
        .iter()
        .find_map(|k| i.extra.get(*k).and_then(Value::as_str)?.parse().ok());
    own.or_else(|| {
        let known: Vec<f64> = sids
            .iter()
            .filter_map(|s| feed.cost.get(s).copied())
            .collect();
        (!known.is_empty()).then(|| known.iter().sum())
    })
}

fn queue_row(i: &Item, feed: &Feed) -> SessionRow {
    let sids = item_sessions(i);
    let status = i.status.as_deref().unwrap_or("ok");
    let pr = i.pr.as_deref().filter(|p| !p.is_empty()).map(pr_number);
    let merged = !extra_str(i, "merged").is_empty();
    SessionRow {
        key: i.slug.clone(),
        bucket: "DONE".into(),
        project: i.project.clone(),
        task: i.title(),
        item: i.slug.clone(),
        session_id: sids.first().cloned().unwrap_or_default(),
        pr_state: if pr.is_none() {
            String::new()
        } else if merged {
            "merged".into()
        } else {
            "open".into()
        },
        pr,
        ended: if status == "ok" {
            "ended".into()
        } else {
            status.to_string()
        },
        finished: i.finished.as_deref().and_then(ts),
        cost_usd: item_cost(i, &sids, feed),
        account: extra_str(i, "account"),
        source: Source::Queue,
        ..SessionRow::default()
    }
}

fn outcome_row(e: &Ended) -> SessionRow {
    SessionRow {
        key: e.session_id.clone(),
        bucket: "DONE".into(),
        project: e.project.clone(),
        task: headline(&e.title).0,
        session_id: e.session_id.clone(),
        pr_state: match (e.prs_merged, e.prs_open) {
            (0, 0) => String::new(),
            (0, _) => "open".into(),
            _ => "merged".into(),
        },
        ended: "ended".into(),
        finished: e.updated_epoch,
        cost_usd: e.cost_usd,
        account: e.account.clone().unwrap_or_default(),
        source: Source::Outcome,
        ..SessionRow::default()
    }
}

/// Every row in the table's own order: live sessions by the vocabulary's bucket order (what needs
/// the human first), then by target, then the ended ones, newest first. An item or session that still has a live
/// row shows only there, and a session counted through its queue item shows only there.
pub fn rows(
    state: &[Value],
    vocab: &Vocab,
    feed: &Feed,
    agents: &[(Agent, Session)],
) -> Vec<SessionRow> {
    let items: HashMap<&str, &Item> = feed.items.iter().map(|i| (i.slug.as_str(), i)).collect();
    let mut live: Vec<SessionRow> = state.iter().map(|s| live_row(s, feed, &items)).collect();
    let strays: Vec<SessionRow> = agents
        .iter()
        .filter(|(a, _)| {
            !live.iter().any(|r| {
                r.target == a.target || (!a.session_id.is_empty() && r.session_id == a.session_id)
            })
        })
        .map(|(a, s)| stray_row(a, s, feed))
        .collect();
    live.extend(strays);
    for r in live.iter_mut().filter(|r| r.account.is_empty()) {
        if let Some((_, s)) = agents.iter().find(|(_, s)| s.target == r.target) {
            r.account = s.account.clone();
        }
    }
    live.sort_by(|a, b| {
        (vocab.rank(&a.bucket), &a.target).cmp(&(vocab.rank(&b.bucket), &b.target))
    });
    let live_items: HashSet<&str> = live.iter().map(|r| r.item.as_str()).collect();
    let mut seen: HashSet<String> = live.iter().map(|r| r.session_id.clone()).collect();
    let mut ended: Vec<SessionRow> = vec![];
    for i in feed.items.iter().filter(|i| i.state == queue::State::Done) {
        let sids = item_sessions(i);
        let never_ran = sids.is_empty() && i.pr.is_none();
        if never_ran || live_items.contains(i.slug.as_str()) {
            continue;
        }
        ended.push(queue_row(i, feed));
        seen.extend(sids);
    }
    for e in &feed.ended {
        if seen.insert(e.session_id.clone()) {
            ended.push(outcome_row(e));
        }
    }
    ended.sort_by(|a, b| b.finished.cmp(&a.finished));
    live.append(&mut ended);
    live
}

/// A session on this machine the state document has no row for: parked, or newer than its last
/// write. It stays in the table so it can still be opened.
fn stray_row(a: &Agent, s: &Session, feed: &Feed) -> SessionRow {
    SessionRow {
        key: a.target.clone(),
        bucket: "PARKED".into(),
        project: a.project.clone(),
        task: a.summary.clone(),
        item: s.items.first().cloned().unwrap_or_default(),
        target: a.target.clone(),
        session_id: a.session_id.clone(),
        cost_usd: feed.cost.get(&a.session_id).copied(),
        account: a.account.clone(),
        ..SessionRow::default()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::table::View;
    use serde_json::json;

    fn item(line: Value) -> Item {
        queue::parse(&line.to_string()).remove(0)
    }

    fn done(slug: &str, sid: &str, finished: &str) -> Item {
        item(
            json!({"slug":slug,"project":"apociseum","state":"done","task":"ucp-394 the fix",
            "sessions":sid,"pr":"Kblack0610/x#1915","merged":"abc","status":"ok",
            "finished":finished,"account":"b","cost_usd":"1.60"}),
        )
    }

    fn vocab() -> Vocab {
        Vocab::from_state(&json!({"vocab": {"buckets": [
            "NEEDS", "STALLED", "DONE", "LANDED", "CHAT", "WORKING", "PARKED"]}}))
    }

    fn state() -> Vec<Value> {
        vec![
            json!({"target":"lab/d:1","bucket":"WORKING","session_id":"s1","cwd":"/w/.dotfiles","project":"dotfiles",
                "topic":"a topic","pr":"-","account":"a","idle_min":3,"phases_done":2,"phases_total":4,
                "item":{"slug":"own","is":"own","origin":"run"}}),
            json!({"target":"lab/d:2","bucket":"NEEDS","session_id":"s2","cwd":"/w/.dotfiles","project":"dotfiles",
                "topic":"fix(mqtt) lock wait","pr":"12","pr_state":"OPEN","ci":"green","account":"a",
                "idle_min":1980,"item":null}),
            json!({"target":"lab/d:3","bucket":"WORKING","session_id":"s3","cwd":"/w/.dotfiles","project":"dotfiles",
                "topic":"shepherd","labels":["shepherd"],"pr":"-","item":null}),
            json!({"target":"lab/d:4","bucket":"DONE","session_id":"s4","cwd":"/w/.dotfiles","project":"dotfiles",
                "topic":"wound down","pr":"-","item":{"slug":"still-here","is":"own","origin":"hand"}}),
        ]
    }

    fn feed() -> Feed {
        Feed {
            items: vec![
                item(
                    json!({"slug":"own","project":"dotfiles","state":"running","task":"the item title"}),
                ),
                done("ucp-394", "s9", "2026-11-06T17:00:00Z"),
                done("still-here", "s4", "2026-11-06T18:00:00Z"),
                item(
                    json!({"slug":"no-session","project":"p","state":"done","task":"t","status":"ok"}),
                ),
            ],
            ended: vec![
                Ended {
                    session_id: "s9".into(),
                    title: "dup of the item".into(),
                    ..Ended::default()
                },
                Ended {
                    session_id: "s1".into(),
                    title: "still live".into(),
                    ..Ended::default()
                },
                Ended {
                    session_id: "h1".into(),
                    project: "notes".into(),
                    title: "a hand session\nmore".into(),
                    cost_usd: Some(2.5),
                    updated_epoch: Some(1_794_000_000),
                    prs_merged: 1,
                    ..Ended::default()
                },
            ],
            cost: HashMap::from([("s1".to_string(), 1.2)]),
            errors: vec![],
        }
    }

    #[test]
    fn a_live_row_prices_its_item_across_all_of_the_items_sessions() {
        let mut f = feed();
        f.items[0].extra.insert("sessions".into(), "s0,s1".into());
        f.cost.insert("s0".into(), 3.0);
        let r = rows(&state(), &vocab(), &f, &[]);
        let own = r.iter().find(|x| x.target == "lab/d:1").unwrap();
        assert_eq!(own.cost_usd, Some(1.2));
        assert_eq!(own.item_cost_usd, Some(4.2));
    }

    #[test]
    fn a_session_with_no_item_shows_the_project_its_row_carries() {
        let s = vec![
            json!({"target":"lab/freqtrade_trading_attempt-agent-1:1","bucket":"WORKING",
            "session_id":"f1","cwd":"/w/freqtrade_trading_attempt-agent-1","project":"trader","item":null}),
        ];
        let r = rows(&s, &vocab(), &feed(), &[]);
        assert_eq!(r[0].project, "trader");
    }

    #[test]
    fn the_vocabulary_orders_the_buckets_not_a_list_here() {
        let swapped = Vocab::from_state(&json!({"vocab": {"buckets": ["WORKING", "NEEDS"]}}));
        let by = |v: &Vocab| {
            rows(&state(), v, &feed(), &[])
                .iter()
                .map(|r| r.bucket.clone())
                .take(2)
                .collect::<Vec<_>>()
        };
        assert_eq!(by(&swapped)[0], "WORKING");
        assert_eq!(by(&vocab())[0], "NEEDS");
    }

    #[test]
    fn a_live_row_takes_its_task_and_project_from_the_item() {
        let r = rows(&state(), &vocab(), &feed(), &[]);
        let own = r.iter().find(|x| x.target == "lab/d:1").unwrap();
        assert_eq!(own.task, "the item title");
        assert_eq!(own.project, "dotfiles");
        assert_eq!(own.cost_usd, Some(1.2));
        assert_eq!(own.source, Source::Live);
        let hand = r.iter().find(|x| x.target == "lab/d:2").unwrap();
        assert_eq!(hand.task, "fix(mqtt) lock wait");
        assert_eq!(hand.project, "dotfiles");
        assert_eq!(hand.pr.as_deref(), Some("12"));
        assert_eq!(hand.pr_state, "open");
    }

    #[test]
    fn needs_sorts_first_and_ended_rows_last_newest_first() {
        let r = rows(&state(), &vocab(), &feed(), &[]);
        let keys: Vec<&str> = r.iter().map(|x| x.key.as_str()).collect();
        assert_eq!(
            keys,
            ["lab/d:2", "lab/d:4", "lab/d:1", "lab/d:3", "h1", "ucp-394"]
        );
    }

    #[test]
    fn an_ended_row_names_its_source_and_each_session_shows_once() {
        let r = rows(&state(), &vocab(), &feed(), &[]);
        let q = r.iter().find(|x| x.key == "ucp-394").unwrap();
        assert_eq!(q.source, Source::Queue);
        assert_eq!(q.bucket, "DONE");
        assert_eq!(q.pr.as_deref(), Some("1915"));
        assert_eq!(q.pr_state, "merged");
        assert_eq!(q.ended, "ended");
        assert_eq!(q.cost_usd, Some(1.6));
        assert_eq!(q.account, "b");
        let o = r.iter().find(|x| x.key == "h1").unwrap();
        assert_eq!(o.source, Source::Outcome);
        assert_eq!(o.task, "a hand session");
        assert_eq!(o.pr_state, "merged");
        assert!(!r
            .iter()
            .any(|x| x.task == "dup of the item" || x.task == "still live"));
        assert!(!r
            .iter()
            .any(|x| x.key == "still-here" || x.key == "no-session"));
    }

    #[test]
    fn a_session_the_state_document_has_not_got_is_a_parked_row() {
        let agent = |target: &str, sid: &str| {
            let a = Agent {
                target: target.into(),
                session_id: sid.into(),
                project: "dotfiles".into(),
                summary: "parked (park)".into(),
                ..Agent::default()
            };
            let s = Session::from(&a);
            (a, s)
        };
        let known = agent("lab/d:1", "s1");
        let moved = agent("lab/d:77", "s2");
        let r = rows(
            &state(),
            &vocab(),
            &feed(),
            &[known, moved, agent("lab/d:9", "s77")],
        );
        let parked: Vec<_> = r.iter().filter(|x| x.bucket == "PARKED").collect();
        assert_eq!(
            parked.len(),
            1,
            "matched by target or session id: {parked:?}"
        );
        assert_eq!(parked[0].target, "lab/d:9");
        assert_eq!(parked[0].task, "parked (park)");
        assert!(!parked[0].unlinked, "item:none is what the header counts");
        let at = |k: &str| r.iter().position(|x| x.key == k).unwrap();
        assert!(
            at("lab/d:9") < at("ucp-394"),
            "live rows stay above ended ones"
        );
    }

    #[test]
    fn an_item_finished_by_a_session_that_moved_on_still_shows() {
        let mut f = feed();
        f.items.push(done("earlier", "s1", "2026-11-06T16:00:00Z"));
        assert!(rows(&state(), &vocab(), &f, &[])
            .iter()
            .any(|x| x.key == "earlier"));
    }

    #[test]
    fn a_failed_item_says_so_where_idle_goes() {
        let mut f = feed();
        f.items.push(item(
            json!({"slug":"bad","project":"p","state":"done","task":"t",
            "sessions":"s7","status":"failed","finished":"2026-11-06T19:00:00Z"}),
        ));
        let r = rows(&[], &vocab(), &f, &[]);
        assert_eq!(r.iter().find(|x| x.key == "bad").unwrap().ended, "failed");
    }

    #[test]
    fn the_chips_split_the_rows() {
        let r = rows(&state(), &vocab(), &feed(), &[]);
        let v = View::new::<SessionRow>("", "", "", "");
        let n: Vec<(&str, usize)> = v.states(&r).iter().map(|c| (c.name, c.n)).collect();
        assert_eq!(
            n,
            [
                ("all", 6),
                ("running", 2),
                ("needs you", 1),
                ("stalled", 0),
                ("done today", 3)
            ]
        );
        let v = View::new::<SessionRow>("", "Needs You", "", "");
        assert_eq!(v.apply(&r).len(), 1);
    }

    #[test]
    fn item_none_lists_what_the_header_counts_so_a_parked_session_is_left_out() {
        let mut s = state();
        s.push(json!({"target":"lab/d:5","bucket":"PARKED","session_id":"s5","item":null}));
        let unlinked: Vec<_> = rows(&s, &vocab(), &feed(), &[])
            .into_iter()
            .filter(|r| r.unlinked)
            .map(|r| r.key)
            .collect();
        assert_eq!(unlinked, ["lab/d:2"]);
        let c = crate::capacity::build(&s, crate::capacity::Sources::default());
        assert_eq!(c.unlinked, unlinked.len());
    }

    #[test]
    fn a_done_item_that_landed_a_pr_shows_with_no_session_and_one_that_never_ran_does_not() {
        let mut f = feed();
        f.items.push(item(
            json!({"slug":"landed","project":"p","state":"done","task":"t","pr":"o/r#7","status":"ok"}),
        ));
        let r = rows(&state(), &vocab(), &f, &[]);
        let landed = r.iter().find(|x| x.key == "landed").unwrap();
        assert_eq!(landed.source, Source::Queue);
        assert_eq!(landed.pr.as_deref(), Some("7"));
        assert!(r.iter().all(|x| x.key != "no-session"));
    }

    #[test]
    fn the_query_finds_unlinked_sessions_open_prs_and_sources() {
        let r = rows(&state(), &vocab(), &feed(), &[]);
        let keys = |q: &str| -> Vec<String> {
            View::new::<SessionRow>(q, "", "", "")
                .apply(&r)
                .iter()
                .map(|x| x.key.clone())
                .collect()
        };
        assert_eq!(keys("item:none"), ["lab/d:2"]);
        assert_eq!(keys("pr:open project:dotfiles"), ["lab/d:2"]);
        assert_eq!(keys("source:outcome"), ["h1"]);
        assert_eq!(keys("item:own"), ["lab/d:1"]);
    }

    #[test]
    fn the_registry_keeps_a_sessions_last_cost() {
        let dir = std::env::temp_dir().join(format!("hub-costs-{}", std::process::id()));
        std::fs::create_dir_all(dir.join("p")).unwrap();
        std::fs::write(
            dir.join("p/sessions.jsonl"),
            "{\"session_id\":\"a\",\"cost_usd\":1.0}\nnot json\n{\"session_id\":\"a\",\"cost_usd\":2.5}\n{\"session_id\":\"b\"}\n",
        )
        .unwrap();
        let c = costs(&dir);
        std::fs::remove_dir_all(&dir).unwrap();
        assert_eq!(c, HashMap::from([("a".to_string(), 2.5)]));
    }

    #[test]
    fn the_registry_names_a_sessions_last_transcript() {
        let dir = std::env::temp_dir().join(format!("hub-transcript-{}", std::process::id()));
        std::fs::create_dir_all(dir.join("p")).unwrap();
        std::fs::write(
            dir.join("p/sessions.jsonl"),
            "{\"session_id\":\"a\",\"transcript\":\"/t/old\"}\n{\"session_id\":\"a\",\"transcript\":\"/t/new\"}\n{\"session_id\":\"b\"}\n",
        )
        .unwrap();
        let (a, b) = (transcript(&dir, "a"), transcript(&dir, "b"));
        std::fs::remove_dir_all(&dir).unwrap();
        assert_eq!(a, Some(PathBuf::from("/t/new")));
        assert_eq!(b, None);
    }

    #[test]
    fn outcomes_that_fail_leave_the_queue_rows_and_say_why() {
        struct R;
        impl Runner for R {
            fn run(&self, argv: &[String]) -> Result<String, String> {
                if argv[0] == "agent-queue" {
                    Ok(json!({"slug":"a","project":"p","state":"done","task":"t","sessions":"s","finished":"2026-11-06T17:00:00Z"}).to_string())
                } else {
                    Err("exit 1".into())
                }
            }
        }
        let f = super::feed(&R, Path::new("/nonexistent"));
        assert_eq!(rows(&[], &vocab(), &f, &[]).len(), 1);
        assert_eq!(f.errors, ["session outcomes: exit 1"]);
    }
}
