//! agent-web: a web view of the Claude agents running in tmux on this machine.
//!
//! Lists every agent (the same pane x `~/.claude/sessions` join agent-panel uses),
//! pages through any agent's transcript, shows its live screen, types into its
//! pane, acts on the session (`hub_core::session_actions`: interrupt, park, unpark,
//! move, stop, cancel), and answers the headless `agent-ask` queue. The board tabs show what the
//! tmux hub boards write (`boards`). Changes are pushed to the browser over SSE
//! from inotify, so nothing polls.
//!
//! Served behind the home cluster ingress (home-config `apps/agents`),
//! which only proxies; Sign in with Forgejo (see `auth`) is the real gate.

mod alerts;
mod assets;
mod audit;
mod auth;
mod board;
mod briefing;
mod builds;
mod cache;
mod cards;
mod cli;
mod costs;
mod deliverables;
mod departments;
mod epics;
mod feed;
mod fleet;
mod focus;
mod infra;
mod jobs;
mod live;
mod outbox;
mod outcomes;
mod pipelines;
mod projects;
mod proposals;
mod push;
mod queue;
mod releases;
mod remote;
mod reqlog;
mod schedules;
mod sessions;
mod setup;
mod shepherd;
mod sprints;
mod stack;
mod stages;
mod suites;
mod widget;
mod worklog;

use std::convert::Infallible;
use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::sync::Arc;
use std::time::Duration;

use agent_core::{agent, parked, session};
use anyhow::Result;
use assets::LOGIN;
use axum::body::Bytes;
use axum::extract::{DefaultBodyLimit, Form, Path as UrlPath, Query, Request, State};
use axum::http::{header, HeaderMap, StatusCode};
use axum::middleware::{self, Next};
use axum::response::sse::{Event as SseEvent, KeepAlive, Sse};
use axum::response::{Html, IntoResponse, Response};
use axum::routing::{get, post};
use axum::{Json, Router};
use hub_core::home::{Home, Need};
use hub_core::session_actions::{self as actions, Action};
use hub_core::session_table;
use hub_core::table::{self, Summary, View};
use hub_core::{boards, transcript};
use notify::{EventKind, RecursiveMode, Watcher};
use serde::{Deserialize, Serialize};
use tokio::io::AsyncWriteExt;
use tokio::sync::{broadcast, watch};
use tokio_stream::wrappers::{BroadcastStream, WatchStream};
use tokio_stream::{Stream, StreamExt};
use tower_http::compression::predicate::{DefaultPredicate, NotForContentType, Predicate};
use tower_http::compression::CompressionLayer;

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
/// The most text one send types into a pane; a paste past this is refused, not cut.
const MAX_SEND: usize = 64 * 1024;
/// The most text one ask answer takes; agent-ask flattens it to one line.
const MAX_ANSWER: usize = 8 * 1024;

struct AppState {
    oauth: auth::OAuth,
    sessions: auth::Sessions,
    events: broadcast::Sender<String>,
    /// True once the server is stopping: each live-update stream ends, so the drain finishes.
    stopping: watch::Receiver<bool>,
    /// The paths agent-web could not watch, so changes there reach no page until a retry works.
    watch_off: WatchOff,
    infra: infra::Cache,
    machines: infra::Pages,
    pools: infra::Pages,
    /// `#releases/apps/<app>`'s read (`hub_core::app_status`).
    apps: infra::Pages,
    alerts: alerts::Cache,
    jobs: jobs::Cache,
    actions: feed::Cache,
    work: worklog::Cache,
    schedules: schedules::Cache,
    stack: stack::Cache,
    session_table: sessions::Cache,
    briefing: briefing::Cache,
    queue: queue::Cache,
    /// judge-eval's answer, which Runners, Log Judges and a judge's runner page read (`fleet.rs`).
    fleet: fleet::Cache,
    /// `fleet-shepherd stats`, which Log's Rundowns and Sessions' Shepherd read (`shepherd.rs`).
    shepherd: shepherd::Cache,
    /// The one read of the sessions, which `/api/agents` (the sidebar every page draws first) and the Sessions table share.
    live: cache::EventCache<live::Live, AGENTS_SECS>,
    /// Home's own reads (`HomeParts`), joined with the queue and infra caches per request.
    home: cache::EventCache<HomeParts, HOME_SECS>,
    /// Wakes the Tilecast push sender (`push::run`).
    push: push::Pusher,
    /// `/api/watch` as served: the fleet state with its asks, and the shepherd's transitions.
    watch: cache::EventCache<(Bytes, bool), WATCH_SECS>,
}

type Shared = Arc<AppState>;
/// The events a slow subscriber may fall behind by before it lags (see `main`).
const EVENT_BACKLOG: usize = 4096;
/// The sidebar's sources: the session registry and park ledgers, the fleet state's phases, asks.
const AGENTS_KINDS: [&str; 3] = ["sessions", "watch", "asks"];
/// A session's status moves without a file event (tmux, a transcript's last line), so the
/// sidebar is not kept past this.
const AGENTS_SECS: u64 = 15;
/// Home's own sources (`HomeParts`); the queue and infra parts are their own caches.
const HOME_KINDS: [&str; 4] = ["watch", "sessions", "asks", "proposals"];
/// The board (`notes board`) pushes no event, so Home's parts are not kept past this.
const HOME_SECS: u64 = 30;
/// The Watch tab's sources: the fleet state and shepherd log (`classify`), and asks.
const WATCH_KINDS: [&str; 2] = ["watch", "asks"];
/// A session's status in the fleet state moves without an event too, so not kept past this.
const WATCH_SECS: u64 = 15;
type ApiResult<T> = Result<T, (StatusCode, String)>;

fn bad(code: StatusCode, msg: impl Into<String>) -> (StatusCode, String) {
    (code, msg.into())
}

#[tokio::main]
async fn main() -> Result<()> {
    let oauth = auth::OAuth::load()?;
    let sessions = auth::Sessions::load();
    // Transcripts alone write about four events a second; a cache read less often than the
    // channel holds takes a lag as a change and reads again, so it holds about a quarter hour.
    let (events, _) = broadcast::channel(EVENT_BACKLOG);
    cache::announce_to(events.clone());
    let watch_off = WatchOff::default();
    watch(events.clone(), watch_off.clone())?;
    let (stop, stopping) = watch::channel(false);
    let state = Arc::new(AppState {
        stopping,
        oauth,
        sessions,
        actions: feed::Cache::new(events.subscribe()),
        work: worklog::Cache::new(events.subscribe()),
        alerts: alerts::Cache::new(events.subscribe()),
        queue: queue::Cache::new(&events),
        fleet: fleet::Cache::new(events.subscribe()),
        shepherd: shepherd::Cache::new(events.subscribe()),
        live: cache::EventCache::new(events.subscribe(), &AGENTS_KINDS, "agents"),
        home: cache::EventCache::new(events.subscribe(), &HOME_KINDS, "home"),
        watch: cache::EventCache::new(events.subscribe(), &WATCH_KINDS, "watch"),
        events,
        watch_off,
        infra: infra::Cache::default(),
        machines: infra::Pages::new("machine-page"),
        pools: infra::Pages::new("pool-page"),
        apps: infra::Pages::new("app-page"),
        jobs: jobs::Cache::default(),
        schedules: schedules::Cache::default(),
        stack: stack::Cache::default(),
        session_table: sessions::Cache::default(),
        briefing: briefing::Cache::default(),
        push: push::Pusher::default(),
    });
    tokio::spawn(warm(state.clone()));
    tokio::spawn(keep_tests(state.clone(), state.events.subscribe()));
    tokio::spawn(push::run(state.clone()));

    let app = router(state);

    let addr = std::env::var("AGENT_WEB_ADDR").unwrap_or_else(|_| DEFAULT_ADDR.into());
    let listener = tokio::net::TcpListener::bind(&addr).await?;
    let term = tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate())?;
    eprintln!("agent-web: listening on {addr}");
    serve_until(listener, app, stop_signal(term), stop, DRAIN).await?;
    Ok(())
}

/// Every route, behind the layers each one needs.
fn router(state: Shared) -> Router {
    let api = Router::new()
        .route("/api/agents", get(agents))
        .route("/api/transcript", get(transcript_page))
        .route("/api/screen", get(screen))
        .route("/api/send", post(send))
        .route("/api/session/{target}/{action}", post(session_action))
        .route("/api/session-options", get(session_options))
        .route("/api/sessions/table", get(sessions_table))
        .route("/api/sessions/page", get(sessions_page))
        .route("/api/sessions/capacity", get(sessions_capacity))
        .route("/api/sessions/timer/{name}/start", post(sessions_start))
        .route("/api/asks", get(asks))
        .route("/api/asks/answer", post(answer))
        .route("/api/asks/parked", get(parked_asks))
        .route("/api/asks/park", post(park))
        .route("/api/asks/{id}/trace", get(ask_trace))
        .route("/api/asks/{id}/preview/{n}", get(ask_preview))
        .route("/api/watch", get(watch_board))
        .route("/api/log", get(log_day))
        .route("/api/log/history", get(log_history))
        .route("/api/home", get(home_board))
        .route("/api/home/waiting", get(home_waiting))
        .route("/api/home/proposals", get(proposals::list))
        .route("/api/home/cards", get(cards::get))
        .route("/api/briefing", get(briefing_night))
        .route("/api/proposals/accept", post(proposals::accept))
        .route("/api/proposals/reject", post(proposals::reject))
        .route("/api/infra", get(infra_board))
        .route("/api/infra/machine", get(infra_machine))
        .route("/api/infra/pool", get(infra_pool))
        .route("/api/fleet", get(fleet_board))
        .route("/api/fleet/runner", get(fleet_runner))
        .route("/api/flow", get(flow_strip))
        .route("/api/jobs", get(jobs_list))
        .route("/api/jobs/log", get(job_log))
        .route("/api/schedules", get(schedules_list))
        .route("/api/stack", get(stack_list))
        .route("/api/stack/flow", get(stack_flow))
        .route("/api/stack/flow.svg", get(stack_flow_svg))
        .route("/api/releases", get(releases_list))
        .route("/api/releases/changelog", get(releases::changelog))
        .route("/api/releases/app", get(releases_app))
        .route("/api/releases/lanes", get(releases_lanes))
        .route("/api/releases/release", get(releases_release))
        .route("/api/releases/version", get(releases_version))
        .route("/api/builds", get(builds_list))
        .route("/api/builds/log", get(build_log))
        .route("/api/builds/detail", get(build_detail))
        .route("/api/builds/joblog", get(build_job_log))
        .route("/api/tests", get(tests_list))
        .route("/api/pipelines", get(pipelines_list))
        .route("/api/pipelines/detail", get(pipelines_detail))
        .route("/api/tests/cases", get(tests_cases))
        .route("/api/board", get(board::feed).post(board::write))
        .route("/api/sprints", get(sprints::get))
        .route("/api/deliverables", get(deliverables::get))
        .route("/api/stages", get(stages::get))
        .route("/api/stages/requirements", get(stages::get_requirements))
        .route("/api/projects", get(projects::get))
        .route("/api/projects/{name}/page", get(projects::page))
        .route(
            "/api/projects/{name}/departments",
            get(departments::get_project),
        )
        .route("/api/coverage", get(departments::get))
        .route("/api/focus", get(focus::get).put(focus::save))
        .route("/api/inbox/ack", post(focus::ack))
        .route("/api/outbox", get(outbox::get).put(outbox::save))
        .route("/api/queue", get(queue::list).post(queue::add))
        .route("/api/queue/cancel", post(queue::cancel))
        .route("/api/queue/bump", post(queue::bump))
        .route("/api/queue/projects", get(queue::projects))
        .route("/api/queue/stats", get(queue::stats))
        .route("/api/queue/candidates", get(queue::candidates))
        .route("/api/queue/history", get(queue::history))
        .route("/api/shepherd", get(shepherd::get))
        .route("/api/outcomes", get(outcomes::ranked))
        .route("/api/outcomes/card", get(outcomes::card))
        .route("/api/alerts", get(alerts_board))
        .route("/api/costs", get(costs::get))
        .route("/api/actions", get(feed::get))
        .route("/api/log/work", get(worklog::get))
        .route("/api/events", get(events_stream))
        .layer(middleware::from_fn_with_state(state.clone(), wrote))
        .layer(middleware::from_fn_with_state(state.clone(), require_auth));

    let app = Router::new()
        .route("/", get(index))
        .route("/login", get(login))
        .route("/login/key", post(login_key))
        .route("/oauth/callback", get(callback))
        .route("/logout", post(logout))
        .route("/healthz", get(|| async { "ok" }))
        // The assets are this public repo's code and carry no data, so they load with no cookie;
        // every read of data stays behind sign-in or the widget key.
        .route("/static/{name}", get(static_file))
        .route("/widget.json", get(widget::doc))
        // A literal, not push::REGISTER, so audit's route test reads it.
        .route(
            "/widget/push-register",
            post(push::register).delete(push::register),
        )
        .route("/widget/push-send", post(push::send))
        // Behind the session sign-in, which each handler checks: never the widget key.
        .route("/widget/setup", get(setup::page))
        .route("/widget/setup/new-key", post(setup::new_key))
        .merge(api);
    guard_writes(app, state.oauth.base())
        .layer(middleware::from_fn_with_state(state.clone(), audit::layer))
        .layer(middleware::map_response(assets::headers))
        .layer(middleware::from_fn(reqlog::log))
        .layer(compression())
        .with_state(state)
}

