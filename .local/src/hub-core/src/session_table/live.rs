//! The live sessions as a sidebar and a table row see them: this machine's agents (`collect_all`
//! and the panel's ledgers) and the fleet workers' agents (the snapshot the minute record
//! publishes, `worker-panel.json`), read once and joined by one rule. agent-web keeps the read
//! (`Live`) and draws the sidebar ([`Sidebar`]) and the table's agent facts ([`RowAgent`]) from it,
//! so neither a route nor the page joins sessions of its own.
//!
//! A worker's pane is known from the snapshot, never over ssh: whether a row there is a live agent
//! comes from [`fresh`], the one freshness rule for the list ([`worker_rows`]) and for acting on a
//! pane ([`worker_pane`]).

use std::path::Path;
use std::time::UNIX_EPOCH;

use serde::Serialize;
use serde_json::Value;

use super::SessionRow;
use crate::boards::{self, Phases};
use crate::display::Shown;
use crate::home::{NeedKind, NeedTag};
use crate::queue::Item;
use crate::session_actions::{self as actions, Session, System};

/// The worker and its own target, for a worker's target (`<host>@<server>/<session>:<window>`,
/// the form fleet-sessions and state.json carry for a worker's rows, so it names no tmux server
/// here); None for a target on this machine.
pub fn split_worker(target: &str) -> Option<(&str, &str)> {
    let (host, local) = target.split_once('@')?;
    let ok =
        !host.is_empty() && !host.starts_with('-') && !host.contains('/') && local.contains('/');
    ok.then_some((host, local))
}

/// The snapshot's document when it parses and is within the ttl it carries; Err (why) otherwise.
fn fresh(snapshot: &str, now: u64) -> Result<Value, String> {
    let doc: Value = serde_json::from_str(snapshot)
        .map_err(|e| format!("the worker snapshot is unreadable: {e}"))?;
    let age = now.saturating_sub(doc["at"].as_u64().unwrap_or(0));
    if age > doc["ttl"].as_u64().unwrap_or(0) {
        return Err(format!(
            "the worker snapshot is {age}s old; the minute record has not refreshed it"
        ));
    }
    Ok(doc)
}

/// Every worker row in the snapshot's text that names a live pane. Empty when the snapshot is
/// unreadable or past its ttl: the sessions table already says which worker went unread
/// (`silent`), so a stale row is never offered as live here.
fn worker_rows(snapshot: &str, now: u64) -> Vec<Value> {
    let Ok(doc) = fresh(snapshot, now) else {
        return Vec::new();
    };
    doc["rows"]
        .as_array()
        .into_iter()
        .flatten()
        .filter(|r| r["pane"].is_string() && r["target"].as_str().and_then(split_worker).is_some())
        .cloned()
        .collect()
}

/// A live agent on a fleet worker: the worker and its pane (`<server>/%<id>`).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct WorkerPane {
    pub host: String,
    pub pane: String,
}

/// The row of `target` in the snapshot's text, as the pane it names. Err (why) when the snapshot
/// is unreadable or older than the ttl it carries, when the target's worker is one the minute
/// record could not read (its sessions are unknown, not gone), or when the row has no pane.
fn worker_pane_in(snapshot: &str, target: &str, now: u64) -> Result<Option<WorkerPane>, String> {
    let doc = fresh(snapshot, now)?;
    let host = split_worker(target).map_or("", |(h, _)| h);
    let row = doc["rows"]
        .as_array()
        .into_iter()
        .flatten()
        .find(|r| r["target"] == target);
    let Some(row) = row else {
        let silent = doc["silent"].as_array().into_iter().flatten();
        return if silent.into_iter().any(|h| h == host) {
            Err(format!(
                "{host} did not answer the last minute record, so its sessions are not known"
            ))
        } else {
            Ok(None)
        };
    };
    let pane = row["pane"]
        .as_str()
        .ok_or_else(|| format!("the snapshot's row for {target} has no pane"))?;
    Ok(Some(WorkerPane {
        host: host.to_string(),
        pane: pane.to_string(),
    }))
}

