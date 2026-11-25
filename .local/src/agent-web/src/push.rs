//! Tilecast push (the tilecast repo's `docs/format.md`, Push): the widget app registers a
//! UnifiedPush endpoint at `POST /widget/push-register`, and a change to what the widget draws
//! POSTs to every endpoint so the phone fetches `/widget.json` within seconds. The push carries
//! no data, only "fetch now", so nothing of the fleet passes through the distributor.
//!
//! `agent-mqtt-publish` pokes `POST /widget/push-send` after every status write and watch change.
//! A poke only wakes `run`: it sends when the cards' `content_key` moved since the last send an
//! endpoint took, and at most once every `GAP`, so a burst of writes is one push and the last
//! change in it is never dropped. Both routes open with the widget key only, never a session
//! cookie, so no other site can register an endpoint through a signed-in browser.

use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::sync::Mutex;
use std::time::Duration;

use axum::body::Bytes;
use axum::extract::{Query, State};
use axum::http::{HeaderMap, Method, StatusCode};
use axum::response::{IntoResponse, Response};
use serde::{Deserialize, Serialize};
use tokio::io::AsyncWriteExt;
use tokio::sync::Notify;
use tokio::time::Instant;

use crate::widget::{self, WidgetQuery};
use crate::Shared;

/// The register route, as the document names it under `AGENT_WEB_BASE_URL`.
pub const REGISTER: &str = "/widget/push-register";

/// At most one push per this long: the distributor and the phone's battery see a burst as one.
const GAP: Duration = Duration::from_secs(30);
/// The most endpoints kept; a new one past it replaces the oldest. A phone holds one per widget.
const MAX_ENDPOINTS: usize = 16;
const ENDPOINT_MAX: usize = 2048;
const CLIENT_MAX: usize = 40;
/// Per endpoint: a distributor that does not answer in this long misses this push, and the
/// app's 15 min backstop covers it.
const SEND_TIMEOUT_S: &str = "10";
/// After a 429 or 5xx with no Retry-After, the first wait; each further one doubles it.
const BACKOFF_FIRST: Duration = Duration::from_secs(60);
/// The longest wait we choose ourselves; a distributor's own Retry-After may ask up to a day.
const BACKOFF_MAX: Duration = Duration::from_secs(3600);
const RETRY_AFTER_MAX: Duration = Duration::from_secs(86_400);

/// Wakes `run`. A poke while `run` is busy is kept (one permit), so it is never lost.
#[derive(Default)]
pub struct Pusher {
    poke: Notify,
}

#[derive(Deserialize)]
struct Reg {
    endpoint: String,
    #[serde(default)]
    client: String,
}

#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
struct Entry {
    endpoint: String,
    client: String,
    at: i64,
}

#[derive(Debug, Default, PartialEq, Serialize, Deserialize)]
struct Endpoints {
    endpoints: Vec<Entry>,
}

/// The endpoints, written only by agent-web.
fn endpoints_file() -> PathBuf {
    agent_core::session::home().join(".local/state/agent-web/push-endpoints.json")
}

/// The last send's result, for the push watch and for troubleshooting.
fn result_file() -> PathBuf {
    agent_core::session::home().join(".local/state/agent-web/push.json")
}

/// One read-modify-write of the endpoints file at a time.
static ENDPOINTS_LOCK: Mutex<()> = Mutex::new(());

/// An endpoint the app may register: https, one line, and nothing that could break out of the
/// quoted `url = "..."` line of curl's config, on a named public host.
fn usable_endpoint(e: &str) -> bool {
    e.starts_with("https://")
        && e.len() > "https://".len()
        && e.chars().count() <= ENDPOINT_MAX
        && !e
            .chars()
            .any(|c| c.is_whitespace() || c.is_control() || c == '"' || c == '\\')
        && named_host(&e["https://".len()..])
}

/// A distributor's endpoint is on a DNS name, so an IP literal, `localhost` or `.local` is
/// refused: the widget key must not turn agent-web into a POST to hosts on its own LAN.
fn named_host(rest: &str) -> bool {
    let authority = rest.split(['/', '?', '#']).next().unwrap_or("");
    if authority.contains('@') || authority.starts_with('[') {
        return false;
    }
    let host = authority
        .rsplit_once(':')
        .map_or(authority, |(h, _)| h)
        .trim_end_matches('.')
        .to_ascii_lowercase();
    let local = host == "localhost" || host.ends_with(".localhost") || host.ends_with(".local");
    // The last label of a DNS name has a letter; that also refuses 127.1 and 0x7f.0.0.1.
    let named = host.contains('.')
        && host
            .rsplit('.')
            .next()
            .is_some_and(|l| l.chars().any(|c| c.is_ascii_alphabetic()));
    named && !local
}

