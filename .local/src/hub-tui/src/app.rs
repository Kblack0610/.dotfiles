//! `hub`: the state, the keys and the drawing. Reads run in worker threads and come back as
//! messages; a read asked for while one is running is coalesced into one more after it.

use std::path::{Path, PathBuf};
use std::sync::mpsc::Sender;
use std::sync::Arc;
use std::time::Duration;

use hub_core::boards::{self, DayRow, Watch};
use hub_core::infra::Infra;
use hub_core::jobs::{self, Jobs, LogRef, Opts, Paths};
use hub_core::queue::Queue;
use hub_core::session_actions::{self as actions, Action, Runner, Snapshot};
use hub_core::tasks::Feed;
use ratatui::crossterm::event::{Event, KeyCode, KeyEvent, KeyEventKind, KeyModifiers};
use ratatui::layout::{Constraint, Layout, Rect};
use ratatui::text::{Line, Span};
use ratatui::widgets::Paragraph;
use ratatui::Frame;

use crate::controls::{Ask, Controls};
use crate::fmt::{clock, Palette};
use crate::forecast::{self, Forecast};
use crate::jobs::{clean, row_id, JobsView, LogPane};
use crate::projtab::{self, ProjView};
use crate::queuetab::{self, QueueView};
use crate::tasktab::{self, TaskView};
use crate::{board, day, fleet, fleettab, focustab, hometab};

/// How often Prometheus is read again, and the job sources with no file to watch (CI, k8s,
/// timers in the journal). A genuine UI cadence: Prometheus has no push, and its rules
/// evaluate every 30-60s anyway.
pub const PROM_REFRESH: Duration = Duration::from_secs(60);
/// Under this many body lines the Projects rows keep the whole window and get no preview pane.
const PREVIEW_MIN_HEIGHT: u16 = 18;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Tab {
    Home,
    Infra,
    Sessions,
    Today,
    History,
    Fleet,
    Focus,
    Queue,
    Projects,
}

impl Tab {
    pub const ALL: [Tab; 9] = [
        Tab::Home,
        Tab::Queue,
        // Jobs' slot and key 3; `jobs`, `ci` and `machines` resolve here and 4 and 5 open its CI
        // and Machines sections, until the layout renumbers the digits once (dashboards.md).
        Tab::Infra,
        // Forecast's slot and key 6; `forecast` resolves here (hub_core::layout::RETIRED).
        Tab::Sessions,
        Tab::Today,
        Tab::History,
        Tab::Fleet,
        // No digit is free until the layout renumbers once (dashboards.md): Tab, BackTab and
        // `hub --tab focus` reach it.
        Tab::Focus,
        // Board's slot and key 0 until the layout renumbers the digits once (dashboards.md).
        Tab::Projects,
    ];
    pub fn title(self) -> &'static str {
        match self {
            Tab::Home => "Home",
            Tab::Infra => "Infra",
            Tab::Sessions => "Sessions",
            Tab::Today => "Today",
            Tab::History => "History",
            Tab::Fleet => "Fleet",
            Tab::Focus => "Focus",
            Tab::Queue => "Queue",
            Tab::Projects => "Projects",
        }
    }
    /// A tab by its title, or by a name hub-core's layout knows (an id or a retired name such as
    /// `overview`), so `hub --tab <old>` still lands.
    pub fn parse(s: &str) -> Option<Tab> {
        let by_title = |n: &str| {
            Tab::ALL
                .into_iter()
                .find(|t| t.title().eq_ignore_ascii_case(n))
        };
        by_title(s).or_else(|| hub_core::layout::resolve(s).and_then(|t| by_title(t.title)))
    }
    fn index(self) -> usize {
        Tab::ALL.iter().position(|t| *t == self).unwrap_or(0)
    }
    /// The digit that opens this tab, as the tab bar shows it.
    fn digit(self) -> char {
        DIGITS
            .iter()
            .find(|(_, t, s)| *t == self && s.is_none())
            .map_or(' ', |(d, _, _)| *d)
    }
    /// The Grafana dashboard that keeps this page's trends; the file-fed pages have none.
    fn dashboard(self) -> Option<&'static str> {
        match self {
            Tab::Home => Some("kb-command-center"),
            Tab::Infra => Some("kb-ci-runners"),
            Tab::Sessions
            | Tab::Today
            | Tab::History
            | Tab::Fleet
            | Tab::Focus
            | Tab::Queue
            | Tab::Projects => None,
        }
    }
}

/// What each digit opens: a tab, or one of its sections. The digits stay where they were
/// until the layout renumbers once (dashboards.md): 4 and 5 were CI and Machines.
const DIGITS: [(char, Tab, Option<&str>); 10] = [
    ('1', Tab::Home, None),
    ('2', Tab::Queue, None),
    ('3', Tab::Infra, None),
    ('4', Tab::Infra, Some("ci")),
    ('5', Tab::Infra, Some("machines")),
    ('6', Tab::Sessions, None),
    ('7', Tab::Today, None),
    ('8', Tab::History, None),
    ('9', Tab::Fleet, None),
    ('0', Tab::Projects, None),
];
/// How many job rows Infra's Jobs section shows; Enter opens the whole table.
const JOBS_SHOWN: usize = 8;

/// The files the Fleet, Today and History tabs are read from.
#[derive(Clone)]
pub struct BoardFiles {
    pub state: PathBuf,
    pub shepherd: PathBuf,
    pub daylog: PathBuf,
}

impl BoardFiles {
    pub fn from_env() -> BoardFiles {
        BoardFiles {
            state: boards::fleet_state(),
            shepherd: boards::shepherd_dir(),
            daylog: boards::daylog_dir(),
        }
    }
    fn watch_log(&self) -> PathBuf {
        self.shepherd.join("watch.log")
    }
    /// Whether a changed path is one the board tabs read (the shepherd dir holds other files).
    pub fn is_board_file(&self, p: &Path) -> bool {
        p == self.state
            || p == self.watch_log()
            || p.parent() == Some(self.daylog.as_path())
                && p.file_name()
                    .and_then(|n| n.to_str())
                    .and_then(|n| n.strip_suffix(".json"))
                    .is_some_and(boards::is_day)
    }
}

/// One read of the board files.
pub struct Boards {
    pub watch: Watch,
    pub days: Vec<String>,
    pub rec: Option<serde_json::Value>,
    pub hist: Vec<DayRow>,
}

impl Boards {
    pub fn read(f: &BoardFiles, day: Option<&str>) -> Boards {
        Boards {
            watch: boards::watch(&f.state, &f.watch_log()),
            days: boards::days(&f.daylog),
            rec: boards::record(&f.daylog, day),
            hist: boards::history(&f.daylog, boards::HISTORY_MAX_DAYS),
        }
    }
}

pub enum Msg {
    Input(Event),
    Tick,
    /// A job source's file changed (a run started or ended).
    Files,
    /// The fleet state, watch.log or a day record changed.
    BoardFiles,
    /// `hub tab <name> [words]` asked for a page (tabreq.rs); the words name a project to open.
    Tab(Tab, Option<String>),
    Boards(Box<Boards>),
    Infra(Box<Infra>),
    Jobs(Box<Jobs>),
    Forecast(Box<Forecast>),
    Fleet(Box<hub_core::fleet::Fleet>),
    /// A day's note through `notes show --json` (hub_core::focus), or why it failed.
    Focus(Box<Result<hub_core::focus::View, String>>),
    Log(u64, Result<String, String>),
    /// The live and parked agent sessions, for the Sessions tab's controls.
    Sessions(Box<Snapshot>),
    /// A session action ended: its output, or why it failed.
    Acted(Result<String, String>),
    /// An item file under the queue dir was written, moved or removed.
    QueueFiles,
    Queue(Box<Queue>),
    /// A queue cancel or bump ended: its output, or why it failed.
    QueueActed(Result<String, String>),
    /// `notes board --json`, or why it failed.
    Tasks(Box<Result<Feed, String>>),
    /// A board write ended: notes' output, or why it failed.
    TasksActed(Result<String, String>),
    /// `notes projects --stats --json` and the project map, for the Projects tab's cards.
    Projects(Box<projtab::Loaded>),
}

/// One background read: never two at once, and a request during one runs once after it.
#[derive(Default)]
struct Read {
    busy: bool,
    again: bool,
}

impl Read {
    /// True when the caller should start a read now.
    fn want(&mut self) -> bool {
        if self.busy {
            self.again = true;
            false
        } else {
            self.busy = true;
            true
        }
    }
    /// A read finished; true when another was asked for meanwhile.
    fn done(&mut self) -> bool {
        self.busy = false;
        std::mem::take(&mut self.again)
    }
}

pub struct App {
    pub tab: Tab,
    pub p: Palette,
    pub hosts: Vec<String>,
    pub paths: Paths,
    pub infra: Option<Infra>,
    pub jobs: Option<Jobs>,
    pub jv: JobsView,
    pub files: BoardFiles,
    pub boards: Option<Boards>,
    pub forecast: Option<Forecast>,
    pub fleet: Option<hub_core::fleet::Fleet>,
    /// The Focus tab's note; None until the first read.
    pub focus: Option<Result<hub_core::focus::View, String>>,
    /// The day the Focus tab shows (`YYYY-MM-DD`); None is today.
    pub focus_day: Option<String>,
    /// agent-queue's items and week, for the Queue tab and Home's running list and numbers.
    pub queue: Option<Queue>,
    pub qv: QueueView,
    /// agent-queue's store, watched so the Queue tab follows it; it is never read here.
    pub queue_dir: PathBuf,
    /// Every project's open rows, for the Projects tab; None until the first read.
    pub tasks: Option<Result<Feed, String>>,
    pub tv: TaskView,
    /// The Projects tab's card inputs; None until the first read.
    pub projects: Option<projtab::Loaded>,
    pub pv: ProjView,
    /// The Sessions tab's session list, selection and confirm.
    pub controls: Controls,
    /// Runs a session action's commands; tests swap in a fake.
    pub runner: Arc<dyn Runner + Send + Sync>,
    /// Reads the sessions an action may target; tests swap in a fixture.
    pub gather: fn(&dyn Runner) -> Snapshot,
    /// The day the Today tab shows; None follows the newest record.
    pub day: Option<String>,
    /// The History tab's selected row, newest first.
    pub hist_sel: usize,
    /// Where the page's sections start, from the last draw (n/N jump between them on Today and
    /// Infra), with Infra's `hub_core::layout` section names.
    sections: Vec<(&'static str, usize)>,
    /// An Infra section to scroll to once the page draws (`hub --tab ci`, key 4).
    seek: Option<&'static str>,
    /// Infra's Jobs section opened as the whole jobs table.
    pub infra_jobs: bool,
    /// Lines scrolled down on every page but Jobs.
    pub scroll: usize,
    pub quit: bool,
    tx: Sender<Msg>,
    infra_read: Read,
    jobs_read: Read,
    boards_read: Read,
    forecast_read: Read,
    fleet_read: Read,
    focus_read: Read,
    sessions_read: Read,
    queue_read: Read,
    tasks_read: Read,
    projects_read: Read,
    log_gen: u64,
    /// The body's last height, for paging.
    page: usize,
    /// Why a file watch could not be set (inotify full), shown in the tab bar.
    pub watch_failed: Option<String>,
    /// Why `hub tab` cannot reach this hub (its socket would not bind), shown in the tab bar.
    pub tab_failed: Option<String>,
}

impl App {
    pub fn new(tab: Tab, tx: Sender<Msg>) -> App {
        App {
            tab,
            p: Palette::from_env(),
            hosts: board::extra_hosts(),
            paths: Paths::from_env(),
            infra: None,
            jobs: None,
            jv: JobsView::default(),
            files: BoardFiles::from_env(),
            boards: None,
            forecast: None,
            fleet: None,
            focus: None,
            focus_day: None,
            queue: None,
            qv: QueueView::default(),
            queue_dir: queue_dir(),
            tasks: None,
            tv: TaskView::default(),
            projects: None,
            pv: ProjView::default(),
            controls: Controls::default(),
            runner: Arc::new(actions::System),
            gather: actions::gather,
            day: None,
            hist_sel: 0,
            sections: vec![],
            seek: None,
            infra_jobs: false,
            scroll: 0,
            quit: false,
            tx,
            infra_read: Read::default(),
            jobs_read: Read::default(),
            boards_read: Read::default(),
            forecast_read: Read::default(),
            fleet_read: Read::default(),
            focus_read: Read::default(),
            sessions_read: Read::default(),
            queue_read: Read::default(),
            tasks_read: Read::default(),
            projects_read: Read::default(),
            log_gen: 0,
            page: 20,
            watch_failed: None,
            tab_failed: None,
        }
    }

