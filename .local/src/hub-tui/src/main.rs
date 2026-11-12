//! `hub`: the hub boards as terminal tabs, in one tmux window (hub:board, hub.conf). tmux
//! Prefix i lands on Home through `hub tab`. Usage, keys and
//! troubleshooting: README.md.

mod alertstab;
mod app;
mod board;
mod builds;
mod controls;
mod coststab;
mod datatable;
mod day;
mod fit;
mod fleet;
mod fleettab;
mod flowline;
mod fmt;
mod focustab;
mod forecast;
mod hometab;
mod infrapage;
mod infratables;
mod innertabs;
mod jobs;
mod logtab;
mod machinetab;
mod outboxtab;
mod pipetab;
mod pooltab;
mod projtab;
mod proptab;
mod queuetab;
mod releases;
mod schedules;
mod tabreq;
mod tasktab;
mod tokens;

use std::io::Write;
use std::sync::mpsc;

use app::{App, Msg, Tab, PROM_REFRESH};
use fit::plain;
use notify::{RecursiveMode, Watcher};

const USAGE: &str = "usage: hub [--once] [--popup] [--tab TAB]
       hub tab TAB
       hub tab projects [NAME]
       hub tab fleet [RUNNER]
       hub actions --since WHEN [--json | --records]
       hub phone --json
       hub vitals [--json]
       hub needs --json | --page
       hub ci [--json | --pool-match SECS]
       hub ci pass [--since WHEN] [--until WHEN] [--branch B]
       hub briefing --json | --md [--agents-md FILE] [--since WHEN]
       hub projects --json
       hub projects --page NAME | --status NAME
       hub board --json
       hub releases --json | check
       hub tabs
  TAB     a tab id (`hub tabs` lists them), or a retired name (hub_core::layout::RETIRED)
          that lands on its new tab, on the section it became when it became one
  --once  print the page(s) as plain text at $COLUMNS and exit (1 when Prometheus failed)
  --popup a floating window: Esc with nothing left to close quits
  --tab   start on this page; with --once, print only it ('projects NAME' prints that card
          over its rows, 'fleet RUNNER' that runner's page)
  tab     ask the running hub to show TAB (the next hub to start takes it when none runs);
          projects takes a project: `hub tab projects agent-runtime` opens its rows (a name
          no card has opens every project's rows searched for it, as `/` would); fleet takes
          a runner (`hub tab fleet inbox-triage` opens its page), sessions a session, queue an
          item's slug, and board a row's `id:=ar-1`: what each link in hub_core::links opens
  tabs    the landed tabs as id<TAB>title<TAB>question, in layout order (control-menu)
  ci      the CI runners board: one line per slot and queued job (hub_core::ci); --json gives it
          whole; --pool-match SECS gives fleet-bench the runners that fit the jobs waiting SECS
          or longer, as metric<TAB>label<TAB>value rows. Exits 1 when Prometheus failed
  ci pass the one CI pass rate (hub_core::builds::verdict) of the run ledger's runs created in
          [WHEN, WHEN) (epoch seconds or RFC 3339; default the last 24h), on one branch with
          --branch, as JSON keyed <forge>:<repo>: runs, green, pass (0..1), and the same per
          workflow. day-log reads it. Exits 1 when the ledger cannot be read
  phone   the phone widget's rows as {state, rows}: what agent-mqtt-publish sends Home Assistant
  needs   Home's NEEDS YOU as {needs, errors}, ranked, each row with the score it counted
          (fleet-bench asks reads it); --page sends one grouped page for the new rows over the
          bar in channels.toml [pager.needs] (fleet-state.service runs it after every pass)
  briefing the human overview (what needs you, what landed, builds and releases, overnight,
          money) for the window from WHEN (epoch seconds or RFC 3339, default 12h ago); --md is
          the file agentctl-briefing writes as briefing.md, and --agents-md FILE writes the agent
          briefing (what needs you, one line per area: Infra, Sessions, Workers overnight,
          Nightly, Delivery, Costs, and the detail) from the same read. Exits 1 when a source
          could not be read (the output says which)
  projects every project's card as {cards, unlinked, errors}, each card with its summary line
          and in_flight: what the waybar projects chip reads
  projects --page NAME
          one project's page, what its card shows when opened: the flow line, what needs you,
          the epics by system with each system's criteria, the next stage and shipped versions
  projects --status NAME
          the numbers of the project's lab STATUS line, which write-lab-status.sh appends: each
          system's current wave and its percent, the version and its ETA, the next stage's gate
          and the playtests waiting. Exits non-zero when a source it says could not be read
  board   the task feed as {today, heads, hints, rows, done, errors}: each open row with its
          forecast day and queue state, one head line per project and the words beside each
          sheet row (what nvim draws as virtual text over a project sheet)
  releases --json
          the Releases tab's read as JSON: every app with its channels and its release history
          (each tag's PRs, board rows and the deploys it reached, hub_core::release_graph);
          fleet-bench reads it. Exits 1 when a source could not be read
  releases check
          one line per place the stores disagree: a PR an item or a tag names that the PR store
          lacks, a bare pr:N on a project with no one repo, a deploy naming a run the runs ledger
          lacks. Exits 1 when it prints a line or a store could not be read
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
        // Every tab but these takes a word: what a link's `tab_args` names (hub_core::links).
        if q.is_some() && matches!(t, Tab::Home | Tab::Schedules) && words.len() > 1 {
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
        let rest: Vec<String> = it.cloned().collect();
        if let [flag, name] = rest.as_slice() {
            let sys = hub_core::session_actions::System;
            let now = hub_core::jobs::now();
            let out = match flag.as_str() {
                "--page" => hub_core::page::named(&sys, name, now)
                    .map(|p| hub_core::page::to_json(&p).to_string()),
                "--status" => hub_core::page::status(&sys, name, now),
                _ => die(USAGE),
            };
            match out {
                Ok(s) => println!("{s}"),
                Err(e) => die(&format!("hub projects {flag}: {e}")),
            }
            return;
        }
        if rest != ["--json"] {
            die(USAGE);
        }
        let p = hub_core::projects::gather();
        println!("{}", hub_core::projects::to_json(&p));
        return;
    }
    if it.peek().map(|a| a.as_str()) == Some("board") {
        it.next();
        if it.cloned().collect::<Vec<String>>() != ["--json"] {
            die(USAGE);
        }
        println!("{}", hub_core::sheet_view::gather());
        return;
    }
    if it.peek().map(|a| a.as_str()) == Some("phone") {
        it.next();
        std::process::exit(phone(it.cloned().collect()));
    }
    if it.peek().map(|a| a.as_str()) == Some("vitals") {
        it.next();
        std::process::exit(vitals(it.cloned().collect()));
    }
    if it.peek().map(|a| a.as_str()) == Some("briefing") {
        it.next();
        std::process::exit(briefing(it.cloned().collect()));
    }
    if it.peek().map(|a| a.as_str()) == Some("ci") {
        it.next();
        std::process::exit(ci(it.cloned().collect()));
    }
    if it.peek().map(|a| a.as_str()) == Some("needs") {
        it.next();
        std::process::exit(needs(it.cloned().collect()));
    }
    if it.peek().map(|a| a.as_str()) == Some("releases") {
        it.next();
        std::process::exit(releases_cmd(it.cloned().collect()));
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

/// `hub needs --json`: NEEDS YOU as Home ranks it. `--page`: the pager over it, with no
/// Prometheus read (red-now rows never page). Exits 1 when the page could not be decided or sent.
fn needs(args: Vec<String>) -> i32 {
    let page = match args.iter().map(String::as_str).collect::<Vec<_>>()[..] {
        ["--json"] => false,
        ["--page"] => true,
        _ => die(USAGE),
    };
    let (state, queue, board, infra) = hub_core::home::gather(!page);
    let home = hub_core::home::build(
        Some(&state),
        Some(&queue),
        Some(&board),
        infra.as_ref(),
        hub_core::jobs::now(),
    );
    if !page {
        let out = serde_json::json!({"needs": home.needs, "errors": home.errors});
        println!("{out}");
        return 0;
    }
    let paths = hub_core::pager::Paths::from_env();
    let now = chrono::Utc::now().timestamp();
    match hub_core::pager::run(&home.needs, now, &paths, &hub_core::session_actions::System) {
        Ok(Some(p)) => {
            println!("paged ({}): {}", p.priority, p.text);
            0
        }
        Ok(None) => 0,
        Err(e) => {
            eprintln!("hub needs --page: {e}");
            1
        }
    }
}

/// `hub ci pass`: the pass rate of the ledger's runs over a window, by repo and workflow.
fn ci_pass(args: &[String]) -> i32 {
    let now = chrono::Utc::now().timestamp();
    let (mut since, mut until, mut branch) = (now - 86400, now, None);
    let mut it = args.iter();
    while let Some(a) = it.next() {
        let v = it.next().unwrap_or_else(|| die(USAGE));
        match a.as_str() {
            "--since" => since = parse_since(v).unwrap_or_else(|| die(USAGE)),
            "--until" => until = parse_since(v).unwrap_or_else(|| die(USAGE)),
            "--branch" => branch = Some(v.as_str()),
            _ => die(USAGE),
        }
    }
    let paths = hub_core::builds::Paths::from_env();
    let text = match std::fs::read_to_string(&paths.ledger) {
        Ok(t) => t,
        Err(e) => {
            eprintln!("hub ci pass: {}: {e}", paths.ledger.display());
            return 1;
        }
    };
    let (rows, _) = hub_core::builds::parse(&text, now);
    let report = hub_core::builds::pass_by_repo(&rows, since, until, branch);
    println!("{}", serde_json::to_string(&report).unwrap_or_default());
    0
}

/// `hub ci`: the CI runners board as text, JSON, or fleet-bench's pool-match rows.
fn ci(args: Vec<String>) -> i32 {
    if args.first().map(String::as_str) == Some("pass") {
        return ci_pass(&args[1..]);
    }
    enum Mode {
        Text,
        Json,
        PoolMatch(i64),
    }
    let mode = match args.iter().map(String::as_str).collect::<Vec<_>>()[..] {
        [] => Mode::Text,
        ["--json"] => Mode::Json,
        ["--pool-match", secs] => match secs.parse() {
            Ok(secs) => Mode::PoolMatch(secs),
            Err(_) => die(USAGE),
        },
        _ => die(USAGE),
    };
    let infra = hub_core::infra::gather();
    if !infra.ok {
        eprintln!(
            "hub ci: {}",
            infra
                .error
                .as_deref()
                .unwrap_or("Prometheus did not answer")
        );
        return 1;
    }
    match mode {
        Mode::Text => {
            let p = fmt::Palette { no_color: true };
            for l in board::ci_runners(&infra, p, 120) {
                println!("{}", plain(&l));
            }
        }
        Mode::Json => println!("{}", serde_json::to_string(&infra.ci).unwrap_or_default()),
        Mode::PoolMatch(secs) => print!("{}", hub_core::ci::pool_match_rows(&infra, secs)),
    }
    0
}

/// `hub briefing`: hub-core's briefing over the window from `--since`.
fn briefing(args: Vec<String>) -> i32 {
    let (mut since, mut md, mut agents) = (None, None, None);
    let mut it = args.iter();
    while let Some(a) = it.next() {
        match a.as_str() {
            "--since" => {
                since = Some(
                    it.next()
                        .and_then(|s| parse_since(s))
                        .unwrap_or_else(|| die(USAGE)),
                )
            }
            "--json" => md = Some(false),
            "--md" => md = Some(true),
            "--agents-md" => agents = Some(it.next().unwrap_or_else(|| die(USAGE)).clone()),
            _ => die(USAGE),
        }
    }
    let md = md.unwrap_or_else(|| die(USAGE));
    let now = chrono::Utc::now().timestamp();
    let since = since.unwrap_or(now - hub_core::briefing::DEFAULT_WINDOW_SECS);
    let b = hub_core::briefing::build(&hub_core::briefing::gather(since, now));
    if let Some(path) = agents {
        if let Err(e) = std::fs::write(&path, b.agents_markdown()) {
            eprintln!("hub: {path}: {e}");
            return 2;
        }
    }
    if md {
        print!("{}", b.markdown());
    } else {
        println!("{}", serde_json::to_string(&b).unwrap_or_default());
    }
    i32::from(!b.errors.is_empty())
}

/// `hub phone --json`: the same join Home draws, reduced to the phone's rows.
fn phone(args: Vec<String>) -> i32 {
    if args != ["--json"] {
        die(USAGE);
    }
    let (state, queue, board, infra) = hub_core::home::gather(true);
    let infra = infra.unwrap_or_default();
    let home = hub_core::home::build(
        Some(&state),
        Some(&queue),
        Some(&board),
        Some(&infra),
        hub_core::jobs::now(),
    );
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

/// `hub releases --json`: the Releases tab's read, joined to the queue. `hub releases check`:
/// one line per place the stores disagree. Either exits 1 when a source could not be read; check
/// also exits 1 when a line is printed.
fn releases_cmd(args: Vec<String>) -> i32 {
    let sys = hub_core::session_actions::System;
    match args
        .iter()
        .map(String::as_str)
        .collect::<Vec<_>>()
        .as_slice()
    {
        ["--json"] => {
            let (items, queue_error) = hub_core::actions::queue_items();
            let mut r = hub_core::releases::read(&sys, &items);
            let groups = r.check_groups();
            r.with_checks(&hub_core::app_status::badges(
                &sys,
                &groups,
                hub_core::jobs::now(),
            ));
            let join = hub_core::builds::Join {
                runner: &sys,
                items: &items,
            };
            let paths = hub_core::builds::Paths::from_env();
            let b = hub_core::builds::read(&paths, Some(join), hub_core::jobs::now());
            r.with_builds(&b.rows);
            r.errors
                .extend(b.errors.iter().map(|e| format!("build runs: {e}")));
            r.errors.extend(queue_error);
            match serde_json::to_string(&r) {
                Ok(s) => println!("{s}"),
                Err(e) => die(&format!("hub releases --json: {e}")),
            }
            i32::from(!r.errors.is_empty())
        }
        ["check"] => {
            let (problems, errors) = hub_core::release_graph::audit(&sys, hub_core::jobs::now());
            for p in &problems {
                println!("{p}");
            }
            for e in &errors {
                eprintln!("hub releases check: {e}");
            }
            i32::from(!problems.is_empty() || !errors.is_empty())
        }
        _ => die(USAGE),
    }
}

/// `hub vitals`: the one-line summary, then a row per question, for tmux, waybar and the briefing;
/// `--json` is the same read whole. Exit 1 when Prometheus did not answer.
fn vitals(args: Vec<String>) -> i32 {
    let json = match args.as_slice() {
        [] => false,
        [a] if a == "--json" => true,
        _ => die(USAGE),
    };
    let v = match hub_core::vitals::fetch() {
        Ok(v) => v,
        Err(e) => {
            eprintln!("hub vitals: Prometheus: {e}");
            return 1;
        }
    };
    if json {
        println!("{}", serde_json::to_string(&v).unwrap_or_default());
        return 0;
    }
    println!("{}", v.line);
    for r in &v.rows {
        println!("{:<8}{}  {}", r.question, r.mark(), r.text());
    }
    0
}

/// The CI runs ledger, joined to the PR store, these queue items and the releases snapshot, as
/// the live app's `read_builds` reads it.
fn read_runs(a: &App, items: &[hub_core::queue::Item], now: i64) -> hub_core::builds::Builds {
    let join = hub_core::builds::Join {
        runner: &hub_core::session_actions::System,
        items,
    };
    hub_core::builds::read(&a.files.builds, Some(join), now)
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
            let f = forecast::Forecast::read();
            a.controls
                .read(Some(&b.watch.state), Some(forecast::schedule(&f)));
            a.forecast = Some(f);
            a.read_sessions_now();
        }
        // `--tab 'fleet NAME'` prints that runner's page in place of the tab.
        if t == Tab::Fleet {
            match section.as_deref().and_then(fleettab::runner_arg) {
                Some(name) => {
                    a.fleet_page = Some(name.to_string());
                    a.fleet_runner = Some(hub_core::fleet::runner::read(
                        &hub_core::fleet::Paths::from_env(),
                        name,
                    ));
                }
                None => {
                    a.fleet = Some(hub_core::fleet::files(&hub_core::fleet::Paths::from_env()));
                }
            }
        }
        a.tab = t;
        for l in a.page_lines(w) {
            let _ = writeln!(out, "{}", plain(&l));
        }
        return 0;
    }
    // Daily prints the note, or with `--tab outbox` the outbox under it.
    if tab == Some(Tab::Daily) {
        let sys = hub_core::session_actions::System;
        if section.as_deref() == Some("outbox") {
            let today = chrono::Local::now().format("%Y-%m-%d").to_string();
            a.outbox = Some(hub_core::outbox::read(&sys, &today));
            a.daily_outbox = true;
        } else {
            a.focus = Some(hub_core::focus::read(&sys, "daily"));
        }
        a.tab = Tab::Daily;
        for l in a.page_lines(w) {
            let _ = writeln!(out, "{}", plain(&l));
        }
        return 0;
    }
    if matches!(tab, None | Some(Tab::Home)) {
        a.proposals = Some(hub_core::proposals::read(
            &hub_core::session_actions::System,
        ));
        // The Queue card's bottleneck is the snapshot's.
        a.pipeline = Some(hub_core::pipeline::read());
        // RUNNING joins each item to its session (phase, ETA, PR, CI) through the fleet state,
        // which the live app reads in a worker.
        a.boards = Some(app::Boards::read(&a.files, None));
    }
    // Home counts the queue too, so it is read for the default pages as well.
    if matches!(tab, None | Some(Tab::Home | Tab::Queue | Tab::Projects)) {
        a.queue = Some(hub_core::queue::Queue::read(
            &hub_core::session_actions::System,
        ));
    }
    if tab == Some(Tab::Queue) {
        a.tab = Tab::Queue;
        a.pipeline = Some(hub_core::pipeline::read());
        // The Candidates fold, with its `as of`: fleet-dispatch's snapshot, a file read.
        a.candidates = Some(hub_core::queue::candidates(&a.files.candidates));
        // `--tab 'queue candidates'` opens the fold, as the tab request does.
        a.open_query(section);
        // Only the link is needed here: the page's `o graph` hint reads the Grafana base.
        a.infra = Some(hub_core::infra::Infra {
            grafana: hub_core::infra::grafana(),
            ..Default::default()
        });
        for l in a.page_lines(w) {
            let _ = writeln!(out, "{}", plain(&l));
        }
        return 0;
    }
    if tab == Some(Tab::Projects) {
        let sys = hub_core::session_actions::System;
        a.boards = Some(app::Boards::read(&a.files, None));
        a.tasks = Some(hub_core::sheet_view::feed(&sys));
        a.projects = Some(projtab::load(&sys));
        a.tab = Tab::Projects;
        // `--tab 'projects <name>'` prints that project's opened card, its page read here, over
        // its rows, what Enter shows: the Prefix+p preview.
        a.open_project(section);
        a.read_proj_page_now(&sys);
        for l in a.page_lines(w) {
            let _ = writeln!(out, "{}", plain(&l));
        }
        return 0;
    }
    // `--tab 'costs by=runner&w=24h'` prints that view of the Costs tab.
    if tab == Some(Tab::Costs) {
        let sys = hub_core::session_actions::System;
        let paths = hub_core::costs::Paths::from_env();
        a.costs = Some(hub_core::costs::read(
            &sys,
            &paths,
            chrono::Utc::now().timestamp(),
        ));
        a.tab = Tab::Costs;
        a.open_query(section);
        for l in a.page_lines(w) {
            let _ = writeln!(out, "{}", plain(&l));
        }
        return 0;
    }
    // `--tab 'infra runs'` (and the moved `releases builds`) prints the whole CI runs table.
    if tab == Some(Tab::Infra) && section.as_deref() == Some("runs") {
        let now = hub_core::jobs::now();
        let (items, queue_error) = hub_core::actions::queue_items();
        let b = read_runs(&a, &items, now);
        let mut errors = b.errors.clone();
        errors.extend(queue_error);
        for l in
            a.ci.status("Runs", &b, a.p, now)
                .iter()
                .chain(&a.ci.table(&b, a.p, w, false, now))
        {
            let _ = writeln!(out, "{}", plain(l));
        }
        return i32::from(!errors.is_empty());
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
    if tab == Some(Tab::Releases) {
        let sys = hub_core::session_actions::System;
        let (items, queue_error) = hub_core::actions::queue_items();
        let mut s = hub_core::releases::read(&sys, &items);
        let now = hub_core::jobs::now();
        s.with_checks(&hub_core::app_status::badges(&sys, &s.check_groups(), now));
        a.tab = Tab::Releases;
        a.open_query(section);
        // The strip with its counts, then the inner tab the request names (Apps by default).
        let mut b = read_runs(&a, &items, now);
        s.with_builds(&b.rows);
        s.errors.extend(queue_error.clone());
        b.errors.extend(queue_error);
        let on = a.rv.on();
        let mut lines = vec![innertabs::strip(
            releases::tab(),
            on,
            &releases::flagged(&s, Some(&b)),
            a.p,
            w,
        )];
        match on {
            "runs" => {
                lines.extend(a.rv.runs.status("Release runs", &b, a.p, now));
                lines.extend(a.rv.runs.table(&b, a.p, w, false, now));
            }
            _ => {
                lines.extend(a.rv.status(&s, a.p, now));
                lines.extend(a.rv.table(&s, a.p, w, false));
            }
        }
        for l in &lines {
            let _ = writeln!(out, "{}", plain(l));
        }
        // The exit code is the shown tab's read: the runs ledger, else the releases snapshot.
        let errors = if on == "runs" { &b.errors } else { &s.errors };
        return i32::from(!errors.is_empty());
    }
    if tab == Some(Tab::Schedules) {
        let paths = hub_core::fleet::Paths::from_env();
        let s = hub_core::schedules::read(&paths, &hub_core::session_actions::System);
        for l in
            a.sv.status(&s, a.p)
                .iter()
                .chain(&a.sv.table(&s, a.p, w, false))
        {
            let _ = writeln!(out, "{}", plain(l));
        }
        return i32::from(!s.errors.is_empty());
    }
    let infra = hub_core::infra::gather();
    let mut failed = !infra.ok;
    a.infra = Some(infra);
    a.jobs = Some(hub_core::jobs::collect(&a.paths, &Default::default()));
    if matches!(tab, None | Some(Tab::Infra)) {
        let (items, _) = hub_core::actions::queue_items();
        a.builds = Some(read_runs(&a, &items, hub_core::jobs::now()));
        // Pipelines joins its sources to those runs; the live app sends them from read_builds.
        let s = hub_core::pipelines::sources(&hub_core::session_actions::System);
        a.handle(Msg::Pipes(Box::new(s)));
    }
    // The reds and the Alerts join are read off-thread in the live app; a printed page has no
    // next frame, so read them here or Alerts prints "reading".
    if matches!(tab, None | Some(Tab::Alerts)) {
        let reds = hub_core::reds::read(&hub_core::session_actions::System);
        let now = hub_core::jobs::now();
        a.alerts = (a.infra.as_ref()).map(|i| hub_core::alerts::read(i, reds.clone(), now));
        a.reds = Some(reds);
        // Printed alone, any source Alerts could not read fails the run, as Prometheus does.
        failed |= tab.is_some() && a.alerts.as_ref().is_some_and(|x| !x.errors.is_empty());
        // `--tab 'alerts fixes'` prints that inner tab; with none named, every one prints.
        a.tab = Tab::Alerts;
        a.av.all = section.is_none();
        a.open_query(section.clone());
    }
    if matches!(tab, None | Some(Tab::Infra)) {
        // `--tab 'infra machines'` prints that inner tab; with none named, every one prints.
        a.tab = Tab::Infra;
        a.infra_all = section.is_none();
        a.open_query(section.clone());
    }
    // The live app reads Deliverables off-thread (about 10s); a printed page has no next frame,
    // so it waits for them here.
    if matches!(tab, None | Some(Tab::Projects)) {
        a.deliverables = Some(hub_core::deliverables::read(
            &hub_core::session_actions::System,
        ));
    }
    // Home's NEEDS YOU joins the human-sheet rows.
    if matches!(tab, None | Some(Tab::Home)) {
        a.tasks = Some(hub_core::tasks::feed(&hub_core::session_actions::System));
        // The live app reads each card's tab off-thread; a printed page waits for them here.
        a.read_home_cards_now();
    }
    let tabs = match tab {
        Some(t) => vec![t],
        None => vec![Tab::Home, Tab::Alerts, Tab::Infra],
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
    // A job starting or ending writes one of the job files, the nightly run a token snapshot,
    // fleet-sessions and day-log the board files, and agent-queue its item files: each re-reads
    // only its own part.
    let files = tx;
    // agent-propose makes its store on the first write, and a watch needs it to exist now.
    std::fs::create_dir_all(hub_core::boards::proposals_dir()).ok();
    std::fs::create_dir_all(&app.files.tokens).ok();
    std::fs::create_dir_all(&app.files.releases).ok();
    std::fs::create_dir_all(&app.files.watches).ok();
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
        if e.paths.iter().any(|p| boards.is_token_file(p)) {
            let _ = files.send(Msg::TokenFiles);
        }
        if e.paths.iter().any(|p| boards.is_release_file(p)) {
            let _ = files.send(Msg::ReleaseFile);
        }
        if e.paths.iter().any(|p| boards.is_build_file(p)) {
            let _ = files.send(Msg::BuildFile);
        }
        if e.paths.iter().any(|p| boards.is_board_file(p)) {
            let _ = files.send(Msg::BoardFiles);
        }
        if e.paths.iter().any(|p| app::is_queue_file(&queue, p)) {
            let _ = files.send(Msg::QueueFiles);
        }
        if e.paths.iter().any(|p| boards.is_proposal_file(p)) {
            let _ = files.send(Msg::ProposalFiles);
        }
        if e.paths.iter().any(|p| boards.is_session_file(p)) {
            let _ = files.send(Msg::SessionFiles);
        }
        if e.paths.iter().any(|p| boards.is_watch_file(p)) {
            let _ = files.send(Msg::WatchFiles);
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
    if app.tab == Tab::Home {
        app.read_home();
    }
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
    if app.tab == Tab::Alerts {
        app.read_reds();
    }
    if app.tab == Tab::Schedules {
        app.read_schedules();
    }
    if app.tab == Tab::Releases {
        app.read_releases();
    }
    // `--tab outbox` read the outbox in open_query above.
    if app.tab == Tab::Daily && !app.daily_outbox {
        app.read_focus();
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
