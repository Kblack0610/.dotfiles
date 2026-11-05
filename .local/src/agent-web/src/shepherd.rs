//! The Shepherd tab: the rundowns and chat answers the shepherd kept
//! (`fleet-shepherd log --rundown`, read by `hub_core::boards::rundowns`) and the live shepherd
//! session, so the page can show its transcript and type into it through the Sessions routes.
//! It also shows what the last check handed to a pass (`fleet-shepherd`'s `.due`, read by
//! `hub_core::boards::due`); what a pass chose to leave is in its log, read by the Actions tab.
//! Its numbers and the pass running now are `fleet-shepherd stats`, the object the MQTT feed
//! publishes, so the page and Home Assistant read one source.

use agent_panel::chooser;
use axum::Json;
use hub_core::boards;
use serde::Serialize;
use serde_json::Value;

/// Rundowns sent to the page. About two weeks at a few a day.
const RUNDOWNS: usize = 60;

#[derive(Serialize)]
pub struct Shepherd {
    /// The pane of the live shepherd, or null when no shepherd is armed.
    target: Option<String>,
    /// Its Claude session id: the page matches transcript events against it.
    session: Option<String>,
    status: Option<String>,
    rundowns: Vec<boards::Rundown>,
    ledger: boards::Due,
    /// `fleet-shepherd stats`, or null when it cannot run or says nothing parseable.
    stats: Option<Value>,
}

fn stats() -> Option<Value> {
    let out = std::process::Command::new("fleet-shepherd")
        .arg("stats")
        .output()
        .ok()?;
    parse_stats(&out.stdout)
}

/// Only an object counts: an error line or empty output is no stats, not a page of nulls.
fn parse_stats(out: &[u8]) -> Option<Value> {
    serde_json::from_slice::<Value>(out)
        .ok()
        .filter(Value::is_object)
}

/// The agent carrying agent-panel's `shepherd` tag, which it sets only while the lease is live,
/// else the session `fleet-shepherd stats` names as the pass: a pass resumed in another pane has
/// no tag until its next lease.
fn armed(agents: Vec<chooser::Agent>, pass: Option<&str>) -> Option<chooser::Agent> {
    let tagged = |a: &chooser::Agent| a.tags.split_whitespace().any(|t| t == "shepherd");
    agents
        .iter()
        .find(|a| tagged(a))
        .or_else(|| agents.iter().find(|a| Some(a.session_id.as_str()) == pass))
        .cloned()
}

pub async fn get() -> Json<Shepherd> {
    let out = tokio::task::spawn_blocking(|| {
        let stats = stats();
        let pass = stats.as_ref().and_then(|s| s["pass_id"].as_str());
        let a = armed(chooser::collect(), pass);
        Shepherd {
            target: a.as_ref().map(|a| a.target.clone()),
            session: a.as_ref().map(|a| a.session_id.clone()),
            status: a.map(|a| a.status),
            rundowns: boards::rundowns(&boards::shepherd_dir().join("rundowns"), RUNDOWNS),
            ledger: boards::due(&boards::shepherd_dir()),
            stats,
        }
    })
    .await
    .unwrap_or(Shepherd {
        target: None,
        session: None,
        status: None,
        rundowns: Vec::new(),
        ledger: boards::Due::default(),
        stats: None,
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
        let got = armed(
            vec![
                agent("a:1", "agent shepherding "),
                agent("b:1", "pinned shepherd "),
            ],
            None,
        );
        assert_eq!(got.map(|a| a.target), Some("b:1".to_string()));
        assert!(armed(vec![agent("a:1", "agent ")], None).is_none());
    }

    #[test]
    fn a_pass_with_no_tag_is_found_by_its_session_id() {
        let resumed = chooser::Agent {
            session_id: "sid".into(),
            ..agent("dotfiles:1", "agent ")
        };
        let got = armed(vec![agent("a:1", "agent "), resumed.clone()], Some("sid"));
        assert_eq!(got.map(|a| a.target), Some("dotfiles:1".to_string()));
        assert!(armed(vec![agent("a:1", "agent "), resumed], Some("other")).is_none());
    }

    #[test]
    fn stats_are_the_object_fleet_shepherd_prints_and_nothing_else() {
        let got = parse_stats(br#"{"due":2,"pass_id":"sid","last_verdict":"WORKED"}"#).unwrap();
        assert_eq!(got["due"], 2);
        assert_eq!(got["last_verdict"], "WORKED");
        assert!(parse_stats(b"").is_none());
        assert!(parse_stats(b"fleet-shepherd: no ledger").is_none());
        assert!(parse_stats(b"[1,2]").is_none());
    }
}
