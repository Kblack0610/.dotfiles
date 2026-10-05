//! agent-web: a web view of the Claude agents running in tmux on this machine.
//!
//! Lists every agent (the same pane x `~/.claude/sessions` join agent-panel uses),
//! pages through any agent's transcript, shows its live screen, types into its
//! pane, and answers the headless `agent-ask` queue. Changes are pushed to the
//! browser over SSE from inotify on `~/.claude`, so nothing polls.
//!
//! Served behind the home cluster ingress (home-config `apps/agents`),
//! which only proxies; Sign in with Forgejo (see `auth`) is the real gate.

mod auth;
mod transcript;

use std::convert::Infallible;
use std::path::Path;
use std::process::Stdio;
use std::sync::Arc;

use agent_panel::{chooser, session, tmux};
use anyhow::Result;
use axum::extract::{Query, Request, State};
use axum::http::{header, HeaderMap, StatusCode};
use axum::middleware::{self, Next};
use axum::response::sse::{Event as SseEvent, KeepAlive, Sse};
use axum::response::{Html, IntoResponse, Response};
use axum::routing::{get, post};
use axum::{Json, Router};
use notify::{EventKind, RecursiveMode, Watcher};
use serde::{Deserialize, Serialize};
use tokio::io::AsyncWriteExt;
use tokio::sync::broadcast;
use tokio_stream::wrappers::BroadcastStream;
use tokio_stream::{Stream, StreamExt};

const INDEX: &str = include_str!("index.html");
const LOGIN: &str = include_str!("login.html");
const DEFAULT_ADDR: &str = "0.0.0.0:8790";
const PAGE_DEFAULT: usize = 150;
const PAGE_MAX: usize = 1000;
const SCREEN_LINES: i32 = -200;
/// Keys the quick-key row may send. Enough to answer a permission prompt, move a
/// menu, or interrupt; deliberately no C-c / C-d, which end the session.
const KEYS: &[&str] = &[
    "Enter", "Escape", "Up", "Down", "Left", "Right", "Tab", "BTab", "Space", "1", "2", "3", "4",
    "5", "6", "7", "8", "9",
];

struct AppState {
    oauth: auth::OAuth,
    sessions: auth::Sessions,
    events: broadcast::Sender<String>,
}

type Shared = Arc<AppState>;
type ApiResult<T> = Result<T, (StatusCode, String)>;

fn bad(code: StatusCode, msg: impl Into<String>) -> (StatusCode, String) {
    (code, msg.into())
}

#[tokio::main]
async fn main() -> Result<()> {
    let oauth = auth::OAuth::load()?;
    let sessions = auth::Sessions::load();
    let (events, _) = broadcast::channel(256);
    let _watcher = watch(events.clone())?; // dropping it stops the inotify watch
    let state = Arc::new(AppState {
        oauth,
        sessions,
        events,
    });

    let api = Router::new()
        .route("/api/agents", get(agents))
        .route("/api/transcript", get(transcript_page))
        .route("/api/screen", get(screen))
        .route("/api/send", post(send))
        .route("/api/asks", get(asks))
        .route("/api/asks/answer", post(answer))
        .route("/api/events", get(events_stream))
        .layer(middleware::from_fn_with_state(state.clone(), require_auth));

    let app = Router::new()
        .route("/", get(index))
        .route("/login", get(login))
        .route("/oauth/callback", get(callback))
        .route("/logout", post(logout))
        .route("/healthz", get(|| async { "ok" }))
        .merge(api)
        .with_state(state);

    let addr = std::env::var("AGENT_WEB_ADDR").unwrap_or_else(|_| DEFAULT_ADDR.into());
    let listener = tokio::net::TcpListener::bind(&addr).await?;
    eprintln!("agent-web: listening on {addr}");
    axum::serve(listener, app).await?;
    Ok(())
}

