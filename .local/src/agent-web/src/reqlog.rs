//! One journal line (stderr) for each request that failed, took longer than `SLOW`, or was
//! dropped before it answered, with its user agent, so the next "network error" a page shows
//! names its cause: a handler's own error, a read that ran long, or a client (or a restart) that
//! went away mid-read. A request that answered in time says nothing. The path is logged without
//! its query, which can carry a sign-in code.

use std::time::{Duration, Instant};

use axum::body::{to_bytes, Body};
use axum::extract::Request;
use axum::http::{header, StatusCode};
use axum::middleware::Next;
use axum::response::Response;

pub const SLOW: Duration = Duration::from_secs(2);

/// The most of a failed answer's body logged, and kept: an error body is one line.
const ERROR_BODY_MAX: usize = 64 * 1024;

/// What one request's line says, or None when it answered in time.
fn verdict(status: Option<StatusCode>, took: Duration) -> Option<&'static str> {
    match status {
        None => Some("dropped before it answered"),
        Some(s) if s.is_server_error() => Some("failed"),
        Some(_) if took > SLOW => Some("slow"),
        Some(_) => None,
    }
}

/// The request as it is logged, written when it is dropped: a request whose client went away is
/// dropped without an answer, so only a guard sees it.
struct Seen {
    what: String,
    started: Instant,
    status: Option<StatusCode>,
    said: String,
}

impl Drop for Seen {
    fn drop(&mut self) {
        let took = self.started.elapsed();
        if let Some(v) = verdict(self.status, took) {
            let status = self.status.map_or("-".into(), |s| s.as_u16().to_string());
            eprintln!(
                "agent-web: {} {v}: status {status} after {}ms{}",
                self.what,
                took.as_millis(),
                self.said
            );
        }
    }
}

pub async fn log(req: Request, next: Next) -> Response {
    let ua = req
        .headers()
        .get(header::USER_AGENT)
        .and_then(|v| v.to_str().ok())
        .unwrap_or("-");
    let mut seen = Seen {
        what: format!("{} {} ua={ua:?}", req.method(), req.uri().path()),
        started: Instant::now(),
        status: None,
        said: String::new(),
    };
    let res = next.run(req).await;
    if !res.status().is_server_error() {
        seen.status = Some(res.status());
        return res;
    }
    let (parts, body) = res.into_parts();
    let bytes = to_bytes(body, ERROR_BODY_MAX).await.unwrap_or_default();
    seen.status = Some(parts.status);
    seen.said = format!(": {}", String::from_utf8_lossy(&bytes).trim());
    Response::from_parts(parts, Body::from(bytes))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_a_failure_a_slow_answer_or_a_drop_is_logged() {
        let quick = Duration::from_millis(5);
        assert_eq!(verdict(Some(StatusCode::OK), quick), None);
        assert_eq!(verdict(Some(StatusCode::UNAUTHORIZED), quick), None);
        assert_eq!(
            verdict(Some(StatusCode::BAD_GATEWAY), quick),
            Some("failed")
        );
        assert_eq!(verdict(Some(StatusCode::OK), SLOW + quick), Some("slow"));
        assert_eq!(verdict(None, quick), Some("dropped before it answered"));
    }
}
