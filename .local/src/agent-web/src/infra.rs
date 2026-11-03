//! The Infra tab: the hub:infra board (`command-center.sh`, Prefix i) for the browser. It asks
//! Prometheus the board's own questions, so the tab, the board and Grafana's kb-command-center
//! all read the same `cc:*` rules (home-config `apps/monitoring/prometheus-rules-command-center.yaml`)
//! and the same runner-exporter series, and none of them judges anything itself.
//!
//! Endpoints come from `CC_PROM_URL` and `CC_GRAFANA_URL`, the board's
//! `~/.config/command-center/env`, which the unit loads as its EnvironmentFile.

use std::collections::BTreeMap;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use hub_core::prom::{self, Series, W};
use serde::Serialize;
use tokio::sync::Mutex;

/// Prometheus evaluates the rules every minute; a second tab or a reload inside this window is
/// served the last answer instead of asking again.
const CACHE: Duration = Duration::from_secs(30);
/// Keeps a machine's run ledger series only while its textfile is fresh, as `cc:host_local_done_24h`.
const LOCAL_FRESH: &str =
    r#"and on (instance) (time() - node_textfile_mtime_seconds{file=~".*fleet_local.prom"} < 180)"#;

/// The board's `fetch()` queries, by name. All but `OPTIONAL` must answer or the tab shows the
/// error instead of numbers, as the board blanks rather than leave stale values up.
fn instant_queries() -> Vec<(&'static str, String)> {
    vec![
        ("cc", r#"{__name__=~"cc:.+",__name__!~"cc:host_instance|cc:host_local_gate|cc:host_core_busy_ratio|cc:runner_cores_.+"}"#.into()),
        ("runners", format!("{W} (github_runner_state)")),
        ("waiting", format!("{W} (github_actions_job_waiting)")),
        ("finished", format!("sum by (repo, workflow, conclusion, scope) ({W} (github_runs_finished))")),
        ("api", "min(github_runner_exporter_api_ok)".into()),
        ("gates", "cc:host_local_gate".into()),
        // Each core's busy share, keyed by host and cpu, so it stays out of `cc` (keyed by host).
        ("cores", "cc:host_core_busy_ratio".into()),
        // Cores each CI runner's job uses, and a pinned slot's CPUs, keyed by host and runner.
        ("runner_cores", r#"{__name__=~"cc:runner_cores_.+"}"#.into()),
        // Runners the governor holds back: idle but not taking jobs, so not online capacity.
        ("withheld", format!("{W} (github_runner_withheld) == 1")),
        // Done today: when runs finished, and which failed. An absent metric is an empty answer,
        // so the tab says "no data" rather than an error until the exporters publish them.
        ("hourly", format!("sum by (hour, conclusion, scope) ({W} (github_runs_by_hour))")),
        ("failed", format!("{W} (github_run_failed)")),
        ("local_hourly", format!("sum by (hour, result) (fleet_local_gate_by_hour {LOCAL_FRESH})")),
        ("local_failed", format!("sum by (hour, repo, branch, platform, result) (fleet_local_gate_failed {LOCAL_FRESH})")),
        // Recent runs, one series per run: the value is when it finished, or how long it took.
        ("recent", format!("{W} (github_actions_run_recent)")),
        ("recent_dur", format!("{W} (github_actions_run_recent_duration_seconds)")),
        // claude-acct's textfile, only while it is fresh; no `max without` here, which would drop
        // the metric names the card reads. An empty answer makes the card say no data.
        ("accounts", r#"{__name__=~"claude_account_.+"} and on (instance) (time() - node_textfile_mtime_seconds{file=~".*claude_acct.prom"} < 3600)"#.into()),
        // The same three sources as the dashboard's "What is red" table.
        ("red", r#"label_replace(mqtt_tripped{topic=~"agents_.+_watch_.+"} == 1, "item", "watch $1", "topic", "agents_.+_watch_(.+)")
            or label_replace(mqtt_failed{topic=~"agents_.+_runner_.+"} == 1, "item", "runner $1", "topic", "agents_.+_runner_(.+)")
            or label_replace(kube_node_status_condition{condition="Ready",status="true"} == 0, "item", "node $1 NotReady", "node", "(.+)")"#.into()),
    ]
}
const OPTIONAL: &[&str] = &[
    "red",
    "accounts",
    "cores",
    "runner_cores",
    "withheld",
    "recent",
    "recent_dur",
];

#[derive(Serialize, Default)]
pub struct Infra {
    pub ok: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
    /// When Prometheus was asked, unix seconds.
    pub at: u64,
    /// `CC_GRAFANA_URL`, for the tab's links.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub grafana: Option<String>,
    pub instant: BTreeMap<&'static str, Vec<Series>>,
}

async fn gather() -> Infra {
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    let mut out = Infra {
        at: now,
        grafana: std::env::var("CC_GRAFANA_URL").ok(),
        ..Default::default()
    };
    let base = match prom::base() {
        Ok(b) => b,
        Err(e) => {
            out.error = Some(e);
            return out;
        }
    };
    let mut set = tokio::task::JoinSet::new();
    for (name, q) in instant_queries() {
        let base = base.clone();
        set.spawn_blocking(move || (name, prom::instant(&base, &q)));
    }
    let mut errors = vec![];
    while let Some(Ok((name, res))) = set.join_next().await {
        match res {
            Ok(s) => _ = out.instant.insert(name, s),
            Err(e) if !OPTIONAL.contains(&name) => errors.push(e),
            Err(_) => {}
        }
    }
    errors.sort();
    errors.dedup();
    if errors.is_empty()
        && out.instant.get("cc").is_some_and(|s| {
            !s.iter()
                .any(|x| x.labels["__name__"] == "cc:overall_status")
        })
    {
        errors.push("no cc:* series (recording rules not loaded?)".into());
    }
    out.ok = errors.is_empty();
    out.error = (!errors.is_empty()).then(|| errors.join("; "));
    out
}

/// The last answer as JSON, and when it was made. Holding the lock while Prometheus is asked
/// also folds concurrent requests into one round of queries.
#[derive(Default)]
pub struct Cache(Mutex<Option<(Instant, String)>>);

impl Cache {
    pub async fn get(&self) -> String {
        let mut c = self.0.lock().await;
        if let Some((at, body)) = c.as_ref() {
            if at.elapsed() < CACHE {
                return body.clone();
            }
        }
        let body = serde_json::to_string(&gather().await)
            .unwrap_or_else(|e| format!(r#"{{"ok":false,"error":"{e}"}}"#));
        *c = Some((Instant::now(), body.clone()));
        body
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_the_extras_are_optional() {
        let names: Vec<_> = instant_queries().into_iter().map(|(n, _)| n).collect();
        assert!(OPTIONAL.iter().all(|o| names.contains(o)));
        assert_eq!(
            OPTIONAL,
            [
                "red",
                "accounts",
                "cores",
                "runner_cores",
                "withheld",
                "recent",
                "recent_dur"
            ]
        );
    }
}
