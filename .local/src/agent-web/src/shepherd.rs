//! The shepherd on the Sessions tab: the rundowns and chat answers the shepherd kept
//! (`fleet-shepherd log --rundown`, read by `hub_core::boards::rundowns`) and the live shepherd
//! session, so the page can show its transcript and type into it through the Sessions routes.
//! It also shows what the last check handed to a pass (`fleet-shepherd`'s `.due`, read by
//! `hub_core::boards::due`); what a pass chose to leave is in its log, read by Log's Actions section.
//! Its numbers and the pass running now are `fleet-shepherd stats`, the object the MQTT feed
//! publishes, so the page and Home Assistant read one source. The files and the live session are
//! read on every request; the stats, the one slow part (most of a second), are kept (`Cache`).

use agent_core::agent;
use axum::extract::{Query, State};
use axum::Json;
use hub_core::boards;
use hub_core::layout::page_rows;
use hub_core::table::{self, Paged};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use tokio::sync::broadcast;

use crate::cache::EventCache;
use crate::Shared;

/// Rundowns sent to the page. About two weeks at a few a day.
const RUNDOWNS: usize = 60;

/// The shepherd's files that reach the page as a `shepherd` event (main.rs `classify`: `.due`,
/// `.lease`, `.pass`, `passes.tsv`, `log.md` and the rundowns), which `fleet-shepherd stats` counts.
const KINDS: [&str; 1] = ["shepherd"];
/// A change the stats count that pushes no event shows within this.
const STATS_SECS: u64 = 30;

/// The kept `fleet-shepherd stats`, which Log's Rundowns and Sessions' Shepherd read. No stats
/// (it failed or printed no object) is not kept, so the next request runs it again.
pub struct Cache(EventCache<Option<Value>, STATS_SECS>);

impl Cache {
    pub fn new(events: broadcast::Receiver<String>) -> Self {
        Cache(EventCache::new(events, &KINDS, "shepherd-stats"))
    }

    pub async fn stats(&self) -> Option<Value> {
        let kept = self.0.get_if((), stats, Option::is_some).await;
        kept.ok().and_then(|v| Option::clone(&v))
    }
}

#[derive(Serialize)]
pub struct Shepherd {
    /// The pane of the live shepherd, or null when no shepherd is armed.
    target: Option<String>,
    /// Its Claude session id: the page matches transcript events against it.
    session: Option<String>,
    status: Option<String>,
    /// The page of rundowns Log's Rundowns section is on (`rdpg`), newest first.
    rundowns: Vec<boards::Rundown>,
    /// What the page draws its pager from: every rundown kept, and where this page sits.
    rundowns_table: Paged,
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
fn armed(agents: Vec<agent::Agent>, pass: Option<&str>) -> Option<agent::Agent> {
    let tagged = |a: &agent::Agent| a.tags.split_whitespace().any(|t| t == "shepherd");
    agents
        .iter()
        .find(|a| tagged(a))
        .or_else(|| agents.iter().find(|a| Some(a.session_id.as_str()) == pass))
        .cloned()
}

/// The page of Log's Rundowns section, its `rd` keys (static/table.js `tblParams`).
#[derive(Deserialize, Default)]
pub struct Q {
    #[serde(default)]
    rdpg: String,
}

/// Keeps page `page` of the rundowns at the section's size (`layout::page_rows("rundowns")`).
fn paged(rundowns: &mut Vec<boards::Rundown>, page: usize) -> Paged {
    table::paged(rundowns, page, page_rows("rundowns"))
}

pub async fn get(State(s): State<Shared>, Query(q): Query<Q>) -> Json<Shepherd> {
    let stats = s.shepherd.stats().await;
    let out = tokio::task::spawn_blocking(move || {
        let pass = stats.as_ref().and_then(|s| s["pass_id"].as_str());
        let a = armed(agent::collect(), pass);
        let mut rundowns = boards::rundowns(&boards::shepherd_dir().join("rundowns"), RUNDOWNS);
        let rundowns_table = paged(&mut rundowns, q.rdpg.parse().unwrap_or(1));
        Shepherd {
            target: a.as_ref().map(|a| a.target.clone()),
            session: a.as_ref().map(|a| a.session_id.clone()),
            status: a.map(|a| a.status),
            rundowns,
            rundowns_table,
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
        rundowns_table: Paged::default(),
        ledger: boards::Due::default(),
        stats: None,
    });
    Json(out)
}

#[cfg(test)]
mod tests {
    use super::*;
    use hub_core::table::Pager;

    fn agent(target: &str, tags: &str) -> agent::Agent {
        agent::Agent {
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
        let resumed = agent::Agent {
            session_id: "sid".into(),
            ..agent("dotfiles:1", "agent ")
        };
        let got = armed(vec![agent("a:1", "agent "), resumed.clone()], Some("sid"));
        assert_eq!(got.map(|a| a.target), Some("dotfiles:1".to_string()));
        assert!(armed(vec![agent("a:1", "agent "), resumed], Some("other")).is_none());
    }

    #[test]
    fn past_one_page_it_sends_the_asked_page_of_rundowns_and_its_pager() {
        let per = page_rows("rundowns");
        let kept = |n: usize| -> Vec<boards::Rundown> {
            (0..n)
                .map(|i| boards::Rundown {
                    file: format!("r{i}.md"),
                    title: String::new(),
                    stamp: String::new(),
                    body: String::new(),
                })
                .collect()
        };
        let mut list = kept(per + 5);
        let got = paged(&mut list, 2);
        assert_eq!(
            got,
            Paged {
                shown: per + 5,
                pager: Some(Pager {
                    page: 2,
                    pages: 2,
                    per
                })
            }
        );
        assert_eq!(list.len(), 5);
        assert_eq!(list[0].file, format!("r{per}.md"));
        let mut one = kept(per);
        assert_eq!(
            paged(&mut one, 1),
            Paged {
                shown: per,
                pager: None
            }
        );
        assert_eq!(one.len(), per);
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