    /// The directories to watch: agentctl's ledger and run markers and the Unity gate ledger (a
    /// job started or ended), then the board files and agent-queue's store.
    pub fn watched(&self) -> Vec<(PathBuf, bool)> {
        let mut v = vec![
            (self.paths.agentctl.clone(), true),
            (self.files.shepherd.clone(), false),
            (self.files.daylog.clone(), false),
            (self.queue_dir.clone(), true),
        ];
        for f in [&self.paths.unity_runs, &self.files.state] {
            if let Some(d) = f.parent() {
                v.push((d.to_path_buf(), false));
            }
        }
        v
    }

    pub fn read_boards(&mut self) {
        if self.boards_read.want() {
            let tx = self.tx.clone();
            let f = self.files.clone();
            let day = self.day.clone();
            std::thread::spawn(move || {
                let _ = tx.send(Msg::Boards(Box::new(Boards::read(&f, day.as_deref()))));
            });
        }
    }

    /// fleet-bench writes no file to watch, so the Sessions tab reads it on the tick, and only
    /// while it is shown: each read is three jq passes over the progress history.
    pub fn read_forecast(&mut self) {
        if self.forecast_read.want() {
            let tx = self.tx.clone();
            std::thread::spawn(move || {
                let _ = tx.send(Msg::Forecast(Box::new(Forecast::read())));
            });
        }
    }

    /// The Fleet tab mixes Prometheus (no push) with agentctl's ledger and the dispatch and ask
    /// files, so it reads on entering, on `r`, on the tick and on an agentctl file event while
    /// it is shown.
    pub fn read_fleet(&mut self) {
        if self.fleet_read.want() {
            let tx = self.tx.clone();
            std::thread::spawn(move || {
                let _ = tx.send(Msg::Fleet(Box::new(hub_core::fleet::collect())));
            });
        }
    }

    /// Nothing here watches the vault (`notes` is its writer), so the Focus tab reads its day
    /// on entering, on a day key, on `r` and on the tick while it is shown.
    pub fn read_focus(&mut self) {
        if self.focus_read.want() {
            let tx = self.tx.clone();
            let runner = self.runner.clone();
            let target = self
                .focus_day
                .as_ref()
                .map_or("daily".to_string(), |d| format!("daily:{d}"));
            std::thread::spawn(move || {
                let _ = tx.send(Msg::Focus(Box::new(hub_core::focus::read(
                    runner.as_ref(),
                    &target,
                ))));
            });
        }
    }

    /// The session list has no one file to watch (tmux, `~/.claude/sessions`, the park
    /// ledger, agent-queue), so the Sessions tab reads it on entering, on `r`, after an action
    /// and on the 60s tick while it is shown.
    pub fn read_sessions(&mut self) {
        if self.sessions_read.want() {
            let tx = self.tx.clone();
            let (runner, gather) = (self.runner.clone(), self.gather);
            std::thread::spawn(move || {
                let _ = tx.send(Msg::Sessions(Box::new(gather(runner.as_ref()))));
            });
        }
    }

    /// Run a confirmed action in a worker: re-read the sessions, so the target and account are
    /// checked against now and not the list on screen, then plan and execute through hub-core.
    fn act(&mut self, target: String, a: Action, account: Option<String>) {
        let label = format!("{} {target}", a.name());
        self.controls.running = Some(label.clone());
        self.controls.said = None;
        let tx = self.tx.clone();
        let (runner, gather) = (self.runner.clone(), self.gather);
        std::thread::spawn(move || {
            let snap = gather(runner.as_ref());
            let r = actions::plan(
                a,
                &target,
                account.as_deref(),
                &snap.sessions(),
                &snap.accounts,
            )
            .and_then(|steps| actions::execute(&steps, runner.as_ref()));
            let r = said(&label, r);
            let _ = tx.send(Msg::Acted(r));
        });
    }

    /// The queue is read through agent-queue (hub_core::queue), never from its files: on
    /// start (Home counts it), on a write under the queue dir, on `r`, after an action,
    /// and on the tick when there is no file watch.
    pub fn read_queue(&mut self) {
        if self.queue_read.want() {
            let tx = self.tx.clone();
            let runner = self.runner.clone();
            std::thread::spawn(move || {
                let _ = tx.send(Msg::Queue(Box::new(Queue::read(runner.as_ref()))));
            });
        }
    }

    /// Run a queue cancel or bump in a worker; the answer comes back as Msg::QueueActed.
    fn queue_act(
        &mut self,
        label: String,
        f: impl FnOnce(&dyn Runner) -> Result<String, String> + Send + 'static,
    ) {
        self.qv.running = Some(label.clone());
        self.qv.said = None;
        let tx = self.tx.clone();
        let runner = self.runner.clone();
        std::thread::spawn(move || {
            let r = said(&label, f(runner.as_ref()));
            let _ = tx.send(Msg::QueueActed(r));
        });
    }

    /// The rows and the cards are read through `notes board --json` (hub_core::tasks) and
    /// `notes projects --stats --json` (hub_core::projects), never from the sheets: on entering
    /// the Projects tab, on `r`, after a write, and on the tick while shown. The vault has no
    /// watch here; `notes` is its writer.
    pub fn read_tasks(&mut self) {
        if self.tasks_read.want() {
            let tx = self.tx.clone();
            let runner = self.runner.clone();
            std::thread::spawn(move || {
                let _ = tx.send(Msg::Tasks(Box::new(hub_core::tasks::feed(runner.as_ref()))));
            });
        }
    }

    /// Both of the Projects tab's reads: the rows and the cards.
    pub fn read_projects(&mut self) {
        self.read_tasks();
        self.read_cards();
    }

    fn read_cards(&mut self) {
        if self.projects_read.want() {
            let tx = self.tx.clone();
            let runner = self.runner.clone();
            std::thread::spawn(move || {
                let _ = tx.send(Msg::Projects(Box::new(projtab::load(runner.as_ref()))));
            });
        }
    }

    /// The cards, joined from the last reads (hub_core::projects::build).
    pub fn cards(&self) -> hub_core::projects::Projects {
        let Some(l) = &self.projects else {
            return Default::default();
        };
        let stats = match &l.stats {
            Ok(s) => s.as_slice(),
            Err(e) => {
                return hub_core::projects::Projects {
                    errors: vec![e.clone()],
                    ..Default::default()
                }
            }
        };
        let feed = match &self.tasks {
            Some(Ok(f)) => Some(f),
            _ => None,
        };
        let null = serde_json::Value::Null;
        let state = self.boards.as_ref().map_or(&null, |b| &b.watch.state);
        hub_core::projects::build(stats, feed, state, self.queue.as_ref(), &l.repos)
    }

    /// Open the project a `hub tab projects <name>` named, once the cards are read.
    fn open_wanted(&mut self) {
        if self.projects.is_none() {
            return;
        }
        if let Some(name) = self.pv.want.take() {
            let cards = self.cards().cards;
            self.pv.go(&mut self.tv, &cards, &name);
            self.scroll = 0;
        }
    }

    /// Run one board write in a worker; the answer comes back as Msg::TasksActed.
    fn tasks_act(&mut self, label: String, w: hub_core::tasks::Write) {
        self.tv.running = Some(label.clone());
        self.tv.said = None;
        let tx = self.tx.clone();
        let runner = self.runner.clone();
        std::thread::spawn(move || {
            let r = said(&label, hub_core::tasks::apply(runner.as_ref(), &w));
            let _ = tx.send(Msg::TasksActed(r));
        });
    }

    pub fn read_infra(&mut self) {
        if self.infra_read.want() {
            let tx = self.tx.clone();
            std::thread::spawn(move || {
                let _ = tx.send(Msg::Infra(Box::new(hub_core::infra::gather())));
            });
        }
    }
    pub fn read_jobs(&mut self) {
        if self.jobs_read.want() {
            let tx = self.tx.clone();
            let paths = self.paths.clone();
            let opts = Opts {
                name: self.jv.history.clone(),
                ..Default::default()
            };
            std::thread::spawn(move || {
                let _ = tx.send(Msg::Jobs(Box::new(jobs::collect(&paths, &opts))));
            });
        }
    }
    fn read_log(&mut self, r: LogRef) {
        let tx = self.tx.clone();
        let paths = self.paths.clone();
        let gen = self.log_gen;
        std::thread::spawn(move || {
            let _ = tx.send(Msg::Log(gen, jobs::read_log(&paths, &r)));
        });
    }

    pub fn handle(&mut self, m: Msg) {
        match m {
            Msg::Input(Event::Key(k)) if k.kind != KeyEventKind::Release => self.key(k),
            Msg::Input(_) => {}
            Msg::Tick => {
                self.read_infra();
                self.read_jobs();
                // With no file watch, the board files are only read here.
                if self.watch_failed.is_some() {
                    self.read_boards();
                    self.read_queue();
                }
                if self.tab == Tab::Sessions {
                    self.read_forecast();
                    self.read_sessions();
                }
                if self.tab == Tab::Fleet {
                    self.read_fleet();
                }
                if self.tab == Tab::Focus {
                    self.read_focus();
                }
                if self.tab == Tab::Projects {
                    self.read_projects();
                }
            }
            Msg::Files => {
                self.read_jobs();
                if self.tab == Tab::Fleet {
                    self.read_fleet();
                }
            }
            Msg::BoardFiles => self.read_boards(),
            Msg::Tab(t, q) => {
                self.go(t);
                self.open_query(q);
            }
            Msg::Boards(b) => {
                let state = b.watch.state["sessions"].as_array().cloned();
                self.controls.read(Some(state.unwrap_or_default()), None);
                self.boards = Some(*b);
                if self.boards_read.done() {
                    self.read_boards();
                }
            }
            Msg::Forecast(f) => {
                self.controls.read(None, Some(forecast::schedule(&f)));
                self.forecast = Some(*f);
                if self.forecast_read.done() {
                    self.read_forecast();
                }
            }
            Msg::Fleet(f) => {
                self.fleet = Some(*f);
                if self.fleet_read.done() {
                    self.read_fleet();
                }
            }
            Msg::Focus(v) => {
                self.focus = Some(*v);
                if self.focus_read.done() {
                    self.read_focus();
                }
            }
            Msg::Infra(i) => {
                self.infra = Some(*i);
                if self.infra_read.done() {
                    self.read_infra();
                }
            }
            Msg::Jobs(j) => {
                let id = self.selected().map(row_id);
                self.jobs = Some(*j);
                if let Some(js) = &self.jobs {
                    self.jv.reselect(js, id);
                }
                // An open log follows its run: a refresh means the run wrote or ended.
                if self.jv.log.as_ref().is_some_and(|l| l.back == 0) {
                    if let Some(r) = self.selected().and_then(|j| j.log.clone()) {
                        self.read_log(r);
                    }
                }
                if self.jobs_read.done() {
                    self.read_jobs();
                }
            }
            Msg::Log(gen, text) => {
                if let Some(l) = self.jv.log.as_mut().filter(|l| l.gen == gen) {
                    l.text = Some(text);
                }
            }
            Msg::Sessions(s) => {
                self.controls.set(*s);
                if self.sessions_read.done() {
                    self.read_sessions();
                }
            }
            Msg::Acted(r) => {
                self.controls.running = None;
                self.controls.said = Some(r);
                self.read_sessions();
            }
            Msg::QueueFiles => self.read_queue(),
            Msg::Queue(q) => {
                let was = self
                    .queue
                    .as_ref()
                    .and_then(|old| self.qv.selected(old))
                    .map(|i| i.slug.clone());
                self.qv.reselect(was, &q);
                self.queue = Some(*q);
                if self.queue_read.done() {
                    self.read_queue();
                }
            }
            Msg::QueueActed(r) => {
                self.qv.running = None;
                self.qv.said = Some(r);
                self.read_queue();
            }
            Msg::Tasks(f) => {
                if let Ok(new) = f.as_ref() {
                    let was = match &self.tasks {
                        Some(Ok(old)) => self.tv.selected(old).cloned(),
                        _ => None,
                    };
                    self.tv.reselect(was, new);
                }
                self.tasks = Some(*f);
                if self.tasks_read.done() {
                    self.read_tasks();
                }
            }
            Msg::TasksActed(r) => {
                self.tv.running = None;
                self.tv.said = Some(r);
                self.read_projects();
            }
            Msg::Projects(l) => {
                self.projects = Some(*l);
                self.open_wanted();
                if self.projects_read.done() {
                    self.read_cards();
                }
            }
        }
    }