impl Endpoints {
    fn load(f: &Path) -> Endpoints {
        std::fs::read_to_string(f)
            .ok()
            .and_then(|t| serde_json::from_str(&t).ok())
            .unwrap_or_default()
    }

    /// Adds or refreshes `e`; past `MAX_ENDPOINTS` the oldest goes.
    fn add(&mut self, e: Entry) {
        self.endpoints.retain(|x| x.endpoint != e.endpoint);
        self.endpoints.push(e);
        self.endpoints.sort_by_key(|x| x.at);
        let over = self.endpoints.len().saturating_sub(MAX_ENDPOINTS);
        self.endpoints.drain(..over);
    }

    fn remove(&mut self, endpoint: &str) -> bool {
        let before = self.endpoints.len();
        self.endpoints.retain(|x| x.endpoint != endpoint);
        self.endpoints.len() != before
    }
}

/// Applies `change` to the endpoints file under the lock, written whole through a temp file.
fn edit(change: impl FnOnce(&mut Endpoints)) -> std::io::Result<()> {
    let _held = ENDPOINTS_LOCK.lock().unwrap_or_else(|p| p.into_inner());
    let f = endpoints_file();
    let mut eps = Endpoints::load(&f);
    change(&mut eps);
    widget::record(&f, &serde_json::to_value(&eps).unwrap_or_default())
}

/// `POST` adds the endpoint, `DELETE` removes it (the app's widget was removed). 204 either way.
pub async fn register(
    State(s): State<Shared>,
    method: Method,
    headers: HeaderMap,
    Query(q): Query<WidgetQuery>,
    body: Bytes,
) -> Response {
    if widget::opens(&s, &headers, q.t.as_deref()) != Some(true) {
        return widget::refused();
    }
    let Ok(reg) = serde_json::from_slice::<Reg>(&body) else {
        return (
            StatusCode::BAD_REQUEST,
            "want {\"endpoint\": \"https://...\"}",
        )
            .into_response();
    };
    if !usable_endpoint(&reg.endpoint) {
        return (StatusCode::BAD_REQUEST, "endpoint must be an https URL").into_response();
    }
    let entry = Entry {
        endpoint: reg.endpoint,
        client: reg.client.chars().take(CLIENT_MAX).collect(),
        at: hub_core::jobs::now(),
    };
    let wrote = tokio::task::spawn_blocking(move || {
        if method == Method::DELETE {
            edit(|eps| {
                eps.remove(&entry.endpoint);
            })
        } else {
            edit(|eps| eps.add(entry))
        }
    })
    .await;
    match wrote {
        Ok(Ok(())) => StatusCode::NO_CONTENT.into_response(),
        Ok(Err(e)) => {
            eprintln!("agent-web: push endpoint not saved: {e}");
            (StatusCode::INTERNAL_SERVER_ERROR, "not saved").into_response()
        }
        Err(e) => (StatusCode::INTERNAL_SERVER_ERROR, e.to_string()).into_response(),
    }
}

/// `POST /widget/push-send`: agent-mqtt-publish's poke. 202 at once; `run` decides whether to send.
pub async fn send(
    State(s): State<Shared>,
    headers: HeaderMap,
    Query(q): Query<WidgetQuery>,
) -> Response {
    if widget::opens(&s, &headers, q.t.as_deref()) != Some(true) {
        return widget::refused();
    }
    s.push.poke.notify_one();
    StatusCode::ACCEPTED.into_response()
}

/// What one send did, kept in `result_file`.
#[derive(Debug, Default, PartialEq, Serialize)]
struct Sent {
    at: i64,
    endpoints: usize,
    sent: usize,
    failed: usize,
    /// Endpoints the distributor said are gone (404, 410), now removed.
    dropped: usize,
    /// The first failure's reason.
    #[serde(skip_serializing_if = "Option::is_none")]
    error: Option<String>,
    /// A distributor throttled (429 or 5xx): the Retry-After it sent, in seconds, if any.
    #[serde(skip_serializing_if = "Option::is_none")]
    retry_after: Option<u64>,
    /// Throttled: no send before this unix time.
    #[serde(skip_serializing_if = "Option::is_none")]
    next_at: Option<i64>,
    /// Set when a distributor throttled, so `run` backs off.
    #[serde(skip)]
    throttled: bool,
}

