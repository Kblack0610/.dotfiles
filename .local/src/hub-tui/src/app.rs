//! `hub`: the state, the keys and the drawing. Reads run in worker threads and come back as
//! messages; a read asked for while one is running is coalesced into one more after it.

use std::path::{Path, PathBuf};
use std::sync::mpsc::Sender;
use std::sync::Arc;
use std::time::Duration;

use hub_core::boards::{self, DayRow, Watch};
use hub_core::fleet::who::{Opens, Who};
use hub_core::fleet::ASK_FILTERS;
use hub_core::infra::Infra;
use hub_core::jobs::{self, Job, Jobs, LogRef, Opts, Paths};
use hub_core::outcomes::{self, Ranked};
use hub_core::proposals::{self, Proposal};
use hub_core::queue::{Candidate, Candidates, Queue};
use hub_core::schedules::{Schedule, Schedules};
use hub_core::session_actions::{self as actions, Action, Runner, Snapshot};
use hub_core::tasks::Feed;
use ratatui::crossterm::event::{Event, KeyCode, KeyEvent, KeyEventKind, KeyModifiers};
use ratatui::layout::{Constraint, Layout, Rect};
use ratatui::text::{Line, Span};
use ratatui::widgets::Paragraph;
use ratatui::Frame;

use crate::controls::{Ask, Controls};
use crate::datatable::{DataTable, Took};
use crate::fmt::{clock, Palette};
use crate::forecast::{self, Forecast};
use crate::jobs::{clean, row_id, JobsView, LogPane};
use crate::projtab::{self, ProjView};
use crate::proptab::ProposalsView;
use crate::queuetab::{self, QueueView};
use crate::schedules::{self, SchedulesView};
use crate::tasktab::{self, TaskView};
use crate::{board, day, fleet, fleettab, focustab, hometab, logtab, outboxtab};

/// How often Prometheus is read again, and the job sources with no file to watch (CI, k8s,
/// timers in the journal). A genuine UI cadence: Prometheus has no push, and its rules
/// evaluate every 30-60s anyway.
pub const PROM_REFRESH: Duration = Duration::from_secs(60);
/// One `fleet-bench reds` read takes about 2s and a fix moves in minutes, so the tick re-reads
/// Red fixes only this often; entering Infra and `r` still read it at once.
pub const REDS_REFRESH: Duration = Duration::from_secs(300);
/// A Schedules read shells out to systemd and Prometheus for seconds, and a schedule changes by
/// the hour: agent-web's cache keeps one this long too.
pub const SCHEDULES_REFRESH: Duration = Duration::from_secs(60);
/// Under this many body lines the Projects rows keep the whole window and get no preview pane.
const PREVIEW_MIN_HEIGHT: u16 = 18;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Tab {
    Home,
    Daily,
    Queue,
    Projects,
    Sessions,
    Infra,
    Log,
    Fleet,
    Schedules,
}

impl Tab {
    /// hub-core's layout order; digit N opens `ALL[N - 1]` (`tabs_are_the_layout` checks).
    pub const ALL: [Tab; 9] = [
        Tab::Home,
        // The daily note; `o` shows the outbox under it (`hub --tab outbox` opens it there).
        Tab::Daily,
        Tab::Queue,
        Tab::Projects,
        Tab::Sessions,
        Tab::Infra,
        Tab::Log,
        Tab::Fleet,
        Tab::Schedules,
    ];
    pub fn title(self) -> &'static str {
        match self {
            Tab::Home => "Home",
            Tab::Daily => "Daily",
            Tab::Queue => "Queue",
            Tab::Projects => "Projects",
            Tab::Sessions => "Sessions",
            Tab::Infra => "Infra",
            Tab::Log => "Log",
            Tab::Fleet => "Fleet",
            Tab::Schedules => "Schedules",
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
        char::from_digit(self.index() as u32 + 1, 10).unwrap_or(' ')
    }
    /// The tab a digit opens; 0 opens none.
    fn by_digit(c: char) -> Option<Tab> {
        let n = c.to_digit(10)? as usize;
        n.checked_sub(1).and_then(|i| Tab::ALL.get(i).copied())
    }
    /// The Grafana dashboard that keeps this page's trends; the file-fed pages have none.
    fn dashboard(self) -> Option<&'static str> {
        match self {
            Tab::Home => Some("kb-command-center"),
            Tab::Infra => Some("kb-ci-runners"),
            Tab::Queue => Some("kb-agents-overview"),
            Tab::Daily | Tab::Projects | Tab::Sessions | Tab::Log | Tab::Fleet | Tab::Schedules => {
                None
            }
        }
    }
}

/// Log's folded sections, their keys and headings, in the page's order after the day and its
/// history (hub_core::layout's Log sections; `log_folds_are_the_layout` checks).
const FOLDS: [(&str, char, &str); 6] = [
    ("actions", 'a', "ACTIONS"),
    ("changes", 'c', "CHANGES"),
    ("rundowns", 's', "RUNDOWNS"),
    ("verdicts", 'v', "JUDGES' VERDICTS"),
    ("forecast", 'f', "FORECAST"),
    ("ranked", 'w', "RANKED SESSIONS"),
];

/// How many job rows Infra's Jobs section shows; Enter opens the whole table.
const JOBS_SHOWN: usize = 8;

/// The files the Sessions, Fleet and Log tabs are read from.
#[derive(Clone)]
pub struct BoardFiles {
    pub state: PathBuf,
    /// agent-ask's store: Home's asks are read live, so an ask filed or answered re-reads them.
    pub asks: PathBuf,
    /// agent-propose's store: a proposal filed or decided re-reads Home's section.
    pub proposals: PathBuf,
    pub shepherd: PathBuf,
    pub daylog: PathBuf,
}

impl BoardFiles {
    pub fn from_env() -> BoardFiles {
        BoardFiles {
            state: boards::fleet_state(),
            asks: boards::asks_dir(),
            proposals: boards::proposals_dir(),
            shepherd: boards::shepherd_dir(),
            daylog: boards::daylog_dir(),
        }
    }
    fn watch_log(&self) -> PathBuf {
        self.shepherd.join("watch.log")
    }
    /// The shepherd's kept rundowns (`fleet-shepherd log --rundown`), one `.md` file each.
    pub fn rundowns(&self) -> PathBuf {
        self.shepherd.join("rundowns")
    }
    pub fn is_proposal_file(&self, p: &Path) -> bool {
        hub_core::boards::is_proposal_file(&self.proposals, p)
    }

    /// Whether a changed path is one the board tabs read (the shepherd dir holds other files).
    pub fn is_board_file(&self, p: &Path) -> bool {
        p == self.state
            || p == self.watch_log()
            || p.parent() == Some(self.rundowns().as_path())
                && p.extension().is_some_and(|e| e == "md")
            || p.starts_with(&self.asks) && p.extension().is_some_and(|e| e == "md")
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
    /// The shepherd's kept rundowns, newest first, at most `FOLD_ROWS`, and how many there are.
    pub rundowns: Vec<boards::Rundown>,
    pub rundowns_total: usize,
}

impl Boards {
    pub fn read(f: &BoardFiles, day: Option<&str>) -> Boards {
        Boards {
            watch: boards::watch(&f.state, &f.watch_log(), &actions::System),
            days: boards::days(&f.daylog),
            rec: boards::record(&f.daylog, day),
            hist: boards::history(&f.daylog, boards::HISTORY_MAX_DAYS),
            rundowns: boards::rundowns(&f.rundowns(), hub_core::layout::FOLD_ROWS),
            rundowns_total: boards::rundown_files(&f.rundowns()).len(),
        }
    }
}

pub enum Msg {
    Input(Event),
    Tick,
    /// agent-propose wrote a record.
    ProposalFiles,
    Proposals(Box<Result<Vec<Proposal>, String>>),
    /// What an accept or a reject answered.
    ProposalActed(Result<String, String>),
    /// A job source's file changed (a run started or ended).
    Files,
    /// The fleet state, watch.log or a day record changed.
    BoardFiles,
    /// `hub tab <name> [words]` asked for a page (tabreq.rs); the words name a project to open.
    Tab(Tab, Option<String>),
    Boards(Box<Boards>),
    Infra(Box<Infra>),
    Jobs(Box<Jobs>),
    Schedules(Box<Schedules>),
    /// The Sessions table's ended rows, then its header, which waits on headroom.
    SessionFeed(Box<hub_core::session_table::Feed>),
    Capacity(Box<hub_core::capacity::Capacity>),
    /// One session's page (hub_core::session_page), for the row it was read for.
    SessionPage(Box<(String, Option<hub_core::session_page::SessionPage>)>),
    Forecast(Box<Forecast>),
    /// `agentctl-session-outcomes worst`, or why it failed.
    Ranked(Result<Vec<Ranked>, String>),
    /// `fleet-bench reds`, split for Infra's Red fixes section, or why it failed.
    Reds(Result<hub_core::reds::Reds, String>),
    Fleet(Box<hub_core::fleet::Fleet>),
    /// One runner's page (hub_core::fleet::runner), for the name it was read for.
    Runner(Box<(String, Result<hub_core::fleet::runner::Runner, String>)>),
    /// The pipeline summary from `agent_chain_*` (hub_core::pipeline); Ok(None) when absent.
    Pipeline(Result<Option<hub_core::pipeline::Pipeline>, String>),
    /// The machinery's actions over the last `logtab::ACTIONS_HOURS`, for Log's Actions section.
    Actions(Box<hub_core::actions::Gathered>),
    /// A day's note through `notes show --json` (hub_core::focus), or why it failed.
    Focus(Box<Result<hub_core::focus::View, String>>),
    /// The outbox and today's intake steps (hub_core::outbox), or why the read failed.
    Outbox(Box<Result<hub_core::outbox::View, String>>),
    Log(u64, Result<String, String>),
    /// The live and parked agent sessions, for the Sessions tab's controls.
    Sessions(Box<Snapshot>),
    /// A session action ended: its output, or why it failed.
    Acted(Result<String, String>),
    /// An item file under the queue dir was written, moved or removed.
    QueueFiles,
    Queue(Box<Queue>),
    /// A queue cancel, bump or promote ended: its output, or why it failed.
    QueueActed(Result<String, String>),
    /// `fleet-dispatch suggest --json` (hub_core::queue::candidates), or why it failed.
    Candidates(Result<Candidates, String>),
    /// `notes board --json`, or why it failed.
    Tasks(Box<Result<Feed, String>>),
    /// A board write ended: notes' output, or why it failed.
    TasksActed(Result<String, String>),
    /// `notes projects --stats --json` and the project map, for the Projects tab's cards.
    Projects(Box<projtab::Loaded>),
    /// The opened card's page (hub_core::page).
    ProjPage(Box<hub_core::page::Page>),
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
    pub sv: SchedulesView,
    pub schedules: Option<Schedules>,
    pub files: BoardFiles,
    pub boards: Option<Boards>,
    pub forecast: Option<Forecast>,
    pub ranked: Option<Result<Vec<Ranked>, String>>,
    /// Infra's Red fixes section; None until the first read.
    pub reds: Option<Result<hub_core::reds::Reds, String>>,
    pub fleet: Option<hub_core::fleet::Fleet>,
    /// The Queue tab's pipeline line: None until the first read.
    pub pipeline: Option<Result<Option<hub_core::pipeline::Pipeline>, String>>,
    /// Fleet's one table: `/` query, `f` state, `s`/`S` sort, `x` clear (datatable).
    pub fleet_table: DataTable,
    /// The tier 1 rows folded (`z`), by runner name; their children leave the table.
    pub fleet_folded: std::collections::HashSet<String>,
    /// The table row j/k pick and Enter opens, an index into `fleettab::shown`.
    pub fleet_sel: usize,
    /// The runner whose page is open (Enter, or `hub tab fleet <runner>`); None is the tab.
    pub fleet_page: Option<String>,
    /// That page's read; None until it comes back.
    pub fleet_runner: Option<Result<hub_core::fleet::runner::Runner, String>>,
    /// The Daily tab's note; None until the first read.
    pub focus: Option<Result<hub_core::focus::View, String>>,
    /// The Daily tab shows the outbox (`o`) in place of the note.
    pub daily_outbox: bool,
    /// The outbox under the Daily tab; None until the first read.
    pub outbox: Option<Result<hub_core::outbox::View, String>>,
    /// What Enter on the outbox did: the editor opened, or why it did not.
    pub outbox_said: Option<Result<String, String>>,
    /// The day the Daily tab shows (`YYYY-MM-DD`); None is today.
    pub focus_day: Option<String>,
    /// agent-queue's items and week, for the Queue tab and Home's running list and numbers.
    pub queue: Option<Queue>,
    pub qv: QueueView,
    /// The ranked board rows for the Queue tab's Candidates fold.
    pub candidates: Option<Result<Candidates, String>>,
    /// agent-queue's store, watched so the Queue tab follows it; it is never read here.
    pub queue_dir: PathBuf,
    /// Every project's open rows, for the Projects tab; None until the first read.
    pub tasks: Option<Result<Feed, String>>,
    pub proposals: Option<Result<Vec<Proposal>, String>>,
    pub prv: ProposalsView,
    pub tv: TaskView,
    /// The Projects tab's card inputs; None until the first read.
    pub projects: Option<projtab::Loaded>,
    pub pv: ProjView,
    /// The opened card's page, read on open and on r, never for the list (dashboards rule 10).
    pub proj_page: Option<hub_core::page::Page>,
    /// The project the last page read was started for.
    proj_page_for: Option<String>,
    /// The Sessions tab's session list, selection and confirm.
    pub controls: Controls,
    /// Runs a session action's commands; tests swap in a fake.
    pub runner: Arc<dyn Runner + Send + Sync>,
    /// Reads the sessions an action may target; tests swap in a fixture.
    pub gather: fn(&dyn Runner) -> Snapshot,
    /// The day Log shows; None follows the newest record.
    pub day: Option<String>,
    /// Log's day list (`h`) is open in place of the day.
    pub log_days: bool,
    /// The day list's selected row, newest first.
    pub hist_sel: usize,
    /// Log's open folds, by `FOLDS` name.
    pub log_open: Vec<&'static str>,
    /// Which of `ASK_FILTERS` the answer judge's verdict list shows.
    pub ask_filter: usize,
    /// Log's Actions section; None until it is first opened.
    pub actions: Option<hub_core::actions::Gathered>,
    /// Where the page's sections start, from the last draw (n/N jump between them on Log and
    /// Infra), with the `hub_core::layout` section names.
    sections: Vec<(&'static str, usize)>,
    /// A section to scroll to once the page draws (`hub --tab ci`, `hub --tab actions`).
    seek: Option<&'static str>,
    /// Infra's Jobs section opened as the whole jobs table.
    pub infra_jobs: bool,
    /// Lines scrolled down on every page but Jobs.
    pub scroll: usize,
    pub quit: bool,
    /// `hub --popup`: a floating window, so Esc with nothing left to close quits.
    pub popup: bool,
    tx: Sender<Msg>,
    infra_read: Read,
    jobs_read: Read,
    feed_read: Read,
    boards_read: Read,
    forecast_read: Read,
    ranked_read: Read,
    reds_read: Read,
    schedules_read: Read,
    /// When the last Red fixes read finished, for `REDS_REFRESH`.
    reds_at: Option<std::time::Instant>,
    /// When the last Schedules read finished, for `SCHEDULES_REFRESH`.
    schedules_at: Option<std::time::Instant>,
    actions_read: Read,
    fleet_read: Read,
    fleet_runner_read: Read,
    pipeline_read: Read,
    focus_read: Read,
    outbox_read: Read,
    sessions_read: Read,
    queue_read: Read,
    candidates_read: Read,
    tasks_read: Read,
    proposals_read: Read,
    projects_read: Read,
    proj_page_read: Read,
    log_gen: u64,
    /// The body's last height, for paging.
    page: usize,
    /// Why a file watch could not be set (inotify full), shown in the tab bar.
    pub watch_failed: Option<String>,
    /// Why `hub tab` cannot reach this hub (its socket would not bind), shown in the tab bar.
    pub tab_failed: Option<String>,
}

/// The Sessions tab's open detail, as a section `seek` goes to.
const DETAIL: &str = "detail";

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
            sv: SchedulesView::default(),
            schedules: None,
            files: BoardFiles::from_env(),
            boards: None,
            forecast: None,
            ranked: None,
            reds: None,
            fleet: None,
            pipeline: None,
            focus: None,
            daily_outbox: false,
            fleet_table: DataTable::default(),
            fleet_folded: Default::default(),
            fleet_sel: 0,
            fleet_page: None,
            fleet_runner: None,
            outbox: None,
            outbox_said: None,
            focus_day: None,
            queue: None,
            qv: QueueView::default(),
            candidates: None,
            queue_dir: queue_dir(),
            tasks: None,
            proposals: None,
            prv: ProposalsView::default(),
            tv: TaskView::default(),
            projects: None,
            pv: ProjView::default(),
            controls: Controls::default(),
            runner: Arc::new(actions::System),
            gather: actions::gather,
            day: None,
            log_days: false,
            hist_sel: 0,
            log_open: vec![],
            ask_filter: 0,
            actions: None,
            sections: vec![],
            seek: None,
            infra_jobs: false,
            scroll: 0,
            quit: false,
            popup: false,
            tx,
            infra_read: Read::default(),
            jobs_read: Read::default(),
            feed_read: Read::default(),
            boards_read: Read::default(),
            forecast_read: Read::default(),
            ranked_read: Read::default(),
            reds_read: Read::default(),
            schedules_read: Read::default(),
            reds_at: None,
            schedules_at: None,
            actions_read: Read::default(),
            fleet_read: Read::default(),
            fleet_runner_read: Read::default(),
            pipeline_read: Read::default(),
            focus_read: Read::default(),
            outbox_read: Read::default(),
            sessions_read: Read::default(),
            queue_read: Read::default(),
            candidates_read: Read::default(),
            tasks_read: Read::default(),
            proposals_read: Read::default(),
            projects_read: Read::default(),
            proj_page_read: Read::default(),
            proj_page: None,
            proj_page_for: None,
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
            (self.files.rundowns(), false),
            (self.files.daylog.clone(), false),
            (self.queue_dir.clone(), true),
            (self.files.asks.clone(), true),
            (self.files.proposals.clone(), false),
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