    fn selected(&self) -> Option<&hub_core::jobs::Job> {
        let js = self.jobs.as_ref()?;
        self.jv.shown(js).get(self.jv.sel).copied()
    }

    fn key(&mut self, k: KeyEvent) {
        if k.code == KeyCode::Char('c') && k.modifiers.contains(KeyModifiers::CONTROL) {
            self.quit = true;
            return;
        }
        if self.tab == Tab::Infra && self.infra_key(k) {
            return;
        }
        if self.tab == Tab::Today && self.today_key(k) {
            return;
        }
        if self.tab == Tab::Focus && self.focus_key(k) {
            return;
        }
        if self.tab == Tab::History && self.history_key(k) {
            return;
        }
        if self.tab == Tab::Sessions && self.sessions_key(k) {
            return;
        }
        if self.tab == Tab::Queue && self.queue_key(k) {
            return;
        }
        if self.tab == Tab::Projects && self.projects_key(k) {
            return;
        }
        let n = self.page.max(1);
        let tabs = Tab::ALL.len();
        match k.code {
            KeyCode::Char('q') => self.quit = true,
            // Each digit opens what DIGITS says, as on the tab bar.
            KeyCode::Char(c @ '0'..='9') => {
                if let Some((_, t, sec)) = DIGITS.iter().find(|(d, _, _)| *d == c) {
                    self.go(*t);
                    if let Some(sec) = sec {
                        self.open_section(sec);
                    }
                }
            }
            KeyCode::Tab => self.go(Tab::ALL[(self.tab.index() + 1) % tabs]),
            KeyCode::BackTab => self.go(Tab::ALL[(self.tab.index() + tabs - 1) % tabs]),
            KeyCode::Char('r') => {
                self.read_infra();
                self.read_jobs();
                self.read_boards();
                self.read_queue();
                if self.tab == Tab::Sessions {
                    self.read_forecast();
                    self.read_sessions();
                }
                if self.tab == Tab::Fleet {
                    self.read_fleet();
                }
                if self.tab == Tab::Focus {
                    self.read_focus();
                }
                if self.tab == Tab::Projects {
                    self.read_projects();
                }
            }
            KeyCode::Char('o') => {
                let g = self.infra.as_ref().and_then(|i| i.grafana.clone());
                if let (Some(g), Some(d)) = (g, self.tab.dashboard()) {
                    open(&format!("{}/d/{d}", g.trim_end_matches('/')));
                }
            }
            KeyCode::Char('j') | KeyCode::Down => self.scroll += 1,
            KeyCode::Char('k') | KeyCode::Up => self.scroll = self.scroll.saturating_sub(1),
            KeyCode::PageDown | KeyCode::Char(' ') => self.scroll += n,
            KeyCode::PageUp => self.scroll = self.scroll.saturating_sub(n),
            KeyCode::Char('g') | KeyCode::Home => self.scroll = 0,
            KeyCode::Char('G') | KeyCode::End => self.scroll = usize::MAX / 2,
            _ => {}
        }
    }

    /// A request's query: an Infra section on Infra, else a project name.
    pub fn open_query(&mut self, q: Option<String>) {
        match (self.tab, q) {
            (Tab::Infra, Some(q)) => {
                let secs = hub_core::layout::resolve("infra").map_or(&[][..], |t| t.sections);
                if let Some(sec) = secs.iter().find(|s| s.eq_ignore_ascii_case(q.trim())) {
                    self.open_section(sec);
                }
            }
            (_, q) => self.open_project(q),
        }
    }

    /// Show one Infra section: Jobs opens the jobs table, any other scrolls to its heading at
    /// the next draw.
    fn open_section(&mut self, sec: &'static str) {
        if sec == "jobs" {
            self.infra_jobs = true;
        } else {
            self.infra_jobs = false;
            self.seek = Some(sec);
        }
    }

    /// `hub tab projects <name>`: open that project's rows (or All searched for the name)
    /// once the cards are read; None leaves the tab as it is.
    pub fn open_project(&mut self, q: Option<String>) {
        if let Some(q) = q.filter(|q| !q.trim().is_empty()) {
            self.pv.want = Some(q.trim().to_string());
            self.open_wanted();
        }
    }

    fn go(&mut self, t: Tab) {
        self.tab = t;
        self.scroll = 0;
        self.infra_jobs = false;
        self.seek = None;
        if t == Tab::Sessions {
            self.read_forecast();
            self.read_sessions();
        }
        if t == Tab::Fleet {
            self.read_fleet();
        }
        if t == Tab::Focus {
            self.read_focus();
        }
        if t == Tab::Queue {
            self.read_queue();
        }
        if t == Tab::Projects {
            self.read_projects();
        }
    }

    /// The Projects tab's keys: the card list's (projtab.rs), or with the rows open theirs
    /// (tasktab.rs), where Esc clears a filter first and then, like Backspace, goes back.
    fn projects_key(&mut self, k: KeyEvent) -> bool {
        if !self.pv.open {
            let cards = self.cards().cards;
            return self.pv.key(&mut self.tv, k, &cards, self.page);
        }
        if self.tv.prompt.is_none() {
            let v = &self.tv;
            let filtered = !v.search.is_empty() || v.lane.is_some() || v.said.is_some();
            if k.code == KeyCode::Backspace || (k.code == KeyCode::Esc && !filtered) {
                self.pv.close(&mut self.tv);
                self.scroll = 0;
                return true;
            }
        }
        // With no rows read there is nothing to clear: Esc still goes back.
        if self.board_key(k) {
            return true;
        }
        if k.code == KeyCode::Esc && self.tv.prompt.is_none() {
            self.pv.close(&mut self.tv);
            return true;
        }
        false
    }

    /// The rows' own keys (tasktab.rs). With a prompt open every key is its; the page keeps the selected row in view (draw).
    fn board_key(&mut self, k: KeyEvent) -> bool {
        let feed = match &self.tasks {
            Some(Ok(f)) => Some(f),
            _ => None,
        };
        match self.tv.key(k, feed, self.page) {
            tasktab::Ask::Pass => false,
            tasktab::Ask::Done => true,
            tasktab::Ask::Write(label, w) => {
                self.tasks_act(label, w);
                true
            }
            tasktab::Ask::Open(sheet, line) => {
                self.tv.said = Some(edit_in_tmux(&sheet, line));
                true
            }
        }
    }

    /// The Queue tab's own keys (queuetab.rs): j/k pick an active item, c arms a cancel, +/-
    /// move its priority. The page scrolls with PgUp/PgDn, space and g/G.
    fn queue_key(&mut self, k: KeyEvent) -> bool {
        match self.qv.key(k, self.queue.as_ref()) {
            queuetab::Ask::Pass => false,
            queuetab::Ask::Done => true,
            queuetab::Ask::Cancel(slug) => {
                self.queue_act(format!("cancel {slug}"), move |r| {
                    hub_core::queue::cancel(r, &slug)
                });
                true
            }
            queuetab::Ask::Bump(slug, prio) => {
                self.queue_act(format!("bump {slug} to {prio}"), move |r| {
                    hub_core::queue::bump(r, &slug, prio)
                });
                true
            }
        }
    }

    /// The Sessions tab's keys (controls.rs): j/k pick a session, a letter arms an action's
    /// confirm, and with one armed every key is the confirm's; Enter opens the selected
    /// session's detail and f the forecast at the bottom. The page scrolls with
    /// PgUp/PgDn, space and g/G, and keeps the selected row in view.
    fn sessions_key(&mut self, k: KeyEvent) -> bool {
        match self.controls.key(k) {
            Ask::Pass => return false,
            Ask::Done => {}
            Ask::Run(t, a, acct) => self.act(t, a, acct),
        }
        // The stage counts and the table header sit above the first row.
        let at = 2 + self.controls.sel;
        let h = self.page.max(1);
        if at < self.scroll {
            self.scroll = at;
        } else if at >= self.scroll + h {
            self.scroll = at + 1 - h;
        }
        true
    }

    /// Today's own keys: `[` and `]` step a day, n and N jump between sections.
    fn today_key(&mut self, k: KeyEvent) -> bool {
        let days = self.boards.as_ref().map_or(&[][..], |b| b.days.as_slice());
        let at = match &self.day {
            Some(d) => days.iter().position(|x| x == d),
            None => days.len().checked_sub(1),
        };
        match k.code {
            KeyCode::Char('[') => {
                if let Some(i) = at.filter(|i| *i > 0) {
                    self.open_day(Some(days[i - 1].clone()));
                }
            }
            KeyCode::Char(']') => match at {
                Some(i) if i + 2 < days.len() => self.open_day(Some(days[i + 1].clone())),
                Some(i) if i + 2 == days.len() => self.open_day(None),
                _ => {}
            },
            KeyCode::Char('t') if self.day.is_some() => self.open_day(None),
            KeyCode::Char('n' | 'N') => self.next_section(k.code == KeyCode::Char('n')),
            _ => return false,
        }
        true
    }

    /// Focus's own keys: `[` and `]` step to the day before or after that has a note, `t`
    /// goes back to today.
    fn focus_key(&mut self, k: KeyEvent) -> bool {
        let note = match &self.focus {
            Some(Ok(v)) => Some(&v.note),
            _ => None,
        };
        let day = match k.code {
            KeyCode::Char('[') => note.and_then(|n| n.prev.clone()),
            KeyCode::Char(']') => note.and_then(|n| n.next.clone()),
            KeyCode::Char('t') if self.focus_day.is_some() => None,
            _ => return false,
        };
        if k.code != KeyCode::Char('t') && day.is_none() {
            return true;
        }
        // The next day with a note may be today's, which is the live view.
        let today = chrono::Local::now().format("%Y-%m-%d").to_string();
        self.focus_day = day.filter(|d| *d != today);
        self.scroll = 0;
        self.read_focus();
        true
    }

    /// Show a day on the Today tab (None: the newest, live one) and read its record.
    fn open_day(&mut self, d: Option<String>) {
        self.day = d;
        self.scroll = 0;
        if let Some(b) = self.boards.as_mut() {
            b.rec = boards::record(&self.files.daylog, self.day.as_deref());
        }
    }

