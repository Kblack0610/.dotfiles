//! Every signed-in request that can change something (any method but GET and HEAD) writes one line on the
//! operator audit log (`hub_core::audit`): the signed-in login as the actor, the route's
//! `noun.verb`, its target, what was asked, and how it went. ROUTES names each mutating route;
//! `every_mutating_route_is_named` fails on a route in main.rs that is not here, and a request to
//! one anyway is still recorded, as `<METHOD> <path>`, never dropped.

use axum::body::{to_bytes, Body, HttpBody};
use axum::extract::{Request, State};
use axum::http::{Method, StatusCode};
use axum::middleware::Next;
use axum::response::{IntoResponse, Response};
use hub_core::audit::{self, Entry};
use serde_json::{Map, Value};

use crate::Shared;

/// The largest body read: a note save is up to 1 MB of text.
const BODY_MAX: usize = 2 * 1024 * 1024;
/// The largest failed answer whose words go into the outcome.
const ERROR_BODY_MAX: usize = 64 * 1024;

/// One mutating route: its method and path as main.rs routes it, the action it records, the
/// fields that name its target (path parameters, then body keys), and the body keys it records
/// as `to`.
pub struct Route {
    pub method: &'static str,
    pub path: &'static str,
    action: fn(&Map<String, Value>) -> String,
    target: &'static [&'static str],
    to: &'static [&'static str],
}

const fn route(
    method: &'static str,
    path: &'static str,
    action: fn(&Map<String, Value>) -> String,
    target: &'static [&'static str],
    to: &'static [&'static str],
) -> Route {
    Route {
        method,
        path,
        action,
        target,
        to,
    }
}

fn s<'a>(f: &'a Map<String, Value>, k: &str) -> &'a str {
    f.get(k).and_then(Value::as_str).unwrap_or("")
}

/// Sign-in is recorded where it happens, in the OAuth callback (`signin.started`, `signin.refused`).
pub const ROUTES: &[Route] = &[
    route(
        "POST",
        "/api/send",
        |_| "session.sent".into(),
        &["t"],
        &["text", "key", "submit"],
    ),
    route(
        "POST",
        "/api/session/{target}/{action}",
        |f| format!("session.{}", audit::past(s(f, "action"))),
        &["target"],
        &["account"],
    ),
    route(
        "POST",
        "/api/sessions/timer/{name}/start",
        |_| "timer.started".into(),
        &["name"],
        &[],
    ),
    route(
        "POST",
        "/api/asks/answer",
        |_| "ask.answered".into(),
        &["id"],
        &["answer"],
    ),
    route(
        "POST",
        "/api/asks/park",
        |f| {
            if f.get("unpark") == Some(&Value::Bool(true)) {
                "ask.unparked"
            } else {
                "ask.parked"
            }
            .into()
        },
        &["id"],
        &[],
    ),
    route(
        "POST",
        "/api/proposals/accept",
        |_| "proposal.accepted".into(),
        &["id"],
        &[],
    ),
    route(
        "POST",
        "/api/proposals/reject",
        |_| "proposal.rejected".into(),
        &["id"],
        &[],
    ),
    route(
        "POST",
        "/api/cloud-runner",
        |_| "runner.power-set".into(),
        &["host"],
        &["action", "hours"],
    ),
    route(
        "POST",
        "/api/board",
        |f| format!("board.{}", audit::past(s(f, "verb"))),
        &["project", "raw"],
        &[
            "text",
            "priority",
            "to",
            "dest",
            "why",
            "dup",
            "proof",
            "unverified",
            "add",
            "remove",
        ],
    ),
    route(
        "POST",
        "/api/inbox/ack",
        |f| {
            if f.get("ack") == Some(&Value::Bool(false)) {
                "inbox.unacked"
            } else {
                "inbox.acked"
            }
            .into()
        },
        &["key"],
        &[],
    ),
    route("PUT", "/api/focus", |_| "note.saved".into(), &["t"], &[]),
    route("PUT", "/api/outbox", |_| "outbox.saved".into(), &[], &[]),
    route(
        "POST",
        "/api/queue",
        |_| "queue.added".into(),
        &["project"],
        &["task", "priority", "mode", "tags"],
    ),
    route(
        "POST",
        "/api/queue/cancel",
        |_| "queue.canceled".into(),
        &["slug"],
        &[],
    ),
    route(
        "POST",
        "/api/queue/bump",
        |_| "queue.bumped".into(),
        &["slug"],
        &["priority"],
    ),
    route("POST", "/logout", |_| "signin.ended".into(), &[], &[]),
];

