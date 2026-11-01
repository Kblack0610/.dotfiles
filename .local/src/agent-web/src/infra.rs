//! The Infra tab: the hub:infra board (`command-center.sh`, Prefix e) for the browser. It asks
//! Prometheus the board's own questions, so the tab, the board and Grafana's kb-command-center
//! all read the same `cc:*` rules (home-config `apps/monitoring/prometheus-rules-command-center.yaml`)
//! and the same runner-exporter series, and none of them judges anything itself.
//!
//! Endpoints come from `CC_PROM_URL` and `CC_GRAFANA_URL`, the board's
//! `~/.config/command-center/env`, which the unit loads as its EnvironmentFile.

use std::collections::BTreeMap;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use serde::Serialize;
use serde_json::Value;
use tokio::sync::Mutex;

/// Prometheus evaluates the rules every minute; a second tab or a reload inside this window is
/// served the last answer instead of asking again.
const CACHE: Duration = Duration::from_secs(30);
/// The timeout guard on each query, as the board's `curl -m 10`.
const QUERY_TIMEOUT_SECS: &str = "10";
const RANGE_HOURS: u64 = 24;
const RANGE_STEP_SECS: u64 = 600;
/// Scrape-target labels, stripped so two exporter pods during a rollout read as one row.
const W: &str = "max without (instance, pod, job, namespace, service, endpoint, container)";
/// Keeps a machine's run ledger series only while its textfile is fresh, as `cc:host_local_done_24h`.
const LOCAL_FRESH: &str = r#"and on (instance) (time() - node_textfile_mtime_seconds{file=~".*fleet_local.prom"} < 180)"#;