/// inotify on the session registry and the transcripts. Each change becomes one
/// small SSE message; the browser decides whether it cares.
fn watch(tx: broadcast::Sender<String>) -> Result<notify::RecommendedWatcher> {
    let claude = session::home().join(".claude");
    let mut w = notify::recommended_watcher(move |res: notify::Result<notify::Event>| {
        let Ok(ev) = res else { return };
        if matches!(ev.kind, EventKind::Access(_)) {
            return;
        }
        for p in &ev.paths {
            if let Some(msg) = classify(p) {
                let _ = tx.send(msg); // no subscribers is fine
            }
        }
    })?;
    w.watch(&claude.join("sessions"), RecursiveMode::NonRecursive)?;
    w.watch(&claude.join("projects"), RecursiveMode::Recursive)?;
    let asks = session::home().join(".agent").join("asks");
    if asks.is_dir() {
        w.watch(&asks, RecursiveMode::Recursive)?;
    }
    Ok(w)
}

fn classify(p: &Path) -> Option<String> {
    let ext = p.extension()?.to_str()?;
    let parent = p.parent()?.file_name()?.to_str()?;
    match ext {
        "json" if parent == "sessions" => Some(r#"{"kind":"sessions"}"#.to_string()),
        "md" if p.ancestors().any(|a| a.ends_with(".agent/asks")) => {
            Some(r#"{"kind":"asks"}"#.to_string())
        }
        "jsonl" => {
            let stem = p.file_stem()?.to_str()?;
            Some(serde_json::json!({"kind": "transcript", "session": stem}).to_string())
        }
        _ => None,
    }
}

fn cookie_header(headers: &HeaderMap) -> Option<&str> {
    headers.get(header::COOKIE).and_then(|v| v.to_str().ok())
}

fn signed_in(s: &AppState, headers: &HeaderMap) -> Option<String> {
    auth::cookie(cookie_header(headers), auth::SESSION_COOKIE).and_then(|id| s.sessions.user(id))
}

async fn require_auth(
    State(s): State<Shared>,
    headers: HeaderMap,
    req: Request,
    next: Next,
) -> Response {
    match signed_in(&s, &headers) {
        Some(_) => next.run(req).await,
        None => (StatusCode::UNAUTHORIZED, "unauthorized").into_response(),
    }
}

/// The app for a signed-in browser, the sign-in page otherwise.
async fn index(State(s): State<Shared>, headers: HeaderMap) -> Response {
    match signed_in(&s, &headers) {
        Some(_) => Html(INDEX).into_response(),
        None => Html(LOGIN.replace("{{error}}", "")).into_response(),
    }
}

fn denied(code: StatusCode, msg: &str) -> Response {
    let err = format!(r#"<div class="err">{msg}</div>"#);
    (code, Html(LOGIN.replace("{{error}}", &err))).into_response()
}

/// Start the OAuth flow: remember a random state in a short-lived cookie and hand the
/// browser to Forgejo. Forgejo shows its own sign-in form if there is no session there.
async fn login(State(s): State<Shared>) -> Response {
    let Ok(state) = auth::random_hex(16) else {
        return denied(
            StatusCode::INTERNAL_SERVER_ERROR,
            "Could not start sign-in.",
        );
    };
    (
        StatusCode::SEE_OTHER,
        [
            (header::SET_COOKIE, auth::state_cookie(&state)),
            (header::LOCATION, s.oauth.authorize_url(&state)),
        ],
    )
        .into_response()
}

#[derive(Deserialize)]
struct CallbackQuery {
    code: Option<String>,
    state: Option<String>,
    error: Option<String>,
}

async fn callback(
    State(s): State<Shared>,
    headers: HeaderMap,
    Query(q): Query<CallbackQuery>,
) -> Response {
    let expected = auth::cookie(cookie_header(&headers), auth::STATE_COOKIE);
    let state_ok =
        matches!((q.state.as_deref(), expected), (Some(a), Some(b)) if auth::matches(a, b));
    if q.error.is_some() || !state_ok {
        return denied(
            StatusCode::BAD_REQUEST,
            "Sign-in was cancelled or expired. Try again.",
        );
    }
    let Some(code) = q.code.as_deref() else {
        return denied(StatusCode::BAD_REQUEST, "Forgejo sent no code. Try again.");
    };
    let login = match s.oauth.login_for_code(code).await {
        Ok(l) => l,
        Err(e) => {
            eprintln!("agent-web: sign-in failed: {e:#}");
            return denied(
                StatusCode::BAD_GATEWAY,
                "Could not reach Forgejo to finish sign-in.",
            );
        }
    };
    if !s.oauth.is_allowed(&login) {
        eprintln!("agent-web: rejected Forgejo user {login}");
        return denied(
            StatusCode::FORBIDDEN,
            "That Forgejo account is not allowed here.",
        );
    }
    let id = match s.sessions.create(&login) {
        Ok(id) => id,
        Err(e) => {
            eprintln!("agent-web: could not store session: {e:#}");
            return denied(
                StatusCode::INTERNAL_SERVER_ERROR,
                "Could not start a session.",
            );
        }
    };
    let mut resp = Response::builder()
        .status(StatusCode::SEE_OTHER)
        .header(header::LOCATION, "/")
        .body(axum::body::Body::empty())
        .unwrap();
    for c in [
        auth::session_cookie(&id),
        auth::clear_cookie(auth::STATE_COOKIE),
    ] {
        resp.headers_mut()
            .append(header::SET_COOKIE, c.parse().unwrap());
    }
    resp
}

async fn logout(State(s): State<Shared>, headers: HeaderMap) -> Response {
    if let Some(id) = auth::cookie(cookie_header(&headers), auth::SESSION_COOKIE) {
        s.sessions.revoke(id);
    }
    (
        StatusCode::SEE_OTHER,
        [
            (header::SET_COOKIE, auth::clear_cookie(auth::SESSION_COOKIE)),
            (header::LOCATION, "/".to_string()),
        ],
    )
        .into_response()
}

#[derive(Serialize)]
struct AgentOut {
    target: String,
    short: String,
    project: String,
    repo: String,
    status: String,
    summary: String,
    session: String,
    tags: String,
}

async fn collect() -> Vec<chooser::Agent> {
    tokio::task::spawn_blocking(chooser::collect)
        .await
        .unwrap_or_default()
}

/// The live agent behind a target. Only targets that are agents right now are
/// accepted, so the API cannot be pointed at an arbitrary tmux pane.
async fn find(target: &str) -> ApiResult<chooser::Agent> {
    collect()
        .await
        .into_iter()
        .find(|a| a.target == target)
        .ok_or_else(|| bad(StatusCode::NOT_FOUND, format!("no live agent at {target}")))
}

async fn agents() -> Json<Vec<AgentOut>> {
    Json(
        collect()
            .await
            .into_iter()
            .map(|a| AgentOut {
                target: a.target,
                short: a.short_target,
                project: a.project,
                repo: a.repo_full,
                status: a.status,
                summary: a.summary,
                session: a.session_id,
                tags: a.tags,
            })
            .collect(),
    )
}

#[derive(Deserialize)]
struct PageQuery {
    t: String,
    before: Option<u64>,
    after: Option<u64>,
    limit: Option<usize>,
}

async fn transcript_page(Query(q): Query<PageQuery>) -> ApiResult<Json<transcript::Page>> {
    let agent = find(&q.t).await?;
    let path = agent
        .jsonl
        .ok_or_else(|| bad(StatusCode::NOT_FOUND, "agent has no transcript yet"))?;
    let limit = q.limit.unwrap_or(PAGE_DEFAULT).clamp(1, PAGE_MAX);
    let page = tokio::task::spawn_blocking(move || match q.after {
        Some(after) => transcript::page_after(&path, after, limit),
        None => transcript::page_before(&path, q.before, limit),
    })
    .await
    .map_err(|e| bad(StatusCode::INTERNAL_SERVER_ERROR, e.to_string()))?
    .map_err(|e| bad(StatusCode::INTERNAL_SERVER_ERROR, e.to_string()))?;
    Ok(Json(page))
}

#[derive(Deserialize)]
struct TargetQuery {
    t: String,
}

async fn screen(Query(q): Query<TargetQuery>) -> ApiResult<String> {
    let agent = find(&q.t).await?;
    tokio::task::spawn_blocking(move || tmux::capture_pane(&agent.pane, false, SCREEN_LINES))
        .await
        .map_err(|e| bad(StatusCode::INTERNAL_SERVER_ERROR, e.to_string()))
}

#[derive(Deserialize)]
struct SendBody {
    t: String,
    #[serde(default)]
    text: String,
    /// Press Enter after the text. Defaults to true; ignored when `text` is empty.
    submit: Option<bool>,
    key: Option<String>,
}

async fn send(Json(b): Json<SendBody>) -> ApiResult<StatusCode> {
    if let Some(k) = b.key.as_deref() {
        if !KEYS.contains(&k) {
            return Err(bad(
                StatusCode::BAD_REQUEST,
                format!("key not allowed: {k}"),
            ));
        }
    }
    if b.text.is_empty() && b.key.is_none() {
        return Err(bad(StatusCode::BAD_REQUEST, "nothing to send"));
    }
    let agent = find(&b.t).await?;
    let (server, pane) = tmux::split(&agent.pane);
    let server =
        server.ok_or_else(|| bad(StatusCode::INTERNAL_SERVER_ERROR, "pane has no server"))?;

    if !b.text.is_empty() {
        // A bracketed paste, not send-keys -l: a newline inside the text stays part of
        // the message instead of submitting it half-written.
        run_tmux(
            server,
            &["load-buffer", "-b", "agent-web", "-"],
            Some(&b.text),
        )
        .await?;
        run_tmux(
            server,
            &["paste-buffer", "-p", "-d", "-b", "agent-web", "-t", pane],
            None,
        )
        .await?;
        if b.submit.unwrap_or(true) {
            run_tmux(server, &["send-keys", "-t", pane, "Enter"], None).await?;
        }
    }
    if let Some(k) = b.key.as_deref() {
        run_tmux(server, &["send-keys", "-t", pane, k], None).await?;
    }
    Ok(StatusCode::NO_CONTENT)
}

async fn run_tmux(server: &str, args: &[&str], stdin: Option<&str>) -> ApiResult<()> {
    let mut cmd = tokio::process::Command::new("tmux");
    cmd.args(["-L", server])
        .args(args)
        .stdout(Stdio::null())
        .stderr(Stdio::piped());
    cmd.stdin(if stdin.is_some() {
        Stdio::piped()
    } else {
        Stdio::null()
    });
    let err = |e: std::io::Error| bad(StatusCode::INTERNAL_SERVER_ERROR, format!("tmux: {e}"));
    let mut child = cmd.spawn().map_err(err)?;
    if let (Some(text), Some(mut pipe)) = (stdin, child.stdin.take()) {
        pipe.write_all(text.as_bytes()).await.map_err(err)?;
    }
    let out = child.wait_with_output().await.map_err(err)?;
    if out.status.success() {
        Ok(())
    } else {
        Err(bad(
            StatusCode::BAD_GATEWAY,
            format!(
                "tmux {}: {}",
                args[0],
                String::from_utf8_lossy(&out.stderr).trim()
            ),
        ))
    }
}

#[derive(Serialize, Debug, PartialEq)]
struct Ask {
    id: String,
    project: String,
    kind: String,
    question: String,
    options: Vec<String>,
    recommend: String,
}

/// `agent-ask list` TSV: id, project, profile, status, kind, question, options,
/// task, answered_at, resumed_at, recommend.
fn parse_asks(tsv: &str) -> Vec<Ask> {
    tsv.lines()
        .filter_map(|l| {
            let f: Vec<&str> = l.split('\t').collect();
            (f.len() >= 7 && !f[0].is_empty()).then(|| Ask {
                id: f[0].into(),
                project: f[1].into(),
                kind: f[4].into(),
                question: f[5].into(),
                options: f[6]
                    .split('|')
                    .filter(|o| !o.is_empty())
                    .map(String::from)
                    .collect(),
                recommend: f.get(10).copied().unwrap_or("").into(),
            })
        })
        .collect()
}

async fn asks() -> ApiResult<Json<Vec<Ask>>> {
    let out = tokio::process::Command::new("agent-ask")
        .args(["list", "--all", "--pending"])
        .output()
        .await
        .map_err(|e| bad(StatusCode::INTERNAL_SERVER_ERROR, format!("agent-ask: {e}")))?;
    Ok(Json(parse_asks(&String::from_utf8_lossy(&out.stdout))))
}

#[derive(Deserialize)]
struct AnswerBody {
    id: String,
    answer: String,
}

async fn answer(Json(b): Json<AnswerBody>) -> ApiResult<StatusCode> {
    if b.id.is_empty()
        || !b
            .id
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_')
    {
        return Err(bad(StatusCode::BAD_REQUEST, "bad ask id"));
    }
    if b.answer.trim().is_empty() {
        return Err(bad(StatusCode::BAD_REQUEST, "empty answer"));
    }
    let out = tokio::process::Command::new("agent-ask")
        .args(["answer", &b.id, b.answer.trim()])
        .output()
        .await
        .map_err(|e| bad(StatusCode::INTERNAL_SERVER_ERROR, format!("agent-ask: {e}")))?;
    if out.status.success() {
        Ok(StatusCode::NO_CONTENT)
    } else {
        Err(bad(
            StatusCode::BAD_REQUEST,
            String::from_utf8_lossy(&out.stderr).trim().to_string(),
        ))
    }
}

async fn events_stream(
    State(s): State<Shared>,
) -> Sse<impl Stream<Item = Result<SseEvent, Infallible>>> {
    let stream = BroadcastStream::new(s.events.subscribe()).map(|m| {
        // A lagged receiver skipped messages; tell the page to refetch everything.
        let data = m.unwrap_or_else(|_| r#"{"kind":"resync"}"#.to_string());
        Ok(SseEvent::default().data(data))
    });
    Sse::new(stream).keep_alive(KeepAlive::default())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn classifies_watched_paths() {
        assert_eq!(
            classify(Path::new("/h/.claude/sessions/123.json")).as_deref(),
            Some(r#"{"kind":"sessions"}"#)
        );
        assert_eq!(
            classify(Path::new("/h/.claude/projects/-h-x/abc.jsonl")).as_deref(),
            Some(r#"{"kind":"transcript","session":"abc"}"#)
        );
        assert_eq!(
            classify(Path::new("/h/.agent/asks/bnb/Y3g.md")).as_deref(),
            Some(r#"{"kind":"asks"}"#)
        );
        assert_eq!(classify(Path::new("/h/notes/x.md")), None);
        assert_eq!(classify(Path::new("/h/.claude/sessions/123.key")), None);
        assert_eq!(
            classify(Path::new("/h/.claude/projects/-h-x/abc.json")),
            None
        );
    }

    #[test]
    fn parses_ask_rows() {
        let tsv = "Y3g\tbnb\t\tpending\tgate\tShip it?\tapprove|hold\t\t\t\tapprove\nshort\trow\n";
        let asks = parse_asks(tsv);
        assert_eq!(asks.len(), 1);
        assert_eq!(asks[0].options, vec!["approve", "hold"]);
        assert_eq!(asks[0].recommend, "approve");
        assert_eq!(asks[0].kind, "gate");
    }

    #[test]
    fn key_whitelist_excludes_session_killers() {
        assert!(KEYS.contains(&"Escape"));
        assert!(!KEYS.contains(&"C-c"));
        assert!(!KEYS.contains(&"C-d"));
    }
}
