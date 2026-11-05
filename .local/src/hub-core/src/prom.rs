//! Prometheus answers as flat series. The endpoint is `CC_PROM_URL`, from the environment or
//! else the boards' `~/.config/command-center/env` (stowed from the private overlay, and the
//! file agent-web's unit loads as its EnvironmentFile).

use std::collections::BTreeMap;
use std::process::Command;

use serde::Serialize;
use serde_json::Value;

/// The timeout guard on each query, as the bash board's `curl -m 10`. `PROM_TIMEOUT` overrides it,
/// the name `prom.sh` reads, for a caller with a tighter budget.
const QUERY_TIMEOUT_SECS: &str = "10";

/// Scrape-target labels, stripped so two exporter pods during a rollout read as one row.
pub const W: &str = "max without (instance, pod, job, namespace, service, endpoint, container)";

#[derive(Serialize, Debug, PartialEq, Clone)]
pub struct Series {
    pub labels: BTreeMap<String, String>,
    /// An instant query's value; None for a range or a value that is not a number.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub value: Option<f64>,
    /// A range query's `[unix seconds, value]` points.
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub points: Vec<(f64, f64)>,
}

impl Series {
    /// A label, or "" when the series has none by that name.
    pub fn label(&self, k: &str) -> &str {
        self.labels.get(k).map(String::as_str).unwrap_or("")
    }
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

/// A board setting: the environment wins, else its `KEY=value` line in
/// `~/.config/command-center/env`, so a TUI started from tmux or waybar needs no wrapper.
pub fn config(key: &str) -> Option<String> {
    if let Ok(v) = std::env::var(key) {
        return Some(v).filter(|v| !v.is_empty());
    }
    let home = std::env::var("HOME").ok()?;
    let file = std::fs::read_to_string(format!("{home}/.config/command-center/env")).ok()?;
    env_line(&file, key)
}

/// The value of `key` in a shell env file: the last `KEY=value` (or `export KEY=value`) line,
/// with one level of quotes removed. Anything fancier than that is not read.
fn env_line(file: &str, key: &str) -> Option<String> {
    file.lines()
        .filter_map(|l| {
            let l = l.trim();
            let l = l.strip_prefix("export ").unwrap_or(l);
            let v = l.strip_prefix(key)?.strip_prefix('=')?;
            let v = v.trim();
            let v = v
                .strip_prefix('"')
                .and_then(|x| x.strip_suffix('"'))
                .or_else(|| v.strip_prefix('\'').and_then(|x| x.strip_suffix('\'')))
                .unwrap_or(v);
            Some(v.to_string())
        })
        .next_back()
        .filter(|v| !v.is_empty())
}

/// `CC_PROM_URL`, or why it is missing.
pub fn base() -> Result<String, String> {
    config("CC_PROM_URL").ok_or_else(|| {
        "CC_PROM_URL is not set: it comes from ~/.config/command-center/env".to_string()
    })
}

/// Ask `<base>/api/v1/<path>` (query or query_range) through curl.
pub fn query(base: &str, path: &str, params: &[(&str, String)]) -> Result<Vec<Series>, String> {
    let mut cmd = Command::new("curl");
    cmd.args([
        "-sf",
        "-m",
        &std::env::var("PROM_TIMEOUT").unwrap_or_else(|_| QUERY_TIMEOUT_SECS.into()),
        "-G",
        &format!("{base}/api/v1/{path}"),
    ]);
    for (k, v) in params {
        cmd.arg("--data-urlencode").arg(format!("{k}={v}"));
    }
    let out = cmd.output().map_err(|e| format!("curl: {e}"))?;
    if !out.status.success() {
        return Err(format!("cannot read {base}"));
    }
    let v: Value = serde_json::from_slice(&out.stdout).map_err(|e| format!("{base}: {e}"))?;
    flatten(&v)
}

/// One instant query.
pub fn instant(base: &str, q: &str) -> Result<Vec<Series>, String> {
    query(base, "query", &[("query", q.to_string())])
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
    fn reads_a_setting_from_an_env_file() {
        let f = "# endpoints\nCC_PROM_URL=http://old\nexport CC_PROM_URL=\"http://prom.lan\"\nCC_GRAFANA_URL='http://g'\nCC_HOSTS=\n";
        assert_eq!(
            env_line(f, "CC_PROM_URL").as_deref(),
            Some("http://prom.lan")
        );
        assert_eq!(env_line(f, "CC_GRAFANA_URL").as_deref(), Some("http://g"));
        assert_eq!(env_line(f, "CC_HOSTS"), None, "an empty value is no value");
        assert_eq!(
            env_line(f, "CC_PROM"),
            None,
            "a prefix of a key is not the key"
        );
    }

    #[test]
    fn an_error_answer_is_an_error() {
        let v: Value = serde_json::json!({"status": "error", "error": "parse error"});
        assert_eq!(flatten(&v), Err("parse error".into()));
        assert!(flatten(&serde_json::json!("<html>")).is_err());
    }
}
