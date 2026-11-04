//! The Shepherd tab: the rundowns and chat answers the shepherd kept
//! (`fleet-shepherd log --rundown`, read by `hub_core::boards::rundowns`) and the live shepherd
//! session, so the page can show its transcript and type into it through the Sessions routes.

use agent_panel::chooser;
use axum::Json;
use hub_core::boards;
use serde::Serialize;

/// Rundowns sent to the page. About two weeks at a few a day.
const RUNDOWNS: usize = 60;

#[derive(Serialize)]
pub struct Shepherd {
    /// The pane holding the shepherd lease, or null when no shepherd is armed.
    target: Option<String>,
    /// Its Claude session id: the page matches transcript events against it.
    session: Option<String>,
    status: Option<String>,
    rundowns: Vec<boards::Rundown>,
}

/// The agent carrying agent-panel's `shepherd` tag, which it sets only while the lease is live.
fn armed(agents: Vec<chooser::Agent>) -> Option<chooser::Agent> {
    agents
        .into_iter()
        .find(|a| a.tags.split_whitespace().any(|t| t == "shepherd"))
}

pub async fn get() -> Json<Shepherd> {
    let out = tokio::task::spawn_blocking(|| {
        let a = armed(chooser::collect());
        Shepherd {
            target: a.as_ref().map(|a| a.target.clone()),
            session: a.as_ref().map(|a| a.session_id.clone()),
            status: a.map(|a| a.status),
            rundowns: boards::rundowns(&boards::shepherd_dir().join("rundowns"), RUNDOWNS),
        }
    })
    .await
    .unwrap_or(Shepherd {
        target: None,
        session: None,
        status: None,
        rundowns: Vec::new(),
    });
    Json(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn agent(target: &str, tags: &str) -> chooser::Agent {
        chooser::Agent {
            target: target.into(),
            tags: tags.into(),
            ..Default::default()
        }
    }

    #[test]
    fn the_shepherd_is_the_agent_with_the_live_lease_tag() {
        let got = armed(vec![
            agent("a:1", "agent shepherding "),
            agent("b:1", "pinned shepherd "),
        ]);
        assert_eq!(got.map(|a| a.target), Some("b:1".to_string()));
        assert!(armed(vec![agent("a:1", "agent ")]).is_none());
    }
}
