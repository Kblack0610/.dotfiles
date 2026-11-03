//! `hub`: the hub boards as terminal pages. `hub infra` is tmux Prefix i (hub.conf) and the
//! waybar load, CI and day chips. Usage, keys and troubleshooting: README.md.

mod app;
mod board;
mod fit;
mod fmt;
mod jobs;

use std::io::Write;
use std::sync::mpsc;

use app::{App, Msg, Tab, PROM_REFRESH};
use fit::plain;
use notify::{RecursiveMode, Watcher};

const USAGE: &str = "usage: hub infra [--once] [--tab overview|jobs|ci|machines]
  --once  print the page(s) as plain text at $COLUMNS and exit (1 when Prometheus failed)
  --tab   start on this page; with --once, print only it";

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let mut once = false;
    let mut tab = None;
    let mut it = args.iter();
    match it.next().map(String::as_str) {
        Some("infra") => {}
        Some("-h" | "--help") => return println!("{USAGE}"),
        _ => die(USAGE),
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
    if let Err(e) = run(tab.unwrap_or(Tab::Overview)) {
        die(&format!("hub: {e}"));
    }
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
    // A job starting or ending writes one of these files; the Jobs page re-reads on that.
    let files = tx;
    let paths = app.watched();
    let probe = app.paths.clone();
    let mut watcher = notify::recommended_watcher(move |r: notify::Result<notify::Event>| {
        if let Ok(e) = r {
            if e.paths.iter().any(|p| app::is_job_file(&probe, p)) {
                let _ = files.send(Msg::Files);
            }
        }
    })
    .map_err(std::io::Error::other)?;
    for (p, recursive) in paths {
        let mode = if recursive {
            RecursiveMode::Recursive
        } else {
            RecursiveMode::NonRecursive
        };
        // A source that is not installed here has no directory; its rows just never come.
        let _ = watcher.watch(&p, mode);
    }

    app.read_infra();
    app.read_jobs();
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
    res
}
