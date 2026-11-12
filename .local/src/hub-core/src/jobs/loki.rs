//! A k8s Job's pod logs, from Loki. Loki is ClusterIP-only, so the query goes through
//! `kube_proxy` (`CC_KUBE_CONTEXT`, `CC_LOKI_SERVICE`).

use serde_json::Value;

use crate::kube_proxy::{self, encode, label};

/// The most lines asked of Loki for one Job: its last ones, which is where a failure is.
const LINES: usize = 5000;
/// Slack around the Job's start and end, for a pod that logs before the Job records its start.
const PAD_SECS: i64 = 60;
/// The API server path that asks Loki for the pods of Job `job` between `from` and `to` (unix
/// seconds). A Job's pods are named `<job>-<5 random>`, which keeps a Job named `x` from
/// matching the pods of a Job named `x-1`.
pub(super) fn path(ns: &str, job: &str, from: i64, to: i64) -> String {
    let q = format!(r#"{{namespace="{ns}", pod=~"{job}-[a-z0-9]{{5}}"}}"#);
    format!(
        "/loki/api/v1/query_range?query={}&start={}&end={}&limit={LINES}&direction=backward",
        encode(&q),
        (from - PAD_SECS) * 1_000_000_000,
        (to + PAD_SECS) * 1_000_000_000,
    )
}

/// Loki's answer as one log, oldest line first. With more than one container, each line
/// names its container.
pub(super) fn text(body: &str) -> Result<String, String> {
    let v: Value = serde_json::from_str(body).map_err(|e| format!("Loki answer: {e}"))?;
    let streams = v["data"]["result"]
        .as_array()
        .ok_or("Loki answer has no data.result")?;
    let mut lines: Vec<(u128, &str, &str)> = Vec::new();
    for s in streams {
        let c = s["stream"]["container"].as_str().unwrap_or("");
        for e in s["values"].as_array().into_iter().flatten() {
            let ts = e[0].as_str().and_then(|t| t.parse().ok()).unwrap_or(0);
            lines.push((ts, c, e[1].as_str().unwrap_or("")));
        }
    }
    if lines.is_empty() {
        return Ok("(Loki has no lines from this Job's pods)\n".into());
    }
    lines.sort_by_key(|l| l.0);
    let named = lines.iter().any(|l| l.1 != lines[0].1);
    let mut out = String::new();
    if lines.len() >= LINES {
        out.push_str(&format!("(last {LINES} lines)\n"));
    }
    for (_, c, l) in lines {
        if named {
            out.push_str(&format!("[{c}] "));
        }
        out.push_str(l.trim_end_matches('\n'));
        out.push('\n');
    }
    Ok(out)
}

/// The log of k8s Job `ns/job` that started at `from` and ended at `to` (None: still running).
pub(super) fn job_log(ns: &str, job: &str, from: i64, to: Option<i64>) -> Result<String, String> {
    if !label(ns) || !label(job) {
        return Err("bad namespace or job name".into());
    }
    let to = to.unwrap_or_else(|| chrono::Utc::now().timestamp());
    text(&kube_proxy::get(
        "CC_LOKI_SERVICE",
        &path(ns, job, from, to),
    )?)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_query_names_only_this_jobs_pods_in_its_window() {
        let p = path("nas", "backup-29895060", 1000, 1200);
        assert!(p.starts_with("/loki/api/v1/query_range?query="));
        assert!(p.contains(&encode(
            r#"{namespace="nas", pod=~"backup-29895060-[a-z0-9]{5}"}"#
        )));
        assert!(p.contains("&start=940000000000&end=1260000000000&"));
        assert!(!p[p.find('?').unwrap()..].contains(['{', '"', ' ']));
    }

    #[test]
    fn a_name_that_could_change_the_query_is_refused_before_kubectl() {
        for bad in ["", "a\"}", "A", "-a", "a-", "a b", "a/b", &"a".repeat(64)] {
            assert_eq!(
                job_log(bad, "j", 0, None),
                Err("bad namespace or job name".into())
            );
        }
    }

    #[test]
    fn lines_from_every_stream_read_oldest_first() {
        let one = r#"{"data":{"result":[{"stream":{"container":"backup"},
            "values":[["300","third\n"],["100","first"]]},
            {"stream":{"container":"backup"},"values":[["200","second"]]}]}}"#;
        assert_eq!(text(one).unwrap(), "first\nsecond\nthird\n");
        let two = r#"{"data":{"result":[{"stream":{"container":"init"},"values":[["1","a"]]},
            {"stream":{"container":"main"},"values":[["2","b"]]}]}}"#;
        assert_eq!(text(two).unwrap(), "[init] a\n[main] b\n");
        let none = r#"{"data":{"result":[]}}"#;
        assert!(text(none).unwrap().contains("no lines"));
        assert!(
            text("{}").is_err(),
            "an answer without a result is an error, not empty"
        );
    }
}
