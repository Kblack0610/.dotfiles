//! The sessions, read once for the sidebar (`/api/agents`) and the Sessions table. Each ran
//! `agent::collect_all` (every tmux server and the panel's ledgers) and an `agent-queue list`
//! of its own on every refresh. This keeps one read of the sessions, and each reader joins the
//! queue items it holds now (`queue::Cache`), so a queue change shows without a new read of them.

use hub_core::boards;
use hub_core::queue::Item;
use hub_core::session_actions::{self as actions, Session, System};

/// One session with what only its files tell: the plan progress, the open dialog and when its
/// transcript was last written. None of these depends on the queue.
pub struct Row {
    pub agent: agent_core::agent::Agent,
    pub session: Session,
    pub phases: Option<boards::Phases>,
    pub question: Option<agent_core::transcript::Question>,
    pub wrote: Option<u64>,
}

/// Every session as `collect_all` finds it, and the fleet workers' rows.
pub struct Live {
    pub rows: Vec<Row>,
    /// The live rows of the worker-panel snapshot (`worker_agents`).
    pub workers: Vec<serde_json::Value>,
}

impl Live {
    /// Blocking: the dialog is a transcript read, done only for agents that have one open.
    pub fn read(workers: Vec<serde_json::Value>) -> Live {
        let state = std::fs::read_to_string(boards::fleet_state())
            .ok()
            .and_then(|s| serde_json::from_str(&s).ok())
            .unwrap_or(serde_json::Value::Null);
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
                            .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
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
}

#[cfg(test)]
mod tests {
    use super::*;
    use hub_core::queue::parse;

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
}