/// The path parameters of `pattern` (`{name}` segments) when `path` matches it.
fn matched(pattern: &str, path: &str) -> Option<Map<String, Value>> {
    let (p, q): (Vec<&str>, Vec<&str>) = (pattern.split('/').collect(), path.split('/').collect());
    if p.len() != q.len() {
        return None;
    }
    let mut params = Map::new();
    for (a, b) in p.iter().zip(&q) {
        match a.strip_prefix('{').and_then(|a| a.strip_suffix('}')) {
            Some(name) => {
                params.insert(name.into(), Value::String((*b).into()));
            }
            None if a == b => {}
            None => return None,
        }
    }
    Some(params)
}

/// The entry a request writes before its outcome is known.
fn entry(actor: &str, method: &Method, path: &str, body: &[u8]) -> Entry {
    let json = serde_json::from_slice::<Value>(body).ok();
    let body = json.as_ref().and_then(Value::as_object);
    for r in ROUTES.iter().filter(|r| r.method == method.as_str()) {
        let Some(mut fields) = matched(r.path, path) else {
            continue;
        };
        if let Some(b) = body {
            for (k, v) in b {
                fields.entry(k.clone()).or_insert_with(|| v.clone());
            }
        }
        let target = r
            .target
            .iter()
            .filter_map(|k| fields.get(*k))
            .map(|v| v.as_str().map_or_else(|| v.to_string(), str::to_string))
            .filter(|v| !v.is_empty())
            .collect::<Vec<_>>()
            .join(" ");
        let to: Map<String, Value> =
            r.to.iter()
                .filter_map(|k| Some((k.to_string(), fields.get(*k)?.clone())))
                .filter(|(_, v)| !v.is_null() && v != "" && v != &Value::Array(vec![]))
                .collect();
        let e = Entry::new(actor, &(r.action)(&fields), &target, "web");
        return if to.is_empty() {
            e
        } else {
            e.to(Value::Object(to))
        };
    }
    Entry::new(actor, &format!("{method} {path}"), "", "web")
}

pub async fn layer(State(s): State<Shared>, req: Request, next: Next) -> Response {
    if matches!(*req.method(), Method::GET | Method::HEAD) {
        return next.run(req).await;
    }
    // A signed-out request changes nothing: require_auth refuses it, and /logout has no session.
    let Some(actor) = crate::signed_in(&s, req.headers()) else {
        return next.run(req).await;
    };
    let (parts, body) = req.into_parts();
    let bytes = match to_bytes(body, BODY_MAX).await {
        Ok(b) => b,
        Err(e) => {
            let mut e2 = entry(&actor, &parts.method, parts.uri.path(), &[]);
            e2.outcome = audit::failed(&format!("body not read: {e}"));
            record(e2).await;
            return (StatusCode::PAYLOAD_TOO_LARGE, "request body too large").into_response();
        }
    };
    let mut e = entry(&actor, &parts.method, parts.uri.path(), &bytes);
    let res = next
        .run(Request::from_parts(parts, Body::from(bytes)))
        .await;
    if res.status().is_success() || res.status().is_redirection() {
        record(e).await;
        return res;
    }
    let status = res.status();
    // The body's own size: Content-Length is only set once the response is written.
    let small = HttpBody::size_hint(res.body())
        .upper()
        .is_some_and(|n| n <= ERROR_BODY_MAX as u64);
    if !small {
        e.outcome = audit::failed(&status.to_string());
        record(e).await;
        return res;
    }
    let (parts, body) = res.into_parts();
    let bytes = to_bytes(body, ERROR_BODY_MAX).await.unwrap_or_default();
    e.outcome = audit::failed(&format!(
        "{status} {}",
        String::from_utf8_lossy(&bytes).trim()
    ));
    record(e).await;
    Response::from_parts(parts, Body::from(bytes))
}