    /// History's own keys: j/k pick a day, Enter opens it on the Today tab.
    fn history_key(&mut self, k: KeyEvent) -> bool {
        let n = self.boards.as_ref().map_or(0, |b| b.hist.len());
        let last = n.saturating_sub(1);
        let page = self.page.max(1);
        match k.code {
            KeyCode::Char('j') | KeyCode::Down => self.hist_sel = (self.hist_sel + 1).min(last),
            KeyCode::Char('k') | KeyCode::Up => self.hist_sel = self.hist_sel.saturating_sub(1),
            KeyCode::PageDown | KeyCode::Char(' ') => {
                self.hist_sel = (self.hist_sel + page).min(last)
            }
            KeyCode::PageUp => self.hist_sel = self.hist_sel.saturating_sub(page),
            KeyCode::Char('g') | KeyCode::Home => self.hist_sel = 0,
            KeyCode::Char('G') | KeyCode::End => self.hist_sel = last,
            KeyCode::Enter => {
                let Some(b) = &self.boards else { return true };
                // Rows are newest first; the newest is the live day.
                let Some(row) = b.hist.iter().rev().nth(self.hist_sel) else {
                    return true;
                };
                let d = (self.hist_sel > 0 || !row.live).then(|| row.date.clone());
                self.open_day(d);
                self.tab = Tab::Today;
            }
            _ => return false,
        }
        true
    }

    /// The Jobs page's own keys; false hands the key to the global ones.
    /// n and N jump to the next or the previous section heading (Today, Infra).
    fn next_section(&mut self, forward: bool) {
        let at = self.sections.iter().map(|s| s.1);
        if forward {
            if let Some(s) = at.clone().find(|s| *s > self.scroll) {
                self.scroll = s;
            }
        } else {
            self.scroll = at.rev().find(|s| *s < self.scroll).unwrap_or(0);
        }
    }

    /// Infra's own keys. The summary: n/N jump between sections, Enter and the jobs keys
    /// (/ s f h) open the jobs table. The table: the jobs keys, and Esc with nothing to clear
    /// goes back to the summary.
    fn infra_key(&mut self, k: KeyEvent) -> bool {
        if !self.infra_jobs {
            match k.code {
                KeyCode::Char('n' | 'N') => self.next_section(k.code == KeyCode::Char('n')),
                KeyCode::Enter => self.infra_jobs = true,
                KeyCode::Char('/' | 's' | 'f' | 'h') => {
                    self.infra_jobs = true;
                    return self.jobs_key(k);
                }
                _ => return false,
            }
            return true;
        }
        let jv = &self.jv;
        let root = jv.typing.is_none()
            && jv.log.is_none()
            && jv.history.is_none()
            && jv.search.is_empty()
            && jv.source.is_none()
            && jv.state == Default::default();
        if root && matches!(k.code, KeyCode::Esc | KeyCode::Backspace) {
            self.infra_jobs = false;
            return true;
        }
        self.jobs_key(k)
    }

    fn jobs_key(&mut self, k: KeyEvent) -> bool {
        if let Some(t) = self.jv.typing.as_mut() {
            match k.code {
                KeyCode::Enter => {
                    self.jv.search = self.jv.typing.take().unwrap_or_default();
                    self.jv.sel = 0;
                }
                KeyCode::Esc => {
                    self.jv.typing = None;
                    self.jv.search.clear();
                }
                KeyCode::Backspace => {
                    t.pop();
                }
                KeyCode::Char(c) => t.push(c),
                _ => {}
            }
            return true;
        }
        let rows = self.jobs.as_ref().map_or(0, |j| self.jv.shown(j).len());
        let last = rows.saturating_sub(1);
        let n = self.page.max(1);
        let jv = &mut self.jv;
        match k.code {
            KeyCode::Char('/') => jv.typing = Some(jv.search.clone()),
            KeyCode::Char('s') => jv.cycle_source(),
            KeyCode::Char('f') => jv.cycle_state(),
            KeyCode::Char('j') | KeyCode::Down => jv.sel = (jv.sel + 1).min(last),
            KeyCode::Char('k') | KeyCode::Up => jv.sel = jv.sel.saturating_sub(1),
            KeyCode::Char('g') | KeyCode::Home => jv.sel = 0,
            KeyCode::Char('G') | KeyCode::End => jv.sel = last,
            KeyCode::PageDown | KeyCode::Char('J') if jv.log.is_some() => {
                let l = jv.log.as_mut().unwrap();
                l.back = l
                    .back
                    .saturating_sub(if k.code == KeyCode::Char('J') { 1 } else { n });
            }
            KeyCode::PageUp | KeyCode::Char('K') if jv.log.is_some() => {
                let l = jv.log.as_mut().unwrap();
                l.back += if k.code == KeyCode::Char('K') { 1 } else { n };
            }
            KeyCode::PageDown => jv.sel = (jv.sel + n).min(last),
            KeyCode::PageUp => jv.sel = jv.sel.saturating_sub(n),
            KeyCode::Enter => self.open_log(),
            KeyCode::Esc => {
                if jv.log.is_some() {
                    jv.log = None;
                } else if jv.history.is_some() {
                    jv.history = None;
                    self.read_jobs();
                } else {
                    jv.search.clear();
                    jv.source = None;
                    jv.state = Default::default();
                }
            }
            KeyCode::Char('h') => {
                let name = self.selected().map(|j| j.name.clone());
                self.jv.history = if self.jv.history.is_some() {
                    None
                } else {
                    name
                };
                self.jv.sel = 0;
                self.read_jobs();
            }
            KeyCode::Char('o') => {
                if let Some(u) = self.selected().and_then(|j| j.url.clone()) {
                    open(&u);
                }
            }
            _ => return false,
        }
        true
    }

    fn open_log(&mut self) {
        let Some(j) = self.selected() else { return };
        let title = format!("{} {}", j.source.name(), j.name);
        let r = j.log.clone();
        let has_url = j.url.is_some();
        self.log_gen += 1;
        self.jv.log = Some(LogPane {
            title,
            text: if r.is_some() {
                None
            } else {
                Some(Err(if has_url {
                    "no log kept for this row; o opens it in the browser".into()
                } else {
                    "no log kept for this row".into()
                }))
            },
            back: 0,
            gen: self.log_gen,
        });
        if let Some(r) = r {
            self.read_log(r);
        }
    }

    pub fn draw(&mut self, f: &mut Frame) {
        let [bar, body, foot] = Layout::vertical([
            Constraint::Length(1),
            Constraint::Min(1),
            Constraint::Length(1),
        ])
        .areas(f.area());
        f.render_widget(Paragraph::new(self.tab_bar()), bar);
        // One project's rows get the selected row in full underneath, under a rule, in at
        // most a third of the window; a short window keeps every line for the rows.
        let preview = self.preview(body.width as usize);
        let body = match preview {
            Some(lines) if body.height >= PREVIEW_MIN_HEIGHT => {
                let h = (lines.len() as u16 + 1).min(body.height / 3);
                let [list, pane] =
                    Layout::vertical([Constraint::Min(1), Constraint::Length(h)]).areas(body);
                let mut l = vec![Line::styled("-".repeat(pane.width as usize), self.p.dim())];
                l.extend(lines);
                f.render_widget(Paragraph::new(l), pane);
                list
            }
            _ => body,
        };
        self.page = body.height.saturating_sub(2) as usize;
        if self.tab == Tab::Infra && self.infra_jobs {
            self.draw_jobs(f, body);
        } else if self.tab == Tab::History && self.boards.is_some() {
            self.draw_history(f, body);
        } else {
            let (lines, sections) = self.body(body.width as usize);
            // The Projects tab's one section is its selected card or row, kept in view.
            if let (Tab::Projects, Some(&(_, at))) = (self.tab, sections.first()) {
                let h = (body.height as usize).max(1);
                if at < self.scroll {
                    self.scroll = at.saturating_sub(2);
                } else if at >= self.scroll + h {
                    self.scroll = at + 1 - h;
                }
            }
            // A section asked for (key 4, `hub --tab ci`) is scrolled to once the page has it.
            if let Some(want) = self.seek {
                if let Some((_, at)) = sections.iter().find(|s| s.0 == want) {
                    self.scroll = *at;
                    self.seek = None;
                }
            }
            self.sections = sections;
            let max = lines.len().saturating_sub(body.height as usize);
            self.scroll = self.scroll.min(max);
            f.render_widget(Paragraph::new(lines).scroll((self.scroll as u16, 0)), body);
        }
        f.render_widget(
            Paragraph::new(Line::styled(self.hints(), self.p.dim())),
            foot,
        );
    }

    fn tab_bar(&self) -> Line<'static> {
        let mut s = vec![Span::styled(" HUB ", self.p.head())];
        for t in Tab::ALL.iter() {
            // A tab with no digit yet (Focus) shows its title alone.
            let label = match t.digit() {
                ' ' => format!(" {} ", t.title()),
                d => format!(" {d} {} ", t.title()),
            };
            s.push(if *t == self.tab {
                Span::styled(label, self.p.sel())
            } else {
                Span::raw(label)
            });
        }
        let now = jobs::now();
        if let Some(i) = &self.infra {
            s.push(Span::raw("   "));
            if i.ok {
                let v = i
                    .get("cc")
                    .iter()
                    .find(|x| x.label("__name__") == "cc:overall_status")
                    .and_then(|x| x.value);
                let (style, word) = self.p.status(v);
                s.push(Span::styled(format!(" {word} "), style));
            } else {
                s.push(Span::styled(" QUERY FAILED ", self.p.status(Some(2.0)).0));
            }
            s.push(Span::styled(
                format!("  read {}", clock(i.at as i64, now)),
                self.p.dim(),
            ));
        }
        s.push(Span::raw(format!("  {}", clock(now, now))));
        if let Some(why) = &self.watch_failed {
            s.push(Span::styled(
                format!("  no file watch ({why}): files re-read every 60s"),
                self.p.warn(),
            ));
        }
        if let Some(why) = &self.tab_failed {
            s.push(Span::styled(
                format!("  hub tab cannot reach this hub ({why})"),
                self.p.warn(),
            ));
        }
        Line::from(s)
    }

    fn hints(&self) -> String {
        let tabs = "0-9";
        match self.tab {
            Tab::Infra if !self.infra_jobs => format!(
                "n/N section  Enter jobs table  4 CI  5 Machines  j/k PgUp/PgDn scroll  r refresh  o Grafana  {tabs} tabs  q quit"
            ),
            Tab::Infra if self.jv.typing.is_some() => "type to search, Enter applies, Esc clears".into(),
            Tab::Infra if self.jv.log.is_some() => {
                "Esc close log  J/K PgUp/PgDn scroll log  j/k move  o open url  q quit".into()
            }
            Tab::Infra => format!(
                "Enter log  s source  f state  / search  h history  o open url  Esc back  r refresh  {tabs} tabs  q quit"
            ),
            Tab::Sessions if self.controls.confirm.is_some() => {
                "y/Enter yes  n/Esc no  Left/Right account (move)".into()
            }
            Tab::Sessions => format!(
                "j/k pick  Enter detail  i p u m x c a act  f forecast  PgUp/PgDn scroll  r refresh  {tabs} tabs  q quit"
            ),
            Tab::Fleet => {
                format!("{tabs}/Tab pages  j/k PgUp/PgDn scroll  r refresh  q quit")
            }
            Tab::Focus if self.focus_day.is_some() => {
                "[ ] day  t today  j/k PgUp/PgDn scroll  r refresh  Tab pages  q quit".into()
            }
            Tab::Focus => "[ ] day  j/k PgUp/PgDn scroll  r refresh  Tab pages  q quit".into(),
            Tab::Today if self.day.is_some() => {
                format!("[ ] day  t today  n/N section  j/k PgUp/PgDn scroll  {tabs} tabs  q quit")
            }
            Tab::Today => format!("[ ] day  n/N section  j/k PgUp/PgDn scroll  {tabs} tabs  q quit"),
            Tab::History => format!("j/k pick a day  Enter open it in Today  {tabs} tabs  q quit"),
            Tab::Queue if self.qv.confirm.is_some() => "y/Enter yes  n/Esc no".into(),
            Tab::Queue => format!(
                "j/k pick  c cancel  +/- priority  PgUp/PgDn scroll  r refresh  {tabs} tabs  q quit"
            ),
            Tab::Projects if self.tv.prompt.is_some() => {
                "type, Enter submits, Esc cancels".into()
            }
            Tab::Projects if self.pv.open => format!(
                "j/k pick  / search  l lane  a add  s start  d done  D unverified  x drop  X dup  m move  e edit  t/T tag  +/- release  o open  Esc clear, back  r refresh  {tabs} tabs  q quit"
            ),
            Tab::Projects => format!(
                "j/k pick  Enter open rows  / search all  r refresh  {tabs} tabs  q quit"
            ),
            _ => format!("{tabs}/Tab pages  j/k PgUp/PgDn scroll  r refresh  o Grafana  q quit"),
        }
    }

