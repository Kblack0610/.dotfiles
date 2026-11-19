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
/// `max_hours` is the governor's own limit on an on (`ci_governor_override_max_hours`), None
/// when it was not read: then only a clear goes through.
fn entry(
    action: &str,
    hours: u64,
    now: u64,
    max_hours: Option<u64>,
) -> Result<Option<String>, String> {
    match (action, max_hours) {
        ("clear", _) => Ok(None),
        ("on" | "off", None) => {
            Err("the governor's override limit (ci_governor_override_max_hours) is not read".into())
        }
        ("on" | "off", Some(max)) if (1..=max).contains(&hours) => Ok(Some(
            json!({"action": action, "until": now + hours * 3600}).to_string(),
        )),
        ("on" | "off", Some(max)) => Err(format!("hours is 1 to {max}")),
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
/// override may run (`ci_governor_override_max_hours`, None with no series), from its metrics.
fn governor_reading() -> Result<(Vec<String>, Option<u64>), String> {
    let base = hub_core::prom::base()?;
    let series = hub_core::prom::instant(&base, "max by (host) (ci_governor_power_state)")?;
    let max = hub_core::prom::instant(&base, "max(ci_governor_override_max_hours)")?
        .first()
        .and_then(|s| s.value)
        .filter(|h| *h >= 1.0)
        .map(|h| h as u64);
    Ok((
        series.iter().map(|s| s.label("host").to_string()).collect(),
        max,
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
    let kubectl = |verb: &[&str]| {
        let args: Vec<String> = kube.iter().chain(verb).map(|a| a.to_string()).collect();
        async move {
            let args: Vec<&str> = args.iter().map(String::as_str).collect();
            run_cmd("kubectl", &args, None).await
        }
    };
    let merge = [
        "patch",
        "configmap",
        CONFIGMAP,
        "--type",
        "merge",
        "-p",
        body.as_str(),
    ];
    let out = match kubectl(&merge).await {
        // The ConfigMap is created only when it does not exist, with this one key; a clear of
        // a missing one is done. Another writer creating it first means patch the one it made.
        Err((_, e)) if e.contains("NotFound") => match &new {
            None => String::new(),
            Some(v) => {
                let lit = format!("--from-literal={}={v}", key(&host));
                match kubectl(&["create", "configmap", CONFIGMAP, lit.as_str()]).await {
                    Err((_, e)) if e.contains("AlreadyExists") => kubectl(&merge).await?,
                    r => r?,
                }
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
        let on = entry("on", 2, 1000, Some(12)).unwrap().unwrap();
        assert_eq!(
            serde_json::from_str::<Value>(&on).unwrap(),
            json!({"action": "on", "until": 1000 + 7200})
        );
        assert!(entry("off", 12, 0, Some(12)).unwrap().is_some());
        assert_eq!(entry("clear", 0, 0, Some(12)), Ok(None));
        // Unread limit: a clear still hands the host back, an on or off is refused.
        assert_eq!(entry("clear", 0, 0, None), Ok(None));
        assert!(entry("on", 2, 0, None).is_err());
    }

    #[test]
    fn a_body_outside_the_button_or_past_the_governor_limit_is_refused() {
        assert!(entry("on", 0, 0, Some(12)).is_err());
        assert_eq!(
            entry("off", 13, 0, Some(12)),
            Err("hours is 1 to 12".into())
        );
        assert!(entry("on", 6, 0, Some(4)).is_err());
        assert!(entry("start", 2, 0, Some(12)).is_err());
        assert!(entry("--force", 2, 0, Some(12)).is_err());
        assert!(entry("", 2, 0, Some(12)).is_err());
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
        let check = |k: &str, v: &str| {
            std::process::Command::new("python3")
                .arg(&gov)
                .args(["check-override", k, v])
                .output()
                .ok()
                .map(|o| {
                    (
                        o.status.success(),
                        String::from_utf8_lossy(&o.stderr).into_owned(),
                    )
                })
        };
        // A known-good key probes for check-override, so an older governor or no python3
        // skips rather than passes.
        if check("h.reserve", r#"{"until":1}"#).map(|c| c.0) != Some(true) {
            eprintln!("skipped: no governor with check-override at {gov} (set GOVERNOR_PY)");
            return;
        }
        for action in ["on", "off"] {
            let v = entry(action, 2, 1_796_112_000, Some(12)).unwrap().unwrap();
            assert!(check(&key("aws-spot-1"), &v).unwrap().0, "{v}");
        }
        let (ok, err) = check("aws-spot-1", r#"{"action":"on","until":1}"#).unwrap();
        assert!(!ok && err.starts_with("override aws-spot-1: "), "{err}");
    }
}