/// The pane at a worker's target from the snapshot file at `path`, no ssh: Err (why) when there
/// is no file or [`worker_pane_in`] refuses it. Blocking.
pub fn worker_pane(path: &Path, target: &str) -> Result<Option<WorkerPane>, String> {
    let text = std::fs::read_to_string(path)
        .map_err(|e| format!("no worker snapshot ({}): {e}", path.display()))?;
    worker_pane_in(&text, target, agent_core::now_secs())
}

/// One session with what only its files tell: the plan progress, the open dialog and when its
/// transcript was last written. None of these depends on the queue.
pub struct Row {
    pub agent: agent_core::agent::Agent,
    pub session: Session,
    pub phases: Option<Phases>,
    pub question: Option<agent_core::transcript::Question>,
    pub wrote: Option<u64>,
}

/// Every session as `collect_all` finds it, and the fleet workers' live rows.
pub struct Live {
    pub rows: Vec<Row>,
    /// The live rows of the worker-panel snapshot ([`worker_rows`]).
    pub workers: Vec<Value>,
}

impl Live {
    /// Blocking: the dialog is a transcript read, done only for agents that have one open.
    pub fn read() -> Live {
        let workers = std::fs::read_to_string(boards::worker_panel())
            .map(|t| worker_rows(&t, agent_core::now_secs()))
            .unwrap_or_default();
        let state = std::fs::read_to_string(boards::fleet_state())
            .ok()
            .and_then(|s| serde_json::from_str(&s).ok())
            .unwrap_or(Value::Null);
        let mut phases = boards::phases(&state);
        let rows = actions::gather_unjoined(&System)
            .agents
            .into_iter()
            .map(|(agent, session)| {
                let question = match (agent.status.as_str(), &agent.jsonl) {
                    ("waiting", Some(p)) => agent_core::transcript::open_question_at(p),
                    _ => None,
                };
                Row {
                    phases: phases.remove(&agent.target),
                    wrote: agent.jsonl.as_ref().and_then(|p| {
                        std::fs::metadata(p)
                            .and_then(|m| m.modified())
                            .ok()
                            .and_then(|t| t.duration_since(UNIX_EPOCH).ok())
                            .map(|d| d.as_secs())
                    }),
                    question,
                    agent,
                    session,
                }
            })
            .collect();
        Live { rows, workers }
    }

    /// Each session with the queue items in its pane (`items`, the active ones), in the order
    /// `collect_all` gave.
    pub fn joined(&self, items: &[Item]) -> Vec<Session> {
        let mut sessions: Vec<Session> = self.rows.iter().map(|r| r.session.clone()).collect();
        for s in &mut sessions {
            s.items.clear();
        }
        actions::with_items(&mut sessions, items);
        sessions
    }

    /// The sidebar: this machine's sessions with their queue items and what each can be asked to
    /// do, then the workers' rows.
    pub fn sidebar(&self, items: &[Item]) -> Vec<Sidebar> {
        let sessions = self.joined(items);
        let local = self.rows.iter().zip(sessions).map(|(r, s)| {
            let a = &r.agent;
            Sidebar {
                phases: r.phases.clone(),
                actions: actions::available(&s)
                    .into_iter()
                    .map(actions::Action::name)
                    .collect(),
                items: s.items,
                account: a.account.clone(),
                attached: a.attached,
                parked: a.parked,
                plan: a.plan_slug.clone(),
                ask: a.ask.clone(),
                need: r
                    .question
                    .as_ref()
                    .map(|q| NeedKind::of_dialog(q.kind).tag()),
                question: r.question.clone(),
                wrote: r.wrote,
                target: a.target.clone(),
                short: a.short_target.clone(),
                project: a.project.clone(),
                repo: a.repo_full.clone(),
                status: a.status.clone(),
                summary: Shown::sub(&a.summary),
                session: a.session_id.clone(),
                tags: a.tags.clone(),
                host: None,
            }
        });
        local
            .chain(self.workers.iter().map(Sidebar::of_worker))
            .collect()
    }
}