/// How long a stop waits for the requests in flight: a cold project page reads for about 10s.
const DRAIN: Duration = Duration::from_secs(30);

/// SIGTERM (systemd's stop, so a rebuild's restart; installed before the listener serves, so a
/// failure to install it stops the start) or Ctrl-C.
async fn stop_signal(mut term: tokio::signal::unix::Signal) {
    tokio::select! {
        _ = term.recv() => {}
        _ = tokio::signal::ctrl_c() => {}
    }
}

/// Serve `app` until `signal`; then take no new connection, set `stop` (each live-update stream
/// ends), and answer the requests in flight for at most `drain`, so a restart drops none of them.
async fn serve_until(
    listener: tokio::net::TcpListener,
    app: Router,
    signal: impl std::future::Future<Output = ()> + Send + 'static,
    stop: watch::Sender<bool>,
    drain: Duration,
) -> std::io::Result<()> {
    let mut stopped = stop.subscribe();
    let serve = axum::serve(listener, app).with_graceful_shutdown(async move {
        signal.await;
        eprintln!("agent-web: stopping; answering the requests in flight first");
        let _ = stop.send(true);
    });
    tokio::select! {
        r = serve => r,
        _ = async {
            let _ = stopped.wait_for(|s| *s).await;
            tokio::time::sleep(drain).await;
        } => {
            eprintln!("agent-web: stopped with requests still in flight after {drain:?}");
            Ok(())
        }
    }
}

/// `stream` until `stopping` turns true.
fn until_stopped<T: Send + 'static>(
    stream: impl Stream<Item = T> + Send + 'static,
    stopping: watch::Receiver<bool>,
) -> impl Stream<Item = T> + Send + 'static {
    let stop = WatchStream::new(stopping).filter(|s| *s).map(|_| None);
    stream
        .map(Some)
        .merge(stop)
        .take_while(Option::is_some)
        .map(|o| o.expect("take_while kept only Some"))
}

/// A directory just created directly under `projects`: a new project, whose transcripts need a
/// watch of their own.
fn is_new_project(kind: &EventKind, p: &Path, projects: &Path) -> bool {
    matches!(kind, EventKind::Create(_)) && p.parent() == Some(projects)
}

/// How long a failed watch waits before it is tried again, doubling up to the cap. The usual
/// failure is the per-user inotify limit (another program holds the watches), and nothing sends
/// an event when it frees some, so this is a retry with backoff.
const WATCH_RETRY_FIRST: Duration = Duration::from_secs(10);
const WATCH_RETRY_MAX: Duration = Duration::from_secs(300);

type WatchOff = Arc<std::sync::Mutex<Vec<String>>>;
type Target = (PathBuf, RecursiveMode);

/// Watch each target; return the ones that failed, each logged. A failed watch is not fatal:
/// the server still answers, the page says live updates are off, and the watch is retried.
fn add_watches(w: &mut impl Watcher, targets: Vec<Target>) -> Vec<Target> {
    targets
        .into_iter()
        .filter(|(p, mode)| match w.watch(p, *mode) {
            Ok(()) => false,
            Err(e) => {
                eprintln!("agent-web: cannot watch {}: {e}", p.display());
                true
            }
        })
        .collect()
}

/// The SSE message that tells the page which paths are not watched (none: live updates on).
fn live_msg(off: &[String]) -> String {
    serde_json::json!({"kind": "live", "off": off}).to_string()
}

/// Record the failed set and tell the pages, if it changed.
fn publish_off(off: &WatchOff, tx: &broadcast::Sender<String>, failed: &[Target]) {
    let now: Vec<String> = failed
        .iter()
        .map(|(p, _)| p.display().to_string())
        .collect();
    let mut cur = off.lock().unwrap_or_else(|e| e.into_inner());
    if *cur != now {
        let _ = tx.send(live_msg(&now));
        *cur = now;
    }
}

/// inotify on the session registry and the transcripts. Each change becomes one
/// small SSE message; the browser decides whether it cares. Transcripts sit directly in each
/// project dir, so nothing below it is watched: a recursive watch took one inotify watch per
/// `tool-results` and `subagents` dir.
fn watch(tx: broadcast::Sender<String>, off: WatchOff) -> Result<()> {
    let claude = session::home().join(".claude");
    let projects = claude.join("projects");
    let (new_dirs, mut new_dirs_rx) = tokio::sync::mpsc::unbounded_channel::<PathBuf>();
    let (cached_events, mut cached_rx) = tokio::sync::mpsc::unbounded_channel::<String>();
    let watched = projects.clone();
    let events = tx.clone();
    let mut w = notify::recommended_watcher(move |res: notify::Result<notify::Event>| {
        let Ok(ev) = res else { return };
        if matches!(ev.kind, EventKind::Access(_)) {
            return;
        }
        for p in &ev.paths {
            if is_new_project(&ev.kind, p, &watched) {
                let _ = new_dirs.send(p.clone());
            }
            match classify(p) {
                // Costs and Builds keep their read, so the task below drops it before it tells
                // the page; a refresh that raced ahead would get the old snapshots back.
                Some(msg)
                    if [COSTS_EVENT, BUILDS_EVENT, PIPELINES_EVENT, STAGES_EVENT]
                        .contains(&msg.as_str()) =>
                {
                    let _ = cached_events.send(msg);
                }
                Some(msg) => {
                    let _ = events.send(msg); // no subscribers is fine
                }
                None => {}
            }
        }
    })?;
    let flat = RecursiveMode::NonRecursive;
    let mut targets: Vec<Target> = vec![(claude.join("sessions"), flat), (projects.clone(), flat)];
    if let Ok(dirs) = std::fs::read_dir(&projects) {
        targets.extend(
            dirs.flatten()
                .map(|e| e.path())
                .filter(|p| p.is_dir())
                .map(|p| (p, flat)),
        );
    }
    let asks = boards::asks_dir();
    if asks.is_dir() {
        targets.push((asks, RecursiveMode::Recursive));
    }
    // claude-acct's park ledgers: a parked session is a row with no live claude.
    let parked = parked::root();
    std::fs::create_dir_all(&parked)?;
    targets.push((parked, flat));
    // agent-queue's store; its states and done/<date>/ come and go, so watch it whole.
    let queue = session::home().join(".agent").join("queue");
    std::fs::create_dir_all(&queue)?;
    targets.push((queue, RecursiveMode::Recursive));
    // agent-propose's store: Home's Proposals section.
    let proposals = boards::proposals_dir();
    std::fs::create_dir_all(&proposals)?;
    targets.push((proposals, flat));
    // The nightly token snapshots: Costs' Where the tokens go. The first one must still push.
    let tokens = boards::token_usage_dir();
    std::fs::create_dir_all(&tokens)?;
    targets.push((tokens, flat));
    // release-state's snapshot, replaced by a rename: the Releases tab.
    let snapshots = boards::releases_dir();
    std::fs::create_dir_all(&snapshots)?;
    targets.push((snapshots, flat));
    // schedules-sync's run ledger and its sync record: the Releases tab's Builds section.
    if let Some(dir) = hub_core::builds::Paths::from_env().ledger.parent() {
        std::fs::create_dir_all(dir)?;
        targets.push((dir.to_path_buf(), flat));
    }
    // schedules-sync's state.json, replaced by a rename: Infra's Pipelines.
    if let Some(dir) = schedules_state().parent() {
        std::fs::create_dir_all(dir)?;
        targets.push((dir.to_path_buf(), flat));
    }
    // The boards' files: watch a directory, not the file, since each is replaced by a rename.
    for dir in [
        boards::fleet_state().parent().map(Path::to_path_buf),
        Some(boards::shepherd_dir()),
        Some(boards::daylog_dir()),
        // Sessions' Runners run ledger, and fleet-dispatch's verdicts and log.
        Some(hub_core::jobs::Paths::from_env().agentctl),
        Some(boards::dispatch_dir()),
        // agent-notify's ledger, for Log's Actions section.
        hub_core::actions::Paths::from_env()
            .notify_log
            .parent()
            .map(Path::to_path_buf),
    ]
    .into_iter()
    .flatten()
    {
        if dir.is_dir() {
            targets.push((dir, flat));
        }
    }
    // The operator audit log, for Log's Actions section. Made here, so the first line reaches an
    // open page.
    if let Some(dir) = hub_core::audit::path().parent() {
        std::fs::create_dir_all(dir)?;
        targets.push((dir.to_path_buf(), flat));
    }
    // fleet-dispatch's state directory, for its Candidates snapshot (replaced by a rename). Made
    // here, as the queue's is, so the first snapshot reaches an open page.
    let dispatch_state = boards::dispatch_state_dir();
    std::fs::create_dir_all(&dispatch_state)?;
    targets.push((dispatch_state, flat));
    // The shepherd's kept rundowns: a directory of whole files, each landed by a rename.
    // Made here, as the queue's is, so the first record reaches an open page.
    let rundowns = boards::shepherd_dir().join("rundowns");
    std::fs::create_dir_all(&rundowns)?;
    targets.push((rundowns, flat));
    // Daily's outbox: the outbox's directory, from the CLI that owns its path, and the notes
    // state directory that holds ingest.jsonl. Both files are replaced by a rename.
    if let Some(dir) = hub_core::outbox::doc(&hub_core::session_actions::System)
        .ok()
        .and_then(|d| PathBuf::from(d.path).parent().map(Path::to_path_buf))
    {
        targets.push((dir, flat));
    }
    let notes_state = session::home().join(".local/state/notes");
    if notes_state.is_dir() {
        targets.push((notes_state, flat));
    }
    // The nightly stage pass's stages.json, replaced by a rename: Projects' Ladder.
    if let Some(dir) = STAGES_FILE.parent().filter(|d| d.is_dir()) {
        targets.push((dir.to_path_buf(), flat));
    }
    // Sentinel's state files: a watch tripping, clearing or failing pushes the Alerts tab.
    let sentinel = hub_core::alerts::watch_dirs().1;
    if sentinel.is_dir() {
        targets.push((sentinel, flat));
    }
    let mut failed = add_watches(&mut w, targets);
    publish_off(&off, &tx, &failed);
    // The task owns the watcher, so it lives as long as the server. The watch calls happen here
    // because notify must not be called from inside its own event handler.
    tokio::spawn(async move {
        let mut delay = WATCH_RETRY_FIRST;
        loop {
            let retry = !failed.is_empty();
            tokio::select! {
                dir = new_dirs_rx.recv() => {
                    let Some(dir) = dir else { break };
                    failed.extend(add_watches(&mut w, vec![(dir, flat)]));
                }
                Some(msg) = cached_rx.recv() => {
                    if msg == BUILDS_EVENT {
                        builds::outdate();
                    } else if msg == PIPELINES_EVENT {
                        pipelines::outdate();
                    } else if msg == STAGES_EVENT {
                        stages::outdate();
                    } else {
                        costs::outdate();
                    }
                    let _ = tx.send(msg);
                }
                () = tokio::time::sleep(delay), if retry => {
                    // A project dir removed since needs no watch; anything else waits to exist.
                    failed.retain(|(p, _)| p.exists() || p.parent() != Some(projects.as_path()));
                    failed = add_watches(&mut w, std::mem::take(&mut failed));
                    delay = if failed.is_empty() { WATCH_RETRY_FIRST } else { (delay * 2).min(WATCH_RETRY_MAX) };
                }
            }
            publish_off(&off, &tx, &failed);
        }
    });
    Ok(())
}

/// A new token snapshot: the Costs tab reads afresh.
const COSTS_EVENT: &str = r#"{"kind":"costs"}"#;
const BUILDS_EVENT: &str = r#"{"kind":"builds"}"#;
/// schedules-sync wrote state.json: the Pipelines section reads afresh.
const PIPELINES_EVENT: &str = r#"{"kind":"pipelines"}"#;

fn schedules_state() -> PathBuf {
    hub_core::schedules::state_path(&session::home().to_string_lossy())
}
/// The nightly stage pass wrote stages.json: Projects' Ladder reads afresh.
const STAGES_EVENT: &str = r#"{"kind":"stages"}"#;
static STAGES_FILE: std::sync::LazyLock<PathBuf> =
    std::sync::LazyLock::new(|| hub_core::stages::Paths::from_env().stages);
/// fleet-dispatch wrote its Candidates snapshot: the Queue tab reads the counts afresh.
const CANDIDATES_EVENT: &str = r#"{"kind":"candidates"}"#;
/// A Sentinel watch changed state: the Alerts tab reads afresh.
const ALERTS_EVENT: &str = r#"{"kind":"alerts"}"#;

