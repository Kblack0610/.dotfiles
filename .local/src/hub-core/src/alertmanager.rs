//! What Alertmanager says is firing: `GET <CC_ALERTMANAGER_URL>/api/v2/alerts`, active and
//! neither silenced nor inhibited, one row per alert. `infra::gather` asks it beside its
//! Prometheus queries, so the answer is cached wherever Infra's is (agent-web's
//! `infra::CACHE_SECS`, the TUI's Prometheus read) and no surface keeps a second cadence.
//!
//! Alertmanager has no change feed a reader can subscribe to without a webhook listener, so this
//! is a poll, the same as Prometheus (dashboards rule 9).

use std::collections::BTreeMap;

use serde::Serialize;
use serde_json::Value;

use crate::prom;

/// Active alerts a human has not silenced and no rule inhibits: what is firing and unhandled.
const FILTER: [(&str, &str); 3] = [
    ("active", "true"),
    ("silenced", "false"),
    ("inhibited", "false"),
];

/// One firing alert.
#[derive(Serialize, Debug, Default, Clone, PartialEq)]
pub struct Firing {
    pub name: String,
    /// The rule's `severity` label: `critical`, `warning` or `info`.
    pub severity: String,
    /// When it started firing, epoch seconds.
    pub since: Option<i64>,
    pub summary: String,
    pub description: String,
    pub runbook: String,
    /// Every label but `alertname`, `severity` and `prometheus` (the stack's own name).
    pub labels: BTreeMap<String, String>,
    /// The receivers it routed to (`ntfy`, `ntfy-digest`).
    pub receivers: Vec<String>,
}

/// Ask Alertmanager at `CC_ALERTMANAGER_URL` through curl.
pub fn read() -> Result<Vec<Firing>, String> {
    let base = prom::required("CC_ALERTMANAGER_URL")?;
    let params = FILTER.map(|(k, v)| (k, v.to_string()));
    parse(&prom::get_json(
        base.trim_end_matches('/'),
        "/api/v2/alerts",
        &params,
    )?)
}

/// The API's answer as rows. Severity `none` is dropped: Watchdog and InfoInhibitor fire by
/// design, to prove the pipeline and to inhibit, and are no one's to fix.
pub fn parse(v: &Value) -> Result<Vec<Firing>, String> {
    let list = v.as_array().ok_or("not an Alertmanager alert list")?;
    let s = |v: &Value| v.as_str().unwrap_or_default().to_string();
    Ok(list
        .iter()
        .filter(|a| a["labels"]["severity"] != "none")
        .map(|a| Firing {
            name: s(&a["labels"]["alertname"]),
            severity: s(&a["labels"]["severity"]),
            since: a["startsAt"].as_str().and_then(crate::fleet::ts),
            summary: s(&a["annotations"]["summary"]),
            description: s(&a["annotations"]["description"]),
            runbook: s(&a["annotations"]["runbook_url"]),
            labels: a["labels"]
                .as_object()
                .into_iter()
                .flatten()
                .filter(|(k, _)| !matches!(k.as_str(), "alertname" | "severity" | "prometheus"))
                .map(|(k, v)| (k.clone(), s(v)))
                .collect(),
            receivers: a["receivers"]
                .as_array()
                .into_iter()
                .flatten()
                .map(|r| s(&r["name"]))
                .collect(),
        })
        .collect())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_the_api_answer_and_drops_the_by_design_alerts() {
        let v = serde_json::json!([
            {"labels": {"alertname": "HomelabBackupStale", "severity": "critical", "namespace": "freqtrade",
                        "prometheus": "monitoring/kube-prometheus-stack-prometheus"},
             "annotations": {"summary": "Backup stale: freqtrade/lab", "description": "No backup in 26h."},
             "startsAt": "2026-11-11T13:22:33.922Z", "receivers": [{"name": "ntfy-critical"}],
             "status": {"state": "active"}},
            {"labels": {"alertname": "Watchdog", "severity": "none"}, "annotations": {},
             "startsAt": "2026-11-01T00:00:00Z", "receivers": [{"name": "null"}]}
        ]);
        let got = parse(&v).unwrap();
        assert_eq!(got.len(), 1, "Watchdog is dropped: {got:?}");
        let a = &got[0];
        assert_eq!(
            (a.name.as_str(), a.severity.as_str()),
            ("HomelabBackupStale", "critical")
        );
        assert_eq!(a.since, Some(1_794_403_353));
        assert_eq!(a.summary, "Backup stale: freqtrade/lab");
        assert_eq!(
            a.labels.keys().collect::<Vec<_>>(),
            ["namespace"],
            "alertname, severity and prometheus are not location"
        );
        assert_eq!(a.receivers, ["ntfy-critical"]);
    }

    #[test]
    fn an_answer_that_is_not_a_list_is_an_error() {
        assert!(parse(&serde_json::json!({"error": "x"})).is_err());
        assert_eq!(parse(&serde_json::json!([])), Ok(vec![]));
    }
}