/// The board's `fetch()` queries, by name. All but `red` must answer or the tab shows the
/// error instead of numbers, as the board blanks rather than leave stale values up.
fn instant_queries() -> Vec<(&'static str, String)> {
    vec![
        ("cc", r#"{__name__=~"cc:.+",__name__!~"cc:host_instance|cc:host_local_gate"}"#.into()),
        ("runners", format!("{W} (github_runner_state)")),
        ("waiting", format!("{W} (github_actions_job_waiting)")),
        ("finished", format!("sum by (repo, workflow, conclusion, scope) ({W} (github_runs_finished))")),
        ("api", "min(github_runner_exporter_api_ok)".into()),
        ("gates", "cc:host_local_gate".into()),
        // Done today: when runs finished, and which failed. An absent metric is an empty answer,
        // so the tab says "no data" rather than an error until the exporters publish them.
        ("hourly", format!("sum by (hour, conclusion, scope) ({W} (github_runs_by_hour))")),
        ("failed", format!("{W} (github_run_failed)")),
        ("local_hourly", format!("sum by (hour, result) (fleet_local_gate_by_hour {LOCAL_FRESH})")),
        ("local_failed", format!("sum by (hour, repo, branch, platform, result) (fleet_local_gate_failed {LOCAL_FRESH})")),
        // The same three sources as the dashboard's "What is red" table.
        ("red", r#"label_replace(mqtt_tripped{topic=~"agents_.+_watch_.+"} == 1, "item", "watch $1", "topic", "agents_.+_watch_(.+)")
            or label_replace(mqtt_failed{topic=~"agents_.+_runner_.+"} == 1, "item", "runner $1", "topic", "agents_.+_runner_(.+)")
            or label_replace(kube_node_status_condition{condition="Ready",status="true"} == 0, "item", "node $1 NotReady", "node", "(.+)")"#.into()),
    ]
}
const OPTIONAL: &[&str] = &["red"];

/// The last day of what the tab charts. A failed range query only leaves its chart empty.
fn range_queries() -> Vec<(&'static str, String)> {
    vec![
        ("domains", "cc:domain_status".into()),
        ("overall", "cc:overall_status".into()),
        // The workstation's local Unity queue is one more pool, as on the board.
        ("queue", r#"sum by (pool) (cc:pool_waiting) or label_replace(sum(cc:host_local_queued), "pool", "unity-local", "", "")"#.into()),
        ("busy", "sum(cc:pool_busy) + (sum(cc:host_local_busy) or vector(0))".into()),
        ("sessions", "cc:sessions_working".into()),
    ]
}

#[derive(Serialize, Debug, PartialEq)]
pub struct Series {
    pub labels: BTreeMap<String, String>,
    /// An instant query's value; None for a range or a value that is not a number.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub value: Option<f64>,
    /// A range query's `[unix seconds, value]` points.
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub points: Vec<(f64, f64)>,
}

fn num(v: &Value) -> Option<f64> {
    v.as_str()?.parse::<f64>().ok().filter(|f| f.is_finite())
}

/// A Prometheus `/api/v1/query(_range)` answer as one Series per result, labels and all.
pub fn flatten(resp: &Value) -> Result<Vec<Series>, String> {
    if resp["status"] != "success" {
        return Err(resp["error"]
            .as_str()
            .unwrap_or("not a Prometheus answer")
            .to_string());
    }
    let result = resp["data"]["result"].as_array().ok_or("no data.result")?;
    Ok(result
        .iter()
        .map(|r| Series {
            labels: r["metric"]
                .as_object()
                .map(|m| {
                    m.iter()
                        .filter_map(|(k, v)| Some((k.clone(), v.as_str()?.to_string())))
                        .collect()
                })
                .unwrap_or_default(),
            value: r["value"].get(1).and_then(num),
            points: r["values"]
                .as_array()
                .map(|vs| {
                    vs.iter()
                        .filter_map(|p| Some((p.get(0)?.as_f64()?, num(p.get(1)?)?)))
                        .collect()
                })
                .unwrap_or_default(),
        })
        .collect())
}

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
    pub range: BTreeMap<&'static str, Vec<Series>>,
}

async fn query(base: &str, path: &str, params: &[(&str, String)]) -> Result<Vec<Series>, String> {
    let mut cmd = tokio::process::Command::new("curl");
    cmd.args([
        "-sf",
        "-m",
        QUERY_TIMEOUT_SECS,
        "-G",
        &format!("{base}/api/v1/{path}"),
    ]);
    for (k, v) in params {
        cmd.arg("--data-urlencode").arg(format!("{k}={v}"));
    }
    let out = cmd.output().await.map_err(|e| format!("curl: {e}"))?;
    if !out.status.success() {
        return Err(format!("cannot read {base}"));
    }
    let v: Value = serde_json::from_slice(&out.stdout).map_err(|e| format!("{base}: {e}"))?;
    flatten(&v)
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
    let Ok(base) = std::env::var("CC_PROM_URL") else {
        out.error = Some(
            "CC_PROM_URL is not set: the unit loads it from ~/.config/command-center/env".into(),
        );
        return out;
    };
    let mut set = tokio::task::JoinSet::new();
    for (name, q) in instant_queries() {
        let base = base.clone();
        set.spawn(async move { (false, name, query(&base, "query", &[("query", q)]).await) });
    }
    let (start, step) = (now - RANGE_HOURS * 3600, RANGE_STEP_SECS.to_string());
    for (name, q) in range_queries() {
        let (base, step) = (base.clone(), step.clone());
        set.spawn(async move {
            let p = [
                ("query", q),
                ("start", start.to_string()),
                ("end", now.to_string()),
                ("step", step),
            ];
            (true, name, query(&base, "query_range", &p).await)
        });
    }
    let mut errors = vec![];
    while let Some(Ok((range, name, res))) = set.join_next().await {
        match (res, range) {
            (Ok(s), true) => _ = out.range.insert(name, s),
            (Ok(s), false) => _ = out.instant.insert(name, s),
            (Err(e), false) if !OPTIONAL.contains(&name) => errors.push(e),
            (Err(_), _) => {}
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
    fn flattens_an_instant_answer() {
        let v: Value = serde_json::json!({"status": "success", "data": {"resultType": "vector", "result": [
            {"metric": {"__name__": "cc:pool_busy", "pool": "unity"}, "value": [1.7e9, "4"]},
            {"metric": {"__name__": "cc:pool_busy", "pool": "x"}, "value": [1.7e9, "NaN"]}
        ]}});
        let s = flatten(&v).unwrap();
        assert_eq!(s[0].labels["pool"], "unity");
        assert_eq!(s[0].value, Some(4.0));
        assert_eq!(
            s[1].value, None,
            "NaN is no number, and JSON cannot carry it"
        );
        assert!(s[0].points.is_empty());
    }

    #[test]
    fn flattens_a_range_answer() {
        let v: Value = serde_json::json!({"status": "success", "data": {"resultType": "matrix", "result": [
            {"metric": {"domain": "ci"}, "values": [[100.0, "0"], [700.0, "2"]]}
        ]}});
        let s = flatten(&v).unwrap();
        assert_eq!(s[0].points, vec![(100.0, 0.0), (700.0, 2.0)]);
        assert_eq!(s[0].value, None);
    }

    #[test]
    fn an_error_answer_is_an_error() {
        let v: Value = serde_json::json!({"status": "error", "error": "parse error"});
        assert_eq!(flatten(&v), Err("parse error".into()));
        assert!(flatten(&serde_json::json!("<html>")).is_err());
    }

    #[test]
    fn red_is_the_only_optional_query() {
        let names: Vec<_> = instant_queries().into_iter().map(|(n, _)| n).collect();
        assert!(OPTIONAL.iter().all(|o| names.contains(o)));
        assert_eq!(OPTIONAL, ["red"]);
    }
}