fn classify(p: &Path) -> Option<String> {
    if p.ends_with(".local/state/fleet/state.json") || p.ends_with(".agent/shepherd/watch.log") {
        return Some(r#"{"kind":"watch"}"#.to_string());
    }
    // The token snapshots are named by day too, so they go before day-log's rule below.
    if p.parent()? == boards::token_usage_dir().as_path() {
        return p
            .extension()
            .is_some_and(|e| e == "json")
            .then(|| COSTS_EVENT.to_string());
    }
    if boards::is_release_snapshot(&boards::releases_dir(), p) {
        return Some(r#"{"kind":"releases"}"#.to_string());
    }
    if hub_core::builds::Paths::from_env().is_ledger_file(p) {
        return Some(BUILDS_EVENT.to_string());
    }
    if p == schedules_state() {
        return Some(PIPELINES_EVENT.to_string());
    }
    if p == *STAGES_FILE {
        return Some(STAGES_EVENT.to_string());
    }
    // fleet-dispatch's ranked snapshot, replaced by a rename: the Queue tab's Candidates counts.
    if p == boards::candidates_file() {
        return Some(CANDIDATES_EVENT.to_string());
    }
    // Only day-log names its files by day; its `.tmp` and `.lock` never match.
    if let Some(day) = p.file_name()?.to_str()?.strip_suffix(".json") {
        if boards::is_day(day) {
            return Some(serde_json::json!({"kind": "log", "date": day}).to_string());
        }
    }
    // A park ledger is named by its tmux session; one starting with `.` is still being written.
    if p.parent()?.ends_with(".agent/parked") && !p.file_name()?.to_str()?.starts_with('.') {
        return Some(r#"{"kind":"sessions"}"#.to_string());
    }
    // A watch's state, written only when it changes (its lastrun and out files are not news).
    if p.extension().is_some_and(|e| e == "state")
        && p.parent() == Some(hub_core::alerts::watch_dirs().1.as_path())
    {
        return Some(ALERTS_EVENT.to_string());
    }
    let parent = p.parent()?.file_name()?.to_str()?;
    let name = p.file_name()?.to_str()?;
    // fleet-shepherd's ledger: the Sessions tab's shepherd due lines, the pass running now and the last
    // one scored. Dotfiles have no extension, so this comes before the `ext` match.
    if parent == "shepherd" && matches!(name, ".due" | ".lease" | ".pass" | "passes.tsv") {
        return Some(r#"{"kind":"shepherd"}"#.to_string());
    }
    // Log's Actions section's own ledgers: the shepherd's log, agent-notify's (which has no
    // extension) and the audit log. The dispatch log, the run ledger and the queue reach it as
    // their own kinds.
    if (parent == "shepherd" && name == "log.md")
        || (parent == "agent-notify" && name == "log")
        || (parent == "audit" && name == "actions.jsonl")
    {
        return Some(r#"{"kind":"actions"}"#.to_string());
    }
    // Daily's outbox: the doc and the ingest record of what intake did with its lines. Before
    // `ext`, which reads any other `.jsonl` as a transcript.
    if name == "outbox.md" || (parent == "notes" && name == "ingest.jsonl") {
        return Some(r#"{"kind":"outbox"}"#.to_string());
    }
    let ext = p.extension()?.to_str()?;
    if (parent == "agentctl" && name == "runs.jsonl")
        || (parent == "dispatch" && matches!(name, "verdicts.jsonl" | "log.md"))
    {
        return Some(r#"{"kind":"fleet"}"#.to_string());
    }
    match ext {
        "json" if parent == "sessions" => Some(r#"{"kind":"sessions"}"#.to_string()),
        "json" if boards::is_proposal_file(&boards::proposals_dir(), p) => {
            Some(r#"{"kind":"proposals"}"#.to_string())
        }
        "md" if p.ancestors().any(|a| a.ends_with(".agent/queue")) => {
            Some(r#"{"kind":"queue"}"#.to_string())
        }
        "md" if p.ancestors().any(|a| a.ends_with(".agent/asks")) => {
            Some(r#"{"kind":"asks"}"#.to_string())
        }
        "md" if parent == "rundowns" => Some(r#"{"kind":"shepherd"}"#.to_string()),
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

/// The write guards every route sits behind: `same_origin`, and a body limit pinned to the
/// audit buffer's (axum's own default is the same 2 MiB; this keeps the two one constant). The
/// one place they are mounted, so the tests that drive this prove what `router` serves.
fn guard_writes<S: Clone + Send + Sync + 'static>(app: Router<S>, base: &str) -> Router<S> {
    app.layer(middleware::from_fn_with_state(
        Arc::<str>::from(base),
        same_origin,
    ))
    .layer(DefaultBodyLimit::max(audit::BODY_MAX))
}

/// Every write a browser makes comes from this server's own pages. A write naming another
/// `Origin` is refused, and so is one that carries the session cookie with no `Origin` at all
/// (browsers send it on every POST, PUT and DELETE). A write with neither, the Tilecast app's
/// push register or agent-mqtt-publish's poke, carries no cookie to ride on and passes to the
/// route's own key check. SameSite=Lax already keeps the cookie off another site's POST; this
/// holds without it, and covers the sign-in form, which has no cookie yet.
async fn same_origin(State(base): State<Arc<str>>, req: Request, next: Next) -> Response {
    let m = req.method();
    if m == axum::http::Method::GET || m == axum::http::Method::HEAD {
        return next.run(req).await;
    }
    let h = req.headers();
    let ok = match h.get(header::ORIGIN).map(|v| v.to_str()) {
        Some(o) => o.is_ok_and(|o| o == &*base),
        None => auth::cookie(cookie_header(h), auth::SESSION_COOKIE).is_none(),
    };
    if ok {
        next.run(req).await
    } else {
        eprintln!(
            "agent-web: {} {} refused: origin {:?} is not {base:?}",
            m,
            req.uri().path(),
            h.get(header::ORIGIN)
        );
        (StatusCode::FORBIDDEN, "cross-origin request refused").into_response()
    }
}

/// After a write through this server (an answer, a park, a board or session action), the first
/// paint's own caches are dropped, so the page's next read waits for the fresh answer and shows
/// the write before its file event lands. A module with its own cache clears it in its handler
/// (`queue`, `epics`). Typing into a pane (`/api/send`) writes no ledger they read.
async fn wrote(State(s): State<Shared>, req: Request, next: Next) -> Response {
    let write = req.method() == axum::http::Method::POST && req.uri().path() != "/api/send";
    let res = next.run(req).await;
    if write && res.status().is_success() {
        s.live.clear();
        s.home.clear();
        s.watch.clear();
        projects::GATHERED.clear();
    }
    res
}

/// Outermost, so every body leaves compressed: Cloudflare compresses off the LAN, and nothing
/// did on it. SSE, images, fonts (woff2 is compressed already) and bodies under 32 bytes go as
/// they are.
fn compression() -> CompressionLayer<impl Predicate> {
    CompressionLayer::new()
        .compress_when(DefaultPredicate::new().and(NotForContentType::const_new("font/")))
}

/// The app for a signed-in browser, the sign-in page otherwise.
async fn index(State(s): State<Shared>, headers: HeaderMap) -> Response {
    match signed_in(&s, &headers) {
        Some(_) => Html(assets::index()).into_response(),
        None => Html(login_page("")).into_response(),
    }
}

fn denied(code: StatusCode, msg: &str) -> Response {
    let err = format!(r#"<div class="err">{msg}</div>"#);
    (code, Html(login_page(&err))).into_response()
}

/// The sign-in page: the Forgejo button always, the key form while `login.key` holds a key.
fn login_page(error: &str) -> String {
    login_html(error, auth::login_key().is_some())
}

fn login_html(error: &str, with_key: bool) -> String {
    LOGIN
        .replace("{{card_css}}", assets::CARD_CSS)
        .replace("{{error}}", error)
        .replace("{{key_form}}", if with_key { KEY_FORM } else { "" })
}

/// One sign-in line in the audit log, written off the request's thread. `method` is `key` for the
/// local key and None for Forgejo.
fn record_signin(actor: &str, action: &str, method: Option<&str>) {
    let mut e = hub_core::audit::Entry::new(actor, action, "agent-web", "web");
    if let Some(m) = method {
        e = e.to(serde_json::json!({ "method": m }));
    }
    tokio::task::spawn_blocking(move || hub_core::audit::record(&e));
}

const KEY_FORM: &str = r#"<form method="post" action="/login/key"><input type="password" name="key" autocomplete="current-password" placeholder="Sign-in key" required><button class="btn" type="submit">Sign in with key</button></form>"#;

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
        record_signin(&login, "signin.refused", None);
        return denied(
            StatusCode::FORBIDDEN,
            "That Forgejo account is not allowed here.",
        );
    }
    let id = match s.sessions.create(&login) {
        Ok(id) => {
            record_signin(&login, "signin.started", None);
            id
        }
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

#[derive(Deserialize)]
struct KeyForm {
    key: String,
}

/// Sign in with the local key, for when Forgejo is down. Same session as the OAuth callback
/// makes, for the first allowed user, so that name is whoever holds the key.
async fn login_key(State(s): State<Shared>, Form(f): Form<KeyForm>) -> Response {
    let (Some(key), Some(user)) = (auth::login_key(), s.oauth.key_user()) else {
        return denied(StatusCode::NOT_FOUND, "Key sign-in is not set up.");
    };
    if !auth::matches(f.key.trim(), &key) {
        record_signin("login-key", "signin.refused", Some("key"));
        return denied(StatusCode::FORBIDDEN, "That key is not right.");
    }
    let id = match s.sessions.create(user) {
        Ok(id) => id,
        Err(e) => {
            eprintln!("agent-web: could not store session: {e:#}");
            return denied(
                StatusCode::INTERNAL_SERVER_ERROR,
                "Could not start a session.",
            );
        }
    };
    record_signin(user, "signin.started", Some("key"));
    (
        StatusCode::SEE_OTHER,
        [
            (header::SET_COOKIE, auth::session_cookie(&id)),
            (header::LOCATION, "/".to_string()),
        ],
    )
        .into_response()
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
    /// The Claude account it runs on (claude-acct's name for its `CLAUDE_CONFIG_DIR`).
    account: String,
    /// The human is attached to its tmux session right now.
    attached: bool,
    /// Parked by `claude-acct park`: no claude runs, unpark resumes it.
    parked: bool,
    /// The plan file's slug, empty when it has none.
    plan: String,
    /// Its plan's `## Phases` progress, as fleet-sessions last read it.
    #[serde(skip_serializing_if = "Option::is_none")]
    phases: Option<boards::Phases>,
    /// The pending ask this session filed.
    ask: Option<String>,
    /// What `POST /api/session/<target>/<action>` accepts for it.
    actions: Vec<&'static str>,
    /// The agent-queue items in this pane (hub-core `with_items`).
    items: Vec<String>,
    /// The open question a `waiting` agent has, from its transcript (`agent_core::transcript::
    /// open_question_at`): a dialog, a permission prompt, or closing text that asks. A message
    /// that hands the turn back without asking is none.
    #[serde(skip_serializing_if = "Option::is_none")]
    question: Option<agent_core::transcript::Question>,
    /// The Needs you kind and label that dialog has (hub-core `NeedKind::of_dialog`), so the
    /// card and the pin lead with the words Home's row does.
    #[serde(skip_serializing_if = "Option::is_none")]
    need: Option<hub_core::home::NeedTag>,
    /// Its transcript's last write, unix seconds: when a `waiting` agent started waiting, and
    /// what the page's new-output dot compares with when it was last opened (sessions.js).
    #[serde(skip_serializing_if = "Option::is_none")]
    wrote: Option<u64>,
    /// The fleet worker it runs on, None when it runs here. A worker's session is read and typed
    /// into through `fleet-host-run` (remote.rs); its transcript and session actions stay there.
    #[serde(skip_serializing_if = "Option::is_none")]
    host: Option<String>,
}

/// A worker's agent-panel row (the worker-panel snapshot) as a sidebar agent. No session action
/// reaches a worker yet, so it offers none.
fn worker_agent(r: &serde_json::Value) -> AgentOut {
    let s = |k: &str| r[k].as_str().unwrap_or_default().to_string();
    let target = s("target");
    AgentOut {
        short: target
            .split_once('/')
            .map_or(target.clone(), |(_, t)| t.to_string()),
        project: s("project"),
        repo: String::new(),
        status: s("status"),
        summary: s("summary"),
        // The UI keys seen-state on this, so a row with no id is keyed by its target, never "".
        session: Some(s("session_id"))
            .filter(|id| !id.is_empty())
            .unwrap_or_else(|| target.clone()),
        tags: String::new(),
        account: s("account"),
        attached: r["attached"].as_bool().unwrap_or(false),
        parked: r["parked"].as_bool().unwrap_or(false),
        plan: s("plan"),
        phases: None,
        ask: r["ask"].as_str().map(str::to_string),
        actions: Vec::new(),
        items: Vec::new(),
        question: None,
        need: None,
        wrote: None,
        host: Some(s("host")).filter(|h| !h.is_empty()),
        target,
    }
}

async fn collect() -> Vec<agent::Agent> {
    tokio::task::spawn_blocking(agent::collect)
        .await
        .unwrap_or_default()
}

/// A failed call to a pane, as the error the page shows.
fn pane_err(host: Option<&str>, e: remote::Failed) -> (StatusCode, String) {
    match (e, host) {
        (remote::Failed::Unreachable(why), _) => bad(StatusCode::BAD_GATEWAY, why),
        (remote::Failed::Exit(c, why), Some(h)) => {
            bad(StatusCode::BAD_GATEWAY, format!("on {h}, exit {c}: {why}"))
        }
        (remote::Failed::Exit(_, why), None) => bad(StatusCode::BAD_GATEWAY, why),
    }
}

/// The live agent behind a target, here or on the fleet worker a `<host>@...` target names. Only
/// targets that are agents right now are accepted, so the API cannot be pointed at an arbitrary
/// tmux pane. A worker's is read from the snapshot the minute record publishes, never over ssh.
async fn find(target: &str) -> ApiResult<remote::Live> {
    let gone = || bad(StatusCode::NOT_FOUND, format!("no live agent at {target}"));
    if let Some((host, _)) = remote::split(target) {
        return remote::find(&boards::worker_panel(), target)
            .await
            .map_err(|e| pane_err(Some(host), e))?
            .ok_or_else(gone);
    }
    collect()
        .await
        .into_iter()
        .find(|a| a.target == target)
        .map(|a| remote::Live {
            host: None,
            pane: a.pane,
        })
        .ok_or_else(gone)
}

/// A live or parked session behind a target, for reading its transcript.
async fn find_any(target: &str) -> ApiResult<agent::Agent> {
    let t = target.to_string();
    tokio::task::spawn_blocking(move || agent::collect_all().into_iter().find(|a| a.target == t))
        .await
        .ok()
        .flatten()
        .ok_or_else(|| bad(StatusCode::NOT_FOUND, format!("no session at {target}")))
}

/// The sidebar every page draws first, from memory: a session event outdates the read of the
/// sessions, and it is refreshed behind the answer. The queue items in each pane are joined on
/// each request from the queue's own kept read, so a queue change shows without a new read.
async fn agents(State(s): State<Shared>) -> Response {
    let (live, items) = tokio::join!(s.live.get((), read_live), s.queue.active());
    // The build clones and serializes every session, so it runs off the async workers.
    let body = match live {
        Ok(l) => cache::off(move || agents_body(&l, &items)).await,
        Err(e) => Err(e),
    }
    .unwrap_or_else(|_| Bytes::from_static(b"[]"));
    ([(header::CONTENT_TYPE, "application/json")], body).into_response()
}

/// The one read of the sessions the sidebar and the Sessions table share (`live.rs`). Blocking.
pub(crate) fn read_live() -> live::Live {
    live::Live::read(worker_agents())
}

/// `/api/agents`' body: the sessions with their queue items, then the workers' rows.
fn agents_body(live: &live::Live, items: &[hub_core::queue::Item]) -> Bytes {
    let sessions = live.joined(items);
    let local = live.rows.iter().zip(sessions).map(|(r, s)| {
        let a = &r.agent;
        AgentOut {
            phases: r.phases.clone(),
            actions: actions::available(&s)
                .into_iter()
                .map(Action::name)
                .collect(),
            items: s.items,
            account: a.account.clone(),
            attached: a.attached,
            parked: a.parked,
            plan: a.plan_slug.clone(),
            ask: a.ask.clone(),
            need: r
                .question
                .as_ref()
                .map(|q| hub_core::home::NeedKind::of_dialog(q.kind).tag()),
            question: r.question.clone(),
            wrote: r.wrote,
            target: a.target.clone(),
            short: a.short_target.clone(),
            project: a.project.clone(),
            repo: a.repo_full.clone(),
            status: a.status.clone(),
            summary: a.summary.clone(),
            session: a.session_id.clone(),
            tags: a.tags.clone(),
            host: None,
        }
    });
    let out: Vec<AgentOut> = local.chain(live.workers.iter().map(worker_agent)).collect();
    serde_json::to_vec(&out).map_or_else(|_| Bytes::from_static(b"[]"), Bytes::from)
}

/// The live rows of the worker-panel snapshot, as `remote::find` trusts them.
fn worker_agents() -> Vec<serde_json::Value> {
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |d| d.as_secs());
    std::fs::read_to_string(boards::worker_panel())
        .map(|t| remote::rows_in(&t, now))
        .unwrap_or_default()
}

#[derive(Deserialize)]
struct PageQuery {
    t: String,
    before: Option<u64>,
    after: Option<u64>,
    limit: Option<usize>,
}

async fn transcript_page(Query(q): Query<PageQuery>) -> ApiResult<Json<transcript::Page>> {
    let path = match find_any(&q.t).await {
        Ok(agent) => agent
            .jsonl
            .ok_or_else(|| bad(StatusCode::NOT_FOUND, "agent has no transcript yet"))?,
        // An ended session is on no pane; the registry still names its transcript.
        Err(gone) => {
            let id = q.t.clone();
            tokio::task::spawn_blocking(move || {
                session_table::transcript(&session_table::registry(), &id)
            })
            .await
            .map_err(|e| bad(StatusCode::INTERNAL_SERVER_ERROR, e.to_string()))?
            .ok_or(gone)?
        }
    };
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
    let live = find(&q.t).await?;
    live.capture(SCREEN_LINES)
        .await
        .map_err(|e| pane_err(live.host.as_deref(), e))
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct ActionBody {
    /// The account a move resumes on.
    #[serde(default)]
    account: String,
}

/// Run one session action. `hub_core::session_actions` checks the target against the live and
/// parked sessions and the account against the accounts file, then runs the command that owns
/// the action (claude-acct, agent-queue, tmux); its stderr comes back as the error.
async fn session_action(
    State(s): State<Shared>,
    UrlPath((target, action)): UrlPath<(String, String)>,
    Json(b): Json<ActionBody>,
) -> ApiResult<Json<serde_json::Value>> {
    let act = Action::parse(&action)
        .ok_or_else(|| bad(StatusCode::BAD_REQUEST, format!("no action {action}")))?;
    let out = tokio::task::spawn_blocking(move || {
        let snap = actions::gather(&actions::System);
        let account = Some(b.account.as_str()).filter(|a| !a.is_empty());
        let steps = actions::plan(act, &target, account, &snap.sessions(), &snap.accounts)?;
        actions::execute(&steps, &actions::System)
    })
    .await
    .map_err(|e| bad(StatusCode::INTERNAL_SERVER_ERROR, e.to_string()))?
    .map_err(|e| bad(StatusCode::BAD_REQUEST, e))?;
    // A cancel or a stop changes a queue item, and the sidebar joins the Queue cache's items.
    s.queue.clear();
    Ok(Json(
        serde_json::json!({ "action": act.name(), "output": out }),
    ))
}

/// What the page's confirm says for each action, and the account names a move can pick.
async fn session_options() -> Json<serde_json::Value> {
    let describe: serde_json::Map<String, serde_json::Value> = Action::ALL
        .into_iter()
        .map(|a| (a.name().to_string(), a.describe().into()))
        .collect();
    let accounts: Vec<String> = agent_core::account::load()
        .into_iter()
        .map(|a| a.name)
        .collect();
    Json(serde_json::json!({ "describe": describe, "accounts": accounts }))
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
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
    let text = cli::plain_text(&b.text, MAX_SEND)
        .ok_or_else(|| bad(StatusCode::BAD_REQUEST, "text is plain lines, under 64 KB"))?;
    let not_taken = || {
        bad(
            StatusCode::CONFLICT,
            "the session did not take the Enter; the text is in its input box",
        )
    };
    let live = find(&b.t).await?;
    // agent-panel send owns typing into a pane: the bracketed paste, waiting for it to be drawn
    // before Enter, and the check that the Enter was taken. tmux sends the key.
    let taken = live
        .send(&text, b.submit.unwrap_or(true), b.key.as_deref())
        .await
        .map_err(|e| pane_err(live.host.as_deref(), e))?;
    if taken {
        Ok(StatusCode::NO_CONTENT)
    } else {
        Err(not_taken())
    }
}

/// Run `prog` with plain arguments (never a shell), `stdin` piped in when given: its stdout on
/// success, its stderr as a 400 the page shows otherwise.
async fn run_cmd(prog: &str, args: &[&str], stdin: Option<&str>) -> ApiResult<String> {
    let err = |e: std::io::Error| bad(StatusCode::INTERNAL_SERVER_ERROR, format!("{prog}: {e}"));
    let mut child = tokio::process::Command::new(prog)
        .args(args)
        .stdin(if stdin.is_some() {
            Stdio::piped()
        } else {
            Stdio::null()
        })
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(err)?;
    if let (Some(text), Some(mut pipe)) = (stdin, child.stdin.take()) {
        pipe.write_all(text.as_bytes()).await.map_err(err)?;
    }
    let out = child.wait_with_output().await.map_err(err)?;
    if out.status.success() {
        Ok(String::from_utf8_lossy(&out.stdout).into_owned())
    } else {
        Err(bad(
            StatusCode::BAD_REQUEST,
            String::from_utf8_lossy(&out.stderr).trim().to_string(),
        ))
    }
}

/// The asks `set` names, from the one reader (`boards::ask_list`). A failed `agent-ask` is a 502
/// the page says, never an empty list it would draw as nothing waiting.
async fn read_asks(set: boards::AskSet) -> ApiResult<Json<Vec<boards::Ask>>> {
    cache::off(move || boards::ask_list(&actions::System, set))
        .await
        .and_then(|r| r)
        .map(Json)
        .map_err(|e| bad(StatusCode::BAD_GATEWAY, e))
}

/// What waits on the human now: a parked ask is left out until its date (agent-ask list --pending).
async fn asks() -> ApiResult<Json<Vec<boards::Ask>>> {
    read_asks(boards::AskSet::Pending).await
}

/// The parked asks, for Home's Parked fold.
async fn parked_asks() -> ApiResult<Json<Vec<boards::Ask>>> {
    read_asks(boards::AskSet::Parked).await
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct ParkBody {
    id: String,
    /// true puts a parked ask back on the boards now.
    #[serde(default)]
    unpark: bool,
}

/// Park an ask until the revisit date agent-ask gives it from its item's priority, or unpark it.
async fn park(Json(b): Json<ParkBody>) -> ApiResult<StatusCode> {
    if !ask_id_ok(&b.id) {
        return Err(bad(StatusCode::BAD_REQUEST, "bad ask id"));
    }
    let verb = if b.unpark { "unpark" } else { "park" };
    run_cmd("agent-ask", &[verb, &b.id], None).await?;
    Ok(StatusCode::NO_CONTENT)
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct AnswerBody {
    id: String,
    answer: String,
}

/// An ask id as agent-ask makes them (mktemp's letters and digits), so nothing else reaches argv.
fn ask_id_ok(id: &str) -> bool {
    !id.is_empty()
        && id
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_')
}

/// One ask's Full log (`boards::ask_trace`): its timeline and the judge's call line as worded
/// rows, and the Langfuse link. Read only when the card's Full log fold is opened.
async fn ask_trace(UrlPath(id): UrlPath<String>) -> ApiResult<Json<boards::AskTrace>> {
    if !ask_id_ok(&id) {
        return Err(bad(StatusCode::BAD_REQUEST, "bad ask id"));
    }
    cache::off(move || boards::ask_trace(&actions::System, &id))
        .await
        .and_then(|r| r)
        .map(Json)
        .map_err(|e| bad(StatusCode::BAD_GATEWAY, e))
}

/// An ask's `n`th preview image, only one under the outbound ledger (hub-core `outbound::preview`).
async fn ask_preview(UrlPath((id, n)): UrlPath<(String, usize)>) -> ApiResult<Response> {
    if !ask_id_ok(&id) {
        return Err(bad(StatusCode::BAD_REQUEST, "bad ask id"));
    }
    let (mime, bytes) = tokio::task::spawn_blocking(move || {
        let ledger = hub_core::boards::outbound_dir();
        let (path, mime) = hub_core::outbound::preview(&boards::asks_dir(), &ledger, &id, n)?;
        std::fs::read(&path)
            .map(|b| (mime, b))
            .map_err(|e| format!("{}: {e}", path.display()))
    })
    .await
    .map_err(|e| bad(StatusCode::INTERNAL_SERVER_ERROR, e.to_string()))?
    .map_err(|e| bad(StatusCode::NOT_FOUND, e))?;
    // A preview is the ledger's copy and never changes, so the browser keeps it across re-renders.
    let keep = "private, max-age=86400, immutable";
    Ok((
        [(header::CONTENT_TYPE, mime), (header::CACHE_CONTROL, keep)],
        bytes,
    )
        .into_response())
}

async fn answer(Json(b): Json<AnswerBody>) -> ApiResult<StatusCode> {
    if !ask_id_ok(&b.id) {
        return Err(bad(StatusCode::BAD_REQUEST, "bad ask id"));
    }
    let answer = cli::plain_text(b.answer.trim(), MAX_ANSWER).ok_or_else(|| {
        bad(
            StatusCode::BAD_REQUEST,
            "an answer is plain text, under 8 KB",
        )
    })?;
    if answer.is_empty() {
        return Err(bad(StatusCode::BAD_REQUEST, "empty answer"));
    }
    let out = tokio::process::Command::new("agent-ask")
        .args(["answer", &b.id, &answer])
        .env_remove("CLAUDE_CODE_SESSION_ID")
        .env_remove("AGENT_QUEUE_ITEM")
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

async fn watch_board(State(s): State<Shared>) -> ApiResult<Response> {
    let read = s
        .watch
        .get_if((), read_watch, |(_, keep)| *keep)
        .await
        .map_err(|e| bad(StatusCode::INTERNAL_SERVER_ERROR, e))?;
    Ok(([(header::CONTENT_TYPE, "application/json")], read.0.clone()).into_response())
}

/// `/api/watch`'s body, and whether it may be kept: a failed `agent-ask list` is named in the
/// state's `unreadable` and served, never kept. Blocking: the fleet state read runs it.
fn read_watch() -> (Bytes, bool) {
    let watch = boards::watch(
        &boards::fleet_state(),
        &boards::shepherd_dir().join("watch.log"),
        &actions::System,
    );
    let asks_read = !watch.state["unreadable"]
        .as_array()
        .is_some_and(|u| u.iter().any(|s| s == "agent-ask"));
    match serde_json::to_vec(&watch) {
        Ok(b) => (Bytes::from(b), asks_read),
        Err(e) => {
            eprintln!("agent-web: watch: {e}");
            (
                Bytes::from_static(br#"{"state":null,"transitions":[]}"#),
                false,
            )
        }
    }
}

#[derive(Deserialize)]
struct LogQuery {
    date: Option<String>,
}

async fn log_day(Query(q): Query<LogQuery>) -> ApiResult<Json<serde_json::Value>> {
    if q.date.as_deref().is_some_and(|d| !boards::is_day(d)) {
        return Err(bad(StatusCode::BAD_REQUEST, "date is YYYY-MM-DD"));
    }
    tokio::task::spawn_blocking(move || {
        boards::record(&boards::daylog_dir(), q.date.as_deref())
            .map(|r| boards::log_view(r, &chrono::Local))
    })
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

/// `/api/home`'s view keys, the ones the page keeps in its URL. Two tables share Home, so Needs
/// you's are n-prefixed (`nq`, `ns`, `nsort`, `ndir`, `npg`) and Proposals keeps the plain ones.
/// `nopen` is the Needs you rows the page has open, `<kind>:<id>` joined by commas.
#[derive(Deserialize, Default)]
#[serde(default)]
struct HomeQuery {
    #[serde(flatten)]
    proposals: proposals::ViewQuery,
    #[serde(rename = "nq")]
    q: String,
    #[serde(rename = "ns")]
    s: String,
    #[serde(rename = "nsort")]
    sort: String,
    #[serde(rename = "ndir")]
    dir: String,
    npg: String,
    nopen: String,
}

/// Home with a view on Needs you and Proposals, and the controls that drew each.
#[derive(Serialize)]
struct HomeShown {
    #[serde(flatten)]
    page: proposals::HomePage,
    table: Summary,
}

/// The view narrows `needs` here and nowhere else: `build` and everything else that reads Home
/// (the TUI's counts, waybar, the phone) keep the whole list, and so do the totals. Home is a
/// glance: no other tab lists every need, so Needs you sends a page of `SHOWN` rows.
fn home_shown(mut home: Home, q: &HomeQuery) -> HomeShown {
    use hub_core::home::SHOWN;
    let view = View::new::<Need>(&q.q, &q.s, &q.sort, &q.dir);
    let (mut rows, mut table) = view.summary(&home.needs);
    // An open row a rerank moved off this page stays under it, so an answer being typed never
    // leaves the page.
    let open: Vec<&str> = q.nopen.split(',').filter(|k| !k.is_empty()).collect();
    let all = if open.is_empty() {
        Vec::new()
    } else {
        rows.clone()
    };
    table::page(&mut rows, &mut table, q.npg.parse().unwrap_or(1), SHOWN);
    let moved: Vec<&Need> = all
        .into_iter()
        .filter(|n| open.contains(&need_key(n).as_str()))
        .filter(|n| !rows.iter().any(|r| std::ptr::eq(*r, *n)))
        .collect();
    if !moved.is_empty() {
        rows.extend(moved);
        table.links = table::links(&rows);
    }
    home.needs = rows.into_iter().cloned().collect();
    HomeShown {
        page: proposals::page(home, &q.proposals),
        table,
    }
}

/// A Needs you row's key, `<kind>:<id>`, as the page keys its open rows (home.js `needKey`).
fn need_key(n: &Need) -> String {
    let kind = serde_json::to_value(n.kind).unwrap_or_default();
    format!("{}:{}", kind.as_str().unwrap_or_default(), n.id)
}

/// The Home tab: hub_core::home over the fleet state (asks read live), the queue and the cached
/// Prometheus answer, the same join the hub TUI's Home draws.
async fn home_board(
    State(s): State<Shared>,
    Query(q): Query<HomeQuery>,
) -> ApiResult<Json<HomeShown>> {
    let home = home_read(&s)
        .await
        .map_err(|e| bad(StatusCode::INTERNAL_SERVER_ERROR, e))?;
    Ok(Json(home_shown(home, &q)))
}

/// How many rows Needs you lists and where they are answered (`Home::waiting`): the one count the
/// sidebar badge, the Queue and Log show. A failed read is a 502 the badge says, never a 0.
async fn home_waiting(State(s): State<Shared>) -> ApiResult<Json<hub_core::home::Waiting>> {
    home_read(&s)
        .await
        .map(|h| Json(h.waiting()))
        .map_err(|e| bad(StatusCode::BAD_GATEWAY, e))
}

/// Home as `/api/home` builds it, before a view narrows it; the widget counts its needs too.
async fn home_read(s: &Shared) -> Result<Home, String> {
    let (home, _, _) = home_inputs(s.clone()).await?;
    Ok(home)
}

/// Home over the cached state, queue and infra reads, with the state and queue it was built from,
/// for a reader that joins more onto them (the briefing), so none of them reads twice.
async fn home_inputs(
    s: Shared,
) -> Result<(Home, serde_json::Value, hub_core::queue::Queue), String> {
    let (infra, queue, parts) = tokio::join!(
        s.infra.infra(),
        s.queue.queue(),
        s.home.get((), HomeParts::read)
    );
    let p = parts?;
    // The build walks every row of the state, board and queue: off the async workers.
    cache::off(move || {
        let mut home = hub_core::home::build(
            Some(&p.state),
            Some(&queue),
            Some(&p.board),
            Some(&infra),
            hub_core::jobs::now(),
        );
        home.set_proposals(&p.open);
        (home, p.state.clone(), queue)
    })
    .await
}

/// Home's reads that no other tab keeps: the fleet state with its live asks, the board and the
/// open proposals. `home_read` joins them with the queue and infra caches on each request, so
/// Home is as fresh as the freshest of them and never caches another cache.
struct HomeParts {
    state: serde_json::Value,
    board: Result<hub_core::tasks::Feed, String>,
    open: Result<Vec<hub_core::proposals::Proposal>, String>,
}

impl HomeParts {
    fn read() -> Self {
        HomeParts {
            state: boards::state(&boards::fleet_state(), &actions::System),
            board: hub_core::tasks::feed(&actions::System),
            open: hub_core::proposals::read(&actions::System),
        }
    }
}

/// Read once at start what the first page draws (the sidebar, Home, its cards and briefing) and
/// every kept read a tab blocks on when cold, so the first visitor after a restart is answered
/// from memory. Which caches it fills, and why each other one may wait for its first open, is the
/// test `every_cache_is_warmed_or_says_why_it_reads_on_open`.
async fn warm(s: Shared) {
    let briefing = s.briefing.get(home_inputs(s.clone()));
    let built = async { builds::current(s.queue.items().await).await };
    let tests = async { suites::keep_newest(s.queue.items().await).await };
    let _ = tokio::join!(
        s.live.get((), read_live),
        s.watch.get_if((), read_watch, |(_, keep)| *keep),
        s.queue.recent(),
        home_read(&s),
        cards::read(&s),
        briefing,
        s.fleet.judge_eval(),
        s.shepherd.stats(),
        s.work.gathered(),
        feed::kept(&s, None),
        epics::chains(),
        outcomes::kept(),
        s.stack.read(),
        built,
        tests,
    );
}

/// A run finishing outdates the builds read; when its refresh lands, the tab's newest run is a
/// new key whose first read downloads its results (5.5 to 5.9 s on 2026-11-19, `agent-web-slow`).
/// Read it here, behind the event, so no visitor waits on it.
async fn keep_tests(s: Shared, mut events: tokio::sync::broadcast::Receiver<String>) {
    use tokio::sync::broadcast::error::RecvError;
    loop {
        match events.recv().await {
            Ok(msg) if cache::is_ready(&msg, "builds") => {
                suites::keep_newest(s.queue.items().await).await
            }
            Ok(_) | Err(RecvError::Lagged(_)) => {}
            Err(RecvError::Closed) => break,
        }
    }
}

/// Home's "Since last night" (briefing.rs): the briefing's areas that are not ok since last night.
async fn briefing_night(State(s): State<Shared>) -> Response {
    (
        [(header::CONTENT_TYPE, "application/json")],
        s.briefing.get(home_inputs(s.clone())).await,
    )
        .into_response()
}

async fn infra_board(State(s): State<Shared>, Query(q): Query<infra::ViewQuery>) -> Response {
    (
        [(header::CONTENT_TYPE, "application/json")],
        s.infra.get(q).await,
    )
        .into_response()
}

#[derive(Deserialize)]
struct MachineQuery {
    host: String,
}

/// One machine's page, read only when `#infra/machines/<host>` opens. An unknown name is a 404.
async fn infra_machine(
    State(s): State<Shared>,
    Query(q): Query<MachineQuery>,
) -> ApiResult<Response> {
    let json = s.machines.machine(s.clone(), q.host).await?;
    Ok(([(header::CONTENT_TYPE, "application/json")], json).into_response())
}

#[derive(Deserialize)]
struct AppQuery {
    app: String,
}

/// One app's status page, read only when `#releases/apps/<app>` opens. An unknown name is a 404.
async fn releases_app(State(s): State<Shared>, Query(q): Query<AppQuery>) -> ApiResult<Response> {
    let json = s.apps.app(q.app).await?;
    Ok(([(header::CONTENT_TYPE, "application/json")], json).into_response())
}

#[derive(Deserialize)]
struct PoolQuery {
    name: String,
}

/// One pool's page, read only when `#infra/pools/<pool>` opens. An unknown name is a 404.
async fn infra_pool(State(s): State<Shared>, Query(q): Query<PoolQuery>) -> ApiResult<Response> {
    let json = s.pools.pool(s.clone(), q.name).await?;
    Ok(([(header::CONTENT_TYPE, "application/json")], json).into_response())
}

/// The pipeline line (hub_core::flow::Rail) over the live queue and fleet-bench's snapshot.
async fn flow_strip(State(s): State<Shared>) -> ApiResult<Json<serde_json::Value>> {
    let queue = s.queue.queue().await;
    tokio::task::spawn_blocking(move || {
        let read = hub_core::pipeline::read();
        let line =
            hub_core::flow::Rail::build(Some(&queue), Some(&read), chrono::Utc::now().timestamp());
        serde_json::json!({ "line": line, "grafana": hub_core::infra::grafana() })
    })
    .await
    .map(Json)
    .map_err(|e| bad(StatusCode::INTERNAL_SERVER_ERROR, e.to_string()))
}

async fn fleet_board(State(s): State<Shared>, Query(q): Query<fleet::FleetQuery>) -> Response {
    (
        [(header::CONTENT_TYPE, "application/json")],
        fleet::get(&s.fleet, q).await,
    )
        .into_response()
}

async fn fleet_runner(
    State(s): State<Shared>,
    Query(q): Query<fleet::RunnerQuery>,
) -> ApiResult<Response> {
    let json = fleet::runner(s, q)
        .await
        .map_err(|e| bad(StatusCode::NOT_FOUND, e))?;
    Ok(([(header::CONTENT_TYPE, "application/json")], json).into_response())
}

async fn jobs_list(State(s): State<Shared>, Query(q): Query<jobs::JobsQuery>) -> Response {
    (
        [(header::CONTENT_TYPE, "application/json")],
        s.jobs.get(q).await,
    )
        .into_response()
}

async fn releases_list(State(s): State<Shared>, Query(q): Query<releases::Query>) -> Response {
    (
        [(header::CONTENT_TYPE, "application/json")],
        releases::get(q, s.queue.items().await).await,
    )
        .into_response()
}

/// One release's page (`hub_core::release_page`), read when `#releases/apps/<app>/<version>` opens.
async fn releases_release(
    State(s): State<Shared>,
    Query(q): Query<releases::ReleaseQuery>,
) -> Response {
    match releases::release(q, s.queue.items().await).await {
        Ok(body) => ([(header::CONTENT_TYPE, "application/json")], body).into_response(),
        Err(e) => e.into_response(),
    }
}

/// One version's page (`hub_core::version_page`), read when `#releases/versions/<project>/<version>` opens.
async fn releases_version(
    State(s): State<Shared>,
    Query(q): Query<releases::VersionQuery>,
) -> Response {
    match releases::version(q, s.queue.items().await).await {
        Ok(body) => ([(header::CONTENT_TYPE, "application/json")], body).into_response(),
        Err(e) => e.into_response(),
    }
}

/// Releases > Flow's lanes (`hub_core::lanes`).
async fn releases_lanes(
    State(s): State<Shared>,
    Query(q): Query<releases::LanesQuery>,
) -> Response {
    (
        [(header::CONTENT_TYPE, "application/json")],
        releases::lanes(q, s.queue.items().await).await,
    )
        .into_response()
}

async fn builds_list(State(s): State<Shared>, Query(q): Query<builds::Query>) -> Response {
    (
        [(header::CONTENT_TYPE, "application/json")],
        builds::get(q, s.queue.items().await).await,
    )
        .into_response()
}

/// The run is named by its ledger key, never by a URL or a path.
async fn build_log(Query(key): Query<hub_core::builds::RunKey>) -> ApiResult<Response> {
    let text = builds::log(key)
        .await
        .map_err(|e| bad(StatusCode::BAD_GATEWAY, e))?;
    Ok(([(header::CONTENT_TYPE, "text/plain; charset=utf-8")], text).into_response())
}

/// The opened run's header, jobs and steps, priced with the Infra answer's rates.
async fn build_detail(
    State(s): State<Shared>,
    Query(key): Query<hub_core::builds::RunKey>,
) -> ApiResult<Response> {
    let body = builds::detail(key, s.infra.rates().await, s.queue.items().await)
        .await
        .map_err(|e| bad(StatusCode::NOT_FOUND, e))?;
    Ok(([(header::CONTENT_TYPE, "application/json")], body).into_response())
}

/// A job of an opened run, named by the run's key and the job's id (it must be one of that run's).
#[derive(serde::Deserialize)]
struct BuildJobLogQuery {
    forge: String,
    repo: String,
    run: u64,
    attempt: u32,
    job: u64,
}

async fn build_job_log(
    State(s): State<Shared>,
    Query(q): Query<BuildJobLogQuery>,
) -> ApiResult<Response> {
    let key = hub_core::builds::RunKey {
        forge: q.forge,
        repo: q.repo,
        id: q.run,
        attempt: q.attempt,
    };
    let text = builds::job_log(key, q.job, s.queue.items().await)
        .await
        .map_err(|e| match e {
            hub_core::builds::JobLogError::Refused(m) => bad(StatusCode::NOT_FOUND, m),
            hub_core::builds::JobLogError::Upstream(m) => bad(StatusCode::BAD_GATEWAY, m),
        })?;
    Ok(([(header::CONTENT_TYPE, "text/plain; charset=utf-8")], text).into_response())
}

async fn tests_list(State(s): State<Shared>, Query(q): Query<suites::Query>) -> Response {
    (
        [(header::CONTENT_TYPE, "application/json")],
        suites::get(q, s.queue.items().await).await,
    )
        .into_response()
}

async fn pipelines_list(State(s): State<Shared>, Query(q): Query<pipelines::Query>) -> Response {
    (
        [(header::CONTENT_TYPE, "application/json")],
        pipelines::get(q, s.queue.items().await).await,
    )
        .into_response()
}

async fn pipelines_detail(
    State(s): State<Shared>,
    Query(q): Query<pipelines::DetailQuery>,
) -> ApiResult<Response> {
    let body = pipelines::detail(q, s.queue.items().await)
        .await
        .map_err(|e| bad(StatusCode::NOT_FOUND, e))?;
    Ok(([(header::CONTENT_TYPE, "application/json")], body).into_response())
}

/// A suite is named by its run and its place in that run's results, never by a path.
async fn tests_cases(
    State(s): State<Shared>,
    Query(q): Query<suites::CasesQuery>,
) -> ApiResult<Response> {
    let body = suites::cases(q, s.queue.items().await)
        .await
        .map_err(|(code, e)| bad(code, e))?;
    Ok(([(header::CONTENT_TYPE, "application/json")], body).into_response())
}

async fn alerts_board(State(s): State<Shared>, Query(q): Query<alerts::Query>) -> Response {
    (
        [(header::CONTENT_TYPE, "application/json")],
        s.alerts.get(&s.infra, q).await,
    )
        .into_response()
}

async fn schedules_list(State(s): State<Shared>, Query(q): Query<schedules::Query>) -> Response {
    (
        [(header::CONTENT_TYPE, "application/json")],
        s.schedules.get(&s.alerts, q).await,
    )
        .into_response()
}

async fn stack_list(State(s): State<Shared>, Query(q): Query<stack::Query>) -> Response {
    (
        [(header::CONTENT_TYPE, "application/json")],
        s.stack.get(q).await,
    )
        .into_response()
}

#[derive(Deserialize)]
struct FlowQuery {
    name: String,
}

/// A Flows row opened: its doc section as markdown, and whether it has a picture.
async fn stack_flow(State(s): State<Shared>, Query(q): Query<FlowQuery>) -> ApiResult<Response> {
    let body = s
        .stack
        .flow(q.name)
        .await
        .map_err(|e| bad(StatusCode::NOT_FOUND, e))?;
    Ok(([(header::CONTENT_TYPE, "application/json")], body).into_response())
}

/// A flow's picture, served here because the page's CSP is `img-src 'self'`. The page draws it as
/// an `<img>`; opened on its own, the sandbox CSP keeps any script in it from running here.
async fn stack_flow_svg(
    State(s): State<Shared>,
    Query(q): Query<FlowQuery>,
) -> ApiResult<Response> {
    let bytes = s
        .stack
        .picture(q.name)
        .await
        .map_err(|e| bad(StatusCode::NOT_FOUND, e))?;
    Ok((
        [
            (header::CONTENT_TYPE, "image/svg+xml"),
            (header::CONTENT_SECURITY_POLICY, "sandbox"),
            (header::X_CONTENT_TYPE_OPTIONS, "nosniff"),
            (header::CACHE_CONTROL, "no-cache"),
        ],
        bytes,
    )
        .into_response())
}

async fn sessions_table(
    State(s): State<Shared>,
    Query(q): Query<sessions::TableQuery>,
) -> Response {
    (
        [(header::CONTENT_TYPE, "application/json")],
        s.session_table.table(&s, q).await,
    )
        .into_response()
}

async fn sessions_page(
    State(s): State<Shared>,
    Query(q): Query<TargetQuery>,
) -> ApiResult<Json<serde_json::Value>> {
    let page = s
        .session_table
        .page(&s, q.t)
        .await
        .map_err(|e| bad(StatusCode::INTERNAL_SERVER_ERROR, e))?;
    let page = (*page)
        .as_ref()
        .ok_or_else(|| bad(StatusCode::NOT_FOUND, "no such session"))?;
    Ok(Json(serde_json::json!(page)))
}

async fn sessions_capacity(State(s): State<Shared>) -> ApiResult<Json<serde_json::Value>> {
    let got = s
        .session_table
        .capacity()
        .await
        .map_err(|e| bad(StatusCode::INTERNAL_SERVER_ERROR, e))?;
    Ok(Json(serde_json::json!(&*got)))
}

async fn sessions_start(
    State(s): State<Shared>,
    UrlPath(name): UrlPath<String>,
) -> ApiResult<Json<serde_json::Value>> {
    let said = s
        .session_table
        .start(name)
        .await
        .map_err(|e| bad(StatusCode::BAD_REQUEST, e))?;
    Ok(Json(serde_json::json!({ "said": said })))
}

#[derive(Deserialize)]
struct JobLogQuery {
    #[serde(rename = "ref")]
    log: String,
}

async fn job_log(Query(q): Query<JobLogQuery>) -> ApiResult<Response> {
    let text = jobs::log(q.log)
        .await
        .map_err(|e| bad(StatusCode::BAD_REQUEST, e))?
        .map_err(|e| bad(StatusCode::BAD_GATEWAY, e))?;
    Ok(([(header::CONTENT_TYPE, "text/plain; charset=utf-8")], text).into_response())
}

#[derive(Deserialize)]
struct StaticQuery {
    v: Option<String>,
}

async fn static_file(UrlPath(name): UrlPath<String>, Query(q): Query<StaticQuery>) -> Response {
    assets::file(&name, q.v.as_deref())
}

async fn events_stream(
    State(s): State<Shared>,
) -> Sse<impl Stream<Item = Result<SseEvent, Infallible>>> {
    // Each page first learns whether live updates are on, then gets the changes.
    let off = live_msg(&s.watch_off.lock().unwrap_or_else(|e| e.into_inner()));
    let changes = BroadcastStream::new(s.events.subscribe()).map(|m| {
        // A lagged receiver skipped messages; tell the page to refetch everything.
        m.unwrap_or_else(|_| r#"{"kind":"resync"}"#.to_string())
    });
    // A stop ends the stream, so the drain is not held open by a page that is only listening.
    let stream = until_stopped(tokio_stream::once(off).chain(changes), s.stopping.clone())
        .map(|data| Ok(SseEvent::default().data(data)));
    Sse::new(stream).keep_alive(KeepAlive::default())
}

#[cfg(test)]
mod tests {
    use super::*;
    use tokio::io::AsyncReadExt;
    use tokio::sync::{oneshot, Notify};

    #[test]
    fn a_worker_row_is_a_sidebar_agent_on_its_host_with_no_actions() {
        let r = serde_json::json!({"target": "razer-laptop@lab/dotfiles-agent-1:1",
            "host": "razer-laptop", "pane": "lab/%4", "status": "busy", "summary": "fix it",
            "session_id": "abc", "project": "dotfiles", "account": "bnb"});
        let a = worker_agent(&r);
        assert_eq!(a.host.as_deref(), Some("razer-laptop"));
        assert_eq!(a.target, "razer-laptop@lab/dotfiles-agent-1:1");
        assert_eq!(a.short, "dotfiles-agent-1:1");
        assert_eq!((a.status.as_str(), a.session.as_str()), ("busy", "abc"));
        assert!(a.actions.is_empty(), "no session action reaches a worker");
        let j = serde_json::to_value(&a).unwrap();
        assert_eq!(j["host"], "razer-laptop");
        let no_id = serde_json::json!({"target": "razer-laptop@lab/s:2", "host": "razer-laptop"});
        assert_eq!(
            worker_agent(&no_id).session,
            "razer-laptop@lab/s:2",
            "a row with no session id is keyed by its target, never an empty id"
        );
    }

    /// The caches `warm` fills, directly or through a read it makes (Home's cards fill projects,
    /// costs, schedules, alerts and the session table).
    const WARMED: [&str; 22] = [
        "actions",
        "agents",
        "alerts",
        "briefing",
        "builds",
        "costs",
        "epics",
        "home",
        "infra",
        "judge-eval",
        "projects",
        "queue",
        "queue-stats",
        "ranked",
        "releases-card",
        "schedules",
        "session-table",
        "shepherd-stats",
        "stack",
        "suites-newest",
        "watch",
        "worklog",
    ];
    /// The caches read on their first open, and why that is fine. Times are each tab's first open
    /// after a start, `agent-web-shot --time --every-tab`, load avg 117, 2026-11-18. Over about 1 s
    /// cold belongs in `warm`. Revisit when a tab's first open passes 1.5 s.
    const ON_OPEN: [(&str, &str); 9] = [
        ("departments", "Projects Coverage, 1492 ms cold"),
        ("stages", "Projects Ladder, 678 ms cold"),
        (
            "suites",
            "Infra Tests on a run other than the newest, 767 ms cold; the newest is `suites-newest`, read by `keep_tests` when a run lands",
        ),
        ("jobs", "Infra Jobs, 619 ms cold"),
        ("pipelines", "Infra Pipelines, 546 ms cold"),
        (
            "queue-candidates",
            "Queue's Candidates fold, read when it opens",
        ),
        ("session-capacity", "Sessions' header, read with the table"),
        ("session-page", "one per session, keyed by the one opened"),
        (
            "machine-page",
            "one per name: nothing to warm before a name is opened",
        ),
    ];
    /// Like `machine-page`: a page per name.
    const PER_NAME: [&str; 2] = ["pool-page", "app-page"];

    /// The name each `ReadCache::new`, `EventCache::new` and `infra::Pages::new` in `text` is
    /// given: its last string literal before the `")` that closes it.
    fn cache_names(text: &str) -> Vec<String> {
        let mut out = Vec::new();
        for pat in ["Cache::new(", "Pages::new("] {
            for (at, _) in text.match_indices(pat) {
                let rest = &text[at..];
                let Some(end) = rest.find("\")") else {
                    continue;
                };
                if rest[..end].contains(';') {
                    continue; // no literal name before the statement ended
                }
                let Some(open) = rest[..end].rfind('"') else {
                    continue;
                };
                out.push(rest[open + 1..end].to_string());
            }
        }
        out
    }

    /// Stack's tab (#2455) shipped with a cache `warm` did not fill: 3.6 to 6.7 s on the first open
    /// after each restart, and agent-web restarts on every landing. A new cache now lands in one of
    /// the lists above, so whoever adds it decides.
    #[test]
    fn every_cache_is_warmed_or_says_why_it_reads_on_open() {
        let dir = std::path::Path::new(concat!(env!("CARGO_MANIFEST_DIR"), "/src"));
        let mut found = std::collections::BTreeSet::new();
        for e in std::fs::read_dir(dir).unwrap() {
            let p = e.unwrap().path();
            // cache.rs's own tests name throwaway caches.
            if p.extension().is_some_and(|x| x == "rs") && !p.ends_with("cache.rs") {
                found.extend(cache_names(&std::fs::read_to_string(&p).unwrap()));
            }
        }
        assert!(found.len() > 25, "the scan found the caches: {found:?}");
        let listed: std::collections::BTreeSet<String> = WARMED
            .iter()
            .chain(ON_OPEN.iter().map(|(n, _)| n))
            .chain(PER_NAME.iter())
            .map(|n| n.to_string())
            .collect();
        let unlisted: Vec<_> = found.difference(&listed).collect();
        assert!(
            unlisted.is_empty(),
            "fill these in warm() and add them to WARMED, or say in ON_OPEN why the first open may wait: {unlisted:?}"
        );
        let gone: Vec<_> = listed.difference(&found).collect();
        assert!(
            gone.is_empty(),
            "listed but no cache has that name: {gone:?}"
        );
        // Negative control: a new tab's cache, in each form, is found. `NEW` is spliced in at run
        // time so this file's own text holds no cache for the scan above to find.
        let new_tab = r#"static READ: ReadCache<Tab, 60> = ReadCache::NEW("new-tab");
            Cache(EventCache::NEW(events.subscribe(), &KINDS, "new-feed"))
            machines: infra::Pages::NEW("new-page"),
            fleet: fleet::Cache::NEW(events.subscribe()),"#
            .replace("NEW", "new");
        assert_eq!(cache_names(&new_tab), ["new-tab", "new-feed", "new-page"]);
    }

    /// The response headers `path` gets from `app` when the browser takes br.
    async fn headers_br(app: Router, path: &str) -> String {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        tokio::spawn(async move { axum::serve(listener, app).await.unwrap() });
        let mut c = tokio::net::TcpStream::connect(addr).await.unwrap();
        let req = format!(
            "GET {path} HTTP/1.1\r\nHost: t\r\nAccept-Encoding: br, gzip\r\nConnection: close\r\n\r\n"
        );
        tokio::io::AsyncWriteExt::write_all(&mut c, req.as_bytes())
            .await
            .unwrap();
        let mut out = Vec::new();
        c.read_to_end(&mut out).await.unwrap();
        let text = String::from_utf8_lossy(&out).to_lowercase();
        text.split("\r\n\r\n")
            .next()
            .unwrap_or_default()
            .to_string()
    }

    #[tokio::test]
    async fn json_and_scripts_leave_compressed_and_fonts_and_the_live_stream_do_not() {
        let body = "x".repeat(4096);
        let typed = |ctype: &'static str| {
            let body = body.clone();
            get(move || async move { ([(header::CONTENT_TYPE, ctype)], body) })
        };
        let app = Router::new()
            .route("/json", typed("application/json"))
            .route("/js", typed("text/javascript"))
            .route("/font", typed("font/woff2"))
            .route(
                "/live",
                get(|| async {
                    let one = tokio_stream::once(Ok::<_, std::convert::Infallible>(
                        SseEvent::default().data("x".repeat(4096)),
                    ));
                    Sse::new(one)
                }),
            )
            .layer(compression());
        for path in ["/json", "/js"] {
            let h = headers_br(app.clone(), path).await;
            assert!(h.contains("content-encoding: br"), "{path}: {h}");
        }
        for path in ["/font", "/live"] {
            let h = headers_br(app.clone(), path).await;
            assert!(!h.contains("content-encoding"), "{path}: {h}");
        }
    }
    // The clock is paused only while the request is in its handler and no socket has bytes in
    // flight, so the timeout fires only once every task is idle: the server still running then is
    // a server waiting on the request, not one that was slow to be polled. It resumes before the
    // answer is written, so a socket wait never jumps the drain timer.
    #[tokio::test]
    async fn a_stop_answers_the_request_in_flight_and_ends_the_live_stream() {
        let entered = Arc::new(Notify::new());
        let release = Arc::new(Notify::new());
        let (e, r) = (entered.clone(), release.clone());
        let app = Router::new().route(
            "/slow",
            get(move || async move {
                e.notify_one();
                r.notified().await;
                "answered"
            }),
        );
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        let (fire, signal) = oneshot::channel::<()>();
        let (stop, stopping) = watch::channel(false);
        let mut live = until_stopped(tokio_stream::pending::<u32>(), stopping.clone());
        let mut server = tokio::spawn(serve_until(
            listener,
            app,
            async move {
                let _ = signal.await;
            },
            stop,
            Duration::from_secs(60),
        ));
        let client = tokio::spawn(async move {
            let mut c = tokio::net::TcpStream::connect(addr).await.unwrap();
            c.write_all(b"GET /slow HTTP/1.1\r\nhost: x\r\nconnection: close\r\n\r\n")
                .await
                .unwrap();
            let mut out = String::new();
            c.read_to_string(&mut out).await.unwrap();
            out
        });
        entered.notified().await;
        fire.send(()).unwrap();
        stopping.clone().wait_for(|s| *s).await.unwrap();
        assert_eq!(live.next().await, None, "the live stream ends on a stop");
        tokio::time::pause();
        let early = tokio::time::timeout(Duration::from_secs(1), &mut server).await;
        tokio::time::resume();
        assert!(
            early.is_err(),
            "the server stopped before the request in flight was answered"
        );
        release.notify_one();
        let out = client.await.unwrap();
        assert!(out.starts_with("HTTP/1.1 200"), "{out}");
        assert!(out.ends_with("answered"), "{out}");
        server.await.unwrap().unwrap();
    }

    #[test]
    fn a_view_on_home_narrows_the_needs_it_sends_and_nothing_else() {
        let state = serde_json::json!({
            "sessions": [
                {"bucket": "NEEDS", "target": "hub/a:1", "project": "a", "idle_min": 9},
                {"bucket": "NEEDS", "target": "hub/b:1", "project": "b", "idle_min": 1},
            ],
        });
        let home = hub_core::home::build(Some(&state), None, None, None, hub_core::jobs::now());
        assert_eq!(home.needs.len(), 2);
        let q = HomeQuery {
            q: "project:b".into(),
            ..Default::default()
        };
        let out = serde_json::to_value(home_shown(home, &q)).unwrap();
        assert_eq!(out["needs"].as_array().unwrap().len(), 1);
        assert_eq!(out["needs"][0]["project"], "b");
        assert_eq!(
            out["needs"][0]["rank"], 2,
            "a row keeps its place in the list"
        );
        assert_eq!(out["table"]["shown"], 1);
        assert_eq!(out["table"]["total"], 2, "the count is of the whole list");
        assert_eq!(out["table"]["q"], "project:b");
        assert!(
            out["proposals_table"].is_object(),
            "Proposals' view rides beside it"
        );
    }

    /// Needs you and Proposals share Home, so each reads its own keys out of one query.
    #[test]
    fn home_query_reads_needs_you_and_proposals_apart() {
        let uri: axum::http::Uri =
            "/api/home?nq=project:b&ns=ask&nsort=age&ndir=asc&q=queue&s=none&sort=id&dir=desc"
                .parse()
                .unwrap();
        let Query(q) = Query::<HomeQuery>::try_from_uri(&uri).unwrap();
        assert_eq!(
            (q.q.as_str(), q.s.as_str(), q.sort.as_str(), q.dir.as_str()),
            ("project:b", "ask", "age", "asc")
        );
        let home = Home {
            proposals: ["aa", "bb"]
                .map(|id| hub_core::proposals::Proposal {
                    id: id.into(),
                    verb: if id == "aa" { "queue" } else { "none" }.into(),
                    ..Default::default()
                })
                .to_vec(),
            ..Home::default()
        };
        let out = serde_json::to_value(home_shown(home, &q)).unwrap();
        assert_eq!(out["proposals_table"]["q"], "queue");
        assert_eq!(out["proposals_table"]["total"], 2);
        assert_eq!(out["table"]["q"], "project:b");
        assert!(
            out.get("running").is_none() && out.get("running_table").is_none(),
            "Home lists no running items: the Queue tab does"
        );

        let Query(plain) =
            Query::<HomeQuery>::try_from_uri(&"/api/home?q=x".parse().unwrap()).unwrap();
        assert_eq!(plain.q, "", "a plain q is Proposals', never Needs you's");
    }

    /// Home is a glance: Needs you pages at `SHOWN`, and an open row stays on whatever page is
    /// drawn.
    #[test]
    fn home_pages_needs_you_and_keeps_an_open_row() {
        use hub_core::home::SHOWN;
        let n = SHOWN + 3;
        let sessions: Vec<_> = (0..n)
            .map(|i| serde_json::json!({"bucket": "NEEDS", "target": format!("hub/s{i}:1"), "project": "p", "idle_min": 100 - i}))
            .collect();
        let state = serde_json::json!({ "sessions": sessions });
        let home = hub_core::home::build(Some(&state), None, None, None, hub_core::jobs::now());
        assert_eq!(home.needs.len(), n);
        let ids = |v: &serde_json::Value| -> Vec<String> {
            v.as_array()
                .unwrap()
                .iter()
                .map(|r| r["id"].as_str().unwrap().to_string())
                .collect()
        };
        let all = ids(&serde_json::to_value(&home.needs).unwrap());
        let last = need_key(home.needs.last().unwrap());
        assert_eq!(
            last,
            format!("session:{}", all[n - 1]),
            "the page's needKey"
        );

        let out = serde_json::to_value(home_shown(home.clone(), &HomeQuery::default())).unwrap();
        assert_eq!(ids(&out["needs"]), all[..SHOWN]);
        assert_eq!(out["table"]["shown"], n, "shown counts every page");
        assert_eq!(out["table"]["pager"]["pages"], 2);

        let q = HomeQuery {
            nopen: format!("ask:gone,{last}"),
            ..Default::default()
        };
        let out = serde_json::to_value(home_shown(home.clone(), &q)).unwrap();
        let mut want = all[..SHOWN].to_vec();
        want.push(all[n - 1].clone());
        assert_eq!(
            ids(&out["needs"]),
            want,
            "the open row past the page stays under it"
        );
        let q = HomeQuery {
            npg: "2".into(),
            nopen: last,
            ..Default::default()
        };
        let out = serde_json::to_value(home_shown(home, &q)).unwrap();
        assert_eq!(
            ids(&out["needs"]),
            all[SHOWN..],
            "on its own page it is not listed twice"
        );
    }

    #[test]
    fn only_a_dir_directly_under_projects_is_a_new_project() {
        use notify::event::{CreateKind, ModifyKind};
        let projects = Path::new("/h/.claude/projects");
        let create = EventKind::Create(CreateKind::Any);
        assert!(is_new_project(&create, &projects.join("-new"), projects));
        assert!(!is_new_project(
            &create,
            &projects.join("-new/s.jsonl"),
            projects
        ));
        let modify = EventKind::Modify(ModifyKind::Any);
        assert!(!is_new_project(&modify, &projects.join("-new"), projects));
    }

    /// A path that cannot be watched comes back as failed and does not stop the others; the
    /// pages hear about the failed set once, and again only when it changes.
    #[tokio::test]
    async fn a_failed_watch_is_reported_not_fatal() {
        let dir = std::env::temp_dir().join(format!("agent-web-watch-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let gone = dir.join("missing");
        let mut w = notify::recommended_watcher(|_: notify::Result<notify::Event>| {}).unwrap();
        let flat = RecursiveMode::NonRecursive;
        let failed = add_watches(&mut w, vec![(gone.clone(), flat), (dir.clone(), flat)]);
        assert_eq!(
            failed.iter().map(|(p, _)| p.clone()).collect::<Vec<_>>(),
            vec![gone.clone()]
        );

        let (tx, mut rx) = broadcast::channel(8);
        let off = WatchOff::default();
        publish_off(&off, &tx, &failed);
        publish_off(&off, &tx, &failed);
        let msg: serde_json::Value = serde_json::from_str(&rx.try_recv().unwrap()).unwrap();
        assert_eq!(msg["kind"], "live");
        assert_eq!(msg["off"][0], gone.display().to_string());
        assert!(rx.try_recv().is_err(), "an unchanged set is not sent again");
        publish_off(&off, &tx, &[]);
        let msg: serde_json::Value = serde_json::from_str(&rx.try_recv().unwrap()).unwrap();
        assert_eq!(msg["off"], serde_json::json!([]));
        std::fs::remove_dir_all(&dir).unwrap();
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
            classify(&boards::proposals_dir().join("0a1b.json")).as_deref(),
            Some(r#"{"kind":"proposals"}"#)
        );
        assert_eq!(classify(&boards::proposals_dir().join(".0a1b.tmp")), None);
        assert_eq!(
            classify(Path::new("/h/.agent/asks/bnb/Y3g.md")).as_deref(),
            Some(r#"{"kind":"asks"}"#)
        );
        assert_eq!(
            classify(Path::new("/h/.agent/queue/done/2026-11-03/20261103-x.md")).as_deref(),
            Some(r#"{"kind":"queue"}"#)
        );
        assert_eq!(classify(Path::new("/h/.agent/queue/.lock")), None);
        assert_eq!(classify(Path::new("/h/.agent/queue/.gate")), None);
        assert_eq!(
            classify(Path::new("/h/.agent/queue/queued/.add.AbC123")),
            None
        );
        assert_eq!(
            classify(Path::new("/h/.local/state/fleet/state.json")).as_deref(),
            Some(r#"{"kind":"watch"}"#)
        );
        assert_eq!(
            classify(Path::new("/h/.agent/shepherd/watch.log")).as_deref(),
            Some(r#"{"kind":"watch"}"#)
        );
        // A new stages.json is Projects' Ladder; its .tmp and the filer's log beside it are not.
        let stages = hub_core::stages::Paths::from_env().stages;
        assert_eq!(classify(&stages).as_deref(), Some(STAGES_EVENT));
        assert_ne!(
            classify(&stages.with_extension("json.tmp")).as_deref(),
            Some(STAGES_EVENT)
        );
        assert_ne!(
            classify(&stages.with_file_name("stage-file.last")).as_deref(),
            Some(STAGES_EVENT)
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
        // A token snapshot is named by day, but it is Costs', never a Log or Runners refresh.
        assert_eq!(
            classify(&boards::token_usage_dir().join("2026-11-05.json")).as_deref(),
            Some(COSTS_EVENT)
        );
        assert_eq!(
            classify(&boards::token_usage_dir().join("2026-11-05.json.tmp")),
            None
        );
        // release-state's snapshot arrives by a rename; its temp files and any other state.json
        // are not it.
        assert_eq!(
            classify(&boards::releases_dir().join("state.json")).as_deref(),
            Some(r#"{"kind":"releases"}"#)
        );
        assert_eq!(classify(&boards::releases_dir().join(".state.123")), None);
        // schedules-sync's ledger and sync record are the Builds section's; its other files are not.
        let ci = hub_core::builds::Paths::from_env();
        assert_eq!(classify(&ci.ledger).as_deref(), Some(BUILDS_EVENT));
        assert_eq!(classify(&ci.sync).as_deref(), Some(BUILDS_EVENT));
        assert_eq!(classify(&ci.sync.with_file_name("other.json")), None);
        // Its state.json is the Pipelines section's; a temp file beside it is not.
        let state = schedules_state();
        assert_eq!(classify(&state).as_deref(), Some(PIPELINES_EVENT));
        // The Candidates snapshot is its own kind; fleet-dispatch's temp file beside it is none.
        let cands = boards::candidates_file();
        assert_eq!(classify(&cands).as_deref(), Some(CANDIDATES_EVENT));
        assert_eq!(
            classify(&cands.with_file_name("candidates.jsonl.123")),
            None
        );
        assert_eq!(classify(&state.with_file_name(".state.json.tmp")), None);
        assert_eq!(
            classify(Path::new("/h/.local/state/fleet/.state.AbC123")),
            None
        );
        assert_eq!(classify(Path::new("/h/.agent/shepherd/watch.state")), None);
        // A watch's state change pushes Alerts; its per-run files do not.
        let sentinel = hub_core::alerts::watch_dirs().1;
        assert_eq!(
            classify(&sentinel.join("nightly.state")).as_deref(),
            Some(ALERTS_EVENT)
        );
        assert_eq!(classify(&sentinel.join("nightly.lastrun")), None);
        assert_eq!(classify(&sentinel.join("nightly.out")), None);
        for p in [
            "/h/.local/state/agentctl/runs.jsonl",
            "/h/.agent/dispatch/verdicts.jsonl",
            "/h/.agent/dispatch/log.md",
        ] {
            assert_eq!(
                classify(Path::new(p)).as_deref(),
                Some(r#"{"kind":"fleet"}"#)
            );
        }
        for p in [
            "/h/.agent/shepherd/rundowns/2026-11-03T1201Z.md",
            "/h/.agent/shepherd/.due",
            "/h/.agent/shepherd/.lease",
            "/h/.agent/shepherd/.pass",
            "/h/.agent/shepherd/passes.tsv",
        ] {
            assert_eq!(
                classify(Path::new(p)).as_deref(),
                Some(r#"{"kind":"shepherd"}"#)
            );
        }
        assert_eq!(classify(Path::new("/h/.agent/shepherd/.skipped")), None);
        assert_eq!(classify(Path::new("/h/.agent/shepherd/.due.tmp")), None);
        for p in [
            "/h/.agent/shepherd/log.md",
            "/h/.local/state/agent-notify/log",
            "/h/.agent/audit/actions.jsonl",
        ] {
            assert_eq!(
                classify(Path::new(p)).as_deref(),
                Some(r#"{"kind":"actions"}"#)
            );
        }
        assert_eq!(
            classify(Path::new("/h/.local/state/agent-notify/log.delivery")),
            None
        );
        assert_eq!(classify(Path::new("/h/.local/state/other/log")), None);
        assert_eq!(
            classify(Path::new(
                "/h/.agent/shepherd/rundowns/2026-11-03T1201Z.md.tmp"
            )),
            None
        );
        assert_eq!(
            classify(Path::new("/h/.agent/parked/dotfiles-agent-3")).as_deref(),
            Some(r#"{"kind":"sessions"}"#)
        );
        assert_eq!(classify(Path::new("/h/.agent/parked/.agent-3.Xy12")), None);
        assert_eq!(classify(Path::new("/h/notes/x.md")), None);
        for p in ["/h/.notes/outbox.md", "/h/.local/state/notes/ingest.jsonl"] {
            assert_eq!(
                classify(Path::new(p)).as_deref(),
                Some(r#"{"kind":"outbox"}"#),
                "{p}"
            );
        }
        assert_eq!(classify(Path::new("/h/.notes/.outbox.lock")), None);
        assert_eq!(classify(Path::new("/h/.claude/sessions/123.key")), None);
        assert_eq!(
            classify(Path::new("/h/.claude/projects/-h-x/abc.json")),
            None
        );
    }

    #[test]
    fn the_sign_in_page_shows_the_key_form_only_with_a_key_and_leaves_no_placeholder() {
        let with = login_html("", true);
        let without = login_html("", false);
        assert!(with.contains(r#"action="/login/key""#));
        assert!(!without.contains("/login/key"));
        assert!(!with.contains("{{") && !without.contains("{{"));
        assert!(login_html("<b>x</b>", false).contains("<b>x</b>"));
    }

    #[test]
    fn ask_ids_are_mktemp_shaped() {
        assert!(ask_id_ok("JSVBgC"));
        assert!(!ask_id_ok(""));
        assert!(!ask_id_ok("../x"));
        assert!(!ask_id_ok("a b"));
    }

    #[test]
    fn key_whitelist_excludes_session_killers() {
        assert!(KEYS.contains(&"Escape"));
        assert!(!KEYS.contains(&"C-c"));
        assert!(!KEYS.contains(&"C-d"));
    }

    const BASE: &str = "https://agents.example";

    /// One write through `guard_writes`, the layers `router` puts on every route.
    async fn through_layers(method: &str, headers: &[(&str, &str)], body: &str) -> StatusCode {
        use tower::ServiceExt;
        // A path held in a variable: audit's route test reads every `.route("` literal here.
        let path = "/w";
        let app = Router::new().route(
            path,
            get(|| async { "ok" }).post(|b: String| async move { b }),
        );
        let app = guard_writes(app, BASE);
        let mut req = Request::builder().method(method).uri("/w");
        for (k, v) in headers {
            req = req.header(*k, *v);
        }
        let req = req.body(axum::body::Body::from(body.to_string())).unwrap();
        app.oneshot(req).await.unwrap().status()
    }

    const COOKIE: (&str, &str) = ("cookie", "agent_web=abc");

    #[tokio::test]
    async fn a_write_from_another_origin_is_refused_whatever_it_carries() {
        for o in [
            "https://evil.example",
            "https://agents.example.evil",
            "null",
        ] {
            for h in [vec![("origin", o), COOKIE], vec![("origin", o)]] {
                assert_eq!(
                    through_layers("POST", &h, "").await,
                    StatusCode::FORBIDDEN,
                    "{h:?}"
                );
            }
        }
        assert_eq!(
            through_layers("DELETE", &[("origin", "https://evil.example")], "").await,
            StatusCode::FORBIDDEN
        );
    }

    #[tokio::test]
    async fn a_signed_in_write_with_no_origin_is_refused() {
        assert_eq!(
            through_layers("POST", &[COOKIE], "").await,
            StatusCode::FORBIDDEN
        );
        // Refused before routing, so a method the path does not take is refused the same way.
        assert_eq!(
            through_layers("PUT", &[COOKIE], "").await,
            StatusCode::FORBIDDEN
        );
    }

    #[tokio::test]
    async fn own_page_writes_keyed_clients_and_reads_pass() {
        let own = [("origin", BASE), COOKIE];
        assert_eq!(through_layers("POST", &own, "").await, StatusCode::OK);
        // The Tilecast app and agent-mqtt-publish: no cookie, no Origin, the route's key decides.
        assert_eq!(through_layers("POST", &[], "").await, StatusCode::OK);
        // A cross-site link is a GET, which writes nothing.
        let read = [("origin", "https://evil.example"), COOKIE];
        assert_eq!(through_layers("GET", &read, "").await, StatusCode::OK);
    }

    #[tokio::test]
    async fn a_body_past_the_audit_limit_is_refused() {
        let own = [("origin", BASE), COOKIE];
        let big = "x".repeat(audit::BODY_MAX + 1);
        assert_eq!(
            through_layers("POST", &own, &big).await,
            StatusCode::PAYLOAD_TOO_LARGE
        );
        let fits = "x".repeat(audit::BODY_MAX);
        assert_eq!(through_layers("POST", &own, &fits).await, StatusCode::OK);
    }

    #[test]
    fn a_write_body_with_a_field_the_route_does_not_take_is_refused() {
        // A mistyped field used to fall back to its default and run anyway.
        assert!(serde_json::from_str::<SendBody>(r#"{"t":"a","txet":"hi"}"#).is_err());
        assert!(
            serde_json::from_str::<AnswerBody>(r#"{"id":"a","answer":"y","by":"judge"}"#).is_err()
        );
        assert!(serde_json::from_str::<ParkBody>(r#"{"id":"a","unpak":true}"#).is_err());
        assert!(serde_json::from_str::<ActionBody>(r#"{"acount":"bnb"}"#).is_err());
        assert!(serde_json::from_str::<hub_core::queue::Add>(
            r#"{"project":"p","task":"t","priorty":"low"}"#
        )
        .is_err());
        // What the pages send still parses (static/app.js, waiting.js, home.js).
        assert!(serde_json::from_str::<SendBody>(r#"{"t":"a","key":"Escape"}"#).is_ok());
        assert!(serde_json::from_str::<ActionBody>("{}").is_ok());
        assert!(
            serde_json::from_str::<hub_core::queue::Add>(r#"{"project":"p","task":"t"}"#).is_ok()
        );
    }

    #[tokio::test]
    async fn send_and_answer_refuse_control_bytes_and_oversize_text_before_any_command() {
        let send_err = |text: String| async move {
            send(Json(SendBody {
                t: "x".into(),
                text,
                submit: None,
                key: None,
            }))
            .await
            .unwrap_err()
        };
        for text in [
            "clear\u{1b}[2J".to_string(),
            "\u{1b}[201~".into(),
            "x".repeat(MAX_SEND + 1),
        ] {
            let (code, msg) = send_err(text).await;
            assert_eq!(code, StatusCode::BAD_REQUEST);
            assert!(msg.contains("plain lines"), "{msg}");
        }
        for text in ["yes\u{7}".to_string(), "y".repeat(MAX_ANSWER + 1)] {
            let (code, msg) = answer_err(text).await;
            assert_eq!(code, StatusCode::BAD_REQUEST);
            assert!(msg.contains("plain text"), "{msg}");
        }
        assert_eq!(answer_err("  \n ".into()).await.1, "empty answer");
    }

    async fn answer_err(text: String) -> (StatusCode, String) {
        answer(Json(AnswerBody {
            id: "abc123".into(),
            answer: text,
        }))
        .await
        .unwrap_err()
    }
}