/// One live agent in the sidebar, here or on a worker.
#[derive(Clone, Serialize)]
pub struct Sidebar {
    pub target: String,
    pub short: String,
    pub project: String,
    pub repo: String,
    pub status: String,
    pub summary: Shown,
    pub session: String,
    pub tags: String,
    /// The Claude account it runs on (claude-acct's name for its `CLAUDE_CONFIG_DIR`).
    pub account: String,
    /// The human is attached to its tmux session right now.
    pub attached: bool,
    /// Parked by `claude-acct park`: no claude runs, unpark resumes it.
    pub parked: bool,
    /// The plan file's slug, empty when it has none.
    pub plan: String,
    /// Its plan's `## Phases` progress, as fleet-sessions last read it.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub phases: Option<Phases>,
    /// The pending ask this session filed.
    pub ask: Option<String>,
    /// What `POST /api/session/<target>/<action>` accepts for it.
    pub actions: Vec<&'static str>,
    /// The agent-queue items in this pane (`with_items`).
    pub items: Vec<String>,
    /// The open question a `waiting` agent has, from its transcript (`agent_core::transcript::
    /// open_question_at`): a dialog, a permission prompt, or closing text that asks. A message
    /// that hands the turn back without asking is none.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub question: Option<agent_core::transcript::Question>,
    /// The Needs you kind and label that dialog has (`NeedKind::of_dialog`), so the card and the
    /// pin lead with the words Home's row does.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub need: Option<NeedTag>,
    /// Its transcript's last write, unix seconds: when a `waiting` agent started waiting, and
    /// what the page's new-output dot compares with when it was last opened.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub wrote: Option<u64>,
    /// The fleet worker it runs on, None when it runs here. A worker's session is read and typed
    /// into through `fleet-host-run`; its transcript and session actions stay there.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub host: Option<String>,
}

impl Sidebar {
    /// A worker's agent-panel row (the worker-panel snapshot) as a sidebar agent. No session
    /// action reaches a worker yet, so it offers none.
    pub fn of_worker(r: &Value) -> Sidebar {
        let s = |k: &str| r[k].as_str().unwrap_or_default().to_string();
        let target = s("target");
        Sidebar {
            short: target
                .split_once('/')
                .map_or(target.clone(), |(_, t)| t.to_string()),
            project: s("project"),
            repo: String::new(),
            status: s("status"),
            summary: Shown::sub(&s("summary")),
            // The UI keys seen-state on this, so a row with no id is keyed by its target, never "".
            session: Some(s("session_id"))
                .filter(|id| !id.is_empty())
                .unwrap_or_else(|| target.clone()),
            tags: String::new(),
            account: s("account"),
            attached: r["attached"].as_bool().unwrap_or(false),
            parked: r["parked"].as_bool().unwrap_or(false),
            plan: s("plan"),
            phases: None,
            ask: r["ask"].as_str().map(str::to_string),
            actions: Vec::new(),
            items: Vec::new(),
            question: None,
            need: None,
            wrote: None,
            host: Some(s("host")).filter(|h| !h.is_empty()),
            target,
        }
    }
}

/// What the table row has of the live agent behind it: what the row's tags and its new-output dot
/// draw, and the id its link opens (`session`, else `target`).
#[derive(Clone, Debug, Default, PartialEq, Serialize)]
pub struct RowAgent {
    pub target: String,
    pub session: String,
    pub attached: bool,
    pub parked: bool,
    /// The fleet worker it runs on, for the side list's `@host`.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub host: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub ask: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub wrote: Option<u64>,
}

