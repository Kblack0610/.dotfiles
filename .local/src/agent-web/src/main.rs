//! agent-web: a web view of the Claude agents running in tmux on this machine.
//!
//! Lists every agent (the same pane x `~/.claude/sessions` join agent-panel uses),
//! pages through any agent's transcript, shows its live screen, types into its
//! pane, and answers the headless `agent-ask` queue. The board tabs show what the
//! tmux hub boards write (`boards`). Changes are pushed to the browser over SSE
//! from inotify, so nothing polls.
//!
//! Served behind the home cluster ingress (home-config `apps/agents`),
//! which only proxies; Sign in with Forgejo (see `auth`) is the real gate.

mod auth;
mod boards;
mod infra;
mod transcript;

use std::convert::Infallible;
use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::sync::Arc;
use std::time::Duration;

use agent_panel::{chooser, session, tmux};
use anyhow::Result;
use axum::extract::{Path as UrlPath, Query, Request, State};
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
/// The board tabs' scripts, served beside the page. Each registers itself in `TABS`.
const STATIC: &[(&str, &str, &str)] = &[
    (
        "charts.js",
        "text/javascript",
        include_str!("../static/charts.js"),
    ),
    (
        "watch.js",
        "text/javascript",
        include_str!("../static/watch.js"),
    ),
    (
        "log.js",
        "text/javascript",
        include_str!("../static/log.js"),
    ),
    (
        "infra.js",
        "text/javascript",
        include_str!("../static/infra.js"),
    ),
];
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
    infra: infra::Cache,
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
    watch(events.clone())?;
    let state = Arc::new(AppState {
        oauth,
        sessions,
        events,
        infra: infra::Cache::default(),
    });

    let api = Router::new()
        .route("/api/agents", get(agents))
        .route("/api/transcript", get(transcript_page))
        .route("/api/screen", get(screen))
        .route("/api/send", post(send))
        .route("/api/asks", get(asks))
        .route("/api/asks/answer", post(answer))
        .route("/api/watch", get(watch_board))
        .route("/api/log", get(log_day))
        .route("/api/log/history", get(log_history))
        .route("/api/infra", get(infra_board))
        .route("/api/events", get(events_stream))
        .route("/static/{name}", get(static_file))
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

/// A directory just created directly under `projects`: a new project, whose transcripts need a
/// watch of their own.
fn is_new_project(kind: &EventKind, p: &Path, projects: &Path) -> bool {
    matches!(kind, EventKind::Create(_)) && p.parent() == Some(projects)
}

/// inotify on the session registry and the transcripts. Each change becomes one
/// small SSE message; the browser decides whether it cares. Transcripts sit directly in each
/// project dir, so nothing below it is watched: a recursive watch took one inotify watch per
/// `tool-results` and `subagents` dir, and agent-web would not start when the user's limit was
/// nearly used up.
fn watch(tx: broadcast::Sender<String>) -> Result<()> {
    let claude = session::home().join(".claude");
    let projects = claude.join("projects");
    let (new_dirs, mut new_dirs_rx) = tokio::sync::mpsc::unbounded_channel::<PathBuf>();
    let watched = projects.clone();
    let mut w = notify::recommended_watcher(move |res: notify::Result<notify::Event>| {
        let Ok(ev) = res else { return };
        if matches!(ev.kind, EventKind::Access(_)) {
            return;
        }
        for p in &ev.paths {
            if is_new_project(&ev.kind, p, &watched) {
                let _ = new_dirs.send(p.clone());
            }
            if let Some(msg) = classify(p) {
                let _ = tx.send(msg); // no subscribers is fine
            }
        }
    })?;
    w.watch(&claude.join("sessions"), RecursiveMode::NonRecursive)?;
    w.watch(&projects, RecursiveMode::NonRecursive)?;
    for entry in std::fs::read_dir(&projects)?.flatten() {
        if entry.path().is_dir() {
            w.watch(&entry.path(), RecursiveMode::NonRecursive)?;
        }
    }
    let asks = session::home().join(".agent").join("asks");
    if asks.is_dir() {
        w.watch(&asks, RecursiveMode::Recursive)?;
    }
    // The boards' files: watch a directory, not the file, since each is replaced by a rename.
    for dir in [
        boards::fleet_state().parent().map(Path::to_path_buf),
        Some(boards::shepherd_dir()),
        Some(boards::daylog_dir()),
    ]
    .into_iter()
    .flatten()
    {
        if dir.is_dir() {
            w.watch(&dir, RecursiveMode::NonRecursive)?;
        }
    }
    // The task owns the watcher, so it lives as long as the server. The watch calls happen here
    // because notify must not be called from inside its own event handler.
    tokio::spawn(async move {
        while let Some(dir) = new_dirs_rx.recv().await {
            if let Err(e) = w.watch(&dir, RecursiveMode::NonRecursive) {
                eprintln!("agent-web: cannot watch {}: {e}", dir.display());
            }
        }
    });
    Ok(())
}

