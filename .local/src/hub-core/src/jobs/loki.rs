//! A k8s Job's pod logs, from Loki. Loki is ClusterIP-only, so the query goes through the API
//! server's service proxy (`kubectl get --raw`) with the kube credentials already on this
//! machine: no ingress and no token. Which cluster, and which service, are board settings
//! (`CC_KUBE_CONTEXT`, `CC_LOKI_SERVICE`), so no cluster is assumed.

use serde_json::Value;

use super::log::run;
use crate::prom::config;

/// The most lines asked of Loki for one Job: its last ones, which is where a failure is.
const LINES: usize = 5000;
/// Slack around the Job's start and end, for a pod that logs before the Job records its start.
const PAD_SECS: i64 = 60;
/// A guard on the API server call.
const REQUEST_TIMEOUT: &str = "--request-timeout=10s";

/// A namespace, Job or service name: a DNS-1123 label, so it cannot break out of the query.
fn label(s: &str) -> bool {
    !s.is_empty()
        && s.len() <= 63
        && !s.starts_with('-')
        && !s.ends_with('-')
        && s.bytes()
            .all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'-')
}

/// `namespace/name:port` as its three parts.
fn service(s: &str) -> Option<(&str, &str, u16)> {
    let (ns, rest) = s.split_once('/')?;
    let (name, port) = rest.split_once(':')?;
    let port = port.parse().ok()?;
    (label(ns) && label(name)).then_some((ns, name, port))
}

fn encode(s: &str) -> String {
    s.bytes()
        .map(|b| match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => {
                (b as char).to_string()
            }
            _ => format!("%{b:02X}"),
        })
        .collect()
}

/// The API server path that asks Loki for the pods of Job `job` between `from` and `to` (unix
/// seconds). A Job's pods are named `<job>-<5 random>`, which keeps a Job named `x` from
/// matching the pods of a Job named `x-1`.
pub(super) fn path(svc: (&str, &str, u16), ns: &str, job: &str, from: i64, to: i64) -> String {
    let q = format!(r#"{{namespace="{ns}", pod=~"{job}-[a-z0-9]{{5}}"}}"#);
    format!(
        "/api/v1/namespaces/{}/services/{}:{}/proxy/loki/api/v1/query_range?query={}&start={}&end={}&limit={LINES}&direction=backward",
        svc.0,
        svc.1,
        svc.2,
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
    let ctx = config("CC_KUBE_CONTEXT")
        .ok_or("CC_KUBE_CONTEXT is not set: it comes from ~/.config/command-center/env")?;
    let svc = config("CC_LOKI_SERVICE")
        .ok_or("CC_LOKI_SERVICE is not set: it comes from ~/.config/command-center/env")?;
    let svc = service(&svc).ok_or("CC_LOKI_SERVICE is not namespace/name:port")?;
    let to = to.unwrap_or_else(|| chrono::Utc::now().timestamp());
    let p = path(svc, ns, job, from, to);
    text(&run(
        "kubectl",
        &["--context", &ctx, REQUEST_TIMEOUT, "get", "--raw", &p],
    )?)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_query_names_only_this_jobs_pods_in_its_window() {
        let p = path(
            ("monitoring", "loki", 3100),
            "nas",
            "backup-29895060",
            1000,
            1200,
        );
        assert!(p.starts_with(
            "/api/v1/namespaces/monitoring/services/loki:3100/proxy/loki/api/v1/query_range?query="
        ));
        assert!(p.contains(&encode(
            r#"{namespace="nas", pod=~"backup-29895060-[a-z0-9]{5}"}"#
        )));
        assert!(p.contains("&start=940000000000&end=1260000000000&"));
        assert!(!p[p.find('?').unwrap()..].contains(['{', '"', ' ']));
    }

    #[test]
    fn a_name_that_could_change_the_query_is_refused_before_kubectl() {
        for bad in ["", "a\"}", "A", "-a", "a-", "a b", "a/b", &"a".repeat(64)] {
            assert!(!label(bad), "{bad:?}");
            assert_eq!(
                job_log(bad, "j", 0, None),
                Err("bad namespace or job name".into())
            );
        }
        assert!(label("actual-budget-backup-29895060"));
        assert_eq!(
            service("monitoring/loki:3100"),
            Some(("monitoring", "loki", 3100))
        );
        assert_eq!(service("monitoring/loki"), None);
        assert_eq!(service("Mon/loki:3100"), None);
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
