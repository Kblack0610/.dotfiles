//! The Infra tab's Cloud runners card: hold a powered standby host on or off for some hours, or
//! hand it back to the governor.
//!
//! home-config's ci-runner-governor owns the power; it reads ConfigMap
//! `ci-runner-governor-override` (namespace monitoring), one key per host holding
//! `{"action":"on"|"off","until":<epoch>}`, and ignores a key that has run out. This only writes
//! that ConfigMap, with kubectl on the command-center context (`CC_KUBE_CONTEXT`), so the page
//! never holds an AWS credential. A host is accepted only when the governor's own metrics name
//! it. Every call is plain arguments, and kubectl's stderr comes back as the error.

use axum::http::StatusCode;
use axum::Json;
use serde::Deserialize;
use serde_json::{json, Map, Value};

use crate::{bad, run_cmd, ApiResult};

const NAMESPACE: &str = "monitoring";
const CONFIGMAP: &str = "ci-runner-governor-override";
/// The longest override the button sets: the governor's daily cap is 12 h.
const MAX_HOURS: u64 = 12;
const REQUEST_TIMEOUT: &str = "--request-timeout=15s";

#[derive(Deserialize)]
pub struct Body {
    host: String,
    action: String,
    #[serde(default)]
    hours: u64,
}

/// The host's new key, or None to remove it (clear), or why the body is refused.
fn entry(action: &str, hours: u64, now: u64) -> Result<Option<String>, &'static str> {
    match action {
        "clear" => Ok(None),
        "on" | "off" if (1..=MAX_HOURS).contains(&hours) => {
            Ok(Some(json!({"action": action, "until": now + hours * 3600}).to_string()))
        }
        "on" | "off" => Err("hours is 1 to 12"),
        _ => Err("action is on, off or clear"),
    }
}

/// The ConfigMap to apply: the current one's keys (from `kubectl get -o json`, empty when it
/// does not exist yet) with `host` set or removed. A whole object, so apply also drops a cleared key.
fn manifest(current: &str, host: &str, entry: Option<String>) -> Value {
    let mut data: Map<String, Value> = serde_json::from_str::<Value>(current)
        .ok()
        .and_then(|v| v.get("data").and_then(Value::as_object).cloned())
        .unwrap_or_default();
    match entry {
        Some(e) => _ = data.insert(host.to_string(), Value::String(e)),
        None => _ = data.remove(host),
    }
    json!({
        "apiVersion": "v1",
        "kind": "ConfigMap",
        "metadata": {"name": CONFIGMAP, "namespace": NAMESPACE},
        "data": data,
    })
}

/// The hosts the governor powers, from its `ci_governor_power_state` series.
fn governed_hosts() -> Result<Vec<String>, String> {
    let base = hub_core::prom::base()?;
    let series = hub_core::prom::instant(&base, "max by (host) (ci_governor_power_state)")?;
    Ok(series
        .iter()
        .map(|s| s.label("host").to_string())
        .collect())
}

pub async fn set(Json(b): Json<Body>) -> ApiResult<Json<Value>> {
    let now = hub_core::jobs::now().max(0) as u64;
    let new = entry(&b.action, b.hours, now).map_err(|m| bad(StatusCode::BAD_REQUEST, m))?;
    let host = b.host.clone();
    let hosts = tokio::task::spawn_blocking(governed_hosts)
        .await
        .map_err(|e| bad(StatusCode::INTERNAL_SERVER_ERROR, e.to_string()))?
        .map_err(|e| bad(StatusCode::BAD_GATEWAY, format!("cannot read the governor's hosts: {e}")))?;
    if !hosts.contains(&host) {
        return Err(bad(
            StatusCode::BAD_REQUEST,
            format!("{host} is not a host the governor powers"),
        ));
    }
    let ctx = hub_core::prom::config("CC_KUBE_CONTEXT").ok_or_else(|| {
        bad(
            StatusCode::INTERNAL_SERVER_ERROR,
            "CC_KUBE_CONTEXT is not set: it comes from ~/.config/command-center/env",
        )
    })?;
    let kube = ["--context", ctx.as_str(), REQUEST_TIMEOUT, "-n", NAMESPACE];
    let get: Vec<&str> = kube
        .into_iter()
        .chain(["get", "configmap", CONFIGMAP, "-o", "json", "--ignore-not-found"])
        .collect();
    let current = run_cmd("kubectl", &get, None).await?;
    let body = manifest(&current, &host, new).to_string();
    let apply: Vec<&str> = kube.into_iter().chain(["apply", "-f", "-"]).collect();
    let out = run_cmd("kubectl", &apply, Some(&body)).await?;
    Ok(Json(json!({ "out": out.trim() })))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn on_and_off_run_for_their_hours_and_clear_removes() {
        let on = entry("on", 2, 1000).unwrap().unwrap();
        assert_eq!(
            serde_json::from_str::<Value>(&on).unwrap(),
            json!({"action": "on", "until": 1000 + 7200})
        );
        assert!(entry("off", 12, 0).unwrap().is_some());
        assert_eq!(entry("clear", 0, 0), Ok(None));
    }

    #[test]
    fn a_body_outside_the_button_is_refused() {
        assert!(entry("on", 0, 0).is_err());
        assert!(entry("off", 13, 0).is_err());
        assert!(entry("start", 2, 0).is_err());
        assert!(entry("--force", 2, 0).is_err());
        assert!(entry("", 2, 0).is_err());
    }

    #[test]
    fn the_manifest_keeps_other_hosts_and_drops_a_cleared_one() {
        let current = r#"{"data":{"aws-burst-1":"old","aws-burst-2":"keep"}}"#;
        let m = manifest(current, "aws-burst-1", Some("new".into()));
        assert_eq!(m["metadata"]["name"], CONFIGMAP);
        assert_eq!(m["metadata"]["namespace"], NAMESPACE);
        assert_eq!(m["data"], json!({"aws-burst-1": "new", "aws-burst-2": "keep"}));
        let m = manifest(current, "aws-burst-1", None);
        assert_eq!(m["data"], json!({"aws-burst-2": "keep"}));
    }

    #[test]
    fn no_configmap_yet_starts_empty() {
        let m = manifest("", "aws-burst-1", Some("x".into()));
        assert_eq!(m["data"], json!({"aws-burst-1": "x"}));
        assert_eq!(manifest("", "h", None)["data"], json!({}));
    }
}