    /// The selected row in full, when one project's rows (or All) are open on Projects.
    fn preview(&self, w: usize) -> Option<Vec<Line<'static>>> {
        if self.tab != Tab::Projects || !self.pv.open {
            return None;
        }
        let Some(Ok(f)) = &self.tasks else {
            return None;
        };
        self.tv.selected(f).map(|r| tasktab::preview(r, self.p, w))
    }

    /// Infra's Jobs section: the jobs line and the first rows; Enter opens the whole table.
    fn jobs_section(&self, w: usize) -> Vec<Line<'static>> {
        let mut out = vec![Line::styled("JOBS", self.p.head())];
        let Some(js) = &self.jobs else {
            out.push(Line::styled("Reading jobs...", self.p.dim()));
            return out;
        };
        out.extend(self.jv.status(js, self.p));
        let table = self.jv.table(js, self.p, w, false);
        let rows = table.len().saturating_sub(1);
        out.extend(table.into_iter().take(1 + JOBS_SHOWN));
        out.push(Line::styled(
            format!(
                "  {} rows; Enter opens the table (/ search, s source, f state, h history, Enter log)",
                rows
            ),
            self.p.dim(),
        ));
        out
    }

    /// A page as lines (or what is being waited for), and where its sections start.
    pub fn body(&self, w: usize) -> (Vec<Line<'static>>, Vec<(&'static str, usize)>) {
        let now = jobs::now();
        let reading = |what: &str| {
            (
                vec![Line::styled(format!("Reading {what}..."), self.p.dim())],
                vec![],
            )
        };
        let (lines, sections) = match (self.tab, &self.boards, &self.infra) {
            // What needs you; the machinery is Infra's.
            (Tab::Home, b, i) => {
                let null = serde_json::Value::Null;
                let state = b.as_ref().map_or(&null, |b| &b.watch.state);
                let home = hub_core::home::build(state, self.queue.as_ref(), i.as_ref());
                (hometab::page(&home, self.p, now, w), vec![])
            }
            (Tab::Projects, ..) if !self.pv.open => match &self.projects {
                None => reading("notes projects"),
                Some(_) => {
                    let feed = match &self.tasks {
                        Some(Ok(f)) => Some(f),
                        _ => None,
                    };
                    let (l, at) = projtab::page(&self.cards(), feed, &self.pv, self.p, w);
                    (l, at.map(|a| ("", a)).into_iter().collect())
                }
            },
            // One project's card stays on top of its rows; All has none.
            (Tab::Projects, ..) => match &self.tasks {
                None => reading("notes board"),
                Some(Err(e)) => (vec![Line::styled(e.clone(), self.p.warn())], vec![]),
                Some(Ok(f)) => {
                    let mut l = vec![];
                    if let Some((profile, name)) = &self.tv.project {
                        let cards = self.cards().cards;
                        if let Some(c) = cards
                            .iter()
                            .find(|c| c.profile == *profile && c.name == *name)
                        {
                            l = projtab::card_lines(c, self.p, w);
                            l.push(Line::raw(""));
                        }
                    }
                    let top = l.len();
                    let (rows, at) = tasktab::page(f, &self.tv, self.p, w);
                    l.extend(rows);
                    (l, at.map(|a| ("", a + top)).into_iter().collect())
                }
            },
            (Tab::Queue, ..) => match &self.queue {
                None => reading("agent-queue"),
                Some(q) => (queuetab::page(q, &self.qv, self.p, now, w), vec![]),
            },
            // One row per session (its controls, stage and ETA), the selected one's detail, the
            // asks and the changes, then the forecast folded at the bottom.
            (Tab::Sessions, b, _) => {
                let table = self.controls.lines(self.p, now, w);
                let mut l = match b {
                    None => {
                        let mut l = reading("the board files").0;
                        l.extend(table);
                        l
                    }
                    Some(b) => fleet::page(&b.watch, table, self.p, now, w),
                };
                l.push(Line::raw(""));
                if self.controls.forecast {
                    l.push(Line::styled("FORECAST  f folds it", self.p.head()));
                    match &self.forecast {
                        None => l.extend(reading("fleet-bench forecast").0),
                        Some(f) => l.extend(forecast::page(f, self.p, now, w)),
                    }
                } else {
                    l.push(crate::fit::clip_line(
                        Line::styled(
                            "FORECAST  f opens the all-done band, the drain, the burn-up and the baseline",
                            self.p.head(),
                        ),
                        w,
                    ));
                }
                (l, vec![])
            }
            // The machinery that runs the sessions: accounts, runners and the judges.
            (Tab::Fleet, ..) => match &self.fleet {
                None => reading("the fleet"),
                Some(f) => (fleettab::page(f, self.p, now, w), vec![]),
            },
            // A day's Focus lanes, read-only (focustab.rs).
            (Tab::Focus, ..) => match &self.focus {
                None => reading("the daily note"),
                Some(Err(e)) => (vec![Line::styled(e.clone(), self.p.warn())], vec![]),
                Some(Ok(v)) => (focustab::page(v, self.p, w), vec![]),
            },
            (Tab::Today | Tab::History, None, _) => reading("the board files"),
            (Tab::Today, Some(b), _) => {
                let pg = day::today(b.rec.as_ref(), self.p, now, w);
                (pg.lines, pg.sections.into_iter().map(|s| ("", s)).collect())
            }
            (Tab::History, Some(b), _) => (day::history(&b.hist, self.hist_sel, self.p, w), vec![]),
            (_, _, None) => reading("Prometheus"),
            // Infra's sections in hub_core::layout order, a blank line between them.
            (_, _, Some(i)) => {
                let mut secs = board::infra(i, self.p, now, w, &self.hosts);
                let at = secs
                    .iter()
                    .position(|s| s.0 == "cloud")
                    .unwrap_or(secs.len());
                secs.insert(at, ("jobs", self.jobs_section(w)));
                let (mut l, mut at) = (vec![], vec![]);
                for (n, (name, lines)) in secs.into_iter().enumerate() {
                    if n > 0 {
                        l.push(Line::raw(""));
                    }
                    at.push((name, l.len()));
                    l.extend(lines);
                }
                (l, at)
            }
        };
        (lines, sections)
    }

    pub fn page_lines(&self, w: usize) -> Vec<Line<'static>> {
        self.body(w).0
    }

    /// The day list keeps its header and scrolls its rows to keep the selection in view.
    fn draw_history(&mut self, f: &mut Frame, area: Rect) {
        let lines = self.page_lines(area.width as usize);
        let h = (area.height as usize).saturating_sub(1).max(1);
        let n = lines.len().saturating_sub(1);
        self.hist_sel = self.hist_sel.min(n.saturating_sub(1));
        if self.hist_sel < self.scroll {
            self.scroll = self.hist_sel;
        } else if self.hist_sel >= self.scroll + h {
            self.scroll = self.hist_sel + 1 - h;
        }
        let mut out: Vec<Line> = lines.iter().take(1).cloned().collect();
        out.extend(lines.into_iter().skip(1 + self.scroll).take(h));
        f.render_widget(Paragraph::new(out), area);
    }

    fn draw_jobs(&mut self, f: &mut Frame, area: Rect) {
        let Some(js) = &self.jobs else {
            f.render_widget(
                Paragraph::new(Line::styled("Reading jobs...", self.p.dim())),
                area,
            );
            return;
        };
        let (list, log) = if self.jv.log.is_some() {
            let [a, b] = Layout::vertical([Constraint::Percentage(50), Constraint::Percentage(50)])
                .areas(area);
            (a, Some(b))
        } else {
            (area, None)
        };
        let status = self.jv.status(js, self.p);
        let table = self.jv.table(js, self.p, list.width as usize, true);
        let head = status.len() + 1;
        let h = (list.height as usize).saturating_sub(head).max(1);
        self.page = h;
        // Keep the selection in view: the table header stays, rows scroll under it.
        let jv = &mut self.jv;
        if jv.sel < jv.top {
            jv.top = jv.sel;
        } else if jv.sel >= jv.top + h {
            jv.top = jv.sel + 1 - h;
        }
        let mut lines = status;
        lines.extend(table.iter().take(1).cloned());
        lines.extend(table.into_iter().skip(1 + jv.top).take(h));
        f.render_widget(Paragraph::new(lines), list);
        if let (Some(area), Some(l)) = (log, &mut self.jv.log) {
            let h = (area.height as usize).saturating_sub(1);
            let mut lines = vec![Line::styled(
                format!("--- log: {} {}", l.title, "-".repeat(area.width as usize)),
                self.p.dim(),
            )];
            match &l.text {
                None => lines.push(Line::styled("reading...", self.p.dim())),
                Some(Err(e)) => lines.push(Line::styled(e.clone(), self.p.warn())),
                Some(Ok(t)) => {
                    let all = clean(t);
                    l.back = l.back.min(all.len().saturating_sub(h));
                    let end = all.len() - l.back;
                    let start = end.saturating_sub(h);
                    lines.extend(all[start..end].iter().map(|s| Line::raw(s.clone())));
                }
            }
            f.render_widget(Paragraph::new(lines), area);
        }
    }
}

/// Whether a watch event wrote something. notify also asks inotify for opens, and every read
/// here opens the files it watches: counted as changes, each read started the next one, back to
/// back for as long as hub ran (a full 24h journalctl each time).
pub fn is_write(k: &notify::EventKind) -> bool {
    use notify::EventKind::{Create, Modify, Remove};
    matches!(k, Create(_) | Modify(_) | Remove(_))
}

/// An action's answer as the status line says it: its output on one line, or why it failed.
fn said(label: &str, r: Result<String, String>) -> Result<String, String> {
    match r {
        Ok(out) if out.trim().is_empty() => Ok(format!("{label}: done")),
        Ok(out) => Ok(format!(
            "{label}: {}",
            out.lines().collect::<Vec<_>>().join("; ")
        )),
        Err(e) => Err(format!("{label}: {e}")),
    }
}

/// agent-queue's store, as agent-queue finds it.
fn queue_dir() -> PathBuf {
    std::env::var_os("AGENT_QUEUE_DIR")
        .filter(|d| !d.is_empty())
        .map(PathBuf::from)
        .unwrap_or_else(|| {
            PathBuf::from(std::env::var_os("HOME").unwrap_or_default()).join(".agent/queue")
        })
}

/// Whether a changed path is a queue item: agent-queue writes `<state>/<slug>.md` and
/// `done/<date>/<slug>.md`, and nothing else under the dir means a change.
pub fn is_queue_file(dir: &Path, p: &Path) -> bool {
    p.starts_with(dir) && p.extension().is_some_and(|e| e == "md")
}

/// Whether a changed path means a job started or ended (agentctl's stdout logs change all the
/// time and mean neither).
pub fn is_job_file(paths: &Paths, p: &std::path::Path) -> bool {
    p == paths.unity_runs
        || matches!(
            p.file_name().and_then(|n| n.to_str()),
            Some("runs.jsonl" | "run")
        ) && p.starts_with(&paths.agentctl)
}