/// How long to hold sends after a throttle: the distributor's Retry-After when it sent one,
/// else `BACKOFF_FIRST` doubling per throttle in a row up to `BACKOFF_MAX`. A send no
/// distributor throttled resets it.
#[derive(Debug, Default)]
struct Backoff {
    strikes: u32,
}

impl Backoff {
    fn throttled(&mut self, retry_after: Option<u64>) -> Duration {
        self.strikes = self.strikes.saturating_add(1);
        match retry_after {
            Some(s) => Duration::from_secs(s).min(RETRY_AFTER_MAX),
            None => BACKOFF_FIRST
                .saturating_mul(1u32 << (self.strikes - 1).min(16))
                .min(BACKOFF_MAX),
        }
    }

    fn reset(&mut self) {
        self.strikes = 0;
    }

    /// The wait before the next card read: `GAP` after a read that sent nothing (the cards drew
    /// what was last sent), else the throttle's hold or `GAP`. The card read runs ten readers and
    /// a Home build, and the poke comes from hooks many times a minute, so a read that found no
    /// change waits `GAP` like a send.
    fn next_read(&mut self, sent: Option<&Sent>) -> Duration {
        match sent {
            Some(s) if s.throttled => self.throttled(s.retry_after).max(GAP),
            Some(_) => {
                self.reset();
                GAP
            }
            None => GAP,
        }
    }
}

/// What a distributor's answer means for its endpoint.
#[derive(Debug, PartialEq)]
enum Answer {
    Took,
    Gone,
    Failed(String),
    /// 429 or 5xx: the distributor asks us to slow down, with its Retry-After seconds if sent.
    Throttled(String, Option<u64>),
}

/// `code` is curl's `%{http_code}`, `retry_after` its `%header{retry-after}`: only the
/// delta-seconds form is read, an HTTP-date falls back to our own backoff.
fn answer(code: Option<u16>, retry_after: &str, err: &str) -> Answer {
    match code {
        Some(200..=299) => Answer::Took,
        Some(404 | 410) => Answer::Gone,
        Some(c @ (429 | 500..=599)) => {
            Answer::Throttled(format!("HTTP {c}"), retry_after.trim().parse().ok())
        }
        Some(c) if c > 0 => Answer::Failed(format!("HTTP {c}")),
        _ if err.trim().is_empty() => Answer::Failed("no answer".into()),
        _ => Answer::Failed(err.trim().chars().take(200).collect()),
    }
}

/// POSTs "fetch now" to one endpoint through curl, the URL on stdin so the endpoint's token
/// stays out of argv. No retry: a missed push is caught by the next one or the app's backstop.
async fn post(endpoint: &str) -> Answer {
    let child = tokio::process::Command::new("curl")
        .args([
            "-sS",
            "-o",
            "/dev/null",
            "-w",
            "%{http_code} %header{retry-after}",
        ])
        .args([
            "--max-time",
            SEND_TIMEOUT_S,
            "-X",
            "POST",
            "--data",
            "1",
            "-K",
            "-",
        ])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .kill_on_drop(true)
        .spawn();
    let mut child = match child {
        Ok(c) => c,
        Err(e) => return Answer::Failed(format!("curl: {e}")),
    };
    if let Some(mut stdin) = child.stdin.take() {
        let conf = format!("url = \"{endpoint}\"\n");
        if let Err(e) = stdin.write_all(conf.as_bytes()).await {
            return Answer::Failed(format!("curl: {e}"));
        }
    }
    match child.wait_with_output().await {
        Ok(o) => {
            let out = String::from_utf8_lossy(&o.stdout);
            let (code, retry_after) = out.trim().split_once(' ').unwrap_or((out.trim(), ""));
            answer(
                code.parse().ok(),
                retry_after,
                &String::from_utf8_lossy(&o.stderr),
            )
        }
        Err(e) => Answer::Failed(format!("curl: {e}")),
    }
}