fn classify(p: &Path) -> Option<String> {
    if p.ends_with(".local/state/fleet/state.json") || p.ends_with(".agent/shepherd/watch.log") {
        return Some(r#"{"kind":"watch"}"#.to_string());
    }
    // Only day-log names its files by day; its `.tmp` and `.lock` never match.
    if let Some(day) = p.file_name()?.to_str()?.strip_suffix(".json") {
        if boards::is_day(day) {
            return Some(serde_json::json!({"kind": "log", "date": day}).to_string());
        }
    }
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
    /// The dialog or permission prompt a `waiting` agent has open, from its transcript. A
    /// question asked in the conversation is not read here: the session files it as an ask
    /// (`stop-post.d/88-ask-filed.sh`), and the ask is what the Waiting tab shows.
    #[serde(skip_serializing_if = "Option::is_none")]
    question: Option<transcript::Question>,
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
    // Blocking: the dialog is a transcript read, done only for agents that have one open.
    let out = tokio::task::spawn_blocking(|| {
        chooser::collect()
            .into_iter()
            .map(|a| AgentOut {
                question: match (a.status.as_str(), &a.jsonl) {
                    ("waiting", Some(p)) => transcript::pending_question(p).ok().flatten(),
                    _ => None,
                },
                target: a.target,
                short: a.short_target,
                project: a.project,
                repo: a.repo_full,
                status: a.status,
                summary: a.summary,
                session: a.session_id,
                tags: a.tags,
            })
            .collect()
    })
    .await
    .unwrap_or_default();
    Json(out)
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
    capture(agent.pane).await
}

/// Sampling a pane while a paste renders. tmux has no event for "the program in this pane has
/// read its input", so this is the one bounded loop on one cadence. 40 samples is 2s.
const PASTE_POLL: Duration = Duration::from_millis(50);
const PASTE_POLLS: u32 = 40;

/// Wait until `capture` has moved away from `before` and then held still for one sample: the
/// program has read the paste and drawn it. Claude Code drops an Enter that arrives on the heels
/// of a paste, which leaves the message sitting unsent in its input box. False when the pane never
/// settles, as under a running spinner; the caller presses Enter regardless, once.
async fn paste_settled<F, Fut>(before: &str, mut capture: F, polls: u32, cadence: Duration) -> bool
where
    F: FnMut() -> Fut,
    Fut: std::future::Future<Output = String>,
{
    let mut last: Option<String> = None;
    for _ in 0..polls {
        let now = capture().await;
        if now != before && last.as_deref() == Some(now.as_str()) {
            return true;
        }
        last = Some(now);
        tokio::time::sleep(cadence).await;
    }
    false
}

async fn capture(pane: String) -> ApiResult<String> {
    tokio::task::spawn_blocking(move || tmux::capture_pane(&pane, false, SCREEN_LINES))
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
        let before = capture(agent.pane.clone()).await?;
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
            paste_settled(
                &before,
                || async { capture(agent.pane.clone()).await.unwrap_or_default() },
                PASTE_POLLS,
                PASTE_POLL,
            )
            .await;
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
    /// The Claude session that asked, empty for a headless run: the tab puts the ask under it.
    session: String,
}

/// `agent-ask list` TSV: id, project, profile, status, kind, question, options,
/// task, answered_at, resumed_at, recommend, created, session, closed_at, closed_reason,
/// claude_session.
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
                session: f.get(15).copied().unwrap_or("").into(),
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

async fn watch_board() -> ApiResult<Json<boards::Watch>> {
    tokio::task::spawn_blocking(|| {
        boards::watch(
            &boards::fleet_state(),
            &boards::shepherd_dir().join("watch.log"),
        )
    })
    .await
    .map(Json)
    .map_err(|e| bad(StatusCode::INTERNAL_SERVER_ERROR, e.to_string()))
}

#[derive(Deserialize)]
struct LogQuery {
    date: Option<String>,
}

async fn log_day(Query(q): Query<LogQuery>) -> ApiResult<Json<serde_json::Value>> {
    if q.date.as_deref().is_some_and(|d| !boards::is_day(d)) {
        return Err(bad(StatusCode::BAD_REQUEST, "date is YYYY-MM-DD"));
    }
    tokio::task::spawn_blocking(move || boards::record(&boards::daylog_dir(), q.date.as_deref()))
        .await
        .map_err(|e| bad(StatusCode::INTERNAL_SERVER_ERROR, e.to_string()))?
        .map(Json)
        .ok_or_else(|| bad(StatusCode::NOT_FOUND, "no day-log record for that day"))
}

#[derive(Deserialize)]
struct HistoryQuery {
    days: Option<usize>,
}

async fn log_history(Query(q): Query<HistoryQuery>) -> ApiResult<Json<Vec<boards::DayRow>>> {
    let n = q.days.unwrap_or(30);
    tokio::task::spawn_blocking(move || boards::history(&boards::daylog_dir(), n))
        .await
        .map(Json)
        .map_err(|e| bad(StatusCode::INTERNAL_SERVER_ERROR, e.to_string()))
}

async fn infra_board(State(s): State<Shared>) -> Response {
    (
        [(header::CONTENT_TYPE, "application/json")],
        s.infra.get().await,
    )
        .into_response()
}

async fn static_file(UrlPath(name): UrlPath<String>) -> Response {
    match STATIC.iter().find(|(n, _, _)| *n == name) {
        Some((_, ctype, body)) => ([(header::CONTENT_TYPE, *ctype)], *body).into_response(),
        None => StatusCode::NOT_FOUND.into_response(),
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

    /// Run `paste_settled` over scripted captures; returns its answer and how many it read.
    async fn settle(script: &[&str], polls: u32) -> (bool, usize) {
        let mut it = script.iter();
        let mut read = 0;
        let settled = paste_settled(
            "before",
            || {
                read += 1;
                let next = it.next().copied().unwrap_or("before").to_string();
                async move { next }
            },
            polls,
            Duration::ZERO,
        )
        .await;
        (settled, read)
    }

    #[test]
    fn only_a_dir_directly_under_projects_is_a_new_project() {
        use notify::event::{CreateKind, ModifyKind};
        let projects = Path::new("/h/.claude/projects");
        let create = EventKind::Create(CreateKind::Any);
        assert!(is_new_project(&create, &projects.join("-new"), projects));
        assert!(!is_new_project(&create, &projects.join("-new/s.jsonl"), projects));
        let modify = EventKind::Modify(ModifyKind::Any);
        assert!(!is_new_project(&modify, &projects.join("-new"), projects));
    }

    #[tokio::test]
    async fn settles_once_the_paste_is_drawn_and_still() {
        let got = settle(&["before", "before", "pasted", "pasted", "unread"], 40).await;
        assert_eq!(got, (true, 4));
    }

    #[tokio::test]
    async fn a_pane_still_redrawing_has_not_settled() {
        let got = settle(&["a", "b", "c", "c"], 40).await;
        assert_eq!(got, (true, 4));
        assert_eq!(settle(&["a", "b", "c", "d"], 4).await, (false, 4));
    }

    #[tokio::test]
    async fn an_unchanged_pane_gives_up_at_the_bound() {
        assert_eq!(settle(&[], 5).await, (false, 5));
    }

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
        assert_eq!(
            classify(Path::new("/h/.local/state/fleet/state.json")).as_deref(),
            Some(r#"{"kind":"watch"}"#)
        );
        assert_eq!(
            classify(Path::new("/h/.agent/shepherd/watch.log")).as_deref(),
            Some(r#"{"kind":"watch"}"#)
        );
        assert_eq!(
            classify(Path::new("/h/.agent/daylog/2026-10-29.json")).as_deref(),
            Some(r#"{"date":"2026-10-29","kind":"log"}"#)
        );
        assert_eq!(
            classify(Path::new("/h/.agent/daylog/2026-10-29.json.tmp")),
            None
        );
        assert_eq!(classify(Path::new("/h/.agent/daylog/.lock")), None);
        assert_eq!(
            classify(Path::new("/h/.local/state/fleet/.state.AbC123")),
            None
        );
        assert_eq!(classify(Path::new("/h/.agent/shepherd/watch.state")), None);
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