    /// The outcome rows change once a night, so the ranked list is read only when its fold
    /// opens and on `r` while it is open.
    pub fn read_ranked(&mut self) {
        if self.ranked_read.want() {
            let (tx, runner) = (self.tx.clone(), self.runner.clone());
            std::thread::spawn(move || {
                let _ = tx.send(Msg::Ranked(outcomes::ranked(runner.as_ref())));
            });
        }
    }

    /// fleet-bench reds writes no file to watch, so Infra reads it on entering, on `r` and on
    /// the tick while it is shown, at most every `REDS_REFRESH`.
    pub fn read_reds(&mut self) {
        if self.reds_read.want() {
            let (tx, runner) = (self.tx.clone(), self.runner.clone());
            std::thread::spawn(move || {
                let _ = tx.send(Msg::Reds(hub_core::reds::read(runner.as_ref())));
            });
        }
    }

    /// Schedules come from systemd, Prometheus and files with no one thing to watch, so the tab
    /// reads on entering, on `r`, and on the tick while it is shown once `SCHEDULES_REFRESH` has
    /// passed.
    pub fn read_schedules(&mut self) {
        if self.schedules_read.want() {
            let (tx, runner) = (self.tx.clone(), self.runner.clone());
            std::thread::spawn(move || {
                let paths = hub_core::fleet::Paths::from_env();
                let s = hub_core::schedules::read(&paths, runner.as_ref());
                let _ = tx.send(Msg::Schedules(Box::new(s)));
            });
        }
    }

    /// A read still going is not due: asking now would queue a second one behind it.
    fn schedules_due(&self) -> bool {
        !self.schedules_read.busy
            && self
                .schedules_at
                .is_none_or(|t| t.elapsed() >= SCHEDULES_REFRESH)
    }

    /// The actions ledger has no one file to watch, so Log's Actions section reads it when it
    /// opens, on `r` and on the tick while it is open, as agent-web's feed does.
    pub fn read_actions(&mut self) {
        if self.actions_read.want() {
            let tx = self.tx.clone();
            std::thread::spawn(move || {
                let g = hub_core::actions::read(jobs::now() - logtab::ACTIONS_HOURS * 3600);
                let _ = tx.send(Msg::Actions(Box::new(g)));
            });
        }
    }

