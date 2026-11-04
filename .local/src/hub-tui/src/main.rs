//! `hub`: the hub boards as terminal tabs, in one tmux window (hub:board, hub.conf). tmux
//! Prefix i, o and O land on Overview, Sessions and Today through `hub tab`. Usage, keys and
//! troubleshooting: README.md.

mod app;
mod board;
mod controls;
mod day;
mod fit;
mod fleet;
mod fleettab;
mod fmt;
mod forecast;
mod jobs;
mod queuetab;
mod tabreq;

use std::io::Write;
use std::sync::mpsc;

use app::{App, Msg, Tab, PROM_REFRESH};
use fit::plain;
use notify::{RecursiveMode, Watcher};

const USAGE: &str = "usage: hub [--once] [--tab TAB]
       hub tab TAB
       hub actions --since WHEN [--json]
  TAB     overview|jobs|ci|machines|sessions|forecast|today|history|fleet|queue
  --once  print the page(s) as plain text at $COLUMNS and exit (1 when Prometheus failed)
  --tab   start on this page; with --once, print only it
  tab     ask the running hub to show TAB (the next hub to start takes it when none runs)
  actions what the fleet's machinery did since WHEN (epoch seconds or RFC 3339): counts per
          actor and the escalations, trips and failed runs, or {actions, counts, errors} with
          --json. Exits 1 when a ledger could not be read.";

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let mut once = false;
    let mut tab = None;
    let mut it = args.iter().peekable();
    if it.peek().map(|a| a.as_str()) == Some("tab") {
        it.next();
        let t = it
            .next()
            .and_then(|t| Tab::parse(t))
            .unwrap_or_else(|| die(USAGE));
        if it.next().is_some() {
            die(USAGE)
        }
        if let Err(e) = tabreq::request(&tabreq::dir(), t) {
            die(&format!("hub tab: {e}"));
        }
        return;
    }
    if it.peek().map(|a| a.as_str()) == Some("actions") {
        it.next();
        std::process::exit(actions(it.cloned().collect()));
    }
    while let Some(a) = it.next() {
        match a.as_str() {
            "--once" => once = true,
            "--tab" => {
                tab = Some(
                    it.next()
                        .and_then(|t| Tab::parse(t))
                        .unwrap_or_else(|| die(USAGE)),
                )
            }
            "-h" | "--help" => return println!("{USAGE}"),
            _ => die(USAGE),
        }
    }
    if once {
        std::process::exit(print_once(tab));
    }
    // A request left while no hub ran (the binding that started this window) wins over --tab.
    let start = tabreq::take(&tabreq::dir())
        .or(tab)
        .unwrap_or(Tab::Overview);
    if let Err(e) = run(start) {
        die(&format!("hub: {e}"));
    }
}

/// `hub actions`: hub-core's actions reader, so the briefing's digest is the Actions tab's.
fn actions(args: Vec<String>) -> i32 {
    let (mut since, mut json) = (None, false);
    let mut it = args.iter();
    while let Some(a) = it.next() {
        match a.as_str() {
            "--since" => since = it.next().and_then(|s| parse_since(s)),
            "--json" => json = true,
            _ => die(USAGE),
        }
    }
    let since = since.unwrap_or_else(|| die(USAGE));
    let (items, err) = match hub_core::queue::list(&hub_core::session_actions::System, "all") {
        Ok(items) => (items, None),
        Err(e) => (vec![], Some(format!("agent-queue list: {e}"))),
    };
    let mut g = hub_core::actions::gather(&hub_core::actions::Paths::from_env(), since, &items);
    g.errors.extend(err);
    if json {
        println!("{}", serde_json::to_string(&g).unwrap_or_default());
    } else {
        print!("{}", hub_core::actions::digest(&g));
    }
    i32::from(!g.errors.is_empty())
}

/// Epoch seconds, or an RFC 3339 time.
fn parse_since(s: &str) -> Option<i64> {
    s.parse().ok().or_else(|| {
        chrono::DateTime::parse_from_rfc3339(s)
            .ok()
            .map(|t| t.timestamp())
    })
}

fn die(msg: &str) -> ! {
    eprintln!("{msg}");
    std::process::exit(2)
}

/// The pages as plain text, for tests, capture-pane and a quick look over ssh.
fn print_once(tab: Option<Tab>) -> i32 {
    let w = std::env::var("COLUMNS")
        .ok()
        .and_then(|c| c.parse().ok())
        .or_else(|| {
            ratatui::crossterm::terminal::size()
                .ok()
                .map(|(w, _)| w as usize)
        })
        .unwrap_or(80);
    let (tx, _rx) = mpsc::channel();
    let mut a = App::new(tab.unwrap_or(Tab::Overview), tx);
    a.p.no_color = true;
    let mut out = std::io::stdout().lock();
    if let Some(t @ (Tab::Sessions | Tab::Today | Tab::History)) = tab {
        a.boards = Some(app::Boards::read(&a.files, None));
        if t == Tab::Sessions {
            a.controls.set(hub_core::session_actions::gather(
                &hub_core::session_actions::System,
            ));
        }
        a.tab = t;
        for l in a.page_lines(w) {
            let _ = writeln!(out, "{}", plain(&l));
        }
        return 0;
    }
    if tab == Some(Tab::Fleet) {
        a.fleet = Some(hub_core::fleet::collect());
        a.tab = Tab::Fleet;
        for l in a.page_lines(w) {
            let _ = writeln!(out, "{}", plain(&l));
        }
        return 0;
    }
    // The Overview counts the queue too, so it is read for the default pages as well.
    if matches!(tab, None | Some(Tab::Overview | Tab::Queue)) {
        a.queue = Some(hub_core::queue::Queue::read(
            &hub_core::session_actions::System,
        ));
    }
    if tab == Some(Tab::Queue) {
        a.tab = Tab::Queue;
        for l in a.page_lines(w) {
            let _ = writeln!(out, "{}", plain(&l));
        }
        return 0;
    }
    if tab == Some(Tab::Forecast) {
        a.forecast = Some(forecast::Forecast::read());
        a.tab = Tab::Forecast;
        for l in a.page_lines(w) {
            let _ = writeln!(out, "{}", plain(&l));
        }
        return 0;
    }
    if tab == Some(Tab::Jobs) {
        let js = hub_core::jobs::collect(&a.paths, &Default::default());
        for l in
            a.jv.status(&js, a.p)
                .iter()
                .chain(&a.jv.table(&js, a.p, w, false))
        {
            let _ = writeln!(out, "{}", plain(l));
        }
        return 0;
    }
    let infra = hub_core::infra::gather();
    let failed = !infra.ok;
    a.infra = Some(infra);
    let tabs = match tab {
        Some(t) => vec![t],
        None => vec![Tab::Overview, Tab::Machines, Tab::Ci],
    };
    for (n, t) in tabs.into_iter().enumerate() {
        if n > 0 {
            let _ = writeln!(out);
        }
        a.tab = t;
        for l in a.page_lines(w) {
            let _ = writeln!(out, "{}", plain(&l));
        }
    }
    i32::from(failed)
}