/// Sends to each endpoint in turn (a phone holds one per widget) and drops the gone ones.
async fn send_all() -> Sent {
    let eps = Endpoints::load(&endpoints_file()).endpoints;
    let mut sent = Sent {
        at: hub_core::jobs::now(),
        endpoints: eps.len(),
        ..Sent::default()
    };
    let mut gone = vec![];
    for e in &eps {
        match post(&e.endpoint).await {
            Answer::Took => sent.sent += 1,
            Answer::Gone => gone.push(e.endpoint.clone()),
            Answer::Failed(why) => {
                sent.failed += 1;
                sent.error.get_or_insert(why);
            }
            Answer::Throttled(why, retry_after) => {
                sent.failed += 1;
                sent.error.get_or_insert(why);
                sent.throttled = true;
                sent.retry_after = sent.retry_after.max(retry_after);
            }
        }
    }
    sent.dropped = gone.len();
    if !gone.is_empty() {
        let dropped = tokio::task::spawn_blocking(move || {
            edit(|eps| {
                for g in &gone {
                    eps.remove(g);
                }
            })
        })
        .await;
        if let Ok(Err(e)) = dropped {
            eprintln!("agent-web: gone push endpoints not removed: {e}");
        }
    }
    sent
}

/// The sender, for the life of the server: waits for a poke, keeps `GAP` since the last card
/// read (longer while a distributor throttles, see `Backoff`), then sends when the cards draw
/// something new.
pub async fn run(s: Shared) {
    let mut last_key: Option<String> = None;
    let mut next_read: Option<Instant> = None;
    let mut backoff = Backoff::default();
    loop {
        s.push.poke.notified().await;
        if let Some(t) = next_read {
            // A rate limit, not a wait for a signal: pokes that come meanwhile fold into this one.
            tokio::time::sleep_until(t).await;
        }
        // No phone registered: nothing to tell, so no card read either.
        if Endpoints::load(&endpoints_file()).endpoints.is_empty() {
            continue;
        }
        let cards = crate::cards::read(&s).await;
        let key = hub_core::widget_doc::document(&cards, &[], 0, None).content_key();
        if last_key.as_deref() == Some(key.as_str()) {
            next_read = Some(Instant::now() + backoff.next_read(None));
            continue;
        }
        let mut sent = send_all().await;
        let wait = backoff.next_read(Some(&sent));
        next_read = Some(Instant::now() + wait);
        if sent.throttled {
            sent.next_at = Some(sent.at + wait.as_secs() as i64);
        }
        // A change no endpoint took goes again on the next poke, `GAP` later.
        if sent.sent > 0 {
            last_key = Some(key);
        }
        if let Some(why) = &sent.error {
            eprintln!(
                "agent-web: push failed to {} of {}: {why}{}",
                sent.failed,
                sent.endpoints,
                if sent.throttled {
                    format!(", next try in {} s", wait.as_secs())
                } else {
                    String::new()
                }
            );
        }
        let value = serde_json::to_value(&sent).unwrap_or_default();
        let wrote =
            tokio::task::spawn_blocking(move || widget::record(&result_file(), &value)).await;
        if let Ok(Err(e)) = wrote {
            eprintln!("agent-web: push result not recorded: {e}");
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn entry(e: &str, at: i64) -> Entry {
        Entry {
            endpoint: e.into(),
            client: "tilecast".into(),
            at,
        }
    }

    #[test]
    fn only_a_plain_https_endpoint_is_taken() {
        assert!(usable_endpoint("https://ntfy.sh/upAbc123?up=1"));
        // Negative controls: another scheme, nothing after it, and what could break curl's config.
        assert!(!usable_endpoint("http://ntfy.sh/up"));
        assert!(!usable_endpoint("https://"));
        assert!(!usable_endpoint(
            "https://x.example/\"\nurl = \"https://evil"
        ));
        assert!(!usable_endpoint("https://x.example/a b"));
        assert!(!usable_endpoint("https://x.example/a\\b"));
        assert!(!usable_endpoint(&format!(
            "https://x.example/{}",
            "a".repeat(ENDPOINT_MAX)
        )));
    }

    #[test]
    fn an_endpoint_on_an_address_or_a_local_name_is_refused() {
        assert!(usable_endpoint("https://ntfy.example.com:8443/up"));
        assert!(usable_endpoint("https://push.example.com./up"));
        for e in [
            "https://10.0.0.5/admin",
            "https://169.254.169.254/latest",
            "https://127.1/x",
            "https://0x7f.0.0.1/x",
            "https://2130706433/x",
            "https://[::1]/x",
            "https://localhost:8790/widget/push-send",
            "https://agent.localhost/x",
            "https://printer.local/x",
            "https://user@ntfy.example.com/up",
            "https://ntfy/up",
        ] {
            assert!(!usable_endpoint(e), "{e}");
        }
    }

    #[test]
    fn a_registration_refreshes_its_endpoint_and_the_oldest_goes_past_the_cap() {
        let mut eps = Endpoints::default();
        eps.add(entry("https://a", 1));
        eps.add(entry("https://a", 5));
        assert_eq!(eps.endpoints, [entry("https://a", 5)]);
        for i in 0..MAX_ENDPOINTS as i64 {
            eps.add(entry(&format!("https://n{i}"), 10 + i));
        }
        assert_eq!(eps.endpoints.len(), MAX_ENDPOINTS);
        assert!(!eps.endpoints.iter().any(|e| e.endpoint == "https://a"));
        assert!(eps.remove("https://n0"));
        assert!(!eps.remove("https://n0"));
    }

    #[test]
    fn a_distributors_answer_says_whether_the_endpoint_stays() {
        assert_eq!(answer(Some(200), "", ""), Answer::Took);
        assert_eq!(answer(Some(201), "", ""), Answer::Took);
        assert_eq!(answer(Some(404), "", ""), Answer::Gone);
        assert_eq!(answer(Some(410), "", ""), Answer::Gone);
        assert_eq!(
            answer(Some(429), "", ""),
            Answer::Throttled("HTTP 429".into(), None)
        );
        assert_eq!(
            answer(Some(429), "120", ""),
            Answer::Throttled("HTTP 429".into(), Some(120))
        );
        assert_eq!(
            answer(Some(503), "Wed, 21 Oct 2026 07:28:00 GMT", ""),
            Answer::Throttled("HTTP 503".into(), None)
        );
        assert_eq!(answer(Some(400), "", ""), Answer::Failed("HTTP 400".into()));
        // curl prints 000 when it got no answer at all; the reason is on stderr.
        assert_eq!(
            answer(Some(0), "", "curl: (28) timed out\n"),
            Answer::Failed("curl: (28) timed out".into())
        );
        assert_eq!(answer(None, "", ""), Answer::Failed("no answer".into()));
    }

    #[test]
    fn a_throttle_honors_retry_after_else_doubles_to_the_cap_and_a_success_resets() {
        let mut b = Backoff::default();
        assert_eq!(b.throttled(None), Duration::from_secs(60));
        assert_eq!(b.throttled(None), Duration::from_secs(120));
        assert_eq!(b.throttled(None), Duration::from_secs(240));
        // The distributor's own ask wins over the doubling, up to a day.
        assert_eq!(b.throttled(Some(7)), Duration::from_secs(7));
        assert_eq!(b.throttled(Some(999_999)), RETRY_AFTER_MAX);
        for _ in 0..40 {
            b.throttled(None);
        }
        assert_eq!(b.throttled(None), BACKOFF_MAX);
        b.reset();
        assert_eq!(b.throttled(None), Duration::from_secs(60));
    }

    #[test]
    fn a_read_that_sent_nothing_waits_the_gap_and_keeps_the_backoff() {
        let mut b = Backoff::default();
        let throttled = Sent {
            throttled: true,
            ..Sent::default()
        };
        assert_eq!(b.next_read(Some(&throttled)), Duration::from_secs(60));
        // An unchanged read waits GAP and leaves the strikes, so the next throttle doubles.
        assert_eq!(b.next_read(None), GAP);
        assert_eq!(b.next_read(Some(&throttled)), Duration::from_secs(120));
        // A send no distributor throttled resets it.
        assert_eq!(b.next_read(Some(&Sent::default())), GAP);
        assert_eq!(b.next_read(Some(&throttled)), Duration::from_secs(60));
        // A short Retry-After still waits at least GAP.
        let short = Sent {
            throttled: true,
            retry_after: Some(5),
            ..Sent::default()
        };
        assert_eq!(b.next_read(Some(&short)), GAP);
    }

    #[test]
    fn the_files_are_the_paths_the_readme_names() {
        assert!(endpoints_file().ends_with(".local/state/agent-web/push-endpoints.json"));
        assert!(result_file().ends_with(".local/state/agent-web/push.json"));
    }
}