    /// Log reads only what its open folds show (the day and changes come with the board files).
    fn read_log_folds(&mut self) {
        for name in self.log_open.clone() {
            match name {
                "actions" => self.read_actions(),
                "verdicts" => self.read_fleet(),
                "forecast" => self.read_forecast(),
                "ranked" => self.read_ranked(),
                _ => {}
            }
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

    /// A runner's page is read only when it opens (dashboards rule 10), then on `r`, the tick and
    /// an agentctl file event while it is shown, as the tab is.
    pub fn read_runner(&mut self) {
        let Some(name) = self.fleet_page.clone() else {
            return;
        };
        if self.fleet_runner_read.want() {
            let tx = self.tx.clone();
            std::thread::spawn(move || {
                let r = hub_core::fleet::runner::read(&hub_core::fleet::Paths::from_env(), &name);
                let _ = tx.send(Msg::Runner(Box::new((name, r))));
            });
        }
    }

    /// Open `name`'s page in place of the Fleet tab.
    pub fn open_runner(&mut self, name: &str) {
        if self.fleet_page.as_deref() != Some(name) {
            self.fleet_runner = None;
        }
        self.fleet_page = Some(name.to_string());
        self.scroll = 0;
        self.read_runner();
    }

    /// The tab's read, or the open page's.
    fn read_fleet_shown(&mut self) {
        if self.fleet_page.is_some() {
            self.read_runner();
        } else {
            self.read_fleet();
        }
    }

    /// The Queue tab's pipeline line is Prometheus (no push): read on entering, on `r` and on the
    /// tick while shown.
    pub fn read_pipeline(&mut self) {
        if self.pipeline_read.want() {
            let tx = self.tx.clone();
            std::thread::spawn(move || {
                let _ = tx.send(Msg::Pipeline(hub_core::pipeline::read()));
            });
        }
    }

    /// Nothing here watches the vault (`notes` is its writer), so the Daily tab reads its day
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

    /// The Daily tab's view: the note, or the outbox when `o` shows it.
    pub fn read_daily(&mut self) {
        if self.daily_outbox {
            self.read_outbox();
        } else {
            self.read_focus();
        }
    }

    /// The outbox has no watch here: Daily reads it on showing it, on `r` and on the tick.
    pub fn read_outbox(&mut self) {
        if self.outbox_read.want() {
            let tx = self.tx.clone();
            let runner = self.runner.clone();
            let today = chrono::Local::now().format("%Y-%m-%d").to_string();
            std::thread::spawn(move || {
                let _ = tx.send(Msg::Outbox(Box::new(hub_core::outbox::read(
                    runner.as_ref(),
                    &today,
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
        if self.feed_read.want() {
            let tx = self.tx.clone();
            let runner = self.runner.clone();
            std::thread::spawn(move || {
                use hub_core::{capacity, session_table as table};
                let feed = table::feed(runner.as_ref(), &table::registry());
                let _ = tx.send(Msg::SessionFeed(Box::new(feed)));
                let cap = capacity::read_fleet(runner.as_ref());
                let _ = tx.send(Msg::Capacity(Box::new(cap)));
            });
        }
    }

    /// Read the page of the session whose detail is open, in a worker.
    fn read_page(&mut self) {
        let Some((id, rows, state)) = self.controls.wants_page() else {
            return;
        };
        let tx = self.tx.clone();
        let runner = self.runner.clone();
        std::thread::spawn(move || {
            use hub_core::{boards, session_page};
            let ledger = boards::shepherd_dir();
            let page = session_page::read(runner.as_ref(), &ledger, &id, &rows, &state);
            let _ = tx.send(Msg::SessionPage(Box::new((id, page))));
        });
    }

    /// What `read_sessions` reads in its workers, here and now, for `--once`.
    pub fn read_sessions_now(&mut self) {
        use hub_core::{capacity, session_table as table};
        let runner = self.runner.clone();
        self.controls.set((self.gather)(runner.as_ref()));
        self.controls
            .read_feed(table::feed(runner.as_ref(), &table::registry()));
        self.controls.capacity = Some(capacity::read_fleet(runner.as_ref()));
    }

    /// Start a timer the header says is stopped, confirmed; the re-read shows it on.
    fn start_timer(&mut self, name: String) {
        let label = format!("start {name}");
        self.controls.running = Some(label.clone());
        self.controls.said = None;
        let tx = self.tx.clone();
        let runner = self.runner.clone();
        std::thread::spawn(move || {
            let r = hub_core::capacity::start(runner.as_ref(), &name);
            let _ = tx.send(Msg::Acted(said(&label, r)));
        });
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

    /// The candidates read every board (seconds), so they are read in a worker on entering the
    /// Queue tab, on `r` there and after a queue action, never on a queue file event.
    pub fn read_candidates(&mut self) {
        if self.candidates_read.want() {
            let (tx, runner) = (self.tx.clone(), self.runner.clone());
            std::thread::spawn(move || {
                let _ = tx.send(Msg::Candidates(hub_core::queue::candidates(
                    runner.as_ref(),
                )));
            });
        }
    }

    /// Run a queue cancel, bump or promote in a worker; the answer comes back as Msg::QueueActed.
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
    /// the Projects tab, on `r`, after a write, and on the tick while shown. Home reads the rows
    /// too, for NEEDS YOU's sheet rows. The vault has no
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

    /// Home's reads beside the fleet state: the human-sheet rows and the proposals.
    pub fn read_home(&mut self) {
        self.read_tasks();
        self.read_proposals();
    }

    fn read_proposals(&mut self) {
        if self.proposals_read.want() {
            let tx = self.tx.clone();
            let runner = self.runner.clone();
            std::thread::spawn(move || {
                let _ = tx.send(Msg::Proposals(Box::new(proposals::read(runner.as_ref()))));
            });
        }
    }

    /// Accept or reject the selected proposal in a worker; the answer comes back as
    /// Msg::ProposalActed.
    fn decide_proposal(&mut self, accept: bool) {
        let rows = open_rows(&self.proposals);
        let Some(id) = self.prv.selected(rows).map(|p| p.id.clone()) else {
            return;
        };
        let tx = self.tx.clone();
        let runner = self.runner.clone();
        std::thread::spawn(move || {
            let r = if accept {
                proposals::accept(runner.as_ref(), &id)
            } else {
                proposals::reject(runner.as_ref(), &id)
            };
            let _ = tx.send(Msg::ProposalActed(said("proposal", r)));
        });
    }

    /// Both of the Projects tab's reads: the rows and the cards.
    pub fn read_projects(&mut self) {
        self.read_tasks();
        self.read_cards();
    }

    /// The open card's name and stage; None on the list or with All open.
    fn open_card(&self) -> Option<(String, String)> {
        if !self.pv.open {
            return None;
        }
        let (profile, name) = self.tv.project.as_ref()?;
        self.cards()
            .cards
            .into_iter()
            .find(|c| c.profile == *profile && c.name == *name)
            .map(|c| (c.name, c.stage))
    }

    /// Read the open card's page in a worker; it comes back as Msg::ProjPage.
    fn read_proj_page(&mut self) {
        let Some((name, stage)) = self.open_card() else {
            return;
        };
        self.proj_page_for = Some(name.clone());
        if self.proj_page_read.want() {
            let tx = self.tx.clone();
            let runner = self.runner.clone();
            std::thread::spawn(move || {
                let pg = hub_core::page::read(runner.as_ref(), &name, &stage, jobs::now());
                let _ = tx.send(Msg::ProjPage(Box::new(pg)));
            });
        }
    }

    /// Read the open card's page here and now, for `--once`.
    pub fn read_proj_page_now(&mut self, runner: &dyn Runner) {
        if let Some((name, stage)) = self.open_card() {
            self.proj_page = Some(hub_core::page::read(runner, &name, &stage, jobs::now()));
        }
    }

    /// Read the page when the open card is not the one last asked for.
    fn want_proj_page(&mut self) {
        if let Some((name, _)) = self.open_card() {
            if self.proj_page_for.as_deref() != Some(name.as_str()) {
                self.read_proj_page();
            }
        }
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
        hub_core::projects::build(stats, feed, state, self.queue.as_ref())
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

    /// Step one project's priority in a worker; the answer comes back like a board write.
    fn prio_act(&mut self, profile: String, name: String, value: &'static str) {
        let label = format!("{name} prio {value}");
        self.tv.running = Some(label.clone());
        self.tv.said = None;
        let tx = self.tx.clone();
        let runner = self.runner.clone();
        std::thread::spawn(move || {
            let r = said(
                &label,
                hub_core::projects::set_prio(runner.as_ref(), &profile, &name, value),
            );
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
                if self.tab == Tab::Infra
                    && self.reds_at.is_none_or(|t| t.elapsed() >= REDS_REFRESH)
                {
                    self.read_reds();
                }
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
                    self.read_fleet_shown();
                }
                if self.tab == Tab::Schedules && self.schedules_due() {
                    self.read_schedules();
                }
                if self.tab == Tab::Queue {
                    self.read_pipeline();
                }
                if self.tab == Tab::Log {
                    self.read_log_folds();
                }
                if self.tab == Tab::Daily {
                    self.read_daily();
                }
                if self.tab == Tab::Projects {
                    self.read_projects();
                }
                if self.tab == Tab::Home {
                    self.read_home();
                }
            }
            Msg::Files => {
                self.read_jobs();
                if self.tab == Tab::Fleet {
                    self.read_fleet_shown();
                } else if self.tab == Tab::Log && self.log_open.contains(&"verdicts") {
                    self.read_fleet();
                }
            }
            Msg::BoardFiles => self.read_boards(),
            Msg::ProposalFiles => self.read_proposals(),
            Msg::Tab(t, q) => {
                self.go(t);
                self.open_query(q);
            }
            Msg::Boards(b) => {
                self.controls.read(Some(&b.watch.state), None);
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
            Msg::Ranked(r) => {
                self.ranked = Some(r);
                if self.ranked_read.done() {
                    self.read_ranked();
                }
            }
            Msg::Reds(r) => {
                self.reds = Some(r);
                self.reds_at = Some(std::time::Instant::now());
                if self.reds_read.done() && self.tab == Tab::Infra {
                    self.read_reds();
                }
            }
            Msg::Schedules(s) => {
                let id = self.selected_schedule().map(schedules::row_id);
                self.schedules = Some(*s);
                self.schedules_at = Some(std::time::Instant::now());
                if let Some(s) = &self.schedules {
                    self.sv.reselect(s, id);
                }
                if self.schedules_read.done() && self.tab == Tab::Schedules {
                    self.read_schedules();
                }
            }
            Msg::Fleet(f) => {
                self.fleet = Some(*f);
                if self.fleet_read.done() {
                    self.read_fleet();
                }
            }
            Msg::Runner(b) => {
                let (name, r) = *b;
                if self.fleet_page.as_deref() == Some(name.as_str()) {
                    self.fleet_runner = Some(r);
                }
                if self.fleet_runner_read.done() {
                    self.read_runner();
                }
            }
            Msg::Pipeline(r) => {
                self.pipeline = Some(r);
                if self.pipeline_read.done() {
                    self.read_pipeline();
                }
            }
            Msg::Actions(g) => {
                self.actions = Some(*g);
                if self.actions_read.done() {
                    self.read_actions();
                }
            }
            Msg::Focus(v) => {
                self.focus = Some(*v);
                if self.focus_read.done() {
                    self.read_focus();
                }
            }
            Msg::Outbox(v) => {
                self.outbox = Some(*v);
                if self.outbox_read.done() {
                    self.read_outbox();
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
            Msg::SessionFeed(f) => {
                self.controls.read_feed(*f);
                self.read_page();
            }
            Msg::SessionPage(p) => self.controls.read_page(p.0, p.1),
            Msg::Capacity(c) => {
                self.controls.capacity = Some(*c);
                if self.feed_read.done() {
                    self.read_sessions();
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
                self.qv.reselect(was, &q, cands_of(&self.candidates));
                self.queue = Some(*q);
                if self.queue_read.done() {
                    self.read_queue();
                }
            }
            Msg::QueueActed(r) => {
                self.qv.running = None;
                self.qv.said = Some(r);
                self.read_queue();
                self.read_candidates();
            }
            Msg::Candidates(c) => {
                self.candidates = Some(c);
                if let Some(q) = &self.queue {
                    let was = self.qv.selected(q).map(|i| i.slug.clone());
                    self.qv.reselect(was, q, cands_of(&self.candidates));
                }
                if self.candidates_read.done() {
                    self.read_candidates();
                }
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
            Msg::Proposals(r) => {
                self.proposals = Some(*r);
                let last = self.prv.shown(open_rows(&self.proposals)).len();
                self.prv.sel = self.prv.sel.min(last.saturating_sub(1));
                if self.proposals_read.done() {
                    self.read_proposals();
                }
            }
            Msg::ProposalActed(r) => {
                self.prv.said = Some(r);
                self.read_proposals();
            }
            Msg::TasksActed(r) => {
                self.tv.running = None;
                self.tv.said = Some(r);
                self.read_projects();
            }
            Msg::Projects(l) => {
                self.projects = Some(*l);
                self.open_wanted();
                self.want_proj_page();
                if self.projects_read.done() {
                    self.read_cards();
                }
            }
            Msg::ProjPage(pg) => {
                self.proj_page = Some(*pg);
                if self.proj_page_read.done() {
                    self.read_proj_page();
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
        // Ctrl-d/Ctrl-u: vim's half page, ahead of every tab's own keys so a tab's plain d or u
        // (a Sessions action) never sees them. Queue moves its selection.
        if k.modifiers.contains(KeyModifiers::CONTROL) && matches!(k.code, KeyCode::Char('d' | 'u'))
        {
            let half = (self.page / 2).max(1);
            if self.tab == Tab::Queue {
                self.queue_key(k);
            } else if k.code == KeyCode::Char('d') {
                self.scroll += half;
            } else {
                self.scroll = self.scroll.saturating_sub(half);
            }
            return;
        }
        if self.tab == Tab::Infra && self.infra_key(k) {
            return;
        }
        if self.tab == Tab::Home && self.home_key(k) {
            return;
        }
        if self.tab == Tab::Log && self.log_key(k) {
            return;
        }
        if self.tab == Tab::Daily && self.daily_key(k) {
            return;
        }
        if self.tab == Tab::Sessions && self.sessions_key(k) {
            return;
        }
        if self.tab == Tab::Queue && self.queue_key(k) {
            return;
        }
        if self.tab == Tab::Projects && self.projects_key(k) {
            self.want_proj_page();
            return;
        }
        if self.tab == Tab::Fleet && self.fleet_key(k) {
            return;
        }
        if self.tab == Tab::Schedules && self.schedules_key(k) {
            return;
        }
        let n = self.page.max(1);
        let tabs = Tab::ALL.len();
        match k.code {
            KeyCode::Char('q') => self.quit = true,
            // Every tab's own Esc (a pane, filter, prompt or table) ran above and kept the key.
            KeyCode::Esc if self.popup => self.quit = true,
            // A digit opens the tab it numbers on the tab bar.
            KeyCode::Char(c) if Tab::by_digit(c).is_some() => {
                if let Some(t) = Tab::by_digit(c) {
                    self.go(t);
                }
            }
            KeyCode::Tab => self.go(Tab::ALL[(self.tab.index() + 1) % tabs]),
            KeyCode::BackTab => self.go(Tab::ALL[(self.tab.index() + tabs - 1) % tabs]),
            KeyCode::Char('r') => {
                self.read_infra();
                self.read_jobs();
                self.read_boards();
                self.read_queue();
                if self.tab == Tab::Infra {
                    self.read_reds();
                }
                if self.tab == Tab::Schedules {
                    self.read_schedules();
                }
                if self.tab == Tab::Queue {
                    self.read_candidates();
                    self.read_pipeline();
                }
                if self.tab == Tab::Sessions {
                    self.read_forecast();
                    self.read_sessions();
                }
                if self.tab == Tab::Fleet {
                    self.read_fleet_shown();
                }
                if self.tab == Tab::Log {
                    self.read_log_folds();
                }
                if self.tab == Tab::Daily {
                    self.read_daily();
                }
                if self.tab == Tab::Projects {
                    self.read_projects();
                    self.read_proj_page();
                }
                if self.tab == Tab::Home {
                    self.read_home();
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

    /// The runner rows as shown, by name: what `[ ]` step through on a runner's page.
    fn fleet_runners(&self) -> Vec<String> {
        self.fleet.as_ref().map_or(vec![], |f| {
            fleettab::shown(f, &self.fleet_table, &self.fleet_folded)
                .iter()
                .filter(|r| r.opens == Opens::Runner)
                .map(|r| r.key.clone())
                .collect()
        })
    }

    /// Open the session `target` on the Sessions tab, as a click on a Fleet row does on the web.
    fn open_session(&mut self, target: &str) {
        self.go(Tab::Sessions);
        if let Some(i) = self.controls.rows().iter().position(|r| r.target == target) {
            self.controls.sel = i;
            self.controls.open = true;
            self.seek = Some(DETAIL);
        }
    }

    /// The Fleet tab's own keys; false leaves the key to the page's defaults. On a runner's page
    /// `[ ]` step to the previous or next runner and Esc goes back to the tab; on the tab the
    /// table keys (`/ f s S x`), j/k pick a row, Enter opens it (a runner's page, or a session on
    /// the Sessions tab) and `z` folds a tier 1 row's children.
    fn fleet_key(&mut self, k: KeyEvent) -> bool {
        if let Some(page) = self.fleet_page.clone() {
            let names = self.fleet_runners();
            match k.code {
                KeyCode::Esc => {
                    self.fleet_page = None;
                    self.fleet_runner = None;
                    self.scroll = 0;
                    self.read_fleet();
                }
                KeyCode::Char(c @ ('[' | ']')) if !names.is_empty() => {
                    let n = names.len();
                    let next = match names.iter().position(|x| *x == page) {
                        None => 0,
                        Some(at) if c == '[' => (at + n - 1) % n,
                        Some(at) => (at + 1) % n,
                    };
                    let name = names[next].clone();
                    self.open_runner(&name);
                }
                _ => return false,
            }
            return true;
        }
        match self.fleet_table.key::<Who>(k.code) {
            Took::View => {
                self.fleet_sel = 0;
                return true;
            }
            Took::Typing => return true,
            Took::No => {}
        }
        let rows: Vec<(Opens, String)> = self.fleet.as_ref().map_or(vec![], |f| {
            fleettab::shown(f, &self.fleet_table, &self.fleet_folded)
                .iter()
                .map(|r| (r.opens, r.key.clone()))
                .collect()
        });
        let last = rows.len().saturating_sub(1);
        self.fleet_sel = self.fleet_sel.min(last);
        match k.code {
            KeyCode::Char('j') | KeyCode::Down => self.fleet_sel = (self.fleet_sel + 1).min(last),
            KeyCode::Char('k') | KeyCode::Up => self.fleet_sel = self.fleet_sel.saturating_sub(1),
            KeyCode::Char('g') | KeyCode::Home => self.fleet_sel = 0,
            KeyCode::Char('G') | KeyCode::End => self.fleet_sel = last,
            KeyCode::Enter => match rows.get(self.fleet_sel).cloned() {
                Some((Opens::Runner, name)) => self.open_runner(&name),
                Some((Opens::Session, target)) => self.open_session(&target),
                None => {}
            },
            KeyCode::Char('z') => {
                if let Some((Opens::Runner, name)) = rows.get(self.fleet_sel) {
                    if !self.fleet_folded.remove(name) {
                        self.fleet_folded.insert(name.clone());
                    }
                }
            }
            KeyCode::Esc if !self.fleet_table.is_default() => self.fleet_table.clear(),
            _ => return false,
        }
        self.keep_fleet_sel_visible();
        true
    }

    /// The reader's errors, the heading, the status and the table head sit above the first row.
    fn keep_fleet_sel_visible(&mut self) {
        let errors = self.fleet.as_ref().map_or(0, |f| f.errors.len());
        let at = 3 + errors + self.fleet_sel;
        let h = self.page.max(1);
        if at < self.scroll {
            self.scroll = at;
        } else if at >= self.scroll + h {
            self.scroll = at + 1 - h;
        }
    }

    /// A request's query: the outbox on Daily, a section on Infra and Log, else a project name.
    pub fn open_query(&mut self, q: Option<String>) {
        match (self.tab, q) {
            (Tab::Daily, q) => {
                if q.is_some_and(|q| q.trim().eq_ignore_ascii_case("outbox")) {
                    self.show_outbox(true);
                }
            }
            (Tab::Infra | Tab::Log, Some(q)) => {
                let secs =
                    hub_core::layout::resolve(self.tab.title()).map_or(&[][..], |t| t.sections);
                if let Some(sec) = secs.iter().find(|s| s.eq_ignore_ascii_case(q.trim())) {
                    self.open_section(sec);
                }
            }
            // Fleet's own section names (`accounts`) scroll there; any other word is a runner.
            (Tab::Fleet, Some(q)) if !q.trim().is_empty() => {
                match crate::fleettab::runner_arg(&q) {
                    Some(name) => self.open_runner(name),
                    None => {
                        let secs = hub_core::layout::resolve(self.tab.title())
                            .map_or(&[][..], |t| t.sections);
                        if let Some(sec) = secs.iter().find(|s| s.eq_ignore_ascii_case(q.trim())) {
                            self.open_section(sec);
                        }
                    }
                }
            }
            (_, q) => self.open_project(q),
        }
    }

    /// Show one section of the tab: Infra's Jobs opens the jobs table, Log's History its day
    /// list and a Log fold opens; any other scrolls to its heading at the next draw.
    fn open_section(&mut self, sec: &'static str) {
        self.infra_jobs = sec == "jobs";
        self.log_days = self.tab == Tab::Log && sec == "history";
        if self.tab == Tab::Log && !self.log_open.contains(&sec) && FOLDS.iter().any(|f| f.0 == sec)
        {
            self.log_open.push(sec);
            self.read_log_folds();
        }
        if !self.infra_jobs && !self.log_days {
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
        self.log_days = false;
        self.seek = None;
        if t == Tab::Log {
            self.read_log_folds();
        }
        if t == Tab::Sessions {
            self.read_forecast();
            self.read_sessions();
        }
        if t == Tab::Fleet {
            self.read_fleet_shown();
        }
        if t == Tab::Infra {
            self.read_reds();
        }
        if t == Tab::Schedules {
            self.read_schedules();
        }
        if t == Tab::Daily {
            self.daily_outbox = false;
            self.read_focus();
        }
        if t == Tab::Queue {
            self.read_queue();
            self.read_candidates();
            self.read_pipeline();
        }
        if t == Tab::Projects {
            self.read_projects();
        }
        if t == Tab::Home {
            self.read_home();
        }
    }

    /// The Projects tab's keys: the card list's (projtab.rs), or with the rows open theirs
    /// (tasktab.rs), where Esc clears a filter first and then, like Backspace, goes back.
    fn projects_key(&mut self, k: KeyEvent) -> bool {
        if !self.pv.open {
            let cards = self.cards().cards;
            if k.code == KeyCode::Char('P') {
                // Card 0 is All, so card i is cards[i - 1].
                if let Some(c) = self.pv.card.checked_sub(1).and_then(|i| cards.get(i)) {
                    self.prio_act(
                        c.profile.clone(),
                        c.name.clone(),
                        hub_core::projects::next_prio(&c.prio),
                    );
                }
                return true;
            }
            return self.pv.key(&mut self.tv, k, &cards, self.page);
        }
        if self.tv.prompt.is_none() && self.tv.project.is_some() && k.code == KeyCode::Char('f') {
            self.pv.folds = !self.pv.folds;
            return true;
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

    /// The Queue tab's own keys (queuetab.rs): j/k, PgUp/PgDn, space, g/G and Ctrl-d/Ctrl-u
    /// pick an active item or a candidate, c arms a cancel, +/- move its priority, f folds the
    /// candidates and p promotes one. The draw keeps the selected row in view.
    fn queue_key(&mut self, k: KeyEvent) -> bool {
        // g and G take the page to its very top (the headings) and bottom (the Candidates fold),
        // which keeping the selected row in view alone would stop short of.
        match k.code {
            KeyCode::Char('g') | KeyCode::Home => self.scroll = 0,
            KeyCode::Char('G') | KeyCode::End => self.scroll = usize::MAX / 2,
            _ => {}
        }
        match self.qv.key(
            k,
            self.queue.as_ref(),
            cands_of(&self.candidates),
            self.page,
        ) {
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
            queuetab::Ask::Promote(label, w) => {
                self.queue_act(label, move |r| hub_core::tasks::apply(r, &w));
                true
            }
        }
    }

    /// The Sessions tab's keys (controls.rs): j/k pick a session, a letter arms an action's
    /// confirm, and with one armed every key is the confirm's; `/ f s S` are the shared table's
    /// and Esc clears its view; T starts a stopped timer; Enter opens the selected session's
    /// detail and goes to it. The page scrolls with PgUp/PgDn, space and g/G, and keeps
    /// the selected row in view while no detail is open.
    fn sessions_key(&mut self, k: KeyEvent) -> bool {
        match self.controls.key(k) {
            Ask::Pass => return false,
            Ask::Done => {}
            Ask::Run(t, a, acct) => self.act(t, a, acct),
            Ask::Start(name) => self.start_timer(name),
        }
        self.read_page();
        // The detail draws under the whole table, so the view goes to it, not to the row.
        if self.controls.open {
            self.seek = Some(DETAIL);
            return true;
        }
        // The stage counts line, then the table's own header.
        let at = 1 + self.controls.above() + self.controls.sel;
        let h = self.page.max(1);
        if at < self.scroll {
            self.scroll = at;
        } else if at >= self.scroll + h {
            self.scroll = at + 1 - h;
        }
        true
    }

    /// Log's ranked sessions: the last `outcomes::DAYS` days' sessions worst first, one line
    /// each, and the command that prints any one's full card.
    fn ranked_lines(&self, w: usize) -> Vec<Line<'static>> {
        let clip = |t: String, st| crate::fit::clip_line(Line::styled(t, st), w);
        let mut l = vec![];
        match &self.ranked {
            None => l.push(clip(
                "Reading agentctl-session-outcomes worst.".into(),
                self.p.dim(),
            )),
            Some(Err(e)) => l.push(clip(format!("No ranking: {e}"), self.p.warn())),
            Some(Ok(rows)) if rows.is_empty() => l.push(clip(
                "No session with friction this week.".into(),
                self.p.dim(),
            )),
            Some(Ok(rows)) => {
                l.extend(
                    rows.iter()
                        .map(|r| clip(r.line(), ratatui::style::Style::default())),
                );
                l.push(clip(
                    "  a full card: agentctl-session-outcomes card <id>".into(),
                    self.p.dim(),
                ));
            }
        }
        l
    }

    /// Log's keys. With the day list open (h): j/k pick a day, Enter opens it, Esc, Backspace
    /// or h go back. Otherwise h opens the day list, a `FOLDS` key opens or folds its section,
    /// and the day's keys.
    fn log_key(&mut self, k: KeyEvent) -> bool {
        if self.log_days {
            if matches!(
                k.code,
                KeyCode::Esc | KeyCode::Backspace | KeyCode::Char('h')
            ) {
                self.log_days = false;
                self.scroll = 0;
                return true;
            }
            return self.history_key(k);
        }
        match k.code {
            KeyCode::Char('h') => {
                self.log_days = true;
                self.scroll = 0;
            }
            KeyCode::Char(c) if FOLDS.iter().any(|f| f.1 == c) => {
                let Some(&(name, ..)) = FOLDS.iter().find(|f| f.1 == c) else {
                    return true;
                };
                if let Some(i) = self.log_open.iter().position(|n| *n == name) {
                    self.log_open.remove(i);
                } else {
                    self.log_open.push(name);
                    self.read_log_folds();
                    self.seek = Some(name);
                }
            }
            KeyCode::Char('V') if self.log_open.contains(&"verdicts") => {
                self.ask_filter = (self.ask_filter + 1) % ASK_FILTERS.len();
            }
            _ => return self.today_key(k),
        }
        true
    }

    /// The day's keys on Log: `[` and `]` step a day, n and N jump between sections.
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

    /// Show the outbox on the Daily tab (true) or the note (false), and read what is shown.
    fn show_outbox(&mut self, on: bool) {
        self.daily_outbox = on;
        self.outbox_said = None;
        self.scroll = 0;
        self.read_daily();
    }

    /// Daily's own keys: `o` shows the outbox and `o` or Esc goes back to the note; on the
    /// outbox Enter edits it, and on the note `[` and `]` step to the day before or after that
    /// has a note, `t` goes back to today.
    fn daily_key(&mut self, k: KeyEvent) -> bool {
        if self.daily_outbox {
            match k.code {
                KeyCode::Char('o') | KeyCode::Esc => self.show_outbox(false),
                KeyCode::Enter => {
                    let path = match &self.outbox {
                        Some(Ok(v)) if !v.doc.path.is_empty() => Some(v.doc.path.clone()),
                        _ => None,
                    };
                    self.outbox_said = Some(match path {
                        Some(p) => edit_in_tmux(&p, 1),
                        None => Err("the outbox has not been read yet: press r".into()),
                    });
                }
                _ => return false,
            }
            return true;
        }
        if k.code == KeyCode::Char('o') {
            self.show_outbox(true);
            return true;
        }
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

    /// Show a day on Log (None: the newest, live one) and read its record.
    fn open_day(&mut self, d: Option<String>) {
        self.day = d;
        self.scroll = 0;
        if let Some(b) = self.boards.as_mut() {
            b.rec = boards::record(&self.files.daylog, self.day.as_deref());
        }
    }

    /// Log's day list's keys: j/k pick a day, Enter opens it.
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
                self.log_days = false;
            }
            _ => return false,
        }
        true
    }

    /// The Jobs page's own keys; false hands the key to the global ones.
    /// n and N jump to the next or the previous section heading (Log, Infra).
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

    /// Home's own keys. The page: Enter and the table keys (/ f s) open the proposals table.
    /// The table: those keys, j/k, Enter the record, a accept, d reject; Esc steps back out.
    fn home_key(&mut self, k: KeyEvent) -> bool {
        if !self.prv.open {
            let opens = k.code == KeyCode::Enter || DataTable::owns(k.code);
            if !opens || open_rows(&self.proposals).is_empty() {
                return false;
            }
            self.prv.open = true;
            if k.code == KeyCode::Enter {
                return true;
            }
        }
        match self.prv.table.key::<Proposal>(k.code) {
            Took::View => {
                self.prv.sel = 0;
                return true;
            }
            Took::Typing => return true,
            Took::No => {}
        }
        let rows = self.prv.shown(open_rows(&self.proposals)).len();
        let pv = &mut self.prv;
        match k.code {
            KeyCode::Char('j') | KeyCode::Down => pv.sel = (pv.sel + 1).min(rows.saturating_sub(1)),
            KeyCode::Char('k') | KeyCode::Up => pv.sel = pv.sel.saturating_sub(1),
            KeyCode::Enter => pv.detail = !pv.detail,
            KeyCode::Char('a') => self.decide_proposal(true),
            KeyCode::Char('d') => self.decide_proposal(false),
            KeyCode::Esc | KeyCode::Backspace if pv.detail => pv.detail = false,
            KeyCode::Esc if !pv.table.is_default() => pv.table.clear(),
            KeyCode::Esc | KeyCode::Backspace => pv.open = false,
            _ => return false,
        }
        true
    }

    /// Infra's own keys. The summary: n/N jump between sections, Enter and the jobs keys
    /// (/ s f h) open the jobs table. The table: the jobs keys, and Esc with nothing to clear
    /// goes back to the summary.
    fn infra_key(&mut self, k: KeyEvent) -> bool {
        if !self.infra_jobs {
            match k.code {
                KeyCode::Char('n' | 'N') => self.next_section(k.code == KeyCode::Char('n')),
                KeyCode::Enter => self.infra_jobs = true,
                c if c == KeyCode::Char('h') || DataTable::owns(c) => {
                    self.infra_jobs = true;
                    return self.jobs_key(k);
                }
                _ => return false,
            }
            return true;
        }
        let jv = &self.jv;
        let root = jv.table.is_default() && jv.log.is_none() && jv.history.is_none();
        if root && matches!(k.code, KeyCode::Esc | KeyCode::Backspace) {
            self.infra_jobs = false;
            return true;
        }
        self.jobs_key(k)
    }

    fn jobs_key(&mut self, k: KeyEvent) -> bool {
        match self.jv.table.key::<Job>(k.code) {
            Took::View => {
                self.jv.sel = 0;
                return true;
            }
            Took::Typing => return true,
            Took::No => {}
        }
        let rows = self.jobs.as_ref().map_or(0, |j| self.jv.shown(j).len());
        let last = rows.saturating_sub(1);
        let n = self.page.max(1);
        let jv = &mut self.jv;
        match k.code {
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
                    jv.table.clear();
                    jv.sel = 0;
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

    fn selected_schedule(&self) -> Option<&Schedule> {
        let s = self.schedules.as_ref()?;
        self.sv.shown(s).get(self.sv.sel).copied()
    }

    /// The Schedules table's keys. Enter opens the row's pane, or an agentctl row's Fleet page,
    /// which already says all the pane would.
    fn schedules_key(&mut self, k: KeyEvent) -> bool {
        match self.sv.table.key::<Schedule>(k.code) {
            Took::View => {
                self.sv.sel = 0;
                return true;
            }
            Took::Typing => return true,
            Took::No => {}
        }
        let rows = self
            .schedules
            .as_ref()
            .map_or(0, |s| self.sv.shown(s).len());
        let last = rows.saturating_sub(1);
        let n = self.page.max(1);
        let before = self.sv.sel;
        let sv = &mut self.sv;
        match k.code {
            KeyCode::Char('j') | KeyCode::Down => sv.sel = (sv.sel + 1).min(last),
            KeyCode::Char('k') | KeyCode::Up => sv.sel = sv.sel.saturating_sub(1),
            KeyCode::Char('g') | KeyCode::Home => sv.sel = 0,
            KeyCode::Char('G') | KeyCode::End => sv.sel = last,
            KeyCode::PageDown => sv.sel = (sv.sel + n).min(last),
            KeyCode::PageUp => sv.sel = sv.sel.saturating_sub(n),
            KeyCode::Char('J') if sv.open => sv.down += 1,
            KeyCode::Char('K') if sv.open => sv.down = sv.down.saturating_sub(1),
            KeyCode::Enter => {
                let page = self.selected_schedule().map(|r| r.page.clone());
                match page.filter(|p| !p.is_empty()) {
                    Some(name) => {
                        self.go(Tab::Fleet);
                        self.open_runner(&name);
                    }
                    None => self.sv.open = !self.sv.open,
                }
            }
            KeyCode::Esc => {
                if sv.open {
                    sv.open = false;
                } else {
                    sv.table.clear();
                    sv.sel = 0;
                }
            }
            KeyCode::Char('o') => {
                let run = self.selected_schedule().and_then(|r| r.runs.first());
                if let Some(u) = run.filter(|u| !u.url.is_empty()) {
                    open(&u.url);
                }
            }
            _ => return false,
        }
        if self.sv.sel != before {
            self.sv.down = 0;
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
        f.render_widget(Paragraph::new(self.tab_bar(bar.width as usize)), bar);
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
        } else if self.tab == Tab::Schedules {
            self.draw_schedules(f, body);
        } else if self.tab == Tab::Home && self.prv.open {
            self.draw_proposals(f, body);
        } else if self.tab == Tab::Log && self.log_days && self.boards.is_some() {
            self.draw_history(f, body);
        } else {
            let (lines, sections) = self.body(body.width as usize);
            // Clamped first, so a jump to the end (G) is the last page before the selection is
            // kept in view on it.
            let max = lines.len().saturating_sub(body.height as usize);
            self.scroll = self.scroll.min(max);
            // The Projects and Queue tabs' one section is the selected card or row, kept in view.
            if let (Tab::Projects | Tab::Queue, Some(&(_, at))) = (self.tab, sections.first()) {
                let h = (body.height as usize).max(1);
                if at < self.scroll {
                    self.scroll = at.saturating_sub(2);
                } else if at >= self.scroll + h {
                    self.scroll = at + 1 - h;
                }
            }
            // A section asked for (`hub --tab ci`, a fold opened) is scrolled to once the page has it.
            if let Some(want) = self.seek {
                if let Some((_, at)) = sections.iter().find(|s| s.0 == want) {
                    self.scroll = *at;
                    self.seek = None;
                }
            }
            self.sections = sections;
            self.scroll = self.scroll.min(max);
            f.render_widget(Paragraph::new(lines).scroll((self.scroll as u16, 0)), body);
        }
        f.render_widget(
            Paragraph::new(Line::styled(self.hints(), self.p.dim())),
            foot,
        );
    }

    fn tab_bar(&self, w: usize) -> Line<'static> {
        let mut s = vec![Span::styled(" HUB ", self.p.head())];
        // Too narrow for every title, the tabs not shown keep their digit, so none is cut off.
        let full: usize = Tab::ALL.iter().map(|t| t.title().len() + 4).sum();
        let tight = " HUB ".len() + full > w;
        for t in Tab::ALL.iter() {
            // A tab with no digit yet (Daily) shows its title alone.
            let label = match t.digit() {
                ' ' => format!(" {} ", t.title()),
                d if tight && *t != self.tab => format!(" {d} "),
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
        let tabs = "1-9";
        match self.tab {
            Tab::Home if self.prv.table.typing.is_some() => {
                "type a query (word, key:value, -key:value), Enter applies, Esc cancels".into()
            }
            Tab::Home if self.prv.open => format!(
                "a accept  d reject  Enter record  / query  f state  s sort  S asc/desc  x clear  Esc back  r refresh  {tabs} tabs  q quit"
            ),
            Tab::Infra if !self.infra_jobs => format!(
                "n/N section  Enter jobs table  j/k PgUp/PgDn ^d/^u scroll  r refresh  o Grafana  {tabs} tabs  q quit"
            ),
            Tab::Infra if self.jv.table.typing.is_some() => {
                "type a query (word, key:value, -key:value), Enter applies, Esc cancels".into()
            }
            Tab::Infra if self.jv.log.is_some() => {
                "Esc close log  J/K PgUp/PgDn scroll log  j/k move  o open url  q quit".into()
            }
            Tab::Infra => format!(
                "Enter log  / query  f state  s sort  S asc/desc  x clear  h history  o open url  Esc back  r refresh  {tabs} tabs  q quit"
            ),
            Tab::Schedules if self.sv.table.typing.is_some() => {
                "type a query (word, key:value, -key:value), Enter applies, Esc cancels".into()
            }
            Tab::Schedules if self.sv.open => {
                "Esc close  J/K scroll pane  j/k move  o open newest run  q quit".into()
            }
            Tab::Schedules => format!(
                "Enter open  / query  f state  s sort  S asc/desc  x clear  o open newest run  r refresh  {tabs} tabs  q quit"
            ),
            Tab::Sessions if self.controls.table.typing.is_some() => {
                "type a query (word, key:value, -key:value), Enter applies, Esc clears".into()
            }
            Tab::Sessions if self.controls.starting.is_some() => "y/Enter yes  n/Esc no".into(),
            Tab::Sessions if self.controls.confirm.is_some() => {
                "y/Enter yes  n/Esc no  Left/Right account (move)".into()
            }
            Tab::Sessions => format!(
                "j/k pick  Enter detail  / query  f state  s sort  S asc/desc  Esc clear  i p u m x c a act  T start timer  PgUp/PgDn scroll  r refresh  {tabs} tabs  q quit"
            ),
            Tab::Fleet if self.fleet_table.typing.is_some() => {
                "type a query (tier:3 state:failed -who:x), Enter applies, Esc drops it".into()
            }
            Tab::Fleet if self.fleet_page.is_some() => format!(
                "[ ] runner  Esc all runners  j/k PgUp/PgDn scroll  r refresh  {tabs}/Tab pages  q quit"
            ),
            Tab::Fleet => format!(
                "j/k pick  Enter open  z fold  / query  f state  s/S sort  x clear  PgUp/PgDn scroll  r refresh  {tabs}/Tab pages  q quit"
            ),
            Tab::Daily if self.daily_outbox => {
                "Enter edit in $EDITOR  o/Esc the note  j/k PgUp/PgDn ^d/^u scroll  r refresh  Tab pages  q quit".into()
            }
            Tab::Daily if self.focus_day.is_some() => {
                "[ ] day  t today  o outbox  j/k PgUp/PgDn ^d/^u scroll  r refresh  Tab pages  q quit".into()
            }
            Tab::Daily => {
                "[ ] day  o outbox  j/k PgUp/PgDn ^d/^u scroll  r refresh  Tab pages  q quit".into()
            }
            Tab::Log if self.log_days => {
                format!("j/k pick a day  Enter open it  Esc back  {tabs} tabs  q quit")
            }
            Tab::Log => format!(
                "[ ] day{}  h days  a c s v f w fold  V verdict filter  n/N section  j/k PgUp/PgDn ^d/^u scroll  r refresh  {tabs} tabs  q quit",
                if self.day.is_some() { "  t today" } else { "" }
            ),
            Tab::Queue if self.qv.confirm.is_some() => "y/Enter yes  n/Esc no".into(),
            Tab::Queue => format!(
                "j/k PgUp/PgDn g/G ^d/^u pick  c cancel  +/- priority  f candidates  p promote  o Grafana  r refresh  {tabs} tabs  q quit"
            ),
            Tab::Projects if self.tv.prompt.is_some() => {
                "type, Enter submits, Esc cancels".into()
            }
            Tab::Projects if self.pv.open => format!(
                "j/k pick  / search  l lane  {}a add  s start  d done  D unverified  x drop  X dup  m move  e edit  t/T tag  +/- release  o open  Esc clear, back  r refresh  {tabs} tabs  q quit",
                if self.tv.project.is_some() { "f page sections  " } else { "" }
            ),
            Tab::Projects => format!(
                "j/k pick  Enter open rows  / search all  P priority  r refresh  {tabs} tabs  q quit"
            ),
            _ => format!("Enter proposals  {tabs}/Tab pages  j/k PgUp/PgDn ^d/^u scroll  r refresh  o Grafana  q quit"),
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
                let mut home = hub_core::home::build(
                    state,
                    self.queue.as_ref(),
                    self.tasks.as_ref(),
                    i.as_ref(),
                );
                match &self.proposals {
                    Some(open) => home.set_proposals(open),
                    None => home.proposals_unread = true,
                }
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
                            let pg = self.proj_page.as_ref().filter(|pg| pg.project == c.name);
                            l = projtab::open_lines(c, pg, self.pv.folds, self.p, w);
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
                Some(q) => {
                    let (l, at) = queuetab::page(
                        q,
                        &self.qv,
                        self.candidates.as_ref(),
                        (
                            self.pipeline.as_ref(),
                            self.infra.as_ref().is_some_and(|i| i.grafana.is_some()),
                        ),
                        self.p,
                        now,
                        w,
                    );
                    (l, at.map(|a| ("", a)).into_iter().collect())
                }
            },
            // One row per session (its controls, stage and ETA), the selected one's detail and
            // the asks; the changes, the forecast and the ranked sessions are Log's.
            (Tab::Sessions, b, _) => {
                let table = self.controls.lines(self.p, now, w);
                let l = match b {
                    None => {
                        let mut l = reading("the board files").0;
                        l.extend(table);
                        l
                    }
                    Some(b) => fleet::page(&b.watch, table, self.p, now, w),
                };
                // From the status line, two above, so an armed action's confirm stays on screen.
                let at = l
                    .iter()
                    .position(|x| crate::fit::plain(x).starts_with("DETAIL  "))
                    .map(|at| (DETAIL, at.saturating_sub(2)));
                (l, at.into_iter().collect())
            }
            // Who is working (runners by tier, then the live sessions), then who pays.
            (Tab::Fleet, ..) if self.fleet_page.is_some() => (
                fleettab::runner_page(
                    self.fleet_page.as_deref().unwrap_or_default(),
                    self.fleet_runner.as_ref(),
                    self.p,
                    now,
                    w,
                ),
                vec![],
            ),
            (Tab::Fleet, ..) => match &self.fleet {
                None => reading("the fleet"),
                Some(f) => (
                    fleettab::page(
                        f,
                        &self.fleet_table,
                        &self.fleet_folded,
                        self.fleet_sel,
                        self.p,
                        now,
                        w,
                    ),
                    vec![],
                ),
            },
            // Daily's outbox view: the outbox and today's intake steps (outboxtab.rs); Enter
            // edits the file.
            (Tab::Daily, ..) if self.daily_outbox => match &self.outbox {
                None => reading("the outbox"),
                Some(Err(e)) => (vec![Line::styled(e.clone(), self.p.warn())], vec![]),
                Some(Ok(v)) => {
                    let mut l = match &self.outbox_said {
                        Some(Ok(m)) => vec![Line::styled(m.clone(), self.p.dim())],
                        Some(Err(e)) => vec![Line::styled(e.clone(), self.p.warn())],
                        None => vec![],
                    };
                    l.extend(outboxtab::page(v, self.p, w));
                    (l, vec![])
                }
            },
            // The daily note's Focus lanes, read-only (focustab.rs).
            (Tab::Daily, ..) => match &self.focus {
                None => reading("the daily note"),
                Some(Err(e)) => (vec![Line::styled(e.clone(), self.p.warn())], vec![]),
                Some(Ok(v)) => (focustab::page(v, self.p, w), vec![]),
            },
            (Tab::Log, None, _) => reading("the board files"),
            (Tab::Log, Some(b), _) if self.log_days => {
                (day::history(&b.hist, self.hist_sel, self.p, w), vec![])
            }
            (Tab::Log, Some(b), _) => self.log_page(b, now, w),
            (_, _, None) => reading("Prometheus"),
            // Infra's sections in hub_core::layout order, a blank line between them.
            (_, _, Some(i)) => {
                let mut secs = board::infra(i, self.p, now, w, &self.hosts);
                // Red fixes is read on its own, so it goes in under Red now (or last, when a
                // failed Prometheus read left only the error).
                let at = secs
                    .iter()
                    .position(|s| s.0 == "red")
                    .map_or(secs.len(), |n| n + 1);
                let fixes = board::fixes(self.reds.as_ref(), self.p, now, w);
                secs.insert(at, ("fixes", fixes));
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

    /// Log: the day, then its history and each `FOLDS` section, a heading with its count when
    /// it is known and, when open, its rows; the section names are hub_core::layout's.
    fn log_page(
        &self,
        b: &Boards,
        now: i64,
        w: usize,
    ) -> (Vec<Line<'static>>, Vec<(&'static str, usize)>) {
        let head = |t: String| crate::fit::clip_line(Line::styled(t, self.p.head()), w);
        let pg = day::today(b.rec.as_ref(), self.p, now, w);
        let mut at: Vec<(&'static str, usize)> = vec![("day", 0)];
        at.extend(pg.sections.into_iter().filter(|s| *s > 0).map(|s| ("", s)));
        let mut l = pg.lines;
        l.push(Line::raw(""));
        at.push(("history", l.len()));
        l.push(head(format!(
            "HISTORY ({})  h lists the days",
            b.hist.len()
        )));
        for (name, key, title) in FOLDS {
            l.push(Line::raw(""));
            at.push((name, l.len()));
            let count = match name {
                "actions" => self.actions.as_ref().map(|g| g.actions.len()),
                "changes" => Some(b.watch.transitions.len()),
                "rundowns" => Some(b.rundowns_total),
                "ranked" => match &self.ranked {
                    Some(Ok(r)) => Some(r.len()),
                    _ => None,
                },
                _ => None,
            };
            let count = count.map_or(String::new(), |n| format!(" ({n})"));
            let open = self.log_open.contains(&name);
            let verb = if open { "folds" } else { "opens" };
            l.push(head(format!("{title}{count}  {key} {verb} it")));
            if !open {
                continue;
            }
            let reading =
                |what: &str| vec![Line::styled(format!("  Reading {what}..."), self.p.dim())];
            l.extend(match name {
                "actions" => match &self.actions {
                    None => reading("the actions"),
                    Some(g) => logtab::actions(g, self.p, now, w),
                },
                "changes" => fleet::changes(&b.watch, self.p, now, w),
                "rundowns" => logtab::rundowns(&b.rundowns, b.rundowns_total, self.p, w),
                "verdicts" => match &self.fleet {
                    None => reading("the fleet"),
                    Some(f) => fleettab::verdicts(f, ASK_FILTERS[self.ask_filter], self.p, now, w),
                },
                "forecast" => match &self.forecast {
                    None => reading("fleet-bench forecast"),
                    Some(f) => forecast::page(f, self.p, now, w),
                },
                _ => self.ranked_lines(w),
            });
        }
        (l, at)
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

    fn draw_schedules(&mut self, f: &mut Frame, area: Rect) {
        let Some(s) = &self.schedules else {
            f.render_widget(
                Paragraph::new(Line::styled("Reading schedules...", self.p.dim())),
                area,
            );
            return;
        };
        let (list, pane) = if self.sv.open {
            let [a, b] = Layout::vertical([Constraint::Percentage(50), Constraint::Percentage(50)])
                .areas(area);
            (a, Some(b))
        } else {
            (area, None)
        };
        let status = self.sv.status(s, self.p);
        let table = self.sv.table(s, self.p, list.width as usize, true);
        let h = (list.height as usize)
            .saturating_sub(status.len() + 1)
            .max(1);
        self.page = h;
        // Keep the selection in view: the table header stays, rows scroll under it.
        let sv = &mut self.sv;
        if sv.sel < sv.top {
            sv.top = sv.sel;
        } else if sv.sel >= sv.top + h {
            sv.top = sv.sel + 1 - h;
        }
        let mut lines = status;
        lines.extend(table.iter().take(1).cloned());
        lines.extend(table.into_iter().skip(1 + sv.top).take(h));
        f.render_widget(Paragraph::new(lines), list);
        let row = self.sv.shown(s).get(self.sv.sel).copied();
        if let (Some(area), Some(r)) = (pane, row) {
            let lines = schedules::detail(r, self.p, s.at, area.width as usize);
            let max = lines.len().saturating_sub(area.height as usize);
            self.sv.down = self.sv.down.min(max);
            let shown: Vec<Line> = lines.into_iter().skip(self.sv.down).collect();
            f.render_widget(Paragraph::new(shown), area);
        }
    }

    fn draw_proposals(&mut self, f: &mut Frame, area: Rect) {
        let rows = open_rows(&self.proposals);
        let w = area.width as usize;
        let mut lines = self.prv.status(rows, self.p);
        let record = if self.prv.detail {
            self.prv.record(rows, self.p, w)
        } else {
            vec![]
        };
        let table = self.prv.lines(rows, self.p, jobs::now(), w);
        let h = (area.height as usize)
            .saturating_sub(lines.len() + 1 + record.len())
            .max(1);
        let pv = &mut self.prv;
        if pv.sel < pv.top {
            pv.top = pv.sel;
        } else if pv.sel >= pv.top + h {
            pv.top = pv.sel + 1 - h;
        }
        lines.extend(table.iter().take(1).cloned());
        lines.extend(table.into_iter().skip(1 + pv.top).take(h));
        lines.extend(record);
        f.render_widget(Paragraph::new(lines), area);
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

/// The candidates read, or none while it is reading or failed.
fn open_rows(p: &Option<Result<Vec<proposals::Proposal>, String>>) -> &[proposals::Proposal] {
    match p {
        Some(Ok(r)) => r,
        _ => &[],
    }
}

fn cands_of(c: &Option<Result<Candidates, String>>) -> &[Candidate] {
    match c {
        Some(Ok(c)) => &c.rows,
        _ => &[],
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

    #[test]
    fn read_sessions_now_fills_everything_the_tab_draws() {
        // `--once` has no workers: a source left out here is a part missing from the printed page.
        let mut a = app(Tab::Sessions);
        let fake = Arc::new(Fake::default());
        a.runner = fake.clone();
        a.gather = fixture_sessions;
        a.read_sessions_now();
        assert!(a.controls.capacity.is_some(), "the header has its parts");
        assert!(
            !a.controls.rows().is_empty(),
            "the snapshot reached the table"
        );
        let ran = fake.0.lock().unwrap().join("\n");
        assert!(ran.contains("agentctl-session-outcomes ended"), "{ran}");
        assert!(ran.contains("fleet-dispatch headroom --json"), "{ran}");
    }

    #[test]
    fn o_on_the_queue_tab_opens_the_agents_overview_through_the_shared_grafana_path() {
        // `o` is not a Queue key (queuetab::key passes it), so the app-wide `o` handles it;
        // Queue was the only tab with trends in Grafana and no dashboard named.
        assert_eq!(Tab::Queue.dashboard(), Some("kb-agents-overview"));
        let mut a = app(Tab::Queue);
        assert_eq!(
            queuetab::QueueView::default().key(
                KeyEvent::new(KeyCode::Char('o'), KeyModifiers::NONE),
                Some(&queuetab::tests::fixture()),
                &[],
                10
            ),
            queuetab::Ask::Pass
        );
        // With no Grafana known nothing opens and nothing is spawned.
        a.handle(key('o'));
        assert!(!a.quit);
    }

    #[test]
    fn the_queue_tab_shows_the_pipeline_line_first() {
        let mut a = app(Tab::Queue);
        a.handle(Msg::Queue(Box::new(queuetab::tests::fixture())));
        let top = |a: &mut App| {
            a.page_lines(80)
                .iter()
                .take(2)
                .map(|l| l.to_string())
                .collect::<Vec<_>>()
        };
        assert!(top(&mut a)[0].starts_with("pipeline  reading"));
        a.handle(Msg::Pipeline(Ok(None)));
        assert_eq!(top(&mut a)[0], "pipeline -");
    }

    /// A queue longer than any screen: `n` queued items, item-0 first.
    fn long_queue(n: usize) -> hub_core::queue::Queue {
        let jsonl: Vec<String> = (0..n)
            .map(|i| format!(r#"{{"slug":"item-{i}","project":"dotfiles","mode":"oneshot","priority":"high","queued":"2026-11-03T10:{:02}:00Z","state":"queued","task":"Task {i}"}}"#, i % 60))
            .collect();
        hub_core::queue::Queue {
            items: hub_core::queue::parse(&jsonl.join("\n")),
            stats: None,
            errors: vec![],
        }
    }

    fn ctrl(c: char) -> Msg {
        Msg::Input(Event::Key(KeyEvent::new(
            KeyCode::Char(c),
            KeyModifiers::CONTROL,
        )))
    }

    #[test]
    fn the_queue_page_follows_the_selection_past_the_bottom() {
        let mut a = app(Tab::Queue);
        a.handle(Msg::Queue(Box::new(long_queue(40))));
        assert!(!screen(&mut a, 80, 20).contains("item-30"));
        for _ in 0..30 {
            a.handle(key('j'));
        }
        let s = screen(&mut a, 80, 20);
        assert_eq!(a.qv.sel, 30);
        assert!(a.scroll > 0, "the page scrolled with the selection");
        assert!(s.contains("item-30"), "the selected row is on screen:\n{s}");
        a.handle(key('k'));
        assert!(screen(&mut a, 80, 20).contains("item-29"));
    }

    #[test]
    fn g_and_shift_g_jump_the_queue_selection_and_the_page_with_it() {
        let mut a = app(Tab::Queue);
        a.handle(Msg::Queue(Box::new(long_queue(40))));
        screen(&mut a, 80, 20);
        a.handle(key('G'));
        let s = screen(&mut a, 80, 20);
        assert_eq!(a.qv.sel, 39);
        assert!(s.contains("item-39"), "{s}");
        assert!(s.contains("CANDIDATES"), "G reaches the page's end:\n{s}");
        a.handle(key('g'));
        let s = screen(&mut a, 80, 20);
        assert_eq!((a.qv.sel, a.scroll), (0, 0));
        assert!(s.contains("item-0"), "{s}");
        // PgDn and space move the selection a page; the page follows rather than snapping back.
        a.handle(Msg::Input(Event::Key(KeyEvent::from(KeyCode::PageDown))));
        assert_eq!(a.qv.sel, a.page);
        let want = format!("item-{}", a.page);
        assert!(screen(&mut a, 80, 20).contains(&want));
    }

    #[test]
    fn ctrl_d_and_ctrl_u_move_the_queue_selection_half_a_page() {
        let mut a = app(Tab::Queue);
        a.handle(Msg::Queue(Box::new(long_queue(40))));
        screen(&mut a, 80, 20);
        let half = a.page / 2;
        assert!(half > 0);
        a.handle(ctrl('d'));
        assert_eq!(a.qv.sel, half);
        a.handle(ctrl('d'));
        assert_eq!(a.qv.sel, 2 * half);
        a.handle(ctrl('u'));
        assert_eq!(a.qv.sel, half);
        // NEGATIVE CONTROL: a plain d or u is no move.
        a.handle(key('d'));
        a.handle(key('u'));
        assert_eq!(a.qv.sel, half);
    }

    #[test]
    fn ctrl_d_scrolls_any_other_page_half_a_page() {
        let mut a = app(Tab::Fleet);
        a.page = 20;
        a.handle(ctrl('d'));
        assert_eq!(a.scroll, 10);
        a.handle(ctrl('u'));
        assert_eq!(a.scroll, 0);
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
        // No test reaches Prometheus: a read in flight is never started again.
        a.pipeline_read.busy = true;
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
            rundowns: vec![],
            rundowns_total: 0,
        }
    }

    /// Log with the board files read; the folds that read a command or the ledgers are marked
    /// already reading, so no test runs one.
    fn log_app(tx: Sender<Msg>) -> App {
        let mut a = with_tx(Tab::Log, tx);
        a.boards = Some(boards());
        a.forecast_read.busy = true;
        a.fleet_read.busy = true;
        a.actions_read.busy = true;
        a
    }

    #[test]
    fn the_sessions_tab_is_one_row_per_session_with_a_confirm() {
        let mut a = app(Tab::Sessions);
        a.controls.set(crate::controls::tests::fixture());
        let s = screen(&mut a, 140, 30);
        let lines: Vec<&str> = s.lines().collect();
        assert!(lines[0].contains("5 Sessions"), "{s}");
        assert!(lines[1].contains("Reading the board files..."), "{s}");
        assert!(lines[2].starts_with("all 2  running"), "{s}");
        assert!(
            lines[3].starts_with("STAGE") && lines[3].contains("ACCOUNT"),
            "{s}"
        );
        for want in ["dotfiles-agent-3:2", "here", "idle", "bnb", "a1"] {
            assert!(
                lines[4].contains(want),
                "{want} missing from {:?}",
                lines[4]
            );
        }
        assert!(
            lines[5].contains("dotfiles-agent-9") && lines[5].contains("parked"),
            "{s}"
        );
        assert!(!s.contains("FORECAST"), "the forecast is Log's: {s}");
        assert!(lines[29].contains("j/k pick  Enter detail  / query"), "{s}");

        // The stages join by target: the NEEDS row is the live session, and it sorts first.
        a.handle(Msg::Boards(Box::new(boards())));
        let s = screen(&mut a, 160, 30);
        let lines: Vec<&str> = s.lines().collect();
        assert!(lines[1].starts_with("SESSIONS   state"), "{s}");
        let row = lines[4];
        for want in ["dotfiles-agent-3:2", "NEEDS", "here", "bnb", "a1"] {
            assert!(row.contains(want), "{want} missing from {row:?}");
        }
        assert!(
            lines[5].contains("unity-core-playground-agent-10") && lines[5].contains("WORKING")
        );
        assert!(
            lines[6].contains("dotfiles-agent-9") && lines[6].contains("parked"),
            "{s}"
        );
        assert!(
            s.contains("ASKS (1)") && !s.contains("CHANGES"),
            "the changes are Log's: {s}"
        );

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
        for want in ["test 10m", "cargo test"] {
            assert!(s.contains(want), "{want} missing from\n{s}");
        }
        assert!(!s.contains("3 behind"), "the page's Worktree says it: {s}");
        assert!(s.contains("TIMELINE"), "{s}");
        assert!(s.contains("PAGE       reading"), "{s}");
        a.handle(Msg::Input(Event::Key(KeyEvent::from(KeyCode::Esc))));
        assert!(!screen(&mut a, 200, 60).contains("DETAIL"));
    }

    #[test]
    fn opening_a_row_of_a_table_taller_than_the_window_goes_to_its_detail() {
        let target = "lab/unity-core-playground-agent-10:1";
        let enter = || Msg::Input(Event::Key(KeyEvent::from(KeyCode::Enter)));
        let mut a = app(Tab::Sessions);
        a.handle(Msg::Boards(Box::new(boards())));
        a.handle(key('j'));
        assert!(!screen(&mut a, 200, 8).contains("DETAIL"));
        a.handle(enter());
        assert!(screen(&mut a, 200, 8).contains(&format!("DETAIL  {target}")));
        a.handle(Msg::Input(Event::Key(KeyEvent::from(KeyCode::Esc))));
        let s = screen(&mut a, 200, 8);
        assert!(!s.contains("DETAIL") && s.contains("unity-core"), "{s}");

        let mut a = app(Tab::Fleet);
        a.handle(Msg::Boards(Box::new(boards())));
        a.open_session(target);
        assert!(screen(&mut a, 200, 8).contains(&format!("DETAIL  {target}")));
    }

    #[test]
    fn the_status_line_stays_above_the_detail_so_a_confirm_is_on_screen() {
        let mut a = app(Tab::Sessions);
        a.controls.set(crate::controls::tests::fixture());
        screen(&mut a, 140, 7);
        a.handle(Msg::Input(Event::Key(KeyEvent::from(KeyCode::Enter))));
        a.handle(key('x'));
        let s = screen(&mut a, 140, 7);
        assert!(s.contains("It will") && s.contains("DETAIL"), "{s}");
    }

    #[test]
    fn the_detail_draws_the_page_for_its_row_and_drops_one_for_a_row_left_since() {
        use hub_core::session_page::{Part, SessionPage};
        let mut a = app(Tab::Sessions);
        a.handle(Msg::Boards(Box::new(boards())));
        a.handle(key('j'));
        a.handle(Msg::Input(Event::Key(KeyEvent::from(KeyCode::Enter))));
        let id = "lab/unity-core-playground-agent-10:1".to_string();
        let part = |label, text: &str, link: Option<&str>, warn| Part {
            label,
            text: text.into(),
            link: link.map(String::from),
            warn,
        };
        let page = SessionPage {
            parts: vec![
                part("Queue item", "the-item (running)", Some("#queue"), false),
                part("Worktree", "~/w  branch feat/x", None, false),
                part(
                    "PR",
                    "#12 open",
                    Some("https://github.com/o/r/pull/12"),
                    true,
                ),
            ],
            errors: vec!["notes board: exit 1".into()],
            ..SessionPage::default()
        };
        a.handle(Msg::SessionPage(Box::new((
            "other:1".into(),
            Some(page.clone()),
        ))));
        assert!(screen(&mut a, 200, 80).contains("PAGE       reading"));
        a.handle(Msg::SessionPage(Box::new((id.clone(), Some(page)))));
        let s = screen(&mut a, 200, 80);
        for want in [
            "QUEUE ITEM the-item (running)",
            "WORKTREE   ~/w  branch feat/x",
            "PR         #12 open  https://github.com/o/r/pull/12",
            "ERROR      notes board: exit 1",
        ] {
            assert!(s.contains(want), "{want} missing from\n{s}");
        }
        assert!(!s.contains("#queue"), "a tab link means nothing here: {s}");
        a.handle(Msg::SessionPage(Box::new((id, None))));
        assert!(screen(&mut a, 200, 80).contains("nothing names this session"));
    }

    #[test]
    fn the_forecasts_etas_are_the_sessions_rows_and_its_bands_a_log_fold() {
        let mut a = app(Tab::Sessions);
        let mut b = boards();
        b.watch.state["sessions"][0]["target"] = "hub/dotfiles:8".into();
        a.handle(Msg::Boards(Box::new(b)));
        a.handle(Msg::Forecast(Box::new(forecast::tests::fixture())));
        let s = screen(&mut a, 200, 60);
        assert!(s.contains("late 5h35m"), "the forecast's ETA wins: {s}");
        assert!(!s.contains("FORECAST"), "the bands are Log's: {s}");
        let (tx, _rx) = std::sync::mpsc::channel();
        let mut a = log_app(tx);
        a.forecast = Some(forecast::tests::fixture());
        assert!(screen(&mut a, 200, 60).contains("FORECAST  f opens it"));
        a.handle(key('f'));
        let s = screen(&mut a, 200, 120);
        assert!(s.contains("FORECAST  f folds it"), "{s}");
        assert!(s.contains("not draining (in 10.63/h, out 6.88/h)"), "{s}");
        assert!(s.contains("BURN-UP 24h"), "{s}");
    }

    #[test]
    fn the_ranked_sessions_are_a_log_fold_read_only_when_opened() {
        let (tx, rx) = std::sync::mpsc::channel();
        let mut a = log_app(tx);
        let fake = Arc::new(Fake::default());
        a.runner = fake.clone();
        let s = screen(&mut a, 200, 80);
        assert!(s.contains("RANKED SESSIONS  w opens it"), "{s}");
        assert!(
            fake.0.lock().unwrap().is_empty(),
            "nothing is read while it is folded"
        );
        a.handle(key('w'));
        // The worker sends Ranked when the read ends: wait for that message, not a timer.
        loop {
            match rx.recv().unwrap() {
                Msg::Ranked(r) => {
                    a.handle(Msg::Ranked(r));
                    break;
                }
                m => a.handle(m),
            }
        }
        assert_eq!(
            fake.0.lock().unwrap().as_slice(),
            ["agentctl-session-outcomes worst --json --days 7 -n 20"]
        );
        assert!(screen(&mut a, 200, 80).contains("No session with friction this week."));
        a.handle(Msg::Ranked(Ok(vec![Ranked {
            session_id: "6f296b73-b7a5".into(),
            project: "dotfiles".into(),
            title: "fix the gate".into(),
            friction: 11,
            why: "9 nudges".into(),
            prs_merged: 1,
            ..Ranked::default()
        }])));
        let s = screen(&mut a, 200, 80);
        assert!(s.contains("RANKED SESSIONS (1)  w folds it"), "{s}");
        assert!(s.contains(" 11  6f296b73  dotfiles"), "{s}");
        assert!(s.contains("agentctl-session-outcomes card <id>"), "{s}");
        a.handle(key('w'));
        assert!(screen(&mut a, 200, 80).contains("RANKED SESSIONS (1)  w opens it"));
    }

    #[test]
    fn log_is_the_day_then_its_history_and_folds_in_layout_order() {
        let (tx, _rx) = std::sync::mpsc::channel();
        let mut a = log_app(tx);
        let s = screen(&mut a, 160, 60);
        let at = |h: &str| s.find(h).unwrap_or_else(|| panic!("{h} missing from\n{s}"));
        let heads = [
            "HISTORY (0)  h lists the days",
            "ACTIONS  a opens it",
            "CHANGES (",
            "RUNDOWNS (0)  s opens it",
            "JUDGES' VERDICTS  v opens it",
            "FORECAST  f opens it",
            "RANKED SESSIONS  w opens it",
        ];
        for w in heads.windows(2) {
            assert!(at(w[0]) < at(w[1]), "{} is not above {}", w[0], w[1]);
        }
        // Changes open in place, under their heading; c folds them again.
        a.handle(key('c'));
        let s = screen(&mut a, 160, 80);
        assert!(s.contains("c folds it"), "{s}");
        a.handle(key('c'));
        assert!(screen(&mut a, 160, 80).contains("c opens it"));
        // h swaps the day for the day list, Esc brings the day back.
        a.handle(key('h'));
        assert!(a.log_days);
        a.handle(Msg::Input(Event::Key(KeyEvent::from(KeyCode::Esc))));
        assert!(!a.log_days);
    }

    #[test]
    fn log_folds_are_the_layout() {
        let log = hub_core::layout::resolve("log").unwrap();
        let mut want = vec!["day", "history"];
        want.extend(FOLDS.iter().map(|f| f.0));
        assert_eq!(log.sections, want.as_slice());
    }

    #[test]
    fn capital_v_steps_the_verdict_filter_only_while_the_fold_is_open() {
        let (tx, _rx) = std::sync::mpsc::channel();
        let mut a = log_app(tx);
        a.tab = Tab::Log;
        let key =
            |a: &mut App, c| a.handle(Msg::Input(Event::Key(KeyEvent::from(KeyCode::Char(c)))));
        key(&mut a, 'V');
        assert_eq!(a.ask_filter, 0);
        a.log_open.push("verdicts");
        key(&mut a, 'V');
        assert_eq!(ASK_FILTERS[a.ask_filter], "answered");
        for _ in 1..ASK_FILTERS.len() {
            key(&mut a, 'V');
        }
        assert_eq!(a.ask_filter, 0);
    }

    #[test]
    fn hub_tab_actions_opens_logs_actions_fold() {
        let (tx, _rx) = std::sync::mpsc::channel();
        let mut a = log_app(tx);
        a.tab = Tab::Home;
        let (t, q) = crate::tabreq::parse("actions").unwrap();
        a.handle(Msg::Tab(t, q));
        assert_eq!((a.tab, a.log_open.as_slice()), (Tab::Log, &["actions"][..]));
        assert!(screen(&mut a, 160, 60).contains("Reading the actions..."));
        a.handle(Msg::Actions(Box::default()));
        let s = screen(&mut a, 160, 60);
        assert!(s.contains("ACTIONS (0)  a folds it"), "{s}");
        assert!(s.contains("nothing in the last 24h"), "{s}");
        // A retired day-list name opens the list itself.
        let (t, q) = crate::tabreq::parse("history").unwrap();
        a.handle(Msg::Tab(t, q));
        assert!(a.log_days);
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
    fn three_opens_the_queue_tab_and_home_counts_the_queue() {
        let mut a = app(Tab::Home);
        assert!(screen(&mut a, 140, 30).contains("Prometheus: reading"));
        a.handle(Msg::Queue(Box::new(queuetab::tests::fixture())));
        let s = screen(&mut a, 140, 30);
        let lines: Vec<&str> = s.lines().collect();
        assert!(
            lines[0].contains("1 Home  2 Daily  3 Queue  4 Projects  5 Sessions  6 Infra"),
            "{s}"
        );
        assert!(
            s.contains("NUMBERS  queue 1 running, 2 up next (1 held) | done today 1"),
            "{s}"
        );
        assert!(s.contains("RUNNING (1)"), "{s}");

        a.handle(key('3'));
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

    #[test]
    fn the_queue_tab_reads_candidates_and_p_promotes_through_fleet_dispatch() {
        let (tx, rx) = std::sync::mpsc::channel();
        let mut a = with_tx(Tab::Home, tx);
        let fake = Arc::new(Fake::default());
        a.runner = fake.clone();
        a.handle(Msg::Queue(Box::new(queuetab::tests::fixture())));
        a.handle(Msg::QueueFiles);
        a.handle(key('3'));
        // Both workers reply when their read ends: wait for the two messages, not a timer.
        let (mut queue, mut cands) = (false, false);
        while !(queue && cands) {
            let m = rx.recv().unwrap();
            queue |= matches!(m, Msg::Queue(_));
            cands |= matches!(m, Msg::Candidates(_));
            a.handle(m);
        }
        // The fake's queue read came back empty; put the fixture back.
        a.handle(Msg::Queue(Box::new(queuetab::tests::fixture())));
        let ran = fake.0.lock().unwrap().clone();
        assert_eq!(
            ran.iter()
                .filter(|c| *c == "fleet-dispatch suggest --json")
                .count(),
            1,
            "read once, on entering the tab, not on a queue file event: {ran:?}"
        );
        assert!(screen(&mut a, 160, 40).contains("+ CANDIDATES (0, 0 auto)"));
        a.handle(Msg::Candidates(Ok(queuetab::tests::cands())));
        a.handle(key('f'));
        for _ in 0..4 {
            a.handle(key('j'));
        }
        let s = screen(&mut a, 160, 40);
        assert!(s.contains("bar-17") && s.contains("auto dispatch"), "{s}");
        assert!(s.contains("f candidates  p promote"), "{s}");
        a.handle(key('p'));
        assert_eq!(a.qv.running.as_deref(), Some("promote shape-city bar-17"));
        loop {
            match rx.recv().unwrap() {
                Msg::QueueActed(r) => {
                    a.handle(Msg::QueueActed(r));
                    break;
                }
                m => a.handle(m),
            }
        }
        let ran = fake.0.lock().unwrap().clone();
        assert!(
            ran.contains(&"fleet-dispatch promote --project shape-city --profile bnb --agent --raw - [ ] fix the jump arc #high <!-- id:bar-17 -->".to_string()),
            "{ran:?}"
        );
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
    fn p_on_a_card_steps_its_priority_through_the_cli_and_all_writes_nothing() {
        let (tx, rx) = std::sync::mpsc::channel();
        let mut a = with_tx(Tab::Home, tx);
        let fake = Arc::new(Fake::default());
        a.runner = fake.clone();
        a.handle(key('4'));
        settle(&mut a, &rx);
        a.handle(Msg::Tasks(Box::new(Ok(crate::tasktab::tests::fixture()))));
        let mut l = loaded();
        if let Ok(st) = l.stats.as_mut() {
            st[1].prio = "focus".into();
        }
        a.handle(Msg::Projects(Box::new(l)));
        let s = screen(&mut a, 140, 30);
        assert!(s.contains("DEMO  bnb, alpha, prio focus"), "{s}");
        assert!(!s.contains("GARDEN  personal, alpha, prio"), "{s}");
        assert!(s.lines().last().unwrap().contains("P priority"), "{s}");
        fake.0.lock().unwrap().clear();
        a.handle(key('P'));
        assert!(fake.0.lock().unwrap().is_empty(), "All is not a project");
        a.handle(key('j'));
        a.handle(key('P'));
        assert_eq!(a.tv.running.as_deref(), Some("demo prio high"));
        loop {
            if let Msg::TasksActed(r) = rx.recv().unwrap() {
                a.handle(Msg::TasksActed(r));
                break;
            }
        }
        let ran = fake.0.lock().unwrap().clone();
        assert!(
            ran.iter()
                .any(|c| c == "notes projects --prio demo --profile bnb --set high"),
            "{ran:?}"
        );
    }

    #[test]
    fn the_projects_tab_lists_cards_then_opens_one_projects_rows_under_its_card() {
        let (tx, rx) = std::sync::mpsc::channel();
        let mut a = with_tx(Tab::Home, tx);
        let fake = Arc::new(Fake::default());
        a.runner = fake.clone();
        assert_eq!(Tab::parse("board"), Some(Tab::Projects), "board is retired");
        // Projects is the fourth tab, so 4 opens it.
        a.handle(key('4'));
        assert_eq!(a.tab, Tab::Projects);
        let s = screen(&mut a, 140, 30);
        let bar = s.lines().next().unwrap();
        assert!(
            bar.contains("4 Projects  5 Sessions") && bar.contains("8 Fleet"),
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
            at("ALL PROJECTS  4 open rows") < at("DEMO  bnb, alpha"),
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
        let ran = |f: &Fake| f.0.lock().unwrap().join("\n");
        assert!(
            !ran(&fake).contains("fleet-bench"),
            "the list reads no page"
        );
        a.handle(Msg::Input(Event::Key(KeyEvent::from(KeyCode::Enter))));
        assert_eq!(a.tv.project, Some(("bnb".into(), "demo".into())));
        // Opening it reads its page once, in a worker; it draws as heads with counts, f opens them.
        assert!(screen(&mut a, 140, 30).contains("reading the page..."));
        loop {
            match rx.recv().unwrap() {
                Msg::ProjPage(pg) => {
                    assert_eq!(pg.project, "demo");
                    a.handle(Msg::ProjPage(pg));
                    break;
                }
                m => a.handle(m),
            }
        }
        assert!(ran(&fake).contains("fleet-bench epics --json --project demo"));
        let s = screen(&mut a, 140, 40);
        assert!(s.contains("NEEDS YOU") && s.contains("NEXT STAGE"), "{s}");
        assert!(s.contains("f opens it"), "{s}");
        assert!(s.lines().last().unwrap().contains("f page sections"), "{s}");
        a.handle(key('f'));
        assert!(a.pv.folds);
        assert!(!screen(&mut a, 140, 40).contains("f opens it"));
        a.handle(key('f'));
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

    fn proposal(id: &str, stream: &str) -> Proposal {
        Proposal {
            id: id.into(),
            stream: stream.into(),
            project: "dotfiles".into(),
            title: format!("Do {id}"),
            why: "it costs".into(),
            verb: "queue".into(),
            does: "agent-queue add --project dotfiles -- x".into(),
            created: "2026-11-05T10:00:00Z".into(),
            ..Proposal::default()
        }
    }

    #[test]
    fn home_says_nothing_about_proposals_before_the_read_answers() {
        let mut a = app(Tab::Home);
        let s = screen(&mut a, 120, 40);
        assert!(
            s.contains("PROPOSALS  reading") && !s.contains("nothing proposed"),
            "{s}"
        );
        a.proposals = Some(Ok(vec![]));
        assert!(screen(&mut a, 120, 40).contains("nothing proposed"));
    }

    #[test]
    fn home_shows_proposals_and_enter_opens_the_table_and_the_record() {
        let mut a = app(Tab::Home);
        a.proposals = Some(Ok(vec![proposal("aa", "dream"), proposal("bb", "ci")]));
        let s = screen(&mut a, 120, 40);
        assert!(
            s.contains("PROPOSALS (2 from 2 streams)") && s.contains("Do aa"),
            "{s}"
        );
        a.handle(Msg::Input(Event::Key(KeyEvent::from(KeyCode::Enter))));
        a.handle(Msg::Input(Event::Key(KeyEvent::from(KeyCode::Char('j')))));
        a.handle(Msg::Input(Event::Key(KeyEvent::from(KeyCode::Enter))));
        let s = screen(&mut a, 120, 40);
        assert!(s.contains("STREAM") && s.contains("a accept"), "{s}");
        assert!(s.contains("accept runs") && s.contains("Do bb"), "{s}");
        // Esc steps out one level at a time.
        for _ in 0..2 {
            a.handle(Msg::Input(Event::Key(KeyEvent::from(KeyCode::Esc))));
        }
        assert!(!a.prv.open && !a.prv.detail);
    }

    #[test]
    fn table_keys_stay_on_home_with_nothing_proposed() {
        let (tx, _rx) = std::sync::mpsc::channel();
        let mut a = with_tx(Tab::Home, tx);
        a.proposals = Some(Ok(vec![]));
        for c in ['s', 'f', '/'] {
            a.handle(Msg::Input(Event::Key(KeyEvent::from(KeyCode::Char(c)))));
        }
        a.handle(Msg::Input(Event::Key(KeyEvent::from(KeyCode::Enter))));
        assert!(!a.prv.open);
    }

    #[test]
    fn a_and_d_decide_the_selected_proposal_only() {
        let (tx, rx) = std::sync::mpsc::channel();
        let mut a = with_tx(Tab::Home, tx);
        let fake = Arc::new(Fake::default());
        a.runner = fake.clone();
        a.proposals = Some(Ok(vec![proposal("aa", "dream"), proposal("bb", "ci")]));
        // Closed, a and d are nobody's: nothing is decided from the page.
        a.handle(Msg::Input(Event::Key(KeyEvent::from(KeyCode::Char('a')))));
        a.prv.open = true;
        for c in ['j', 'a', 'd'] {
            a.handle(Msg::Input(Event::Key(KeyEvent::from(KeyCode::Char(c)))));
        }
        let mut answers = 0;
        while answers < 2 {
            if let Msg::ProposalActed(r) = rx.recv().unwrap() {
                assert!(r.is_ok());
                answers += 1;
            }
        }
        let calls = fake.0.lock().unwrap();
        let decided: Vec<_> = calls.iter().filter(|c| !c.contains("list")).collect();
        assert_eq!(decided.len(), 2, "{calls:?}");
        assert!(
            decided.iter().any(|c| *c == "agent-propose accept bb"),
            "{calls:?}"
        );
        assert!(
            decided.iter().any(|c| *c == "agent-propose reject bb"),
            "{calls:?}"
        );
    }

    #[test]
    fn home_draws_what_needs_you_and_green_collapses() {
        let mut a = app(Tab::Home);
        a.infra = Some(board::tests::fixture());
        let s = screen(&mut a, 120, 40);
        let first = s.lines().next().unwrap();
        assert!(
            first.contains("1 Home") && first.contains("6 Infra") && first.contains(" RED "),
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
        assert_eq!(Tab::parse("forecast"), Some(Tab::Log));
        assert_eq!(Tab::parse("today"), Some(Tab::Log));
        assert_eq!(Tab::parse("history"), Some(Tab::Log));
        assert_eq!(Tab::parse("actions"), Some(Tab::Log));
        assert_eq!(Tab::parse("watch"), Some(Tab::Sessions));
        assert_eq!(Tab::parse("shepherd"), Some(Tab::Sessions));
    }

    #[test]
    fn the_tabs_are_the_layout_and_each_digit_its_place() {
        // docs/dashboards.md rule 8: both surfaces list hub_core::layout's tabs in its order,
        // and the digits follow that order, 1 for the first.
        let titles: Vec<&str> = Tab::ALL.iter().map(|t| t.title()).collect();
        let layout: Vec<&str> = hub_core::layout::TABS.iter().map(|t| t.title).collect();
        assert_eq!(titles, layout);
        for (i, t) in Tab::ALL.iter().enumerate() {
            let d = char::from_digit(i as u32 + 1, 10).unwrap();
            assert_eq!((t.digit(), Tab::by_digit(d)), (d, Some(*t)));
        }
        assert_eq!(Tab::by_digit('0'), None);
    }

    #[test]
    fn the_daily_tab_reads_today_then_steps_a_day_with_its_keys() {
        let (tx, rx) = std::sync::mpsc::channel();
        let mut a = with_tx(Tab::Home, tx);
        let fake = Arc::new(Fake::default());
        a.runner = fake.clone();
        // Focus was Daily's name; the Outbox tab is Daily's outbox view (hub_core::layout).
        for n in ["daily", "Daily", "focus", "outbox"] {
            assert_eq!(Tab::parse(n), Some(Tab::Daily), "{n}");
        }
        a.handle(Msg::Tab(Tab::Daily, None));
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
            s.contains("DAILY 2026-11-05  1 open, 0 done  o outbox")
                && s.contains("[ ] fix the menu"),
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
    fn o_on_daily_toggles_the_outbox_and_hub_tab_outbox_opens_it() {
        let (tx, rx) = std::sync::mpsc::channel();
        let mut a = with_tx(Tab::Home, tx);
        a.runner = Arc::new(Fake::default());
        let esc = || Msg::Input(Event::Key(KeyEvent::from(KeyCode::Esc)));
        // Each read is answered, as the loop would, so the next one is free.
        let answer = |a: &mut App| {
            let m = rx.recv().unwrap();
            a.handle(m);
        };
        a.handle(Msg::Tab(Tab::Daily, None));
        answer(&mut a);
        assert!(!a.daily_outbox, "Daily opens on the note");
        assert!(screen(&mut a, 120, 20).contains("o outbox"));
        a.handle(key('o'));
        answer(&mut a);
        assert!(a.daily_outbox);
        let doc = hub_core::outbox::Doc {
            path: "/vault/outbox.md".into(),
            text: "- call the vet\n".into(),
            waiting: 1,
            ..Default::default()
        };
        a.handle(Msg::Outbox(Box::new(Ok(hub_core::outbox::View {
            doc,
            ..Default::default()
        }))));
        let s = screen(&mut a, 120, 20);
        assert_eq!(a.tab, Tab::Daily, "{s}");
        assert!(
            top(&s).starts_with("OUTBOX  1 waiting") && s.contains("- call the vet"),
            "{s}"
        );
        assert!(s.lines().last().unwrap().contains("o/Esc the note"), "{s}");
        // Esc goes back to the note, even in a popup, and `o` toggles both ways.
        a.popup = true;
        a.handle(esc());
        answer(&mut a);
        assert!(!a.daily_outbox && !a.quit);
        a.handle(key('o'));
        answer(&mut a);
        a.handle(key('o'));
        answer(&mut a);
        assert!(!a.daily_outbox);
        // `hub --tab outbox` lands on Daily's outbox; `focus` on the note.
        let (t, q) = crate::tabreq::parse("outbox").unwrap();
        assert_eq!((t, q.as_deref()), (Tab::Daily, Some("outbox")));
        a.handle(Msg::Tab(Tab::Home, None));
        a.handle(Msg::Tab(t, q));
        answer(&mut a);
        answer(&mut a);
        assert!(a.tab == Tab::Daily && a.daily_outbox);
        let (t, q) = crate::tabreq::parse("focus").unwrap();
        a.handle(Msg::Tab(t, q));
        answer(&mut a);
        assert!(a.tab == Tab::Daily && !a.daily_outbox);
    }

    #[test]
    fn the_fleet_keys_query_the_table_and_esc_clears_them() {
        let key = |c| Msg::Input(Event::Key(KeyEvent::from(c)));
        let ch = |c| key(KeyCode::Char(c));
        let mut a = app(Tab::Fleet);
        a.handle(Msg::Fleet(Box::new(fleettab::tests::fixture())));
        let s = screen(&mut a, 160, 40);
        assert!(
            s.contains("all 3") && s.contains("j/k pick  Enter open"),
            "{s}"
        );

        // Typing keeps its letters, even the page's own keys, and applies on Enter.
        a.handle(ch('/'));
        assert!(screen(&mut a, 160, 40).contains("type a query"));
        for c in "idle".chars() {
            a.handle(ch(c));
        }
        a.handle(key(KeyCode::Enter));
        let s = screen(&mut a, 160, 40);
        assert!(
            s.contains("/idle") && s.contains("idle-one") && !s.contains("dream"),
            "{s}"
        );
        assert!(a.fleet_table.typing.is_none() && a.tab == Tab::Fleet);

        // A search that hits nothing says so, and Esc brings every row back.
        a.handle(ch('x'));
        a.handle(ch('/'));
        a.handle(ch('z'));
        a.handle(key(KeyCode::Enter));
        assert!(screen(&mut a, 160, 40).contains("No runner or session matches"));
        a.handle(key(KeyCode::Esc));
        assert!(a.fleet_table.is_default());
        assert!(screen(&mut a, 160, 40).contains("dream"));

        // f steps the state chip, s the sort.
        a.handle(ch('f'));
        assert_eq!(a.fleet_table.view.state, "failed");
        let s = screen(&mut a, 160, 40);
        assert!(s.contains("dream") && !s.contains("idle-one"), "{s}");
        a.handle(ch('x'));
        a.handle(ch('s'));
        assert_eq!(a.fleet_table.view.sort, "tier");
    }

    #[test]
    fn the_fleet_tab_draws_the_table_and_the_accounts() {
        let mut a = app(Tab::Fleet);
        assert!(screen(&mut a, 120, 10).contains("Reading the fleet..."));
        a.handle(Msg::Fleet(Box::new(fleettab::tests::fixture())));
        let s = screen(&mut a, 160, 40);
        assert!(s.lines().next().unwrap().contains("8 Fleet"), "{s}");
        for want in ["FLEET", "TIER", "dotfiles-agent-11", "CLAUDE ACCOUNTS"] {
            assert!(s.contains(want), "{want} missing from\n{s}");
        }
        assert!(
            !s.contains("DISPATCH JUDGE"),
            "the judges moved to their pages and Log\n{s}"
        );
    }

    /// A page read in flight that is never started again, so no test reads this machine's
    /// agentctl state.
    fn hold_runner(a: &mut App) {
        a.fleet_runner_read.busy = true;
        a.fleet_runner_read.again = false;
    }

    #[test]
    fn enter_opens_the_picked_row_brackets_step_runners_and_esc_goes_back() {
        let k = |c| Msg::Input(Event::Key(KeyEvent::from(c)));
        let mut a = app(Tab::Fleet);
        hold_runner(&mut a);
        a.handle(Msg::Fleet(Box::new(fleettab::tests::fixture())));
        assert!(screen(&mut a, 160, 40).contains("j/k pick  Enter open"));

        // The pick starts on the first row; j moves it and k goes back.
        a.handle(k(KeyCode::Char('j')));
        assert_eq!(a.fleet_sel, 1);
        a.handle(k(KeyCode::Char('k')));
        assert_eq!(a.fleet_sel, 0);

        a.handle(k(KeyCode::Enter));
        assert_eq!(a.fleet_page.as_deref(), Some("dream"));
        assert!(screen(&mut a, 160, 40).contains("Reading dream..."));
        // A read for another runner (the page moved on meanwhile) draws nothing.
        a.handle(Msg::Runner(Box::new((
            "idle-one".into(),
            Err("late".into()),
        ))));
        assert!(a.fleet_runner.is_none());
        hold_runner(&mut a);
        a.handle(Msg::Runner(Box::new((
            "dream".into(),
            Ok(fleettab::tests::runner_fixture()),
        ))));
        let s = screen(&mut a, 160, 40);
        assert!(
            s.contains("DREAM  memory") && s.contains("status: retry 17:30"),
            "{s}"
        );
        assert!(s.contains("Esc all runners"), "{s}");

        // ] steps to the next runner's page and drops the last one's read.
        hold_runner(&mut a);
        a.handle(k(KeyCode::Char(']')));
        assert_eq!(a.fleet_page.as_deref(), Some("idle-one"));
        assert!(a.fleet_runner.is_none());

        a.handle(k(KeyCode::Esc));
        assert!(a.fleet_page.is_none() && a.tab == Tab::Fleet && !a.quit);
        assert!(screen(&mut a, 160, 40).contains("FLEET"));
    }

    #[test]
    fn z_folds_a_tier_one_row_and_enter_on_a_session_opens_it_on_the_sessions_tab() {
        let k = |c| Msg::Input(Event::Key(KeyEvent::from(c)));
        let mut a = app(Tab::Fleet);
        a.handle(Msg::Fleet(Box::new(fleettab::tests::fixture())));
        assert!(screen(&mut a, 160, 40).contains("dotfiles-agent-11"));
        a.handle(k(KeyCode::Char('z')));
        assert!(a.fleet_folded.contains("dream"));
        assert!(!screen(&mut a, 160, 40).contains("dotfiles-agent-11"));
        a.handle(k(KeyCode::Char('z')));
        assert!(a.fleet_folded.is_empty());
        // Enter on the session row leaves the Fleet tab for Sessions.
        a.handle(k(KeyCode::Char('G')));
        assert_eq!(a.fleet_sel, 2);
        a.handle(k(KeyCode::Enter));
        assert_eq!(a.tab, Tab::Sessions);
    }

    #[test]
    fn hub_tab_fleet_with_a_runner_opens_its_page_and_a_section_name_scrolls() {
        let mut a = app(Tab::Home);
        hold_runner(&mut a);
        a.fleet_read.busy = true;
        let (t, q) = crate::tabreq::parse("fleet inbox-triage").unwrap();
        a.handle(Msg::Tab(t, q));
        assert!(a.tab == Tab::Fleet);
        assert_eq!(a.fleet_page.as_deref(), Some("inbox-triage"));
        a.handle(Msg::Input(Event::Key(KeyEvent::from(KeyCode::Esc))));
        let (t, q) = crate::tabreq::parse("fleet accounts").unwrap();
        a.handle(Msg::Tab(t, q));
        assert!(a.fleet_page.is_none());
        assert_eq!(a.seek, Some("accounts"));
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
        let (tx, _rx) = std::sync::mpsc::channel();
        let mut a = log_app(tx);
        a.forecast = Some(Forecast::read_with("hub-test-no-such-fleet-bench"));
        a.handle(key('f'));
        let s = screen(&mut a, 160, 80);
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
        a.handle(key('5'));
        assert_eq!(a.tab, Tab::Sessions);
        a.handle(key('7'));
        assert_eq!(a.tab, Tab::Log);
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
    fn entering_infra_reads_red_fixes_and_draws_them_under_red_now() {
        let (tx, rx) = std::sync::mpsc::channel();
        let mut a = with_tx(Tab::Home, tx);
        a.infra = Some(board::tests::fixture());
        a.handle(Msg::Tab(Tab::Infra, None));
        // The read went through the app's runner (the Fake), never a real fleet-bench.
        let m = rx.recv_timeout(std::time::Duration::from_secs(5)).unwrap();
        assert!(matches!(m, Msg::Reds(Ok(_))));
        a.handle(Msg::Reds(Err("reds: cannot read the queue".into())));
        let s = screen(&mut a, 160, 80);
        let at = |w: &str| s.find(w).unwrap_or_else(|| panic!("no {w} in {s}"));
        assert!(at("RED NOW") < at("RED FIXES  read failed"), "{s}");
        assert!(at("RED FIXES") < at("MACHINE "), "{s}");
        assert!(s.contains("reds: cannot read the queue"), "{s}");
    }

    #[test]
    fn the_tick_rereads_red_fixes_only_after_reds_refresh_and_r_reads_at_once() {
        let (tx, _rx) = std::sync::mpsc::channel();
        let mut a = with_tx(Tab::Infra, tx);
        a.handle(Msg::Reds(Err("x".into())));
        assert!(!a.reds_read.busy);
        // A fresh answer: the tick leaves it alone (one read is about 2s of fleet-bench).
        a.handle(Msg::Tick);
        assert!(!a.reds_read.busy, "the tick re-read a fresh answer");
        // r always reads.
        a.handle(key('r'));
        assert!(a.reds_read.busy, "r did not read red fixes");
        a.reds_read.done();
        // An answer older than REDS_REFRESH is re-read on the tick.
        a.reds_at = std::time::Instant::now().checked_sub(REDS_REFRESH);
        a.handle(Msg::Tick);
        assert!(a.reds_read.busy, "the tick did not re-read a stale answer");
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
        a.handle(key('6'));
        let s = screen(&mut a, 160, 200);
        let bar = s.lines().next().unwrap();
        assert!(
            bar.contains("5 Sessions  6 Infra") && !bar.contains("Machines"),
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
        a.handle(key('6'));
        a.handle(Msg::Input(Event::Key(KeyEvent::from(KeyCode::Enter))));
        assert!(a.infra_jobs);
        let s = screen(&mut a, 120, 20);
        assert!(top(&s).starts_with("all 1  running 0"), "{s}");
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

    fn schedule(kind: &str, name: &str, page: &str) -> Schedule {
        let mut r = Schedule::default();
        (r.kind, r.name, r.page) = (kind.into(), name.into(), page.into());
        r
    }

    #[test]
    fn a_schedules_read_still_going_is_not_due_again() {
        let mut a = app(Tab::Schedules);
        assert!(a.schedules_due(), "never read");
        a.schedules_read.busy = true;
        assert!(
            !a.schedules_due(),
            "a tick must not queue a read behind this one"
        );
        a.handle(Msg::Schedules(Box::default()));
        assert!(!a.schedules_due(), "just read");
    }

    #[test]
    fn enter_on_schedules_opens_the_pane_and_an_agentctl_row_its_fleet_page() {
        let mut a = app(Tab::Schedules);
        a.schedules_read.busy = true;
        a.handle(Msg::Schedules(Box::new(Schedules {
            rows: vec![
                schedule("ci", "app / Tests", ""),
                schedule("agentctl", "dream", "dream"),
            ],
            ..Default::default()
        })));
        let key = |c| Msg::Input(Event::Key(KeyEvent::from(c)));
        a.handle(key(KeyCode::Enter));
        assert!(a.sv.open);
        a.handle(key(KeyCode::Esc));
        assert!(!a.sv.open, "Esc closes the pane before it clears the view");
        a.handle(key(KeyCode::Char('j')));
        a.fleet_read.busy = true;
        a.handle(key(KeyCode::Enter));
        assert_eq!(
            (a.tab, a.fleet_page.as_deref()),
            (Tab::Fleet, Some("dream"))
        );
    }

    #[test]
    fn a_refresh_keeps_the_selected_schedule_and_a_query_takes_every_key() {
        let mut a = app(Tab::Schedules);
        let rows = |r: Vec<Schedule>| {
            Msg::Schedules(Box::new(Schedules {
                rows: r,
                ..Default::default()
            }))
        };
        a.schedules_read.busy = true;
        a.handle(rows(vec![schedule("ci", "a", ""), schedule("ci", "b", "")]));
        let key = |c| Msg::Input(Event::Key(KeyEvent::from(KeyCode::Char(c))));
        a.handle(key('j'));
        a.schedules_read.busy = true;
        a.handle(rows(vec![
            schedule("ci", "new", ""),
            schedule("ci", "a", ""),
            schedule("ci", "b", ""),
        ]));
        assert_eq!(a.selected_schedule().map(|r| r.name.as_str()), Some("b"));
        a.handle(key('/'));
        a.handle(key('q'));
        a.handle(key('2'));
        assert!(!a.quit && a.tab == Tab::Schedules);
        assert_eq!(a.sv.table.typing.as_deref(), Some("q2"));
    }

    #[test]
    fn a_narrow_tab_bar_keeps_every_digit_and_the_open_tab_s_title() {
        let a = app(Tab::Schedules);
        let bar: String = a
            .tab_bar(80)
            .spans
            .iter()
            .map(|s| s.content.as_ref())
            .collect();
        assert!(
            bar.starts_with(" HUB  1  2  3  4  5  6  7  8  9 Schedules "),
            "{bar:?}"
        );
        let wide: String = a
            .tab_bar(120)
            .spans
            .iter()
            .map(|s| s.content.as_ref())
            .collect();
        assert!(wide.contains(" 1 Home "), "{wide:?}");
    }

    #[test]
    fn number_keys_switch_pages_and_q_quits() {
        let mut a = app(Tab::Home);
        let key = |c| Msg::Input(Event::Key(KeyEvent::from(KeyCode::Char(c))));
        a.handle(key('6'));
        assert_eq!((a.tab, a.seek), (Tab::Infra, None));
        a.handle(key('7'));
        assert_eq!(a.tab, Tab::Log);
        a.handle(key('0'));
        assert_eq!(a.tab, Tab::Log, "0 opens nothing");
        a.fleet_read.busy = true;
        a.handle(Msg::Input(Event::Key(KeyEvent::from(KeyCode::Tab))));
        assert_eq!(a.tab, Tab::Fleet);
        a.handle(key('q'));
        assert!(a.quit);
    }

    #[test]
    fn esc_quits_a_popup_only_when_nothing_is_left_to_close() {
        let esc = || Msg::Input(Event::Key(KeyEvent::from(KeyCode::Esc)));
        // Negative control: the tmux hub pane is never closed by Esc.
        let mut a = app(Tab::Home);
        a.handle(esc());
        assert!(!a.quit);
        // A popup: Esc first backs out of the jobs table, then quits.
        let mut a = app(Tab::Infra);
        a.popup = true;
        a.handle(Msg::Input(Event::Key(KeyEvent::from(KeyCode::Enter))));
        assert!(a.infra_jobs);
        a.handle(esc());
        assert!(!a.infra_jobs && !a.quit);
        a.handle(esc());
        assert!(a.quit);
        // An armed confirm keeps its Esc.
        let mut a = app(Tab::Queue);
        a.popup = true;
        a.qv.confirm = Some("x".into());
        a.handle(esc());
        assert!(a.qv.confirm.is_none() && !a.quit);
        a.handle(esc());
        assert!(a.quit);
    }

    #[test]
    fn a_start_query_opens_its_infra_section() {
        let (t, q) = crate::tabreq::parse("infra ci").unwrap();
        let mut a = app(t);
        a.open_query(q);
        assert_eq!((a.tab, a.seek), (Tab::Infra, Some("ci")));
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