async fn record(e: Entry) {
    let _ = tokio::task::spawn_blocking(move || audit::record(&e)).await;
}

#[cfg(test)]
mod tests {
    use super::*;

    /// `(method, path)` for each mutating method a `.route("<path>", ...)` line in `src` names.
    fn mutating_routes(src: &str) -> Vec<(String, String)> {
        let mut out = vec![];
        for chunk in src.split(".route(").skip(1) {
            let Some(rest) = chunk.trim_start().strip_prefix('"') else {
                continue;
            };
            let Some((path, handlers)) = rest.split_once('"') else {
                continue;
            };
            let handlers = handlers.split("))").next().unwrap_or("");
            for m in ["post", "put", "patch", "delete"] {
                let at_start = handlers
                    .trim_start_matches([',', ' ', '\n'])
                    .starts_with(&format!("{m}("));
                if at_start || handlers.contains(&format!(".{m}(")) {
                    out.push((m.to_uppercase(), path.to_string()));
                }
            }
        }
        out
    }

    #[test]
    fn every_mutating_route_is_named() {
        let found = mutating_routes(include_str!("main.rs"));
        for (method, path) in &found {
            assert!(
                ROUTES.iter().any(|r| r.method == method && r.path == path),
                "{method} {path} changes something and is not in audit::ROUTES"
            );
        }
        assert_eq!(
            found.len(),
            ROUTES.len(),
            "a ROUTES entry main.rs no longer routes: {found:?}"
        );
        // Negative control: the scan sees a route of each shape main.rs uses.
        let fake =
            r#".route("/api/x", post(x)).route("/api/y", get(a).put(b)).route("/api/z", get(z))"#;
        assert_eq!(
            mutating_routes(fake),
            [
                ("POST".to_string(), "/api/x".to_string()),
                ("PUT".into(), "/api/y".into())
            ]
        );
    }

    #[test]
    fn a_request_names_its_action_target_and_what_was_asked() {
        let e = entry(
            "ken",
            &Method::POST,
            "/api/session/hub:agent-4/approve-plan",
            br#"{"account":""}"#,
        );
        assert_eq!(
            (e.action.as_str(), e.target.as_str(), &e.to),
            ("session.plan-approved", "hub:agent-4", &Value::Null)
        );
        let e = entry(
            "ken",
            &Method::POST,
            "/api/queue/bump",
            br#"{"slug":"fix-x","priority":"high"}"#,
        );
        assert_eq!(
            (e.action.as_str(), e.target.as_str()),
            ("queue.bumped", "fix-x")
        );
        assert_eq!(e.to, serde_json::json!({"priority": "high"}));
        let e = entry(
            "ken",
            &Method::POST,
            "/api/asks/park",
            br#"{"id":"abc","unpark":true}"#,
        );
        assert_eq!(e.action, "ask.unparked");
        let e = entry(
            "ken",
            &Method::PUT,
            "/api/focus",
            br#"{"t":"status/inbox","base":"x","text":"long"}"#,
        );
        assert_eq!(
            (e.action.as_str(), e.target.as_str(), &e.to),
            ("note.saved", "status/inbox", &Value::Null)
        );
    }

    #[test]
    fn an_unnamed_route_is_still_recorded() {
        let e = entry("ken", &Method::DELETE, "/api/nothing", b"");
        assert_eq!(
            (e.action.as_str(), e.actor.as_str()),
            ("DELETE /api/nothing", "ken")
        );
    }
}
