//! `hub`: the hub boards as terminal tabs, in one tmux window (hub:board, hub.conf). tmux
//! Prefix i lands on Home through `hub tab`. Usage, keys and
//! troubleshooting: README.md.

mod app;
mod board;
mod controls;
mod day;
mod fit;
mod fleet;
mod fleettab;
mod fmt;
mod focustab;
mod forecast;
mod hometab;
mod jobs;
mod logtab;
mod outboxtab;
mod projtab;
mod queuetab;
mod tabreq;
mod tasktab;

use std::io::Write;
use std::sync::mpsc;

use app::{App, Msg, Tab, PROM_REFRESH};
use fit::plain;
use notify::{RecursiveMode, Watcher};

const USAGE: &str = "usage: hub [--once] [--popup] [--tab TAB]
       hub tab TAB
       hub tab projects [NAME]
       hub actions --since WHEN [--json | --records]
       hub phone --json
       hub projects --json
       hub tabs
  TAB     home|queue|infra|sessions|today|history|fleet|projects, or a retired name
          (overview, waiting, asks, board, forecast, watch, shepherd, jobs, ci, machines) that
          lands on its new tab; jobs, ci and machines open that section of Infra
  --once  print the page(s) as plain text at $COLUMNS and exit (1 when Prometheus failed)
  --popup a floating window: Esc with nothing left to close quits
  --tab   start on this page; with --once, print only it ('projects NAME' prints that card
          over its open rows)
  tab     ask the running hub to show TAB (the next hub to start takes it when none runs);
          projects takes a project: `hub tab projects agent-runtime` opens its rows (a name
          no card has opens every project's rows searched for it, as `/` would)
  tabs    the landed tabs as id<TAB>title<TAB>question, in layout order (control-menu)
  phone   the phone widget's rows as {state, rows}: what agent-mqtt-publish sends Home Assistant
  projects every project's card as {cards, unlinked, errors}, each card with its summary line
          and in_flight: what the waybar projects chip reads
  actions what the fleet's machinery did since WHEN (epoch seconds or RFC 3339): counts per
          actor and the escalations, trips and failed runs, or {actions, counts, errors} with
          --json. Exits 1 when a ledger could not be read.";

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let mut once = false;
    let mut popup = false;
    let mut tab = None;
    let mut it = args.iter().peekable();
    if it.peek().map(|a| a.as_str()) == Some("tab") {
        it.next();
        let words: Vec<&str> = it.map(String::as_str).collect();
        let (t, q) = tabreq::parse(&words.join(" ")).unwrap_or_else(|| die(USAGE));
        // A search is the Projects tab's; Infra's query is the section a retired name names.
        if q.is_some() && t != Tab::Projects && words.len() > 1 {
            die(USAGE)
        }
        if let Err(e) = tabreq::request(&tabreq::dir(), t, q.as_deref()) {
            die(&format!("hub tab: {e}"));
        }
        return;
    }
    if it.peek().map(|a| a.as_str()) == Some("actions") {
        it.next();
        std::process::exit(actions(it.cloned().collect()));
    }
    if it.peek().map(|a| a.as_str()) == Some("tabs") {
        for t in &hub_core::layout::TABS {
            println!("{}\t{}\t{}", t.id, t.title, t.question);
        }
        return;
    }
    if it.peek().map(|a| a.as_str()) == Some("projects") {
        it.next();
        if it.cloned().collect::<Vec<_>>() != ["--json"] {
            die(USAGE);
        }
        let p = hub_core::projects::gather();
        println!("{}", hub_core::projects::to_json(&p));
        return;
    }
    if it.peek().map(|a| a.as_str()) == Some("phone") {
        it.next();
        std::process::exit(phone(it.cloned().collect()));
    }
    while let Some(a) = it.next() {
        match a.as_str() {
            "--once" => once = true,
            "--popup" => popup = true,
            "--tab" => {
                tab = Some(
                    it.next()
                        .and_then(|t| tabreq::parse(t))
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
        .unwrap_or((Tab::Home, None));
    if let Err(e) = run(start, popup) {
        die(&format!("hub: {e}"));
    }
}

/// `hub actions`: hub-core's actions reader, so the briefing's digest is Log's Actions section's.
/// `--records` streams the whole window as JSONL, one action or reject per line, with none
/// capped: comms-lint's `fleet-log` channel reads it.
fn actions(args: Vec<String>) -> i32 {
    let (mut since, mut json, mut records) = (None, false, false);
    let mut it = args.iter();
    while let Some(a) = it.next() {
        match a.as_str() {
            "--since" => since = it.next().and_then(|s| parse_since(s)),
            "--json" => json = true,
            "--records" => records = true,
            _ => die(USAGE),
        }
    }
    let since = since.unwrap_or_else(|| die(USAGE));
    let (items, err) = hub_core::actions::queue_items();
    let paths = hub_core::actions::Paths::from_env();
    let mut g = if records {
        hub_core::actions::window(&paths, since, &items)
    } else {
        hub_core::actions::gather(&paths, since, &items)
    };
    g.errors.extend(err);
    if records {
        let lines = g.actions.iter().map(serde_json::to_string);
        for line in lines.chain(g.rejects.iter().map(serde_json::to_string)) {
            println!("{}", line.unwrap_or_default());
        }
        g.errors.iter().for_each(|e| eprintln!("hub actions: {e}"));
    } else if json {
        println!("{}", serde_json::to_string(&g).unwrap_or_default());
    } else {
        print!("{}", hub_core::actions::digest(&g));
    }
    i32::from(!g.errors.is_empty())
}

/// `hub phone --json`: the same join Home draws, reduced to the phone's rows.
fn phone(args: Vec<String>) -> i32 {
    if args != ["--json"] {
        die(USAGE);
    }
    let state = hub_core::boards::state(
        &hub_core::boards::fleet_state(),
        &hub_core::session_actions::System,
    );
    let (queue, infra) = std::thread::scope(|s| {
        let infra = s.spawn(hub_core::infra::gather);
        let queue = hub_core::queue::Queue::read(&hub_core::session_actions::System);
        (queue, infra.join().unwrap_or_default())
    });
    let home = hub_core::home::build(&state, Some(&queue), Some(&infra));
    let projects = hub_core::projects::gather();
    let phone = hub_core::phone::build(
        &home,
        &hub_core::phone::Inputs {
            state: &state,
            queue: Some(&queue),
            infra: Some(&infra),
            projects: Some(&projects),
            merged: hub_core::phone::merged_today(),
            now: chrono::Utc::now().timestamp(),
        },
    );
    println!("{}", serde_json::to_string(&phone).unwrap_or_default());
    0
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
fn print_once(req: Option<tabreq::Req>) -> i32 {
    let section = req.as_ref().and_then(|r| r.1.clone());
    let tab = req.map(|r| r.0);
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
    let mut a = App::new(tab.unwrap_or(Tab::Home), tx);
    a.p.no_color = true;
    let mut out = std::io::stdout().lock();
    if let Some(t @ (Tab::Sessions | Tab::Fleet | Tab::Log)) = tab {
        a.boards = Some(app::Boards::read(&a.files, None));
        if t == Tab::Sessions {
            let b = a.boards.as_ref().expect("just read");
            let state = b.watch.state["sessions"].as_array().cloned();
            let f = forecast::Forecast::read();
            a.controls.read(state, Some(forecast::schedule(&f)));
            a.forecast = Some(f);
            a.controls.set(hub_core::session_actions::gather(
                &hub_core::session_actions::System,
            ));
        }
        if t == Tab::Fleet {
            a.fleet = Some(hub_core::fleet::collect());
        }
        a.tab = t;
        for l in a.page_lines(w) {
            let _ = writeln!(out, "{}", plain(&l));
        }
        return 0;
    }
    if tab == Some(Tab::Outbox) {
        let today = chrono::Local::now().format("%Y-%m-%d").to_string();
        a.outbox = Some(hub_core::outbox::read(
            &hub_core::session_actions::System,
            &today,
        ));
        a.tab = Tab::Outbox;
        for l in a.page_lines(w) {
            let _ = writeln!(out, "{}", plain(&l));
        }
        return 0;
    }
    // Home counts the queue too, so it is read for the default pages as well.
    if matches!(tab, None | Some(Tab::Home | Tab::Queue | Tab::Projects)) {
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
    if tab == Some(Tab::Projects) {
        let sys = hub_core::session_actions::System;
        a.boards = Some(app::Boards::read(&a.files, None));
        a.tasks = Some(hub_core::tasks::feed(&sys));
        a.projects = Some(projtab::load(&sys));
        a.tab = Tab::Projects;
        // `--tab 'projects <name>'` prints that project's card over its rows, what Enter shows:
        // the Prefix+p preview.
        a.open_project(section);
        for l in a.page_lines(w) {
            let _ = writeln!(out, "{}", plain(&l));
        }
        return 0;
    }
    // `--tab jobs` prints the whole jobs table, as the Jobs tab did.
    if tab == Some(Tab::Infra) && section.as_deref() == Some("jobs") {
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
    a.jobs = Some(hub_core::jobs::collect(&a.paths, &Default::default()));
    let tabs = match tab {
        Some(t) => vec![t],
        None => vec![Tab::Home, Tab::Infra],
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

fn run((tab, query): tabreq::Req, popup: bool) -> std::io::Result<()> {
    let (tx, rx) = mpsc::channel();
    let mut app = App::new(tab, tx.clone());
    app.popup = popup;
    // The same reader as `hub tab`: an Infra section on Infra, else a project.
    app.open_query(query);

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
    if app.tab == Tab::Queue {
        app.read_candidates();
    }
    if app.tab == Tab::Sessions {
        app.read_forecast();
        app.read_sessions();
    }
    if app.tab == Tab::Fleet {
        app.read_fleet();
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