/// Open a sheet at a line in `$EDITOR` (nvim when unset), in a new window of the tmux session
/// the hub runs in, so quitting the editor lands back here.
fn edit_in_tmux(sheet: &str, line: usize) -> Result<String, String> {
    if std::env::var_os("TMUX").is_none() {
        return Err(format!("not in tmux: open {sheet}:{line} by hand"));
    }
    let editor = std::env::var("EDITOR")
        .ok()
        .filter(|e| !e.trim().is_empty() && !e.contains(char::is_whitespace))
        .unwrap_or_else(|| "nvim".into());
    let ok = std::process::Command::new("tmux")
        .args(["new-window", "-n", "sheet", "--", &editor])
        .arg(format!("+{}", line.max(1)))
        .arg(sheet)
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .status()
        .is_ok_and(|s| s.success());
    if ok {
        Ok(format!("opened {sheet}:{line}"))
    } else {
        Err(format!(
            "tmux new-window failed: open {sheet}:{line} by hand"
        ))
    }
}

/// Open a URL in the desktop's browser, detached: the board never waits on it.
fn open(url: &str) {
    let _ = std::process::Command::new("xdg-open")
        .arg(url)
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .spawn();
}

#[cfg(test)]
mod tests {
    use super::*;
    use ratatui::backend::TestBackend;
    use ratatui::Terminal;

    /// Records every argv it is asked to run and runs none, so no test reaches tmux,
    /// claude-acct or agent-queue.
    #[derive(Default)]
    struct Fake(std::sync::Mutex<Vec<String>>);

    impl Runner for Fake {
        fn run(&self, argv: &[String]) -> Result<String, String> {
            self.0.lock().unwrap().push(argv.join(" "));
            Ok(String::new())
        }
    }

    fn no_sessions(_: &dyn Runner) -> Snapshot {
        Snapshot {
            agents: vec![],
            accounts: vec![],
        }
    }

    fn fixture_sessions(_: &dyn Runner) -> Snapshot {
        crate::controls::tests::fixture()
    }

    fn app(tab: Tab) -> App {
        let (tx, _rx) = std::sync::mpsc::channel();
        with_tx(tab, tx)
    }

    fn with_tx(tab: Tab, tx: Sender<Msg>) -> App {
        let mut a = App::new(tab, tx);
        a.p = Palette { no_color: true };
        a.hosts = vec!["workstation".into()];
        a.runner = Arc::new(Fake::default());
        a.gather = no_sessions;
        a
    }

    /// The fleet-sessions fixture with the controls fixture's live session in it, so one row
    /// joins both and the parked one is the snapshot's alone.
    fn boards() -> Boards {
        let mut watch = fleet::tests::fixture();
        watch.state["sessions"][1]["target"] = "lab/dotfiles-agent-3:2".into();
        Boards {
            watch,
            days: vec![],
            rec: None,
            hist: vec![],
        }
    }

    #[test]
    fn the_sessions_tab_is_one_row_per_session_with_a_confirm() {
        let mut a = app(Tab::Sessions);
        a.controls.set(crate::controls::tests::fixture());
        let s = screen(&mut a, 140, 30);
        let lines: Vec<&str> = s.lines().collect();
        assert!(lines[0].contains("6 Sessions"), "{s}");
        assert!(lines[1].contains("Reading the board files..."), "{s}");
        assert!(
            lines[2].starts_with("SESSION") && lines[2].contains("ACCOUNT"),
            "{s}"
        );
        for want in [
            "dotfiles-agent-3:2",
            "here",
            "idle",
            "bnb",
            "new-curious-garden",
            "a1",
        ] {
            assert!(
                lines[3].contains(want),
                "{want} missing from {:?}",
                lines[3]
            );
        }
        assert!(
            lines[4].contains("dotfiles-agent-9") && lines[4].contains("parked"),
            "{s}"
        );
        assert!(s.contains("FORECAST  f opens"), "{s}");
        assert!(
            lines[29].contains("j/k pick  Enter detail  i p u m x c a act"),
            "{s}"
        );

        // The stages join by target: the NEEDS row is the live session, and it sorts first.
        a.handle(Msg::Boards(Box::new(boards())));
        let s = screen(&mut a, 160, 30);
        let lines: Vec<&str> = s.lines().collect();
        assert!(
            lines[1].starts_with("SESSIONS  2  NEEDS 1  WORKING 1"),
            "{s}"
        );
        let row = lines[3];
        for want in ["dotfiles-agent-3:2", "NEEDS", "here", "bnb", "a1"] {
            assert!(row.contains(want), "{want} missing from {row:?}");
        }
        assert!(
            lines[4].contains("unity-core-playground-agent-10") && lines[4].contains("WORKING")
        );
        assert!(
            lines[5].contains("dotfiles-agent-9") && lines[5].contains("parked"),
            "{s}"
        );
        assert!(s.contains("ASKS (1)") && s.contains("CHANGES"), "{s}");

        a.handle(key('x'));
        let s = screen(&mut a, 140, 30);
        assert!(
            s.contains(
                "Stop lab/dotfiles-agent-3:2? It will type /exit and close its tmux window."
            ),
            "{s}"
        );
        assert!(
            s.lines().last().unwrap().contains("y/Enter yes  n/Esc no"),
            "{s}"
        );
        // Tab is the confirm's while one is armed, not the next page.
        a.handle(Msg::Input(Event::Key(KeyEvent::from(KeyCode::Tab))));
        assert_eq!(a.tab, Tab::Sessions);
        a.handle(Msg::Input(Event::Key(KeyEvent::from(KeyCode::Esc))));
        assert!(a.controls.confirm.is_none());
        assert!(!screen(&mut a, 140, 30).contains("Stop lab/"));

        // A row fleet-sessions has but no live session here offers nothing.
        a.handle(key('j'));
        a.handle(key('x'));
        assert!(a.controls.confirm.is_none());
        assert!(
            screen(&mut a, 160, 30).contains("is not a live or parked session on this machine"),
            "{s}"
        );
    }

    #[test]
    fn enter_opens_the_selected_sessions_detail_and_its_timeline() {
        let mut a = app(Tab::Sessions);
        a.handle(Msg::Boards(Box::new(boards())));
        a.handle(Msg::Forecast(Box::new(forecast::tests::fixture())));
        a.handle(key('j'));
        assert!(!screen(&mut a, 200, 60).contains("DETAIL"));
        a.handle(Msg::Input(Event::Key(KeyEvent::from(KeyCode::Enter))));
        let s = screen(&mut a, 200, 80);
        assert!(
            s.contains("DETAIL  lab/unity-core-playground-agent-10:1"),
            "{s}"
        );
        for want in ["3 behind", "2 ahead", "test 10m", "cargo test", "feat/x"] {
            assert!(s.contains(want), "{want} missing from\n{s}");
        }
        assert!(s.contains("TIMELINE"), "{s}");
        a.handle(Msg::Input(Event::Key(KeyEvent::from(KeyCode::Esc))));
        assert!(!screen(&mut a, 200, 60).contains("DETAIL"));
    }

    #[test]
    fn the_forecast_folds_at_the_bottom_of_sessions_and_its_etas_are_the_rows() {
        let mut a = app(Tab::Sessions);
        let mut b = boards();
        b.watch.state["sessions"][0]["target"] = "hub/dotfiles:8".into();
        a.handle(Msg::Boards(Box::new(b)));
        assert!(!screen(&mut a, 200, 60).contains("not draining"));
        a.handle(Msg::Forecast(Box::new(forecast::tests::fixture())));
        let s = screen(&mut a, 200, 60);
        assert!(s.contains("late 5h35m"), "the forecast's ETA wins: {s}");
        a.handle(key('f'));
        let s = screen(&mut a, 200, 120);
        assert!(s.contains("not draining (in 10.63/h, out 6.88/h)"), "{s}");
        assert!(s.contains("BURN-UP 24h"), "{s}");
    }

    #[test]
    fn a_confirmed_move_runs_claude_acct_through_hub_core() {
        let (tx, rx) = std::sync::mpsc::channel();
        let mut a = with_tx(Tab::Sessions, tx);
        let fake = Arc::new(Fake::default());
        a.runner = fake.clone();
        a.gather = fixture_sessions;
        a.controls.set(crate::controls::tests::fixture());
        a.handle(key('m'));
        assert!(fake.0.lock().unwrap().is_empty(), "nothing runs before y");
        a.handle(Msg::Input(Event::Key(KeyEvent::from(KeyCode::Right))));
        a.handle(key('y'));
        assert_eq!(
            a.controls.running.as_deref(),
            Some("move lab/dotfiles-agent-3:2")
        );
        // The worker sends Acted when the action ends: wait for that message, not a timer.
        loop {
            match rx.recv().unwrap() {
                Msg::Acted(r) => {
                    a.handle(Msg::Acted(r));
                    break;
                }
                m => a.handle(m),
            }
        }
        assert_eq!(
            a.controls.said,
            Some(Ok("move lab/dotfiles-agent-3:2: done".into()))
        );
        let ran = fake.0.lock().unwrap().clone();
        assert!(
            ran.contains(&"claude-acct move dotfiles-agent-3 --server lab --to alt".to_string()),
            "{ran:?}"
        );
        assert!(ran.iter().all(|c| !c.starts_with("tmux")), "{ran:?}");
    }

    #[test]
    fn two_opens_the_queue_tab_and_home_counts_the_queue() {
        let mut a = app(Tab::Home);
        assert!(screen(&mut a, 140, 30).contains("Prometheus: reading"));
        a.handle(Msg::Queue(Box::new(queuetab::tests::fixture())));
        let s = screen(&mut a, 140, 30);
        let lines: Vec<&str> = s.lines().collect();
        assert!(
            lines[0].contains("1 Home  2 Queue  3 Infra  6 Sessions"),
            "{s}"
        );
        assert!(
            s.contains("NUMBERS  queue 1 running, 2 up next (1 held) | done today 1"),
            "{s}"
        );
        assert!(s.contains("RUNNING (1)"), "{s}");

        a.handle(key('2'));
        assert_eq!(a.tab, Tab::Queue);
        let s = screen(&mut a, 140, 30);
        assert!(
            s.contains("WAITING FOR YOU  1") && s.contains("UP NEXT  2"),
            "{s}"
        );
        assert!(
            s.lines().last().unwrap().contains("c cancel  +/- priority"),
            "{s}"
        );
        a.handle(key('1'));
        assert_eq!(a.tab, Tab::Home);
    }

    #[test]
    fn a_confirmed_cancel_runs_agent_queue_through_hub_core() {
        let (tx, rx) = std::sync::mpsc::channel();
        let mut a = with_tx(Tab::Queue, tx);
        let fake = Arc::new(Fake::default());
        a.runner = fake.clone();
        a.handle(Msg::Queue(Box::new(queuetab::tests::fixture())));
        a.handle(key('c'));
        assert!(fake.0.lock().unwrap().is_empty(), "nothing runs before y");
        assert!(screen(&mut a, 140, 30).contains("Cancel pick-sides?"));
        a.handle(key('y'));
        assert_eq!(a.qv.running.as_deref(), Some("cancel pick-sides"));
        // The worker sends QueueActed when agent-queue ends: wait for it, not a timer.
        loop {
            match rx.recv().unwrap() {
                Msg::QueueActed(r) => {
                    a.handle(Msg::QueueActed(r));
                    break;
                }
                m => a.handle(m),
            }
        }
        assert_eq!(a.qv.said, Some(Ok("cancel pick-sides: done".into())));
        let ran = fake.0.lock().unwrap().clone();
        // The re-read after it may already be running agent-queue list.
        assert_eq!(
            ran.first().map(String::as_str),
            Some("agent-queue cancel pick-sides")
        );
        assert_eq!(ran.iter().filter(|c| c.contains("cancel")).count(), 1);
    }