/// Join each live row to the sidebar agent with its target, else its Claude session id: the one
/// join, so a row's tags, dot and link never come from a lookup the page makes.
pub fn join_agents(agents: &[Sidebar], rows: &mut [SessionRow]) {
    for r in rows.iter_mut() {
        r.agent = agents
            .iter()
            .find(|a| {
                (!r.target.is_empty() && a.target == r.target)
                    || (!r.session_id.is_empty() && a.session == r.session_id)
            })
            .map(|a| RowAgent {
                target: a.target.clone(),
                session: a.session.clone(),
                attached: a.attached,
                parked: a.parked,
                host: a.host.clone(),
                ask: a.ask.clone(),
                wrote: a.wrote,
            });
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::queue::parse;
    use serde_json::json;

    fn row(target: &str, tmux: &str) -> Row {
        Row {
            agent: Default::default(),
            session: Session {
                target: target.into(),
                server: "lab".into(),
                tmux_session: tmux.into(),
                ..Session::default()
            },
            phases: None,
            question: None,
            wrote: None,
        }
    }

    #[test]
    fn each_join_takes_the_items_held_now_and_keeps_none_from_the_last() {
        let live = Live {
            rows: vec![row("lab/a:1", "a"), row("lab/b:1", "b")],
            workers: vec![],
        };
        let one = parse(r#"{"slug":"x","session":"lab:a","state":"running"}"#);
        let two = parse(r#"{"slug":"y","session":"lab:b","state":"running"}"#);
        let items = |s: Vec<Session>| s.into_iter().map(|s| s.items).collect::<Vec<_>>();
        assert_eq!(items(live.joined(&one)), [vec!["x"], vec![]]);
        assert_eq!(
            items(live.joined(&two)),
            [vec![], vec!["y"]],
            "a queue change shows with no new read of the sessions"
        );
        assert!(
            live.rows[0].session.items.is_empty(),
            "the read is not written to"
        );
    }

    #[test]
    fn a_worker_target_splits_and_a_local_one_does_not() {
        assert_eq!(split_worker("razer@lab/s1:2"), Some(("razer", "lab/s1:2")));
        assert_eq!(split_worker("lab/s1:2"), None);
        // An @ inside a local session or window name is not a worker.
        assert_eq!(split_worker("lab/me@x:1"), None);
        assert_eq!(split_worker("@lab/s1:2"), None);
        assert_eq!(split_worker("-oProxyCommand=x@lab/s1:2"), None);
        assert_eq!(split_worker("razer@nothing"), None);
    }

    const SNAP: &str = r#"{"at":1000,"ttl":180,"rows":[
        {"target":"hp@lab/s1:1","pane":"lab/%3","host":"hp"},
        {"target":"hp@lab/s1:2","pane":"lab/%7","host":"hp"}]}"#;

    #[test]
    fn the_session_list_takes_every_fresh_worker_row_with_a_pane() {
        let rows = worker_rows(SNAP, 1100);
        assert_eq!(rows.len(), 2);
        assert_eq!(rows[1]["target"], "hp@lab/s1:2");
        let no_pane = r#"{"at":1000,"ttl":180,"rows":[{"target":"hp@lab/s1:1","host":"hp"},
            {"target":"lab/s1:1","pane":"lab/%3"}]}"#;
        assert!(
            worker_rows(no_pane, 1100).is_empty(),
            "no pane, or not a worker's target"
        );
    }

    #[test]
    fn a_stale_or_unreadable_snapshot_lists_no_worker_session() {
        assert!(worker_rows(SNAP, 1181).is_empty());
        assert!(worker_rows("not json", 1000).is_empty());
    }

    #[test]
    fn only_a_listed_target_gives_a_pane_on_its_worker() {
        let l = worker_pane_in(SNAP, "hp@lab/s1:2", 1100)
            .ok()
            .flatten()
            .unwrap();
        assert_eq!((l.host.as_str(), l.pane.as_str()), ("hp", "lab/%7"));
        assert!(worker_pane_in(SNAP, "hp@lab/s1:9", 1100).unwrap().is_none());
    }

    #[test]
    fn a_snapshot_past_its_own_ttl_or_unreadable_is_an_error_not_an_empty_answer() {
        assert!(worker_pane_in(SNAP, "hp@lab/s1:2", 1180).is_ok());
        assert!(worker_pane_in(SNAP, "hp@lab/s1:2", 1181).is_err());
        assert!(worker_pane_in("not json", "hp@lab/s1:2", 1000).is_err());
    }

    #[test]
    fn a_worker_the_record_could_not_read_is_unknown_not_empty() {
        let snap = r#"{"at":1000,"ttl":180,"rows":[
            {"target":"hp@lab/s1:1","pane":"lab/%3"}],"silent":["nuc"]}"#;
        assert!(worker_pane_in(snap, "nuc@lab/s1:1", 1100).is_err());
        assert!(worker_pane_in(snap, "hp@lab/s1:9", 1100).unwrap().is_none());
        assert!(worker_pane_in(snap, "hp@lab/s1:1", 1100).unwrap().is_some());
    }

    #[test]
    fn a_row_without_a_pane_is_an_error() {
        let snap = r#"{"at":1000,"ttl":180,"rows":[{"target":"hp@lab/s1:1"}]}"#;
        assert!(worker_pane_in(snap, "hp@lab/s1:1", 1100).is_err());
    }

    #[test]
    fn a_missing_snapshot_file_is_an_error_naming_it() {
        let e = worker_pane(Path::new("/nonexistent/worker-panel.json"), "hp@lab/s1:1");
        assert!(e.unwrap_err().contains("worker-panel.json"));
    }

    #[test]
    fn a_worker_row_is_a_sidebar_agent_on_its_host_with_no_actions() {
        let r = json!({"target": "razer-laptop@lab/dotfiles-agent-1:1",
            "host": "razer-laptop", "pane": "lab/%4", "status": "busy", "summary": "fix it",
            "session_id": "abc", "project": "dotfiles", "account": "bnb"});
        let a = Sidebar::of_worker(&r);
        assert_eq!(a.host.as_deref(), Some("razer-laptop"));
        assert_eq!(a.target, "razer-laptop@lab/dotfiles-agent-1:1");
        assert_eq!(a.short, "dotfiles-agent-1:1");
        assert_eq!((a.status.as_str(), a.session.as_str()), ("busy", "abc"));
        assert!(a.actions.is_empty(), "no session action reaches a worker");
        let j = serde_json::to_value(&a).unwrap();
        assert_eq!(j["host"], "razer-laptop");
        let no_id = json!({"target": "razer-laptop@lab/s:2", "host": "razer-laptop"});
        assert_eq!(
            Sidebar::of_worker(&no_id).session,
            "razer-laptop@lab/s:2",
            "a row with no session id is keyed by its target, never an empty id"
        );
    }

    #[test]
    fn a_row_takes_the_agent_with_its_target_else_its_session_id() {
        let agents = vec![
            Sidebar::of_worker(
                &json!({"target":"hp@lab/s:1","session_id":"w1","ask":"ask-1",
                "attached":true,"host":"hp"}),
            ),
            Sidebar::of_worker(&json!({"target":"hp@lab/s:2","session_id":"w2","parked":true})),
        ];
        let mut rows = vec![
            SessionRow {
                target: "hp@lab/s:1".into(),
                ..SessionRow::default()
            },
            SessionRow {
                session_id: "w2".into(),
                ..SessionRow::default()
            },
            SessionRow {
                key: "ended".into(),
                session_id: "gone".into(),
                ..SessionRow::default()
            },
            SessionRow::default(),
        ];
        join_agents(&agents, &mut rows);
        let a = rows[0].agent.as_ref().unwrap();
        assert_eq!(
            (a.session.as_str(), a.ask.as_deref()),
            ("w1", Some("ask-1"))
        );
        assert!(a.attached && !a.parked);
        assert!(rows[1].agent.as_ref().unwrap().parked, "by session id");
        assert!(rows[2].agent.is_none(), "an ended session has no agent");
        assert!(
            rows[3].agent.is_none(),
            "a row naming nothing joins nothing"
        );
    }
}
