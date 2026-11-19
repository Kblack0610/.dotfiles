//! A machine page's Governor buttons (`#infra/machines/<host>`): hold a powered standby host on or
//! off for some hours, or hand it back to the governor.
//!
//! home-config's ci-runner-governor owns the power; it reads ConfigMap
//! `ci-runner-governor-override` (namespace monitoring), whose contract is home-config
//! `apps/ci-runner-governor/override.schema.json`: this writes only the host's `<host>.power` key,
//! `{"action":"on"|"off","until":<epoch>}`, with `kubectl patch --type merge` (a null removes it),
//! so no other writer's key is read or rewritten. It runs kubectl on the command-center context
//! (`CC_KUBE_CONTEXT`), so the page never holds an AWS credential. A host is accepted only when
//! the governor's own metrics name it, and the hours limit is its `ci_governor_override_max_hours`.
//! Every call is plain arguments, and kubectl's stderr comes back as the error.

use axum::http::StatusCode;
use axum::Json;
use serde::Deserialize;
use serde_json::{json, Value};

use crate::{bad, run_cmd, ApiResult};

const NAMESPACE: &str = "monitoring";
const CONFIGMAP: &str = "ci-runner-governor-override";
const REQUEST_TIMEOUT: &str = "--request-timeout=15s";

#[derive(Deserialize)]
pub struct Body {
    host: String,
    action: String,
    #[serde(default)]
    hours: u64,
}

/// The host's power key's new value, or None to remove it (clear), or why the body is refused.
/// `max_hours` is the governor's own limit on an on (`ci_governor_override_max_hours`).
fn entry(action: &str, hours: u64, now: u64, max_hours: u64) -> Result<Option<String>, String> {
    match action {
        "clear" => Ok(None),
        "on" | "off" if (1..=max_hours).contains(&hours) => Ok(Some(
            json!({"action": action, "until": now + hours * 3600}).to_string(),
        )),
        "on" | "off" => Err(format!("hours is 1 to {max_hours}")),
        _ => Err("action is on, off or clear".into()),
    }
}

/// The host's family key in the override ConfigMap.
fn key(host: &str) -> String {
    format!("{host}.power")
}

/// The merge-patch that sets the host's key, or removes it with a null.
fn patch(host: &str, entry: Option<&str>) -> Value {
    json!({"data": {key(host): entry}})
}

/// The hosts the governor powers (its `ci_governor_power_state` series) and how many hours an
/// override may run (`ci_governor_override_max_hours`), both from the governor's metrics.
fn governor_reading() -> Result<(Vec<String>, u64), String> {
    let base = hub_core::prom::base()?;
    let series = hub_core::prom::instant(&base, "max by (host) (ci_governor_power_state)")?;
    let max = hub_core::prom::instant(&base, "max(ci_governor_override_max_hours)")?
        .first()
        .and_then(|s| s.value)
        .filter(|h| *h >= 1.0)
        .ok_or("no ci_governor_override_max_hours")?;
    Ok((
        series.iter().map(|s| s.label("host").to_string()).collect(),
        max as u64,
    ))
}

pub async fn set(Json(b): Json<Body>) -> ApiResult<Json<Value>> {
    let now = hub_core::jobs::now().max(0) as u64;
    let host = b.host.clone();
    let (hosts, max_hours) = tokio::task::spawn_blocking(governor_reading)
        .await
        .map_err(|e| bad(StatusCode::INTERNAL_SERVER_ERROR, e.to_string()))?
        .map_err(|e| {
            bad(
                StatusCode::BAD_GATEWAY,
                hub_core::reading::State::NotRead(format!("the governor's hosts, {e}")).words(""),
            )
        })?;
    let new =
        entry(&b.action, b.hours, now, max_hours).map_err(|m| bad(StatusCode::BAD_REQUEST, m))?;
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
    let body = patch(&host, new.as_deref()).to_string();
    let args: Vec<&str> = kube
        .into_iter()
        .chain([
            "patch",
            "configmap",
            CONFIGMAP,
            "--type",
            "merge",
            "-p",
            body.as_str(),
        ])
        .collect();
    let out = match run_cmd("kubectl", &args, None).await {
        // The ConfigMap is created only when it does not exist, with this one key.
        Err((_, e)) if e.contains("NotFound") => match &new {
            None => String::new(),
            Some(v) => {
                let lit = format!("--from-literal={}={v}", key(&host));
                let args: Vec<&str> = kube
                    .into_iter()
                    .chain(["create", "configmap", CONFIGMAP, lit.as_str()])
                    .collect();
                run_cmd("kubectl", &args, None).await?
            }
        },
        r => r?,
    };
    Ok(Json(json!({ "out": out.trim() })))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn on_and_off_run_for_their_hours_and_clear_removes() {
        let on = entry("on", 2, 1000, 12).unwrap().unwrap();
        assert_eq!(
            serde_json::from_str::<Value>(&on).unwrap(),
            json!({"action": "on", "until": 1000 + 7200})
        );
        assert!(entry("off", 12, 0, 12).unwrap().is_some());
        assert_eq!(entry("clear", 0, 0, 12), Ok(None));
    }

    #[test]
    fn a_body_outside_the_button_or_past_the_governor_limit_is_refused() {
        assert!(entry("on", 0, 0, 12).is_err());
        assert_eq!(entry("off", 13, 0, 12), Err("hours is 1 to 12".into()));
        assert!(entry("on", 6, 0, 4).is_err());
        assert!(entry("start", 2, 0, 12).is_err());
        assert!(entry("--force", 2, 0, 12).is_err());
        assert!(entry("", 2, 0, 12).is_err());
    }

    #[test]
    fn the_patch_carries_only_the_hosts_power_key() {
        assert_eq!(
            patch("aws-spot-1", Some("x")),
            json!({"data": {"aws-spot-1.power": "x"}})
        );
        assert_eq!(
            patch("aws-spot-1", None),
            json!({"data": {"aws-spot-1.power": null}})
        );
    }

    /// Each value the button writes passes the governor's override.schema.json, checked by
    /// `governor.py check-override` (home-config; `GOVERNOR_PY`, else the usual checkout). Skips
    /// when that governor or its schema is not on this machine.
    #[test]
    fn what_the_button_writes_passes_the_governors_schema() {
        let gov = std::env::var("GOVERNOR_PY").unwrap_or_else(|_| {
            format!(
                "{}/dev/home/home-config/apps/ci-runner-governor/governor.py",
                std::env::var("HOME").unwrap_or_default()
            )
        });
        let gov = std::path::Path::new(&gov);
        if !gov.with_file_name("override.schema.json").is_file() {
            eprintln!(
                "skipped: no governor with override.schema.json at {}",
                gov.display()
            );
            return;
        }
        let check = |k: &str, v: &str| {
            std::process::Command::new("python3")
                .arg(gov)
                .args(["check-override", k, v])
                .status()
                .unwrap()
                .success()
        };
        for action in ["on", "off"] {
            let v = entry(action, 2, 1_796_112_000, 12).unwrap().unwrap();
            assert!(check(&key("aws-spot-1"), &v), "{v}");
        }
        assert!(!check("aws-spot-1", r#"{"action":"on","until":1}"#));
    }
}