    /// The cards for tasktab's fixture feed: bnb/demo and personal/garden.
    fn loaded() -> projtab::Loaded {
        let stat = |profile: &str, name: &str, done: u32, open: u32| hub_core::projects::Stats {
            profile: profile.into(),
            name: name.into(),
            stage: "alpha".into(),
            version: Some("v0.1.0".into()),
            progress: hub_core::projects::Progress {
                open,
                done,
                open_weight: open,
                done_weight: done,
                closed_28d: 1,
                closed_weight_28d: 1,
                ..Default::default()
            },
            ..Default::default()
        };
        projtab::Loaded {
            stats: Ok(vec![
                stat("personal", "garden", 1, 1),
                stat("bnb", "demo", 1, 3),
            ]),
            repos: Default::default(),
        }
    }

    /// Answer the reads entering the tab started (the fake prints nothing): wait for both.
    fn settle(a: &mut App, rx: &std::sync::mpsc::Receiver<Msg>) {
        let (mut tasks, mut cards) = (false, false);
        while !(tasks && cards) {
            let m = rx.recv().unwrap();
            tasks |= matches!(m, Msg::Tasks(_));
            cards |= matches!(m, Msg::Projects(_));
            a.handle(m);
        }
    }

    #[test]
    fn the_projects_tab_lists_cards_then_opens_one_projects_rows_under_its_card() {
        let (tx, rx) = std::sync::mpsc::channel();
        let mut a = with_tx(Tab::Home, tx);
        let fake = Arc::new(Fake::default());
        a.runner = fake.clone();
        assert_eq!(Tab::parse("board"), Some(Tab::Projects), "board is retired");
        // Projects has Board's slot and key: every other digit keeps its meaning.
        a.handle(key('0'));
        assert_eq!(a.tab, Tab::Projects);
        let s = screen(&mut a, 140, 30);
        let bar = s.lines().next().unwrap();
        assert!(
            bar.contains("3 Infra") && bar.contains("9 Fleet  Focus  0 Projects"),
            "{s}"
        );
        assert!(s.contains("Reading notes projects..."), "{s}");
        settle(&mut a, &rx);
        assert!(screen(&mut a, 140, 30).contains("notes projects --stats --json"));

        a.handle(Msg::Tasks(Box::new(Ok(crate::tasktab::tests::fixture()))));
        a.handle(Msg::Projects(Box::new(loaded())));
        let s = screen(&mut a, 140, 30);
        let at = |t: &str| s.find(t).unwrap_or_else(|| panic!("{t} missing:\n{s}"));
        assert!(
            at("ALL PROJECTS  5 open rows") < at("DEMO  bnb, alpha"),
            "{s}"
        );
        assert!(
            at("DEMO  bnb, alpha") < at("GARDEN  personal, alpha"),
            "by name when none is in flight"
        );
        assert!(s.contains("v0.1.0 25% (1 of 4 by size)"), "{s}");
        assert!(s.lines().last().unwrap().contains("Enter open rows"), "{s}");

        // The card's numbers stay on top of its rows.
        a.handle(key('j'));
        a.handle(Msg::Input(Event::Key(KeyEvent::from(KeyCode::Enter))));
        assert_eq!(a.tv.project, Some(("bnb".into(), "demo".into())));
        let s = screen(&mut a, 140, 30);
        assert!(
            at_line(&s, "DEMO  bnb, alpha") < at_line(&s, "OPEN ROWS  3 open rows"),
            "{s}"
        );
        assert!(!s.contains("water the beds"), "only demo's rows:\n{s}");
        assert!(s.lines().last().unwrap().contains("t/T tag"), "{s}");
        // The selected row in full sits under the rows, above the keys.
        assert!(
            at_line(&s, "OPEN ROWS") < at_line(&s, "no id  bnb/demo  human  v0.1.0  open  urgent"),
            "{s}"
        );
        assert!(
            at_line(&s, "sheet  /v/bnb/demo/human.md:0") < s.lines().count() - 1,
            "{s}"
        );

        a.handle(key('q'));
        assert!(a.quit, "q quits with no prompt open");
        a.quit = false;
        a.handle(key('x'));
        for c in "stale".chars() {
            a.handle(key(c));
        }
        a.handle(Msg::Input(Event::Key(KeyEvent::from(KeyCode::Enter))));
        assert_eq!(a.tv.running.as_deref(), Some("drop in bnb/demo"));
        loop {
            match rx.recv().unwrap() {
                Msg::TasksActed(r) => {
                    a.handle(Msg::TasksActed(r));
                    break;
                }
                m => a.handle(m),
            }
        }
        assert_eq!(a.tv.said, Some(Ok("drop in bnb/demo: done".into())));
        let ran = fake.0.lock().unwrap().clone();
        assert!(
            ran.contains(
                &"notes ptask demo --profile bnb --exact drop --why stale -- - [ ] fix the menu"
                    .to_string()
            ),
            "{ran:?}"
        );

        // Esc clears what is said first, then goes back to the cards on the card it opened.
        let esc = || Msg::Input(Event::Key(KeyEvent::from(KeyCode::Esc)));
        a.handle(esc());
        assert!(a.pv.open && a.tv.said.is_none());
        a.handle(esc());
        assert!(!a.pv.open);
        assert_eq!(a.pv.card, 1);

        // All keeps the cross-project board, the last row scrolled into view.
        a.handle(key('g'));
        a.handle(Msg::Input(Event::Key(KeyEvent::from(KeyCode::Enter))));
        assert_eq!(a.tv.project, None);
        for _ in 0..4 {
            a.handle(key('j'));
        }
        let s = screen(&mut a, 140, 12);
        assert!(
            s.contains("water the beds"),
            "the last row scrolled into view:\n{s}"
        );
        assert!(!s.contains("PROJECTS  2 projects"), "{s}");
        assert!(
            !s.contains("sheet  /v/"),
            "a short window has no preview:\n{s}"
        );

        // `hub tab projects garden` opens garden's rows.
        a.handle(Msg::Tab(Tab::Projects, Some("garden".into())));
        assert_eq!(a.tv.project, Some(("personal".into(), "garden".into())));
        a.handle(Msg::Input(Event::Key(KeyEvent::from(KeyCode::Tab))));
        a.handle(Msg::Input(Event::Key(KeyEvent::from(KeyCode::BackTab))));
        assert_eq!(a.tab, Tab::Projects, "the last tab");
    }

    fn at_line(s: &str, t: &str) -> usize {
        s.lines()
            .position(|l| l.contains(t))
            .unwrap_or_else(|| panic!("{t} missing:\n{s}"))
    }

    #[test]
    fn only_an_item_file_under_the_queue_dir_is_a_queue_change() {
        let d = Path::new("/q");
        assert!(is_queue_file(d, Path::new("/q/queued/fix-it.md")));
        assert!(is_queue_file(d, Path::new("/q/done/2026-11-03/fix-it.md")));
        assert!(!is_queue_file(d, Path::new("/q/queued/.fix-it.tmp")));
        assert!(!is_queue_file(d, Path::new("/elsewhere/queued/fix-it.md")));
    }

    fn screen(a: &mut App, w: u16, h: u16) -> String {
        let mut t = Terminal::new(TestBackend::new(w, h)).unwrap();
        t.draw(|f| a.draw(f)).unwrap();
        let buf = t.backend().buffer().clone();
        (0..h)
            .map(|y| {
                (0..w)
                    .map(|x| buf[(x, y)].symbol().to_string())
                    .collect::<String>()
            })
            .collect::<Vec<_>>()
            .join("\n")
    }

    #[test]
    fn home_draws_what_needs_you_and_green_collapses() {
        let mut a = app(Tab::Home);
        a.infra = Some(board::tests::fixture());
        let s = screen(&mut a, 120, 40);
        let first = s.lines().next().unwrap();
        assert!(
            first.contains("1 Home") && first.contains("3 Infra") && first.contains(" RED "),
            "{s}"
        );
        let at = |t: &str| s.find(t).unwrap_or_else(|| panic!("{t} missing: {s}"));
        // cc:red_now is a need; the strip draws only what is not green.
        assert!(at("NEEDS YOU (1)") < at("watch mac_studio_mlx"));
        assert!(s.contains("ci NODATA") && s.contains("llm RED") && s.contains("1 green"));
        assert!(!s.contains("k3s OK"), "{s}");
        assert!(!s.contains("MACHINES"), "the machinery is Infra's: {s}");
        assert!(s.lines().last().unwrap().contains("r refresh"));
    }

    #[test]
    fn a_retired_tab_name_opens_its_new_home() {
        assert_eq!(Tab::parse("overview"), Some(Tab::Home));
        assert_eq!(Tab::parse("waiting"), Some(Tab::Home));
        assert_eq!(Tab::parse("ci"), Some(Tab::Infra));
        assert_eq!(Tab::parse("machines"), Some(Tab::Infra));
        assert_eq!(Tab::parse("jobs"), Some(Tab::Infra));
        assert_eq!(Tab::parse("forecast"), Some(Tab::Sessions));
        assert_eq!(Tab::parse("watch"), Some(Tab::Sessions));
        assert_eq!(Tab::parse("shepherd"), Some(Tab::Sessions));
    }

    #[test]
    fn the_landed_layout_tabs_lead_in_hub_core_order() {
        // docs/dashboards.md rule 8: both surfaces list hub_core::layout's landed tabs in its order.
        // Rule 13's interim: until the layout renumbers the digits once, a landed tab that
        // replaced one keeps that tab's key, so it sits out the order check: Projects is
        // Board's 0, Sessions Forecast's 6 and Infra Jobs' 3 (4 and 5 open its CI and Machines).
        let interim = [
            (Tab::Projects, '0'),
            (Tab::Sessions, '6'),
            (Tab::Infra, '3'),
        ];
        for (t, d) in interim {
            assert_eq!(t.digit(), d, "{} left its interim key", t.title());
        }
        let titles: Vec<&str> = Tab::ALL.iter().map(|t| t.title()).collect();
        let mut at = 0;
        for t in hub_core::layout::landed() {
            let i = titles
                .iter()
                .position(|x| *x == t.title)
                .unwrap_or_else(|| panic!("{} is landed but not a TUI tab", t.title));
            if interim.iter().any(|(x, _)| x.title() == t.title) {
                continue;
            }
            assert!(i >= at, "{} is out of layout order: {titles:?}", t.title);
            at = i;
        }
    }

    #[test]
    fn the_focus_tab_reads_today_then_steps_a_day_with_its_keys() {
        let (tx, rx) = std::sync::mpsc::channel();
        let mut a = with_tx(Tab::Home, tx);
        let fake = Arc::new(Fake::default());
        a.runner = fake.clone();
        assert_eq!(Tab::parse("focus"), Some(Tab::Focus));
        a.handle(Msg::Tab(Tab::Focus, None));
        // The fake answers nothing, so the read fails, and says why.
        let first = rx.recv().unwrap();
        a.handle(first);
        assert!(
            screen(&mut a, 100, 20).contains("notes show --json"),
            "the error is drawn"
        );
        let note = hub_core::focus::Note {
            exists: true,
            date: Some("2026-11-05".into()),
            prev: Some("2026-11-04".into()),
            markdown: "## Focus\n### Urgent\n- [ ] fix the menu\n".into(),
            ..Default::default()
        };
        a.handle(Msg::Focus(Box::new(Ok(hub_core::focus::build(note)))));
        let s = screen(&mut a, 100, 20);
        assert!(
            s.contains("FOCUS 2026-11-05  1 open, 0 done") && s.contains("[ ] fix the menu"),
            "{s}"
        );
        a.handle(key('['));
        assert_eq!(a.focus_day.as_deref(), Some("2026-11-04"));
        // Each answer is handled, as the loop would, so the read is free for the next key.
        let m = rx.recv().unwrap();
        a.handle(m);
        a.handle(key('t'));
        assert_eq!(a.focus_day, None);
        let m = rx.recv().unwrap();
        a.handle(m);
        let ran = fake.0.lock().unwrap().clone();
        assert_eq!(
            ran,
            [
                "notes show --json -- daily",
                "notes show --json -- daily:2026-11-04",
                "notes show --json -- daily"
            ]
        );
    }