fn run(tab: Tab) -> std::io::Result<()> {
    let (tx, rx) = mpsc::channel();
    let mut app = App::new(tab, tx.clone());

    let input = tx.clone();
    std::thread::spawn(move || {
        while let Ok(e) = ratatui::crossterm::event::read() {
            if input.send(Msg::Input(e)).is_err() {
                break;
            }
        }
    });
    // Prometheus has no push, so its pages are read on a cadence (PROM_REFRESH explains why).
    let tick = tx.clone();
    std::thread::spawn(move || loop {
        std::thread::sleep(PROM_REFRESH);
        if tick.send(Msg::Tick).is_err() {
            break;
        }
    });
    // `hub tab` asks over a socket. Only the first hub listens; a second one keeps its keys.
    let listener = match tabreq::listen(&tabreq::dir()) {
        Ok(l) => l,
        Err(e) => {
            app.tab_failed = Some(e.to_string());
            None
        }
    };
    if let Some(l) = listener.as_ref().and_then(|l| l.try_clone().ok()) {
        let tabs = tx.clone();
        std::thread::spawn(move || tabreq::serve(l, tabs));
    }
    // A job starting or ending writes one of the job files, fleet-sessions and day-log write
    // the board files, and agent-queue its item files: each re-reads only its own part.
    let files = tx;
    let paths = app.watched();
    let probe = app.paths.clone();
    let boards = app.files.clone();
    let queue = app.queue_dir.clone();
    let watcher = notify::recommended_watcher(move |r: notify::Result<notify::Event>| {
        let Ok(e) = r else { return };
        if !app::is_write(&e.kind) {
            return;
        }
        if e.paths.iter().any(|p| app::is_job_file(&probe, p)) {
            let _ = files.send(Msg::Files);
        }
        if e.paths.iter().any(|p| boards.is_board_file(p)) {
            let _ = files.send(Msg::BoardFiles);
        }
        if e.paths.iter().any(|p| app::is_queue_file(&queue, p)) {
            let _ = files.send(Msg::QueueFiles);
        }
    });
    // Kept alive until hub exits; dropping it ends the watch.
    let _watcher = match watcher {
        Ok(mut w) => {
            watch_all(&mut w, paths, &mut app);
            Some(w)
        }
        Err(e) => {
            app.watch_failed = Some(watch_reason(&e));
            None
        }
    };

    app.read_infra();
    app.read_jobs();
    app.read_boards();
    app.read_queue();
    if app.tab == Tab::Forecast {
        app.read_forecast();
    }
    if app.tab == Tab::Fleet {
        app.read_fleet();
    }
    if app.tab == Tab::Sessions {
        app.read_sessions();
    }
    let mut term = ratatui::init();
    let res = (|| {
        loop {
            term.draw(|f| app.draw(f))?;
            let Ok(m) = rx.recv() else { break };
            app.handle(m);
            // Drain what is already queued so a burst draws once.
            while let Ok(m) = rx.try_recv() {
                app.handle(m);
            }
            if app.quit {
                break;
            }
        }
        Ok(())
    })();
    ratatui::restore();
    if listener.is_some() {
        let _ = std::fs::remove_file(tabreq::dir().join("tab.sock"));
    }
    res
}

/// Watch each directory. A source that is not installed here has no directory, and its rows
/// just never come. Any other failure (inotify full) is shown, and the 60s tick reads instead.
fn watch_all(w: &mut impl Watcher, paths: Vec<(std::path::PathBuf, bool)>, app: &mut App) {
    for (p, recursive) in paths {
        let mode = if recursive {
            RecursiveMode::Recursive
        } else {
            RecursiveMode::NonRecursive
        };
        if let Err(e) = w.watch(&p, mode) {
            if !not_found(&e) {
                app.watch_failed = Some(watch_reason(&e));
            }
        }
    }
}

fn not_found(e: &notify::Error) -> bool {
    match &e.kind {
        notify::ErrorKind::PathNotFound => true,
        notify::ErrorKind::Io(io) => io.kind() == std::io::ErrorKind::NotFound,
        _ => false,
    }
}

fn watch_reason(e: &notify::Error) -> String {
    match &e.kind {
        notify::ErrorKind::MaxFilesWatch => "inotify full".into(),
        _ => e.to_string(),
    }
}