    #[test]
    fn the_fleet_tab_draws_the_workers_and_judges() {
        let mut a = app(Tab::Fleet);
        assert!(screen(&mut a, 120, 10).contains("Reading the fleet..."));
        a.handle(Msg::Fleet(Box::new(fleettab::tests::fixture())));
        let s = screen(&mut a, 160, 40);
        assert!(s.lines().next().unwrap().contains("9 Fleet"), "{s}");
        for want in [
            "CLAUDE ACCOUNTS",
            "WORKERS",
            "DISPATCH JUDGE",
            "ANSWER JUDGE",
        ] {
            assert!(s.contains(want), "{want} missing from\n{s}");
        }
    }

    #[test]
    fn before_the_first_answer_it_says_it_is_reading() {
        let mut a = app(Tab::Infra);
        assert!(screen(&mut a, 80, 10).contains("Reading Prometheus..."));
        a.infra_jobs = true;
        assert!(screen(&mut a, 80, 10).contains("Reading jobs..."));
    }

    #[test]
    fn a_failed_fleet_bench_draws_the_fallbacks() {
        let mut a = app(Tab::Sessions);
        let f = Forecast::read_with("hub-test-no-such-fleet-bench");
        a.handle(Msg::Forecast(Box::new(f)));
        a.handle(key('f'));
        let s = screen(&mut a, 160, 20);
        assert!(
            s.contains("No forecast: hub-test-no-such-fleet-bench"),
            "{s}"
        );
        assert!(
            s.contains("no baseline yet: fleet-bench forecast --baseline <label>"),
            "{s}"
        );
    }

    /// Infra with its Jobs section open as the whole table.
    fn jobs_app() -> App {
        let mut a = app(Tab::Infra);
        a.infra_jobs = true;
        a
    }

    fn key(c: char) -> Msg {
        Msg::Input(Event::Key(KeyEvent::from(KeyCode::Char(c))))
    }

    #[test]
    fn a_tab_request_switches_the_running_board() {
        let mut a = app(Tab::Home);
        // Entering Fleet and Sessions read the fleet and fleet-bench; mark them already reading
        // so no test runs them.
        a.fleet_read.busy = true;
        a.forecast_read.busy = true;
        a.handle(Msg::Tab(Tab::Fleet, None));
        assert_eq!(a.tab, Tab::Fleet);
        a.handle(key('6'));
        assert_eq!(a.tab, Tab::Sessions);
        a.handle(key('7'));
        assert_eq!(a.tab, Tab::Today);
    }

    #[test]
    fn a_failed_watch_or_socket_is_on_screen_and_the_tick_reads_the_boards() {
        let mut a = app(Tab::Fleet);
        assert!(!screen(&mut a, 160, 6).contains("no file watch"));
        a.watch_failed = Some("inotify full".into());
        a.tab_failed = Some("path must be shorter than SUN_LEN".into());
        let s = screen(&mut a, 240, 6);
        let bar = s.lines().next().unwrap();
        assert!(bar.contains("no file watch (inotify full)"), "{s}");
        assert!(
            bar.contains("hub tab cannot reach this hub (path must"),
            "{s}"
        );
        // Prometheus and the job sources are not what this checks: mark them already reading.
        a.infra_read.busy = true;
        a.jobs_read.busy = true;
        a.fleet_read.busy = true;
        a.handle(Msg::Tick);
        assert!(a.boards_read.busy, "the tick stands in for the watch");
    }

    fn infra_app() -> App {
        let mut a = app(Tab::Home);
        a.infra = Some(board::tests::fixture());
        a.jobs = Some(Jobs {
            at: 0,
            window_secs: 86400,
            jobs: vec![hub_core::jobs::Job::new(
                hub_core::jobs::Source::Ci,
                "gate",
                hub_core::jobs::State::Done,
            )],
            errors: vec![],
        });
        a
    }

    /// The first body line under the tab bar.
    fn top(s: &str) -> &str {
        s.lines().nth(1).unwrap_or("")
    }

    #[test]
    fn hub_tab_ci_lands_on_infras_ci_section() {
        let mut a = infra_app();
        let (t, q) = crate::tabreq::parse("ci").unwrap();
        a.handle(Msg::Tab(t, q));
        let s = screen(&mut a, 160, 30);
        assert_eq!(a.tab, Tab::Infra);
        assert!(top(&s).starts_with("CI  running 3"), "{s}");
        // Machines the same way, and n/N step between the section headings from there.
        let (t, q) = crate::tabreq::parse("machines").unwrap();
        a.handle(Msg::Tab(t, q));
        let s = screen(&mut a, 160, 30);
        assert!(top(&s).starts_with("MACHINE "), "{s}");
        a.handle(key('n'));
        assert!(top(&screen(&mut a, 160, 30)).starts_with("CI  running"));
        a.handle(key('N'));
        assert!(top(&screen(&mut a, 160, 30)).starts_with("MACHINE "));
    }

    #[test]
    fn infra_reads_health_red_machines_ci_jobs_cloud_governor_in_order() {
        let mut a = infra_app();
        a.handle(key('3'));
        let s = screen(&mut a, 160, 200);
        let bar = s.lines().next().unwrap();
        assert!(
            bar.contains("3 Infra  6 Sessions") && !bar.contains("Machines"),
            "{s}"
        );
        assert!(top(&s).starts_with("HEALTH"), "{s}");
        let at = |t: &str| s.find(t).unwrap_or_else(|| panic!("{t} missing: {s}"));
        let order = [
            "HEALTH",
            "RED NOW",
            "MACHINE ",
            "CI  running",
            "JOBS",
            "CLOUD RUNNERS",
            "GOVERNOR",
        ];
        for w in order.windows(2) {
            assert!(at(w[0]) < at(w[1]), "{} after {}: {s}", w[0], w[1]);
        }
        assert!(s.contains("Enter opens the table"), "{s}");
    }

    #[test]
    fn enter_opens_the_jobs_table_and_esc_comes_back() {
        let mut a = infra_app();
        a.handle(key('3'));
        a.handle(Msg::Input(Event::Key(KeyEvent::from(KeyCode::Enter))));
        assert!(a.infra_jobs);
        let s = screen(&mut a, 120, 20);
        assert!(top(&s).starts_with("all sources"), "{s}");
        assert!(s.lines().last().unwrap().contains("Esc back"), "{s}");
        // A filter clears first; the next Esc goes back to the summary.
        a.handle(key('f'));
        a.handle(Msg::Input(Event::Key(KeyEvent::from(KeyCode::Esc))));
        assert!(a.infra_jobs);
        a.handle(Msg::Input(Event::Key(KeyEvent::from(KeyCode::Esc))));
        assert!(!a.infra_jobs);
        // `hub --tab jobs` opens the table straight away.
        let (t, q) = crate::tabreq::parse("jobs").unwrap();
        a.handle(Msg::Tab(t, q));
        assert!(a.infra_jobs);
    }

    #[test]
    fn number_keys_switch_pages_and_q_quits() {
        let mut a = app(Tab::Home);
        let key = |c| Msg::Input(Event::Key(KeyEvent::from(KeyCode::Char(c))));
        a.handle(key('4'));
        assert_eq!((a.tab, a.seek), (Tab::Infra, Some("ci")));
        a.handle(key('5'));
        assert_eq!((a.tab, a.seek), (Tab::Infra, Some("machines")));
        a.handle(Msg::Input(Event::Key(KeyEvent::from(KeyCode::Tab))));
        assert_eq!(a.tab, Tab::Sessions);
        a.handle(key('q'));
        assert!(a.quit);
    }

    #[test]
    fn only_a_run_starting_or_ending_wakes_the_jobs_page() {
        let a = app(Tab::Infra);
        let st = &a.paths.agentctl;
        assert!(is_job_file(&a.paths, &st.join("runs.jsonl")));
        assert!(is_job_file(&a.paths, &st.join("dream/run")));
        assert!(!is_job_file(&a.paths, &st.join("dream.stdout.log")));
        assert!(is_job_file(&a.paths, &a.paths.unity_runs));
    }

    #[test]
    fn a_read_opening_a_watched_file_is_not_a_change() {
        use notify::event::{AccessKind, AccessMode, CreateKind, DataChange, ModifyKind};
        use notify::event::{RemoveKind, RenameMode};
        use notify::EventKind;
        assert!(!is_write(&EventKind::Access(AccessKind::Open(
            AccessMode::Any
        ))));
        assert!(!is_write(&EventKind::Access(AccessKind::Close(
            AccessMode::Read
        ))));
        assert!(is_write(&EventKind::Modify(ModifyKind::Data(
            DataChange::Any
        ))));
        assert!(is_write(&EventKind::Modify(ModifyKind::Name(
            RenameMode::To
        ))));
        assert!(is_write(&EventKind::Create(CreateKind::File)));
        assert!(is_write(&EventKind::Remove(RemoveKind::File)));
    }

    #[test]
    fn a_read_asked_for_during_one_runs_once_after_it() {
        let mut r = Read::default();
        assert!(r.want());
        assert!(!r.want());
        assert!(!r.want());
        assert!(r.done(), "one more read for the asks that came during it");
        assert!(!r.done(), "and only one");
    }

    #[test]
    fn a_log_with_no_reference_says_so_instead_of_reading() {
        let mut a = jobs_app();
        let mut j = hub_core::jobs::Job::new(
            hub_core::jobs::Source::Ci,
            "gate",
            hub_core::jobs::State::Done,
        );
        j.url = Some("https://example.test/run/1".into());
        a.jobs = Some(Jobs {
            at: 0,
            window_secs: 86400,
            jobs: vec![j],
            errors: vec![],
        });
        a.handle(Msg::Input(Event::Key(KeyEvent::from(KeyCode::Enter))));
        let s = screen(&mut a, 100, 20);
        assert!(s.contains("--- log: ci gate"), "{s}");
        assert!(s.contains("o opens it in the browser"), "{s}");
        a.handle(Msg::Input(Event::Key(KeyEvent::from(KeyCode::Esc))));
        assert!(a.jv.log.is_none());
    }

    #[test]
    fn an_open_log_shows_its_tail_and_scrolls_back() {
        let mut a = jobs_app();
        let mut j = hub_core::jobs::Job::new(
            hub_core::jobs::Source::Agentctl,
            "task",
            hub_core::jobs::State::Done,
        );
        j.log = Some(LogRef::Journal {
            invocation: "task".into(),
        });
        a.jobs = Some(Jobs {
            at: 0,
            window_secs: 86400,
            jobs: vec![j],
            errors: vec![],
        });
        a.handle(Msg::Input(Event::Key(KeyEvent::from(KeyCode::Enter))));
        let gen = a.jv.log.as_ref().unwrap().gen;
        let text: String = (1..=100).map(|n| format!("line {n}\n")).collect();
        a.handle(Msg::Log(gen, Ok(text)));
        let s = screen(&mut a, 60, 20);
        assert!(s.contains("line 100") && !s.contains("line 92 "), "{s}");
        a.handle(Msg::Input(Event::Key(KeyEvent::from(KeyCode::Char('K')))));
        let s = screen(&mut a, 60, 20);
        assert!(!s.contains("line 100") && s.contains("line 92 "), "{s}");
        // A read for a pane since reopened is dropped.
        a.handle(Msg::Log(gen + 5, Ok("stale".into())));
        assert!(!screen(&mut a, 60, 20).contains("stale"));
    }
}
