//! `hub`: the state, the keys and the drawing. Reads run in worker threads and come back as
//! messages; a read asked for while one is running is coalesced into one more after it.

use std::path::{Path, PathBuf};
use std::sync::mpsc::Sender;
use std::sync::Arc;
use std::time::Duration;

use hub_core::alerts::Alert;
use hub_core::boards::{self, DayRow, Watch};
use hub_core::builds::{self, Builds, Scope};
use hub_core::fleet::who::{Opens, Who};
use hub_core::fleet::ASK_FILTERS;
use hub_core::home::Need;
use hub_core::infra::Infra;
use hub_core::jobs::{self, Job, Jobs, LogRef, Opts, Paths};
use hub_core::links::{Kind, Link};
use hub_core::outcomes::{self, Ranked};
use hub_core::proposals::{self, Proposal};
use hub_core::queue::{Candidate, Candidates, Queue};
use hub_core::releases::{App as ReleaseApp, Changelog, Releases};
use hub_core::schedules::{Schedule, Schedules};
use hub_core::session_actions::{self as actions, Action, Runner, Snapshot};
use hub_core::tasks::Feed;
use ratatui::crossterm::event::{Event, KeyCode, KeyEvent, KeyEventKind, KeyModifiers};
use ratatui::layout::{Constraint, Layout, Rect};
use ratatui::text::{Line, Span};
use ratatui::widgets::Paragraph;
use ratatui::Frame;

use crate::alertstab::{self, AlertsView};
use crate::builds as bv;
use crate::controls::{Ask, Controls};
use crate::datatable::{DataTable, Took};
use crate::flowline;
use crate::fmt::{clock, Palette};
use crate::forecast::{self, Forecast};
use crate::infrapage::InfraPage;
use crate::jobs::{log_lines, row_id, JobsView, LogPane};
use crate::projtab::{self, ProjView};
use crate::proptab::ProposalsView;
use crate::queuetab::{self, QueueView};
use crate::releases::{self, ReleasesView};
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
/// VictoriaMetrics has no push and a check runs every one to five minutes, so the tick re-reads
/// the open app's checks this often, the web page's cadence.
pub const APP_STATUS_REFRESH: Duration = Duration::from_secs(60);
/// One `fleet-bench epics` read takes about 10s and an epic moves in hours, so the tick re-reads
/// Deliverables only this often; entering Projects and `r` still read it at once.
pub const DELIVERABLES_REFRESH: Duration = Duration::from_secs(300);
/// A Schedules read shells out to systemd and Prometheus for seconds, and a schedule changes by
/// the hour: agent-web's cache keeps one this long too.
pub const SCHEDULES_REFRESH: Duration = Duration::from_secs(60);
/// The Costs sources are written nightly or per call and none is watched, so the tick re-reads
/// them this often while the tab is shown; entering it and `r` read at once.
pub const COSTS_REFRESH: Duration = Duration::from_secs(300);
/// Under this many body lines the Projects rows keep the whole window and get no preview pane.
const PREVIEW_MIN_HEIGHT: u16 = 18;

/// Which of Infra's tables is opened whole over its summary: the jobs table or CI's runs table.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Opened {
    Jobs,
    Runs,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Tab {
    Home,
    Daily,
    Queue,
    Projects,
    Sessions,
    Alerts,
    Infra,
    Log,
    Fleet,
    Schedules,
    Costs,
    Releases,
}

impl Tab {
    /// hub-core's layout order, every page the TUI can show (`tabs_are_the_layout` checks).
    pub const ALL: [Tab; 12] = [
        Tab::Home,
        // The daily note; `o` shows the outbox under it (`hub --tab outbox` opens it there).
        Tab::Daily,
        Tab::Log,
        Tab::Queue,
        Tab::Sessions,
        Tab::Fleet,
        Tab::Projects,
        Tab::Releases,
        Tab::Alerts,
        Tab::Infra,
        Tab::Schedules,
        Tab::Costs,
    ];
    /// The tabs on the bar, in `ALL`'s order; digit N opens `SHOWN[N - 1]` and 0 the tenth, past
    /// which a tab has no digit and Tab reaches it (`hub_core::layout::bar_digit`). Daily is left
    /// off (asked 2026-11-06): agent-web keeps it, and `hub --tab daily` still opens it.
    pub const SHOWN: [Tab; 11] = [
        Tab::Home,
        Tab::Log,
        Tab::Queue,
        Tab::Sessions,
        Tab::Fleet,
        Tab::Projects,
        Tab::Releases,
        Tab::Alerts,
        Tab::Infra,
        Tab::Schedules,
        Tab::Costs,
    ];
    pub fn title(self) -> &'static str {
        match self {
            Tab::Home => "Home",
            Tab::Daily => "Daily",
            Tab::Queue => "Queue",
            Tab::Projects => "Projects",
            Tab::Sessions => "Sessions",
            Tab::Alerts => "Alerts",
            Tab::Infra => "Infra",
            Tab::Log => "Log",
            Tab::Fleet => "Fleet",
            Tab::Schedules => "Schedules",
            Tab::Costs => "Costs",
            Tab::Releases => "Releases",
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
        by_title(s).or_else(|| {
            let t = hub_core::layout::resolve(s)?;
            // Agent-web's Board tab is `a` on Projects here.
            by_title(if t.id == "board" { "Projects" } else { t.title })
        })
    }
    fn index(self) -> usize {
        Tab::SHOWN.iter().position(|t| *t == self).unwrap_or(0)
    }
    /// The digit that opens this tab, as the tab bar shows it; a tab off the bar, or past the
    /// tenth, has none.
    fn digit(self) -> char {
        Tab::SHOWN
            .iter()
            .position(|t| *t == self)
            .filter(|i| *i < 10)
            .and_then(|i| char::from_digit((i as u32 + 1) % 10, 10))
            .unwrap_or(' ')
    }
    /// The tab a digit opens, along the number row: 1 for the first, 0 for the tenth.
    fn by_digit(c: char) -> Option<Tab> {
        Tab::SHOWN.get((c.to_digit(10)? as usize + 9) % 10).copied()
    }
    /// The Grafana dashboard that keeps this page's trends; the file-fed pages have none.
    fn dashboard(self) -> Option<&'static str> {
        match self {
            Tab::Home => Some("kb-command-center"),
            Tab::Infra => Some("kb-ci-runners"),
            Tab::Queue | Tab::Costs => Some(hub_core::costs::DASHBOARD),
            Tab::Daily
            | Tab::Projects
            | Tab::Sessions
            | Tab::Alerts
            | Tab::Log
            | Tab::Fleet
            | Tab::Schedules
            | Tab::Releases => None,
        }
    }
}

/// Log's sections after Work, the day and its history, their keys and headings, in the page's
/// order (hub_core::layout's Log sections; `log_folds_are_the_layout` checks). A key opens the
/// inner tab holding its section.
const FOLDS: [(&str, char, &str); 6] = [
    ("actions", 'a', "ACTIONS"),
    ("changes", 'c', "CHANGES"),
    ("rundowns", 's', "RUNDOWNS"),
    ("verdicts", 'v', "JUDGES' VERDICTS"),
    ("ranked", 'w', "RANKED SESSIONS"),
    ("forecast", 'f', "FORECAST"),
];

/// A Log table's keys. Esc or Backspace with nothing to clear gives the keys back to Log; a key
/// that is not the table's is Log's, so `n` still jumps and `a` still folds.
fn log_table_key<R: hub_core::table::Row>(t: &mut DataTable, has: &mut bool, k: KeyEvent) -> bool {
    if t.is_default() && matches!(k.code, KeyCode::Esc | KeyCode::Backspace) {
        *has = false;
        return true;
    }
    if t.typing.is_none() && k.code == KeyCode::Esc {
        t.clear();
        return true;
    }
    t.key::<R>(k.code) != Took::No
}

/// How many job rows Infra's Jobs section shows; Enter opens the whole table.
const JOBS_SHOWN: usize = 8;
/// Lines an opened run's log keeps under its detail, however many jobs the detail lists.
const BUILD_LOG_MIN: usize = 6;

/// Infra's layout entry: its sections and inner tabs.
fn infra_tab() -> &'static hub_core::layout::Tab {
    hub_core::layout::resolve("infra").expect("infra is a tab")
}
fn log_tab() -> &'static hub_core::layout::Tab {
    hub_core::layout::resolve("log").expect("log is a tab")
}
/// The tabs that draw the CI runs ledger: Infra's CI runs and Releases' Release runs.
fn reads_runs(t: Tab) -> bool {
    matches!(t, Tab::Releases | Tab::Infra)
}
/// The footer while a table's query is being typed.
const QUERY_HINT: &str = "type a query (word, key:value, -key:value), Enter applies, Esc cancels";

/// The files the Sessions, Fleet and Log tabs are read from.
#[derive(Clone)]
pub struct BoardFiles {
    pub state: PathBuf,
    /// agent-ask's store: Home's asks are read live, so an ask filed or answered re-reads them.
    pub asks: PathBuf,
    /// agent-propose's store: a proposal filed or decided re-reads Home's section.
    pub proposals: PathBuf,
    /// Claude's session files: a dialog opening or answered changes NEEDS YOU at once.
    pub sessions: PathBuf,
    pub shepherd: PathBuf,
    pub daylog: PathBuf,
    /// The nightly token snapshots behind Costs' Where the tokens go.
    pub tokens: PathBuf,
    /// `release-state`'s directory: its snapshot is replaced by a rename when a refresh finishes.
    pub releases: PathBuf,
    /// schedules-sync's run ledger behind Infra's CI runs and Releases' Release runs.
    pub builds: builds::Paths,
    /// The Queue tab's Candidates: the snapshot each real `fleet-dispatch run` writes.
    pub candidates: PathBuf,
    /// Sentinel's state directory: a watch tripping or clearing rewrites its `.state` file.
    pub watches: PathBuf,
}

impl BoardFiles {
    pub fn from_env() -> BoardFiles {
        BoardFiles {
            state: boards::fleet_state(),
            asks: boards::asks_dir(),
            proposals: boards::proposals_dir(),
            sessions: boards::claude_sessions_dir(),
            shepherd: boards::shepherd_dir(),
            daylog: boards::daylog_dir(),
            tokens: boards::token_usage_dir(),
            releases: boards::releases_dir(),
            builds: builds::Paths::from_env(),
            candidates: boards::candidates_file(),
            watches: hub_core::alerts::watch_dirs().1,
        }
    }
    fn watch_log(&self) -> PathBuf {
        self.shepherd.join("watch.log")
    }
    /// The shepherd's kept rundowns (`fleet-shepherd log --rundown`), one `.md` file each.
    pub fn rundowns(&self) -> PathBuf {
        self.shepherd.join("rundowns")
    }
    pub fn is_session_file(&self, p: &Path) -> bool {
        p.parent() == Some(self.sessions.as_path()) && p.extension().is_some_and(|e| e == "json")
    }

    pub fn is_proposal_file(&self, p: &Path) -> bool {
        hub_core::boards::is_proposal_file(&self.proposals, p)
    }

    pub fn is_token_file(&self, p: &Path) -> bool {
        p.parent() == Some(self.tokens.as_path()) && p.extension().is_some_and(|e| e == "json")
    }

    pub fn is_build_file(&self, p: &Path) -> bool {
        self.builds.is_ledger_file(p)
    }

    pub fn is_watch_file(&self, p: &Path) -> bool {
        p.parent() == Some(self.watches.as_path()) && p.extension().is_some_and(|e| e == "state")
    }

    pub fn is_release_file(&self, p: &Path) -> bool {
        hub_core::boards::is_release_snapshot(&self.releases, p)
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
    /// A Claude session's status changed; only Home's NEEDS YOU reads it live.
    SessionFiles,
    Proposals(Box<Result<Vec<Proposal>, String>>),
    /// Home's Since last night (hub_core::briefing::night).
    Night(Box<hub_core::briefing::Night>),
    /// What Queue a fix answered for the area it names.
    FixQueued(String, Result<String, String>),
    /// What an accept or a reject answered.
    ProposalActed(Result<String, String>),
    /// A job source's file changed (a run started or ended).
    Files,
    /// The nightly token run wrote a snapshot (`~/.agent/token-usage`): Costs' token folds.
    TokenFiles,
    /// The fleet state, watch.log or a day record changed.
    BoardFiles,
    /// `hub tab <name> [words]` asked for a page (tabreq.rs); the words name a project to open.
    Tab(Tab, Option<String>),
    Boards(Box<Boards>),
    Infra(Box<Infra>),
    Jobs(Box<Jobs>),
    Schedules(Box<Schedules>),
    Releases(Box<Releases>),
    /// `release-state` wrote a new snapshot.
    ReleaseFile,
    /// One project's changelog for the ask numbered first, or why it could not be read.
    Changelog(Result<Changelog, String>),
    /// One app's checks (`hub_core::app_status`), for the project named.
    AppStatus(String, Box<Result<hub_core::app_status::AppStatus, String>>),
    Builds(Box<Builds>),
    /// The Pipelines view's sources, read with the runs on Infra.
    Pipes(Box<hub_core::pipelines::Sources>),
    /// schedules-sync appended to the run ledger.
    BuildFile,
    /// The Sessions table's ended rows, then its header.
    SessionFeed(Box<hub_core::session_table::Feed>),
    Capacity(Box<hub_core::capacity::Capacity>),
    /// One session's page (hub_core::session_page), for the row it was read for.
    SessionPage(Box<(String, Option<hub_core::session_page::SessionPage>)>),
    Forecast(Box<Forecast>),
    /// `agentctl-session-outcomes worst`, or why it failed.
    Ranked(Result<Vec<Ranked>, String>),
    /// `fleet-bench reds`, split for Alerts' Fixes section and its owners, or why it failed.
    Reds(Result<hub_core::reds::Reds, String>),
    /// The Alerts tab's join (hub_core::alerts) over the held Infra and reds.
    Alerts(Box<hub_core::alerts::Alerts>),
    /// A Sentinel watch's state file changed (a trip, a clear, an error).
    WatchFiles,
    /// `fleet-bench epics --json` for the Projects tab's Deliverables section, or why it failed.
    Deliverables(Result<hub_core::deliverables::Deliverables, String>),
    /// The Costs tab's one read of every source it cuts (hub_core::costs::read).
    Costs(Box<hub_core::costs::Costs>),
    Fleet(Box<hub_core::fleet::Fleet>),
    /// One runner's page (hub_core::fleet::runner), for the name it was read for.
    Runner(Box<(String, Result<hub_core::fleet::runner::Runner, String>)>),
    /// An Infra page's read (`infrapage`), for the page it was read for.
    InfraPage(Box<InfraPage>),
    /// The pipeline summary from `agent_chain_*` (hub_core::pipeline); Ok(None) when absent.
    Pipeline(Result<Option<hub_core::pipeline::Pipeline>, String>),
    /// The machinery's actions over the last `logtab::ACTIONS_HOURS`, for Log's Actions section.
    Actions(Box<hub_core::actions::Gathered>),
    /// Log's Work table, every project's done and not done.
    Work(Box<hub_core::worklog::Gathered>),
    /// A day's note through `notes show --json` (hub_core::focus), or why it failed.
    Focus(Box<Result<hub_core::focus::View, String>>),
    /// The outbox and today's intake steps (hub_core::outbox), or why the read failed.
    Outbox(Box<Result<hub_core::outbox::View, String>>),
    Log(u64, Result<String, String>),
    /// The opened run's detail, for the open numbered first (`hub_core::builds::detail`).
    BuildDetail(u64, Box<Result<hub_core::run_detail::RunDetail, String>>),
    /// The live and parked agent sessions, for the Sessions tab's controls.
    Sessions(Box<Snapshot>),
    /// A session action ended: its output, or why it failed.
    Acted(Result<String, String>),
    /// An item file under the queue dir was written, moved or removed.
    QueueFiles,
    Queue(Box<Queue>),
    /// A queue cancel, bump or promote ended: its output, or why it failed.
    QueueActed(Result<String, String>),
    /// fleet-dispatch's Candidates snapshot (hub_core::queue::candidates), or why it failed.
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
    /// The views over Infra's machines, pools and CI tables (`infratables`).
    pub itab: crate::infratables::InfraTables,
    pub paths: Paths,
    pub infra: Option<Infra>,
    pub jobs: Option<Jobs>,
    pub jv: JobsView,
    /// The views over Home's Needs you and Running tables, and which has the keys.
    pub hv: hometab::HomeView,
    pub sv: SchedulesView,
    pub schedules: Option<Schedules>,
    pub rv: ReleasesView,
    pub releases: Option<Releases>,
    /// Every CI run: Infra's CI runs table (`ci`), and Releases' Release runs (`rv.runs`, the
    /// view in `Scope::Release`).
    pub builds: Option<Builds>,
    pub ci: bv::BuildsView,
    /// Infra's Pipelines table and its opened row (`pipetab`).
    pub plv: crate::pipetab::PipelinesView,
    /// What the Pipelines view is built from (state.json, the night runners and their starts),
    /// read with the runs on Infra; `pipes` is it over the runs read, rebuilt when either lands.
    pipe_src: Option<hub_core::pipelines::Sources>,
    pub pipes: Option<hub_core::pipelines::Pipelines>,
    /// A run's record asked for (`hub tab 'infra runs/<repo>/<run>'`) before a ledger read has it:
    /// it opens when one does, unless the page moved first.
    run_want: Option<String>,
    /// A session asked for (a Home Running row, `hub tab 'sessions <id>'`) before the sessions
    /// feed has it: it opens when the feed does, unless the page moved first.
    session_want: Option<String>,
    pub files: BoardFiles,
    pub boards: Option<Boards>,
    pub forecast: Option<Forecast>,
    pub ranked: Option<Result<Vec<Ranked>, String>>,
    /// `fleet-bench reds`, the Alerts tab's Fixes and owners; None until the first read.
    pub reds: Option<Result<hub_core::reds::Reds, String>>,
    /// The Alerts tab's join; None until Prometheus and the reds have both answered.
    pub alerts: Option<hub_core::alerts::Alerts>,
    /// The Alerts tab's table view, opened row and Watches fold.
    pub av: AlertsView,
    alerts_read: Read,
    /// The Projects tab's Deliverables section; None until the first read.
    pub deliverables: Option<Result<hub_core::deliverables::Deliverables, String>>,
    /// The Costs tab's read; None until the first.
    pub costs: Option<hub_core::costs::Costs>,
    /// The Costs tab's cut, window, query and sort.
    pub cv: crate::coststab::CostsView,
    pub fleet: Option<hub_core::fleet::Fleet>,
    /// The Queue tab's pipeline line: None until the first read.
    pub pipeline: Option<Result<Option<hub_core::pipeline::Pipeline>, String>>,
    /// Fleet's one table: `/` query, `f` state, `s`/`S` sort, `x` clear (datatable), and the
    /// row j/k pick and Enter opens, an index into `fleettab::shown`.
    pub fleet_table: DataTable,
    /// The tier 1 rows folded (`z`), by runner name; their children leave the table.
    pub fleet_folded: std::collections::HashSet<String>,
    /// The runner whose page is open (Enter, or `hub tab fleet <runner>`); None is the tab.
    pub fleet_page: Option<String>,
    /// That page's read; None until it comes back.
    pub fleet_runner: Option<Result<hub_core::fleet::runner::Runner, String>>,
    /// The page open in place of Infra's tables, a machine's or a pool's, with its read (Enter
    /// on its row, a link to it, or `hub tab 'infra machines/<host>'`); None is the tab.
    pub infra_page: Option<InfraPage>,
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
    pub night: Option<hub_core::briefing::Night>,
    night_read: Read,
    night_at: Option<std::time::Instant>,
    /// Queue a fix per area name: None while it runs, then what agent-queue answered.
    pub fixes: hometab::Fixes,
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
    /// Log's inner tab shown (`hub_core::layout`'s Log groups): only its sections are drawn and read.
    pub log_inner: &'static str,
    /// Which of `ASK_FILTERS` the answer judge's verdict list shows.
    pub ask_filter: usize,
    /// Log's Work table; None until Log is first read.
    pub work: Option<hub_core::worklog::Gathered>,
    /// The view of Log's Work table.
    pub work_table: DataTable,
    /// Which of `logtab::WORK_WINDOWS` the Work table keeps, when no past day is open.
    work_window: usize,
    /// The Work table has the keys.
    log_work: bool,
    /// Log's Actions section; None until it is first opened.
    pub actions: Option<hub_core::actions::Gathered>,
    /// The view of Log's Actions table.
    pub actions_table: DataTable,
    /// The Actions table has the keys: its `f` and `s` are not the Forecast and Rundowns folds.
    log_actions: bool,
    /// Where the page's sections start, from the last draw (n/N jump between them on Log and
    /// Infra), with the `hub_core::layout` section names.
    sections: Vec<(&'static str, usize)>,
    /// A section to scroll to once the page draws (`hub --tab ci`, `hub --tab actions`).
    seek: Option<&'static str>,
    /// Infra's table opened whole over the summary: the Jobs section's or CI's Runs.
    pub infra_open: Option<Opened>,
    /// Infra's inner tab shown (a `hub_core::layout::Inner` id of Infra).
    pub infra_inner: &'static str,
    /// Infra shows every inner tab's sections under the strip: the printed page (`hub --once`),
    /// which has no keys to switch with.
    pub infra_all: bool,
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
    deliverables_read: Read,
    schedules_read: Read,
    releases_read: Read,
    builds_read: Read,
    /// When the last reds read finished, for `REDS_REFRESH`.
    reds_at: Option<std::time::Instant>,
    /// When the last Deliverables read finished, for `DELIVERABLES_REFRESH`.
    deliverables_at: Option<std::time::Instant>,
    /// When the last Schedules read finished, for `SCHEDULES_REFRESH`.
    schedules_at: Option<std::time::Instant>,
    costs_read: Read,
    costs_at: Option<std::time::Instant>,
    actions_read: Read,
    work_read: Read,
    fleet_read: Read,
    fleet_runner_read: Read,
    infra_page_read: Read,
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
            itab: Default::default(),
            paths: Paths::from_env(),
            infra: None,
            jobs: None,
            jv: JobsView::default(),
            hv: hometab::HomeView::default(),
            sv: SchedulesView::default(),
            schedules: None,
            rv: ReleasesView::default(),
            releases: None,
            builds: None,
            ci: bv::BuildsView::default(),
            plv: crate::pipetab::PipelinesView::default(),
            pipe_src: None,
            pipes: None,
            run_want: None,
            session_want: None,
            files: BoardFiles::from_env(),
            boards: None,
            forecast: None,
            ranked: None,
            reds: None,
            alerts: None,
            av: AlertsView::default(),
            alerts_read: Read::default(),
            deliverables: None,
            costs: None,
            cv: crate::coststab::CostsView::default(),
            fleet: None,
            pipeline: None,
            focus: None,
            daily_outbox: false,
            fleet_table: DataTable::default(),
            fleet_folded: Default::default(),
            fleet_page: None,
            fleet_runner: None,
            infra_page: None,
            outbox: None,
            outbox_said: None,
            focus_day: None,
            queue: None,
            qv: QueueView::default(),
            candidates: None,
            queue_dir: queue_dir(),
            tasks: None,
            proposals: None,
            night: None,
            night_read: Read::default(),
            night_at: None,
            fixes: Default::default(),
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
            log_inner: hub_core::layout::inner_tab(log_tab(), None).map_or("", |i| i.id),
            ask_filter: 0,
            actions: None,
            actions_table: DataTable::default(),
            work: None,
            work_table: DataTable::default(),
            work_window: 0,
            log_work: false,
            log_actions: false,
            sections: vec![],
            seek: None,
            infra_open: None,
            infra_inner: hub_core::layout::inner_tab(infra_tab(), None).map_or("", |i| i.id),
            infra_all: false,
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
            deliverables_read: Read::default(),
            schedules_read: Read::default(),
            releases_read: Read::default(),
            builds_read: Read::default(),
            reds_at: None,
            deliverables_at: None,
            schedules_at: None,
            costs_read: Read::default(),
            costs_at: None,
            actions_read: Read::default(),
            work_read: Read::default(),
            fleet_read: Read::default(),
            fleet_runner_read: Read::default(),
            infra_page_read: Read::default(),
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
            (self.files.sessions.clone(), false),
            (self.files.tokens.clone(), false),
            (self.files.releases.clone(), false),
            (self.files.watches.clone(), false),
        ];
        if let Some(d) = self.files.builds.ledger.parent() {
            v.push((d.to_path_buf(), false));
        }
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

    /// The Costs tab reads on entering, on `r`, on a new token snapshot (`Msg::TokenFiles`) and
    /// on the tick while it is shown, at most every `COSTS_REFRESH`: its other sources have no
    /// file to watch.
    pub fn read_costs(&mut self) {
        if self.costs_read.want() {
            let (tx, runner) = (self.tx.clone(), self.runner.clone());
            std::thread::spawn(move || {
                let paths = hub_core::costs::Paths::from_env();
                let c = hub_core::costs::read(runner.as_ref(), &paths, jobs::now());
                let _ = tx.send(Msg::Costs(Box::new(c)));
            });
        }
    }

    /// fleet-bench reds writes no file to watch, so Alerts reads it on entering, on `r` and on
    /// the tick while it is shown, at most every `REDS_REFRESH`.
    pub fn read_reds(&mut self) {
        if self.reds_read.want() {
            let (tx, runner) = (self.tx.clone(), self.runner.clone());
            std::thread::spawn(move || {
                let _ = tx.send(Msg::Reds(hub_core::reds::read(runner.as_ref())));
            });
        }
    }

    /// The Alerts join, once Prometheus and the reds have answered: on entering, on `r`, on each
    /// Prometheus or reds answer and on a watch's state file changing while the tab is shown.
    /// The watch files and the agent-notify ledger are read in the join, off the draw thread.
    pub fn read_alerts(&mut self) {
        let (Some(infra), Some(reds)) = (&self.infra, &self.reds) else {
            return;
        };
        if self.alerts_read.want() {
            let (tx, infra, reds) = (self.tx.clone(), infra.clone(), reds.clone());
            std::thread::spawn(move || {
                let a = hub_core::alerts::read(&infra, reds, jobs::now());
                let _ = tx.send(Msg::Alerts(Box::new(a)));
            });
        }
    }

    /// `fleet-bench epics` writes no file to watch, so Projects reads it on entering, on `r` and
    /// on the tick while it is shown, at most every `DELIVERABLES_REFRESH`.
    pub fn read_deliverables(&mut self) {
        if self.deliverables_read.want() {
            let (tx, runner) = (self.tx.clone(), self.runner.clone());
            std::thread::spawn(move || {
                let _ = tx.send(Msg::Deliverables(hub_core::deliverables::read(
                    runner.as_ref(),
                )));
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

    /// `release-state` replaces one file, so the tab reads on entering, on `r` and on that file's
    /// event; the snapshot's age is worked out as it is drawn. It joins the queue the hub holds
    /// (read on start), so each release's ROWS cell names its PRs' rows.
    pub fn read_releases(&mut self) {
        if self.releases_read.want() {
            let (tx, runner) = (self.tx.clone(), self.runner.clone());
            let items = self.queue_items();
            std::thread::spawn(move || {
                let s = hub_core::releases::read(runner.as_ref(), &items);
                let _ = tx.send(Msg::Releases(Box::new(s)));
            });
        }
    }

    /// Read the changelog of the selected app, at `tag` or its newest release, in a
    /// worker. One read at a time: while it runs a new ask waits, and `sync_changelog` makes it
    /// when the answer lands.
    fn read_changelog(&mut self, tag: Option<String>) {
        let Some(project) = self.selected_release().map(|r| r.project.clone()) else {
            return;
        };
        if self.rv.cl.busy {
            return;
        }
        self.rv.cl.busy = true;
        self.rv.cl.project = project.clone();
        self.rv.cl.read = None;
        self.rv.down = 0;
        let (tx, runner) = (self.tx.clone(), self.runner.clone());
        std::thread::spawn(move || {
            let r = hub_core::releases::changelog(runner.as_ref(), &project, tag.as_deref());
            let _ = tx.send(Msg::Changelog(r));
        });
    }

    /// With the pane open, the changelog and the checks are the selected app's: read each when
    /// the selection came to rest on another (a key, a re-sort, a new snapshot, an answer that
    /// landed), and the checks again each `APP_STATUS_REFRESH`, keeping the last read meanwhile.
    fn sync_changelog(&mut self) {
        let Some(project) = self.selected_release().map(|r| r.project.clone()) else {
            return;
        };
        if !self.rv.open {
            return;
        }
        if project != self.rv.cl.project {
            // Another app's pane starts open and at its top.
            self.rv.others = true;
            self.read_changelog(None);
        }
        let other = project != self.rv.st.project;
        let due = self
            .rv
            .st
            .at
            .is_some_and(|t| t.elapsed() >= APP_STATUS_REFRESH);
        if (other || due) && !self.rv.st.busy {
            self.rv.st.busy = true;
            if other {
                self.rv.st.project = project.clone();
                self.rv.st.read = None;
                self.rv.st.at = None;
            }
            let (tx, runner) = (self.tx.clone(), self.runner.clone());
            std::thread::spawn(move || {
                let now = chrono::Utc::now().timestamp();
                let r = hub_core::app_status::read(runner.as_ref(), &project, now);
                let _ = tx.send(Msg::AppStatus(project, Box::new(r)));
            });
        }
    }

    /// The ledger is appended to by schedules-sync every ten minutes: read on entering the tab,
    /// on `r` and on that file's event. Each run's PRs, owner and release are the graph's join
    /// over the PR store, the queue the hub holds and the releases snapshot.
    pub fn read_builds(&mut self) {
        if self.builds_read.want() {
            let (tx, runner) = (self.tx.clone(), self.runner.clone());
            let paths = self.files.builds.clone();
            let items = self.queue_items();
            // Only Infra draws Pipelines, and its sources list systemd's timers.
            let pipes = self.tab == Tab::Infra;
            std::thread::spawn(move || {
                let join = builds::Join {
                    runner: runner.as_ref(),
                    items: &items,
                };
                let b = builds::read(&paths, Some(join), jobs::now());
                let _ = tx.send(Msg::Builds(Box::new(b)));
                if pipes {
                    let s = hub_core::pipelines::sources(runner.as_ref());
                    let _ = tx.send(Msg::Pipes(Box::new(s)));
                }
            });
        }
    }

    /// Pipelines over the sources and runs last read, the same row kept selected and an opened
    /// row's detail rebuilt from them.
    fn build_pipes(&mut self) {
        let (Some(s), Some(b)) = (&self.pipe_src, &self.builds) else {
            return;
        };
        let p = hub_core::pipelines::pipelines(s, &b.rows);
        let id = self
            .pipes
            .as_ref()
            .and_then(|old| self.plv.selected(old))
            .map(crate::pipetab::row_id);
        self.plv.reselect(&p, id);
        if let Some(d) = &self.plv.open {
            self.plv.open = hub_core::pipelines::detail(s, &b.rows, &d.row.repo, &d.row.file);
        }
        self.pipes = Some(p);
    }

    /// The Pipelines inner tab's keys: its table's, j/k on its rows, Enter the selected row's
    /// detail (again, closes it) and Esc closes the detail, then clears the view. False for the
    /// rest, the page's keys.
    fn pipes_key(&mut self, k: KeyEvent) -> bool {
        let Some(p) = &self.pipes else {
            return false;
        };
        // Esc is the table's only while a query is typed.
        if self.plv.table.key::<hub_core::pipelines::Pipeline>(k.code) != Took::No {
            return true;
        }
        let n = self.plv.shown(p).len();
        if !k
            .modifiers
            .intersects(KeyModifiers::CONTROL | KeyModifiers::ALT)
            && self.plv.table.moves(k, n, self.page)
        {
            return true;
        }
        match k.code {
            KeyCode::Enter => {
                let id = self.plv.selected(p).map(crate::pipetab::row_id);
                let same = self
                    .plv
                    .open
                    .as_ref()
                    .map(|d| crate::pipetab::row_id(&d.row))
                    == id;
                self.plv.open = match (&self.pipe_src, &self.builds, id) {
                    (Some(s), Some(b), Some((repo, file))) if !same => {
                        hub_core::pipelines::detail(s, &b.rows, &repo, &file)
                    }
                    _ => None,
                };
            }
            KeyCode::Esc if self.plv.open.is_some() => self.plv.open = None,
            KeyCode::Esc if !self.plv.table.is_default() => self.plv.table.clear(),
            _ => return false,
        }
        true
    }

    /// Each app's build runs are the builds read's rows: put them on whichever read lands last.
    fn put_builds(&mut self) {
        if let (Some(r), Some(b)) = (&mut self.releases, &self.builds) {
            r.with_builds(&b.rows);
        }
    }

    /// The queue's items as last read, none before the first read lands.
    fn queue_items(&self) -> Vec<hub_core::queue::Item> {
        self.queue
            .as_ref()
            .map(|q| q.items.clone())
            .unwrap_or_default()
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

    /// The Work table loops over the queue's item files, so it reads on a worker, as Actions does.
    pub fn read_work(&mut self) {
        if self.work_read.want() {
            let tx = self.tx.clone();
            std::thread::spawn(move || {
                let g = hub_core::worklog::read(&hub_core::session_actions::System);
                let _ = tx.send(Msg::Work(Box::new(g)));
            });
        }
    }

    /// Log reads only what its shown inner tab draws (dashboards rule 10; the day, changes and
    /// rundowns come with the board files).
    fn read_log_tab(&mut self) {
        let shown = hub_core::layout::inner_tab(log_tab(), Some(self.log_inner));
        for name in shown.map_or(&[][..], |i| i.sections) {
            match *name {
                "work" => self.read_work(),
                "actions" => self.read_actions(),
                "verdicts" => self.read_fleet(),
                "forecast" => self.read_forecast(),
                "ranked" => self.read_ranked(),
                _ => {}
            }
        }
    }

    /// Whether Log shows the inner tab holding section `sec`.
    fn log_shows(&self, sec: &str) -> bool {
        crate::innertabs::named(log_tab(), sec) == Some(self.log_inner)
    }

    /// Show Log's inner tab `id` at its top, and read what it draws. The tables give their keys
    /// back: they are on another page now.
    fn log_go(&mut self, id: &'static str) {
        if self.log_inner != id {
            self.scroll = 0;
        }
        self.log_inner = id;
        self.log_work = false;
        self.log_actions = false;
        self.log_days = false;
        self.read_log_tab();
    }

    /// The Fleet tab reads agentctl's ledger and the dispatch and ask files, so it reads on
    /// entering, on `r`, on the tick and on an agentctl file event while it is shown.
    pub fn read_fleet(&mut self) {
        if self.fleet_read.want() {
            let tx = self.tx.clone();
            std::thread::spawn(move || {
                let f = hub_core::fleet::files(&hub_core::fleet::Paths::from_env());
                let _ = tx.send(Msg::Fleet(Box::new(f)));
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

    /// The open page's read, from the Infra rows last read: it waits for the first Prometheus
    /// read, and a later one reads it again.
    pub fn read_infra_page(&mut self) {
        let (Some(page), Some(infra)) = (self.infra_page.as_ref(), self.infra.clone()) else {
            return;
        };
        // Its history is three range queries, so a page left open behind another tab is not read,
        // and a page that reads the alerts waits for them (`Msg::Alerts` reads it) rather than
        // run twice.
        let ready = self.alerts.is_some() || !page.reads_alerts();
        if self.tab == Tab::Infra && ready && self.infra_page_read.want() {
            let tx = self.tx.clone();
            let firing = (self.alerts.as_ref())
                .filter(|_| page.reads_alerts())
                .map(|a| a.pages().cloned().collect::<Vec<_>>());
            let jobs = self.files.builds.jobs.clone();
            let page = page.unread();
            std::thread::spawn(move || {
                let now = jobs::now().max(0) as u64;
                let r = page.read(&infra, firing.as_deref(), &jobs, now);
                let _ = tx.send(Msg::InfraPage(Box::new(r)));
            });
        }
    }

    /// Open `page` in place of Infra's tables, on the inner tab its link names; the same page
    /// already open keeps its last read while it reads again.
    pub fn open_infra_page(&mut self, page: InfraPage) {
        if !self.infra_page.as_ref().is_some_and(|p| p.is(&page)) {
            self.infra_page = Some(page);
        }
        let Some(page) = &self.infra_page else { return };
        let (inner, alerts) = (page.inner(), page.reads_alerts());
        self.scroll = 0;
        self.go(Tab::Infra);
        self.infra_inner = inner;
        if self.infra_open == Some(Opened::Runs) {
            self.infra_open = None;
        }
        self.read_reds();
        if alerts {
            self.read_alerts();
        }
        self.read_infra_page();
    }

    /// Back from a page to the tab.
    fn close_infra_page(&mut self) {
        self.infra_page = None;
        self.scroll = 0;
    }

    /// The tab's read, or the open page's.
    fn read_fleet_shown(&mut self) {
        if self.fleet_page.is_some() {
            self.read_runner();
        } else {
            self.read_fleet();
        }
    }

    /// The flow strip's inbox and board are fleet-bench's snapshot, a file with no watch on it: read
    /// on entering Home or Queue, on `r` and on the tick while one is shown.
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

    /// The candidates are fleet-dispatch's snapshot, read in a worker on entering the Queue tab,
    /// on `r` there and after a queue action (a promote takes its row out of the file).
    pub fn read_candidates(&mut self) {
        if self.candidates_read.want() {
            let (tx, path) = (self.tx.clone(), self.files.candidates.clone());
            std::thread::spawn(move || {
                let _ = tx.send(Msg::Candidates(hub_core::queue::candidates(&path)));
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
                let _ = tx.send(Msg::Tasks(Box::new(hub_core::sheet_view::feed(
                    runner.as_ref(),
                ))));
            });
        }
    }

    /// Home's reads beside the fleet state: the human-sheet rows, the proposals and, at most
    /// every `briefing::NIGHT_REFRESH`, Since last night.
    pub fn read_home(&mut self) {
        self.read_tasks();
        self.read_proposals();
        self.read_night();
        self.read_pipeline();
    }

    /// Since last night over the fleet state, queue and Home this App already holds, so only
    /// what Home does not read is read again. Before the fleet state has loaded it waits: the
    /// tick asks again, and Sessions is never worded from an empty state.
    fn read_night(&mut self) {
        let due = self
            .night_at
            .is_none_or(|t| t.elapsed() >= hub_core::briefing::NIGHT_REFRESH);
        let Some(state) = self
            .boards
            .as_ref()
            .filter(|_| due)
            .map(|b| b.watch.state.clone())
        else {
            return;
        };
        if !self.night_read.want() {
            return;
        }
        let home = hub_core::home::build(
            &state,
            self.queue.as_ref(),
            self.tasks.as_ref(),
            self.infra.as_ref(),
        );
        let queue = self.queue.clone();
        let (tx, runner) = (self.tx.clone(), self.runner.clone());
        std::thread::spawn(move || {
            let now = jobs::now();
            let queue = queue.unwrap_or_else(|| hub_core::queue::Queue::read(runner.as_ref()));
            let n = hub_core::briefing::since_last_night(now, state, queue, home);
            let _ = tx.send(Msg::Night(Box::new(n)));
        });
    }

    /// Queue a fix for the first bad area not queued yet (`hometab::next_fix`), through the
    /// same `agent-queue add` agent-web's Queue a fix posts to.
    fn queue_fix(&mut self) {
        let Some((name, fix)) = self
            .night
            .as_ref()
            .and_then(|n| hometab::next_fix(n, &self.fixes))
            .map(|(name, fix)| (name.to_string(), fix.clone()))
        else {
            return;
        };
        self.fixes.insert(name.clone(), None);
        let (tx, runner) = (self.tx.clone(), self.runner.clone());
        std::thread::spawn(move || {
            let add = hub_core::queue::Add {
                project: fix.project.into(),
                task: fix.task,
                ..Default::default()
            };
            let r = hub_core::queue::add(runner.as_ref(), &add).map(|o| o.trim().to_string());
            let _ = tx.send(Msg::FixQueued(name, r));
        });
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
    pub fn read_proj_page_now(&mut self, runner: &(dyn Runner + Sync)) {
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
        hub_core::projects::build(stats, feed, state, self.queue.as_ref(), chrono::Utc::now())
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
                if self.tab == Tab::Releases {
                    self.sync_changelog();
                }
                if self.tab == Tab::Alerts
                    && self.reds_at.is_none_or(|t| t.elapsed() >= REDS_REFRESH)
                {
                    self.read_reds();
                }
                if self.tab == Tab::Projects
                    && self
                        .deliverables_at
                        .is_none_or(|t| t.elapsed() >= DELIVERABLES_REFRESH)
                {
                    self.read_deliverables();
                }
                if self.tab == Tab::Costs
                    && self.costs_at.is_none_or(|t| t.elapsed() >= COSTS_REFRESH)
                {
                    self.read_costs();
                }
                if self.tab == Tab::Home {
                    self.read_night();
                    self.read_pipeline();
                }
                // With no file watch, the board files are only read here.
                if self.watch_failed.is_some() {
                    self.read_boards();
                    self.read_queue();
                    if self.tab == Tab::Releases {
                        self.read_releases();
                    }
                    if reads_runs(self.tab) {
                        self.read_builds();
                    }
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
                    self.read_log_tab();
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
                } else if self.tab == Tab::Log && self.log_shows("verdicts") {
                    self.read_fleet();
                }
            }
            Msg::TokenFiles if self.tab == Tab::Costs => self.read_costs(),
            Msg::TokenFiles => {}
            Msg::ReleaseFile if self.tab == Tab::Releases => self.read_releases(),
            Msg::ReleaseFile => {}
            Msg::BuildFile if reads_runs(self.tab) => self.read_builds(),
            Msg::BuildFile => {}
            Msg::BoardFiles => self.read_boards(),
            Msg::ProposalFiles => self.read_proposals(),
            Msg::SessionFiles if self.tab == Tab::Home => self.read_boards(),
            Msg::SessionFiles => {}
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
            Msg::Costs(c) => {
                self.costs = Some(*c);
                self.costs_at = Some(std::time::Instant::now());
                if self.costs_read.done() && self.tab == Tab::Costs {
                    self.read_costs();
                }
            }
            Msg::Reds(r) => {
                self.reds = Some(r);
                self.reds_at = Some(std::time::Instant::now());
                if self.reds_read.done() && self.tab == Tab::Alerts {
                    self.read_reds();
                }
                if self.tab == Tab::Alerts {
                    self.read_alerts();
                }
            }
            Msg::Alerts(a) => {
                let id = self
                    .alerts
                    .as_ref()
                    .and_then(|old| self.av.selected(old))
                    .map(alertstab::row_id);
                self.av.reselect(&a, id);
                self.alerts = Some(*a);
                if self.alerts_read.done() && self.tab == Tab::Alerts {
                    self.read_alerts();
                }
                if self
                    .infra_page
                    .as_ref()
                    .is_some_and(InfraPage::reads_alerts)
                {
                    self.read_infra_page();
                }
            }
            Msg::WatchFiles => {
                if self.tab == Tab::Alerts {
                    self.read_alerts();
                }
            }
            Msg::Deliverables(r) => {
                self.deliverables = Some(r);
                self.deliverables_at = Some(std::time::Instant::now());
                if self.deliverables_read.done() && self.tab == Tab::Projects {
                    self.read_deliverables();
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
            Msg::Releases(s) => {
                let id = self.selected_release().map(releases::row_id);
                self.releases = Some(*s);
                self.put_builds();
                if let Some(s) = &self.releases {
                    self.rv.reselect(s, id);
                }
                self.sync_changelog();
                if self.releases_read.done() && self.tab == Tab::Releases {
                    self.read_releases();
                }
            }
            Msg::Changelog(r) => {
                self.rv.cl.busy = false;
                self.rv.cl.read = Some(r);
                self.sync_changelog();
            }
            Msg::AppStatus(project, r) => {
                self.rv.st.busy = false;
                if project == self.rv.st.project {
                    self.rv.st.read = Some(*r);
                    self.rv.st.at = Some(std::time::Instant::now());
                }
                self.sync_changelog();
            }
            Msg::Builds(b) => {
                let key = |v: &bv::BuildsView| {
                    self.builds
                        .as_ref()
                        .and_then(|b| v.selected(b))
                        .map(hub_core::builds::Run::key)
                };
                let (ci, rel) = (key(&self.ci), key(&self.rv.runs));
                self.ci.reselect(&b, ci);
                self.rv.runs.reselect(&b, rel);
                self.builds = Some(*b);
                self.put_builds();
                self.build_pipes();
                self.open_wanted_run();
                if self.builds_read.done() && reads_runs(self.tab) {
                    self.read_builds();
                }
            }
            Msg::Pipes(s) => {
                self.pipe_src = Some(*s);
                self.build_pipes();
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
            Msg::InfraPage(b) => {
                // A late answer for another page does not land on this one.
                if let Some(open) = self.infra_page.as_mut().filter(|p| p.is(&b)) {
                    *open = *b;
                }
                if self.infra_page_read.done() {
                    self.read_infra_page();
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
            Msg::Work(g) => {
                self.work = Some(*g);
                if self.work_read.done() {
                    self.read_work();
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
                if self.infra_page.is_some() {
                    self.read_infra_page();
                }
                if self.tab == Tab::Alerts {
                    self.read_alerts();
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
                // A wanted session the feed does not have yet stays wanted until the page moves.
                if let Some(id) = self.session_want.clone() {
                    if self.tab == Tab::Sessions && self.show_session(&id) {
                        self.session_want = None;
                    }
                }
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
                let logs = [
                    self.jv.log.as_mut(),
                    self.ci.log.as_mut(),
                    self.rv.runs.log.as_mut(),
                ];
                if let Some(l) = logs.into_iter().flatten().find(|l| l.gen == gen) {
                    l.text = Some(text);
                }
            }
            Msg::BuildDetail(gen, d) => {
                let panes = [self.ci.detail.as_mut(), self.rv.runs.detail.as_mut()];
                if let Some(p) = panes.into_iter().flatten().find(|p| p.gen == gen) {
                    p.read = Some(*d);
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
                let now = jobs::now();
                let was = self
                    .queue
                    .as_ref()
                    .and_then(|old| self.qv.selected(old, now))
                    .map(|i| i.slug.clone());
                self.qv.reselect(was, &q, cands_of(&self.candidates), now);
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
                    let now = jobs::now();
                    let was = self.qv.selected(q, now).map(|i| i.slug.clone());
                    self.qv.reselect(was, q, cands_of(&self.candidates), now);
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
                let n = self.prv.shown(open_rows(&self.proposals)).len();
                self.prv.table.clamp(n);
                if self.proposals_read.done() {
                    self.read_proposals();
                }
            }
            Msg::Night(n) => {
                if self.night.as_ref().is_some_and(|o| o.since != n.since) {
                    self.fixes.clear();
                }
                self.night = Some(*n);
                self.night_at = Some(std::time::Instant::now());
                if self.night_read.done() && self.tab == Tab::Home {
                    self.read_night();
                }
            }
            Msg::FixQueued(name, r) => {
                self.fixes.insert(name, Some(r));
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
        self.jv.shown(js).get(self.jv.table.sel).copied()
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
        if self.tab == Tab::Home && self.home_key(k) {
            return;
        }
        if self.tab == Tab::Infra && self.infra_key(k) {
            return;
        }
        if self.tab == Tab::Alerts && self.alerts_key(k) {
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
        if self.tab == Tab::Releases && self.releases_key(k) {
            return;
        }
        // A Ctrl or Alt chord is never one of the tab's letters, nor text for its query.
        if self.tab == Tab::Costs
            && !k
                .modifiers
                .intersects(KeyModifiers::CONTROL | KeyModifiers::ALT)
        {
            let c = self.costs.as_ref();
            let t = c.and_then(|c| c.tokens.as_ref());
            // Only `K` needs the Consumers level, so only `K` builds the section for it.
            let level = (k.code == KeyCode::Char('K'))
                .then(|| c.map(|c| hub_core::costs::consumers(c, Default::default()).level))
                .flatten();
            let was = self.cv.inner;
            if let Some(seek) = self.cv.fold(k.code, t, level) {
                self.seek = seek;
                // Another inner tab is another page: it opens at its top, not at this offset.
                if self.cv.inner != was {
                    self.scroll = 0;
                }
                return;
            }
            if self.cv.key(k.code) {
                self.scroll = 0;
                self.seek = crate::coststab::key_section(k.code);
                return;
            }
        }
        let n = self.page.max(1);
        let tabs = Tab::SHOWN.len();
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
            KeyCode::Tab => self.go(Tab::SHOWN[(self.tab.index() + 1) % tabs]),
            KeyCode::BackTab => self.go(Tab::SHOWN[(self.tab.index() + tabs - 1) % tabs]),
            KeyCode::Char('r') => {
                self.read_infra();
                self.read_jobs();
                self.read_boards();
                self.read_queue();
                if self.tab == Tab::Alerts {
                    self.read_reds();
                    self.read_alerts();
                }
                if self.tab == Tab::Projects {
                    self.read_deliverables();
                }
                if self.tab == Tab::Schedules {
                    self.read_schedules();
                }
                if self.tab == Tab::Releases {
                    self.read_releases();
                }
                if reads_runs(self.tab) {
                    self.read_builds();
                }
                if self.tab == Tab::Costs {
                    self.read_costs();
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
                    self.read_log_tab();
                }
                if self.tab == Tab::Home {
                    self.night_at = None;
                    self.read_home();
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

    /// Open what a link names, as `hub tab` would (`hub_core::links`): a record's tab and the
    /// word it opens there, or a page outside the hub in the browser. A runner or a session opens
    /// by its id directly, so one named like a Fleet section (`workers`) or a moved tab still opens.
    pub fn follow(&mut self, l: &Link) {
        if let Some(page) = InfraPage::from_link(l) {
            return self.open_infra_page(page);
        }
        match (l, l.tab_args()) {
            (Link::Url(u), _) => open(u),
            (Link::To(Kind::Runner, id), _) => {
                self.go(Tab::Fleet);
                self.open_runner(id);
            }
            (Link::To(Kind::Session, id), _) => self.open_session(id),
            (_, Some((tab, arg))) => {
                if let Some((t, q)) = crate::tabreq::parse(&format!("{tab} {arg}")) {
                    self.go(t);
                    self.open_query(q);
                }
            }
            (Link::To(..), None) => {}
        }
    }

    /// Open the session `target` on the Sessions tab, as a click on a Fleet row does on the web:
    /// now, or once the sessions feed has it.
    fn open_session(&mut self, target: &str) {
        self.go(Tab::Sessions);
        if !self.show_session(target) {
            self.session_want = Some(target.to_string());
        }
    }

    /// Select the session `target` and open its page, when the feed has it.
    fn show_session(&mut self, target: &str) -> bool {
        let Some(i) = self.controls.position(target) else {
            return false;
        };
        self.controls.table.sel = i;
        self.controls.open = true;
        self.seek = Some(DETAIL);
        true
    }

    /// `hub tab 'queue <word>'`: the Queue table under that word; an item's slug also selects
    /// the item and opens its record, as `#queue/<slug>` does on the web.
    fn open_queue(&mut self, q: &str) {
        self.qv.open(q);
        let slug = q.trim();
        let at = self.queue.as_ref().and_then(|queue| {
            self.qv
                .shown(queue, jobs::now())
                .iter()
                .position(|r| r.item.slug == slug)
        });
        if let Some(i) = at {
            self.qv.table.sel = i;
            self.qv.detail = true;
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
        if self.fleet_table.key::<Who>(k.code) != Took::No {
            return true;
        }
        let rows: Vec<(Opens, String)> = self.fleet.as_ref().map_or(vec![], |f| {
            fleettab::shown(f, &self.fleet_table, &self.fleet_folded)
                .into_iter()
                .map(|r| (r.opens, r.key.clone()))
                .collect()
        });
        // The selection back in range of the rows for Enter and z: a re-read can leave fewer.
        self.fleet_table.clamp(rows.len());
        if self.fleet_table.moves(k, rows.len(), self.page) {
            self.keep_fleet_sel_visible();
            return true;
        }
        let sel = self.fleet_table.sel;
        match k.code {
            KeyCode::Enter => {
                let l = self.fleet.as_ref().and_then(|f| {
                    fleettab::shown(f, &self.fleet_table, &self.fleet_folded)
                        .get(sel)
                        .and_then(|r| DataTable::opens(*r))
                });
                if let Some(l) = l {
                    self.follow(&l);
                }
            }
            KeyCode::Char('z') => {
                if let Some((Opens::Runner, name)) = rows.get(sel) {
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
        let at = 3 + errors + self.fleet_table.sel;
        let h = self.page.max(1);
        if at < self.scroll {
            self.scroll = at;
        } else if at >= self.scroll + h {
            self.scroll = at + 1 - h;
        }
    }

    /// A request's query: the outbox on Daily, a section on Infra and Log, else a project name.
    pub fn open_query(&mut self, q: Option<String>) {
        // `hub tab 'infra machines/<host>'` and each other record's page (links::PAGES).
        let tab = self.tab.title();
        if let Some((kind, id)) = q.as_deref().and_then(|q| hub_core::links::page_of(tab, q)) {
            return self.open_page(kind, id);
        }
        match (self.tab, q) {
            (Tab::Daily, q) => {
                if q.is_some_and(|q| q.trim().eq_ignore_ascii_case("outbox")) {
                    self.show_outbox(true);
                }
            }
            // `hub tab 'infra runs pr:=o/r#7'`: the runs table under that query (a PR's CI runs).
            (Tab::Infra, Some(q)) if q.trim().starts_with("runs ") => {
                self.open_runs(q.trim()["runs ".len()..].trim().to_string());
            }
            (Tab::Alerts | Tab::Infra | Tab::Log, Some(q)) => {
                let secs =
                    hub_core::layout::resolve(self.tab.title()).map_or(&[][..], |t| t.sections);
                if let Some(sec) = secs.iter().find(|s| s.eq_ignore_ascii_case(q.trim())) {
                    self.open_section(sec);
                } else if let (Tab::Log, Some(id)) =
                    (self.tab, crate::innertabs::named(log_tab(), &q))
                {
                    // `hub --tab 'log judges'`: an inner tab's own name opens it at its top.
                    self.log_go(id);
                } else if let (Tab::Infra, Some(id)) =
                    (self.tab, crate::innertabs::named(infra_tab(), &q))
                {
                    // `hub --tab 'infra reds'`: an inner tab's own name opens it at its top.
                    self.infra_inner = id;
                    self.infra_open = None;
                    self.scroll = 0;
                } else if let Some((table, chip)) = hub_core::layout::moved_chip("infra", &q) {
                    // `hub --tab 'infra governor'`: the table it moved into, under its chip.
                    if let Some(t) = self.itab.view(table) {
                        t.clear();
                        t.view.state = chip.into();
                    }
                    self.open_section(table);
                }
            }
            // Fleet's own section names (`workers`) scroll there; any other word is a runner. A
            // section that moved off Fleet (`tokens`) never gets here: tabreq::parse sends it on.
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
            // A section's name opens its fold and scrolls to it; other words set the view.
            (Tab::Costs, Some(q)) => {
                self.cv.open(&q);
                let secs =
                    hub_core::layout::resolve(self.tab.title()).map_or(&[][..], |t| t.sections);
                if let Some(sec) = secs.iter().find(|s| s.eq_ignore_ascii_case(q.trim())) {
                    self.seek = Some(sec);
                }
            }
            (Tab::Queue, Some(q)) => self.open_queue(&q),
            (Tab::Sessions, Some(q)) => self.open_session(q.trim()),
            // An inner tab's or a section's name shows that inner tab; any other word is the query.
            (Tab::Releases, Some(q)) => match crate::innertabs::named(releases::tab(), &q) {
                Some(id) => self.rv.show(id),
                None => self.rv.open_view(q),
            },
            (_, q) => self.open_project(q),
        }
    }

    /// A record's page on its tab (`links::PAGES`): a machine's or a pool's page (`InfraPage`),
    /// a CI run's record (the runs table narrowed to it, its newest attempt opened with its jobs
    /// and log, now or once the ledger is read), or every run of one job, as `h` on its row lists.
    fn open_page(&mut self, kind: Kind, id: &str) {
        if let Some(page) = InfraPage::new(kind, id) {
            return self.open_infra_page(page);
        }
        match kind {
            Kind::CiRun => {
                self.open_runs(hub_core::builds::run_query(id));
                self.run_want = Some(id.to_string());
                self.open_wanted_run();
            }
            Kind::Job => {
                self.open_jobs();
                self.jobs_history(Some(id.to_string()));
            }
            Kind::App => {
                self.rv.open_app(self.releases.as_ref(), id);
                self.sync_changelog();
            }
            _ => {}
        }
    }

    /// The runs table under one query, from its top, with no run open.
    fn open_runs(&mut self, q: String) {
        self.open_section("runs");
        let v = &mut self.ci;
        v.table.clear();
        v.table.view.q = q;
        (v.log, v.detail) = (None, None);
    }

    fn open_wanted_run(&mut self) {
        if self.run_want.is_none() || self.builds.is_none() || self.tab != Tab::Infra {
            return;
        }
        // The runs table narrowed to the run: its first row is its newest attempt, once read.
        self.ci.table.sel = 0;
        if self.selected_build().is_some() {
            self.run_want = None;
            self.open_build_log();
        }
    }

    /// Show one section of the tab: Infra's Jobs opens the jobs table and its Runs the runs
    /// table, Log's History its day list and a Log fold opens; any other scrolls to its heading
    /// at the next draw.
    fn open_section(&mut self, sec: &'static str) {
        self.infra_open = match sec {
            "jobs" => Some(Opened::Jobs),
            "runs" if self.tab == Tab::Infra => Some(Opened::Runs),
            _ => None,
        };
        // A section on another inner tab switches to it.
        if self.tab == Tab::Infra {
            if let Some(id) = crate::innertabs::named(infra_tab(), sec) {
                self.infra_inner = id;
            }
        }
        if self.tab == Tab::Alerts {
            if let Some(id) = crate::innertabs::named(alertstab::tab(), sec) {
                self.av.inner = id;
            }
        }
        if self.tab == Tab::Log {
            if let Some(id) = crate::innertabs::named(log_tab(), sec) {
                self.log_go(id);
            }
        }
        self.log_days = self.tab == Tab::Log && sec == "history";
        if self.infra_open.is_none() && !self.log_days {
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
        self.infra_open = None;
        self.log_days = false;
        self.log_actions = false;
        self.log_work = false;
        self.seek = None;
        self.run_want = None;
        self.session_want = None;
        if t == Tab::Log {
            self.read_log_tab();
        }
        if t == Tab::Sessions {
            self.read_forecast();
            self.read_sessions();
        }
        if t == Tab::Fleet {
            self.read_fleet_shown();
        }
        if t == Tab::Alerts {
            self.read_reds();
            self.read_alerts();
        }
        if t == Tab::Schedules {
            self.read_schedules();
        }
        if t == Tab::Releases {
            self.read_releases();
        }
        if reads_runs(t) {
            self.read_builds();
        }
        if t == Tab::Costs {
            self.read_costs();
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
            self.read_deliverables();
        }
        if t == Tab::Home {
            self.read_home();
        }
    }

    /// The Projects tab's keys: the list's (projtab.rs), or with the rows open theirs
    /// (tasktab.rs), where Esc clears a filter first and then, like Backspace, goes back.
    fn projects_key(&mut self, k: KeyEvent) -> bool {
        if !self.pv.open {
            let cards = self.cards().cards;
            if k.code == KeyCode::Char('P') && self.pv.table.typing.is_none() && !self.pv.dfocus {
                if let Some(c) = self.pv.selected(&cards) {
                    self.prio_act(
                        c.profile.clone(),
                        c.name.clone(),
                        hub_core::projects::next_prio(&c.prio),
                    );
                }
                return true;
            }
            // `d` takes the keys only for a table that is read: with none, it is a plain no-op.
            if k.code == KeyCode::Char('d')
                && self.pv.table.typing.is_none()
                && !self.pv.dfocus
                && !matches!(self.deliverables, Some(Ok(_)))
            {
                return true;
            }
            if self.pv.dfocus {
                if let Some(Ok(d)) = &self.deliverables {
                    return self.pv.dkey(&mut self.tv, k, &cards, d, self.page);
                }
                self.pv.dfocus = false;
            }
            return self.pv.key(&mut self.tv, k, &cards, self.page);
        }
        // An opened project's inner tabs: Left/Right switch them, and every inner tab but Rows
        // takes its own keys (projtab.rs `page_key`); the row keys are Rows' alone.
        if !self.tv.typing() && self.tv.project.is_some() {
            let name = self.tv.project.as_ref().map(|(_, n)| n.clone());
            let pg = self
                .proj_page
                .as_ref()
                .filter(|pg| Some(&pg.project) == name.as_ref());
            if self.pv.page_key(&mut self.tv, k, pg, self.page) {
                self.scroll = 0;
                return true;
            }
        }
        if let (false, KeyCode::Char('R'), Some((_, name))) =
            (self.tv.typing(), k.code, self.tv.project.clone())
        {
            self.open_releases(&name);
            return true;
        }
        if let (false, KeyCode::Char('A'), Some((_, name))) =
            (self.tv.typing(), k.code, self.tv.project.clone())
        {
            self.open_alerts(&name);
            return true;
        }
        if !self.tv.typing() {
            let v = &self.tv;
            let filtered = self.pv.rows_shown(v) && (!v.table.is_default() || v.said.is_some());
            if k.code == KeyCode::Backspace || (k.code == KeyCode::Esc && !filtered) {
                self.pv.close(&mut self.tv);
                self.scroll = 0;
                return true;
            }
        }
        // With no rows read there is nothing to clear: Esc still goes back.
        if self.pv.rows_shown(&self.tv) && self.board_key(k) {
            return true;
        }
        if k.code == KeyCode::Esc && !self.tv.typing() {
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
    /// pick a row or a candidate, `/ f s S x` are the shared table's, Enter opens a row's detail
    /// and Esc closes it or clears the view, c arms a cancel and +/- move the priority of an
    /// active item, C folds or opens the candidates (open at first) and p promotes one. The draw keeps the selected row
    /// in view.
    fn queue_key(&mut self, k: KeyEvent) -> bool {
        // g and G take the page to its very top (the headings) and bottom (the Candidates fold),
        // which keeping the selected row in view alone would stop short of.
        let typing = self.qv.table.typing.is_some() || self.qv.confirm.is_some();
        match k.code {
            _ if typing => {}
            KeyCode::Char('g') | KeyCode::Home => self.scroll = 0,
            KeyCode::Char('G') | KeyCode::End => self.scroll = usize::MAX / 2,
            _ => {}
        }
        let line_key = matches!(
            k.code,
            KeyCode::Char('[' | ']' | '{' | '}') | KeyCode::Esc | KeyCode::Enter
        );
        if line_key && !typing && !k.modifiers.contains(KeyModifiers::CONTROL) {
            if let Some(q) = &self.queue {
                let rail =
                    hub_core::flow::Rail::build(Some(q), self.pipeline.as_ref(), jobs::now());
                match self.qv.line.key(k.code, &rail) {
                    flowline::Took::No => {}
                    flowline::Took::Moved => return true,
                    flowline::Took::Open(slug) => {
                        self.open_queue(&slug);
                        self.scroll = 0;
                        return true;
                    }
                }
            }
        }
        match self.qv.key(
            k,
            self.queue.as_ref(),
            cands_of(&self.candidates),
            self.page,
            jobs::now(),
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
            queuetab::Ask::Follow(l) => {
                self.follow(&l);
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
        let armed = |c: &Controls| c.confirm.is_some() || c.starting.is_some();
        let was = (
            self.controls.open,
            self.controls.table.sel,
            armed(&self.controls),
        );
        match self.controls.key(k) {
            Ask::Pass => return false,
            Ask::Done => {}
            Ask::Run(t, a, acct) => self.act(t, a, acct),
            Ask::Start(name) => self.start_timer(name),
        }
        self.read_page();
        // The detail draws under the whole table, so the view goes to it when it opens, changes
        // row or a confirm is armed, and otherwise stays where the reader scrolled it.
        if self.controls.open {
            let now_armed = armed(&self.controls);
            if !was.0 || was.1 != self.controls.table.sel || (now_armed && !was.2) {
                self.seek = Some(DETAIL);
            }
            return true;
        }
        self.seek = None;
        // The stage counts line, then the table's own header.
        let at = 1 + self.controls.above() + self.controls.table.sel;
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
    /// or h go back. Otherwise Left/Right step the inner tabs, h opens the day list, a `FOLDS`
    /// key opens the inner tab holding its section, and the day's keys.
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
        if self.log_work && self.work_key(k) {
            return true;
        }
        if self.log_actions && self.actions_key(k) {
            return true;
        }
        match k.code {
            KeyCode::Left | KeyCode::Right => {
                let to = crate::innertabs::step(log_tab(), self.log_inner, k.code == KeyCode::Left);
                self.log_go(to);
            }
            // `W` and `A` open Work's or Actions' inner tab and give its table the keys.
            KeyCode::Char('W') => {
                self.log_go("work");
                self.log_work = true;
            }
            KeyCode::Char('A') => {
                self.log_go("actions");
                self.log_actions = true;
            }
            // Enter and `/` are the table of the inner tab shown, Work's or Actions'.
            KeyCode::Enter | KeyCode::Char('/')
                if !self.log_actions && !self.log_work && self.log_shows("work") =>
            {
                self.log_work = true;
                return k.code == KeyCode::Enter || self.work_key(k);
            }
            KeyCode::Enter | KeyCode::Char('/')
                if !self.log_actions && !self.log_work && self.log_shows("actions") =>
            {
                self.log_actions = true;
                return k.code == KeyCode::Enter || self.actions_key(k);
            }
            KeyCode::Char('h') => {
                self.log_go("day");
                self.log_days = true;
                self.scroll = 0;
            }
            KeyCode::Char(c) if FOLDS.iter().any(|f| f.1 == c) => {
                let Some(&(name, ..)) = FOLDS.iter().find(|f| f.1 == c) else {
                    return true;
                };
                if let Some(id) = crate::innertabs::named(log_tab(), name) {
                    self.log_go(id);
                    self.seek = Some(name);
                }
            }
            KeyCode::Char('V') if self.log_shows("verdicts") => {
                self.ask_filter = (self.ask_filter + 1) % ASK_FILTERS.len();
            }
            // The day's keys step the day Day shows; on another inner tab they are not Log's.
            KeyCode::Char('[' | ']' | 't') if !self.log_shows("day") => return false,
            _ => return self.today_key(k),
        }
        true
    }

    fn actions_key(&mut self, k: KeyEvent) -> bool {
        log_table_key::<hub_core::actions::Action>(
            &mut self.actions_table,
            &mut self.log_actions,
            k,
        )
    }

    /// The Work table's keys, and `d` to step its window. A past day in the stepper is the
    /// window while it is picked, so the first `d` goes back to the window it replaced.
    fn work_key(&mut self, k: KeyEvent) -> bool {
        if self.work_table.typing.is_none() && k.code == KeyCode::Char('d') {
            if self.day.is_some() {
                self.open_day(None);
            } else {
                self.work_window = (self.work_window + 1) % logtab::WORK_WINDOWS.len();
            }
            return true;
        }
        log_table_key::<hub_core::worklog::Work>(&mut self.work_table, &mut self.log_work, k)
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

    /// Home's own keys. The page: Tab and BackTab move the keys between the Needs you and
    /// Running tables, F queues a fix for Since last night's next bad area and a flow key opens
    /// its chip, whichever has them. Needs you: its table keys (/ f s S x, Esc clears its view
    /// first) and Enter opens the proposals table. Running (`home_running_key`): its table keys,
    /// j/k pick a row and Enter opens it. The proposals table: the table keys, j/k, Enter the
    /// record, a accept, d reject; Esc steps back out.
    /// Home from the reads held, as the page draws it.
    fn home_build(&self) -> hub_core::home::Home {
        let null = serde_json::Value::Null;
        let state = self.boards.as_ref().map_or(&null, |b| &b.watch.state);
        hub_core::home::build(
            state,
            self.queue.as_ref(),
            self.tasks.as_ref(),
            self.infra.as_ref(),
        )
    }

    fn home_key(&mut self, k: KeyEvent) -> bool {
        if !self.prv.open {
            if !self.hv.typing() {
                if k.code == KeyCode::Char('F') {
                    self.queue_fix();
                    return true;
                }
                if let KeyCode::Char(c) = k.code {
                    if let Some(chip) = hometab::FLOW_KEYS.iter().find(|(key, _)| *key == c) {
                        self.open_flow(chip.1);
                        return true;
                    }
                }
                // With nothing running there is nothing to give the keys to: Tab turns the page.
                if matches!(k.code, KeyCode::Tab | KeyCode::BackTab)
                    && (self.hv.on_running || !self.home_build().running.is_empty())
                {
                    self.hv.on_running = !self.hv.on_running;
                    self.hv.follow = self.hv.on_running;
                    return true;
                }
            }
            if self.hv.on_running {
                return self.home_running_key(k);
            }
            if self.hv.needs.typing.is_none() {
                if k.code == KeyCode::Enter && !open_rows(&self.proposals).is_empty() {
                    self.prv.open = true;
                    return true;
                }
                if k.code == KeyCode::Esc && !self.hv.needs.is_default() {
                    self.hv.needs.clear();
                    self.scroll = 0;
                    return true;
                }
                // Needs you hides its empty chips, so `f` steps over the ones drawn.
                if k.code == KeyCode::Char('f') {
                    let needs = self.home_build().needs;
                    self.hv.needs.view.cycle_shown(&needs);
                    self.scroll = 0;
                    return true;
                }
            }
            return match self.hv.needs.key::<Need>(k.code) {
                Took::View => {
                    self.scroll = 0;
                    true
                }
                Took::Typing => true,
                Took::No => false,
            };
        }
        if self.prv.table.key::<Proposal>(k.code) != Took::No {
            return true;
        }
        let rows = self.prv.shown(open_rows(&self.proposals)).len();
        let pv = &mut self.prv;
        if pv.table.moves(k, rows, self.page) {
            return true;
        }
        match k.code {
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

    /// Home's Running table with the keys: its table keys (`f` steps over the chips drawn), j/k,
    /// g/G and Home/End pick a row, Enter opens it as the web's row click does (its session's page,
    /// else its queue item), Esc clears the view and then gives the keys back to Needs you.
    fn home_running_key(&mut self, k: KeyEvent) -> bool {
        if k.modifiers
            .intersects(KeyModifiers::CONTROL | KeyModifiers::ALT)
        {
            return false;
        }
        let moves = matches!(
            k.code,
            KeyCode::Char('j' | 'k' | 'g' | 'G')
                | KeyCode::Up
                | KeyCode::Down
                | KeyCode::Home
                | KeyCode::End
        );
        let typing = self.hv.running.typing.is_some();
        // Only the keys that read the rows build Home.
        let reads = !typing && (moves || matches!(k.code, KeyCode::Enter | KeyCode::Char('f')));
        let h = if reads {
            self.home_build()
        } else {
            hub_core::home::Home::default()
        };
        // What Enter and j/k step through: the rows drawn, the selection back in their range.
        let n = self.hv.running_rows(&h).len();
        if reads {
            // Nothing left to pick (the last item finished): the keys go back to Needs you.
            if n == 0 {
                self.hv.on_running = false;
                return false;
            }
            self.hv.running.clamp(n);
        }
        let rv = &mut self.hv.running;
        if !typing {
            match k.code {
                KeyCode::Enter => {
                    let l = self
                        .hv
                        .running_rows(&h)
                        .get(self.hv.running.sel)
                        .and_then(|r| DataTable::opens(*r));
                    if let Some(l) = l {
                        self.follow(&l);
                    }
                    return true;
                }
                KeyCode::Esc if rv.is_default() => {
                    self.hv.on_running = false;
                    return true;
                }
                KeyCode::Esc => rv.clear(),
                KeyCode::Char('f') => {
                    rv.view.cycle_shown(&h.running);
                    rv.sel = 0;
                }
                _ => {}
            }
            if matches!(k.code, KeyCode::Esc | KeyCode::Char('f')) {
                self.hv.follow = true;
                return true;
            }
        }
        match rv.key::<hub_core::home::Running>(k.code) {
            Took::View => {
                self.hv.follow = true;
                return true;
            }
            Took::Typing => return true,
            Took::No => {}
        }
        if moves && rv.moves(k, n, self.page) {
            self.hv.follow = true;
            return true;
        }
        false
    }

    /// A flow chip's view: the Queue on its state chip, or the Projects tab for the board chip.
    fn open_flow(&mut self, key: &str) {
        let Some(to) = hub_core::flow::Strip::build(None)
            .chips
            .into_iter()
            .find(|c| c.key == key)
            .and_then(|c| c.to)
        else {
            return;
        };
        match to.tab {
            "queue" => {
                self.go(Tab::Queue);
                self.qv.open("");
                self.qv.table.view.state = to.state.into();
            }
            tab => {
                if let Some(t) = Tab::parse(tab) {
                    self.go(t);
                }
            }
        }
    }

    /// Infra's own keys. The summary: Left/Right switch the inner tab, n/N jump between
    /// sections, the table keys (/ f s S x, Esc) go to the inner tab's table that has them and
    /// `c` passes them on (`infratables`); on Runs, Enter opens the runs table; on Pipelines the
    /// table keys and j/k are its table's and Enter opens the selected row's detail; elsewhere
    /// Enter and the jobs keys (/ s f h) open the jobs table. The runs and jobs tables: their
    /// keys, and Esc with nothing to clear goes back to the summary.
    fn infra_key(&mut self, k: KeyEvent) -> bool {
        // A page: Esc back to the tables, `o` its Grafana board, Left/Right another inner tab;
        // the rest scroll it.
        if let Some(page) = self
            .infra_page
            .as_ref()
            .filter(|_| self.infra_open != Some(Opened::Jobs))
        {
            match k.code {
                KeyCode::Esc | KeyCode::Backspace => self.close_infra_page(),
                KeyCode::Char('o') => match page.grafana() {
                    Some(u) => open(&u),
                    None => return false,
                },
                KeyCode::Left | KeyCode::Right => {
                    self.close_infra_page();
                    return self.infra_key(k);
                }
                _ => return false,
            }
            return true;
        }
        if self.infra_open == Some(Opened::Runs) {
            let v = &self.ci;
            let root = v.table.is_default() && v.log.is_none();
            if root && matches!(k.code, KeyCode::Esc | KeyCode::Backspace) {
                self.infra_open = None;
                return true;
            }
            return self.builds_key(k);
        }
        if self.infra_open.is_none() {
            if !crate::infratables::InfraTables::on(self.infra_inner).is_empty() {
                // The table first: a `c` typed into its query is the query's.
                if self.itab.key(self.infra.as_ref(), self.infra_inner, k.code) != Took::No {
                    return true;
                }
                if k.code == KeyCode::Char('c') {
                    self.itab.cycle(self.infra_inner);
                    return true;
                }
                // G arrives with SHIFT; Ctrl and Alt keys are the page's.
                if !k
                    .modifiers
                    .intersects(KeyModifiers::CONTROL | KeyModifiers::ALT)
                    && self.itab.moves(self.infra.as_ref(), self.infra_inner, k)
                {
                    return true;
                }
                // Enter opens the selected row's record: a machine's page, a pool's.
                if k.code == KeyCode::Enter {
                    if let Some(l) = self.itab.opens(self.infra.as_ref(), self.infra_inner) {
                        self.follow(&l);
                        return true;
                    }
                }
            }
            // The runs table is one key away, as Jobs is from the rest.
            if self.infra_inner == "runs" && k.code == KeyCode::Enter {
                self.infra_open = Some(Opened::Runs);
                return true;
            }
            if self.infra_inner == "pipelines" && self.pipes_key(k) {
                return true;
            }
            match k.code {
                KeyCode::Left | KeyCode::Right => {
                    self.infra_inner = crate::innertabs::step(
                        infra_tab(),
                        self.infra_inner,
                        k.code == KeyCode::Left,
                    );
                    // Another inner tab is another page: it opens at its top.
                    self.scroll = 0;
                }
                KeyCode::Char('n' | 'N') => self.next_section(k.code == KeyCode::Char('n')),
                KeyCode::Enter => self.open_jobs(),
                c if c == KeyCode::Char('h') || DataTable::owns(c) => {
                    self.open_jobs();
                    return self.jobs_key(k);
                }
                _ => return false,
            }
            return true;
        }
        let jv = &self.jv;
        let root = jv.table.is_default() && jv.log.is_none() && jv.history.is_none();
        if root && matches!(k.code, KeyCode::Esc | KeyCode::Backspace) {
            self.infra_open = None;
            return true;
        }
        self.jobs_key(k)
    }

    /// The whole jobs table, from the Jobs inner tab, so Esc comes back to it.
    fn open_jobs(&mut self) {
        self.infra_open = Some(Opened::Jobs);
        self.infra_inner = "jobs";
    }

    /// Every run of one job, or with None the folded list again, from its top.
    fn jobs_history(&mut self, name: Option<String>) {
        self.jv.history = name;
        self.jv.table.sel = 0;
        self.read_jobs();
    }

    fn jobs_key(&mut self, k: KeyEvent) -> bool {
        if self.jv.table.key::<Job>(k.code) != Took::No {
            return true;
        }
        let rows = self.jobs.as_ref().map_or(0, |j| self.jv.shown(j).len());
        let n = self.page.max(1);
        let jv = &mut self.jv;
        match k.code {
            c @ (KeyCode::PageDown | KeyCode::PageUp | KeyCode::Char('J' | 'K'))
                if jv.log.as_mut().is_some_and(|l| l.scroll(c, n)) => {}
            KeyCode::Enter => self.open_log(),
            KeyCode::Esc => {
                if jv.log.is_some() {
                    jv.log = None;
                } else if jv.history.is_some() {
                    jv.history = None;
                    self.read_jobs();
                } else {
                    jv.table.clear();
                }
            }
            KeyCode::Char('h') => {
                let name = self.selected().map(|j| j.name.clone());
                self.jobs_history(name.filter(|_| self.jv.history.is_none()));
            }
            KeyCode::Char('o') => {
                if let Some(u) = self.selected().and_then(|j| j.url.clone()) {
                    open(&u);
                }
            }
            _ => return jv.table.moves(k, rows, n),
        }
        true
    }

    fn selected_schedule(&self) -> Option<&Schedule> {
        let s = self.schedules.as_ref()?;
        self.sv.shown(s).get(self.sv.table.sel).copied()
    }

    /// The Schedules table's keys. Enter opens the row's pane, or an agentctl row's Fleet page,
    /// which already says all the pane would.
    /// The Alerts tab's keys: Left/Right switch the inner tab, `w` shows or folds the ok watches
    /// (on Watches). On
    /// Firing, the table's (/ f s S x; a new view shuts the opened row), j/k and the page keys
    /// move its selection, Enter opens the row under it, `o` its fix PR, `i` its queue item; Esc
    /// shuts the row, then clears the view, then is the global Esc. The other inner tabs scroll.
    fn alerts_key(&mut self, k: KeyEvent) -> bool {
        if k.modifiers
            .intersects(KeyModifiers::CONTROL | KeyModifiers::ALT)
        {
            return false;
        }
        let typing = self.av.table.typing.is_some();
        match k.code {
            KeyCode::Left | KeyCode::Right if !typing => {
                let back = k.code == KeyCode::Left;
                self.av.inner = crate::innertabs::step(alertstab::tab(), self.av.on(), back);
                self.scroll = 0;
                self.av.follow = true;
                return true;
            }
            // `w` shows or folds the ok watches, on Watches, which opens at its top.
            KeyCode::Char('w') if !typing => {
                self.av.ok_watches = !self.av.ok_watches || self.av.on() != "watches";
                self.av.inner = "watches";
                self.scroll = 0;
                self.av.follow = true;
                return true;
            }
            _ if self.av.on() != "firing" => return false,
            _ => {}
        }
        match self.av.table.key::<Alert>(k.code) {
            Took::No => {}
            Took::Typing => return true,
            Took::View => {
                self.av.open = false;
                self.av.follow = true;
                return true;
            }
        }
        let rows = self.alerts.as_ref().map_or(0, |a| self.av.shown(a).len());
        if matches!(
            k.code,
            KeyCode::Char('j' | 'k' | 'g' | 'G')
                | KeyCode::Up
                | KeyCode::Down
                | KeyCode::Home
                | KeyCode::End
        ) && self.av.table.moves(k, rows, self.page)
        {
            self.av.follow = true;
            return true;
        }
        let sel = self
            .alerts
            .as_ref()
            .and_then(|a| self.av.selected(a))
            .cloned();
        match k.code {
            KeyCode::Enter if sel.is_some() => {
                self.av.open = !self.av.open;
                self.av.follow = true;
            }
            KeyCode::Esc if self.av.open => self.av.open = false,
            KeyCode::Esc if !self.av.table.is_default() => self.av.table.clear(),
            KeyCode::Char('o') => match sel.and_then(|a| a.pr_url) {
                Some(u) => open(&u),
                None => return false,
            },
            KeyCode::Char('i') => match sel.filter(|a| !a.slug.is_empty()) {
                Some(a) => {
                    self.go(Tab::Queue);
                    self.qv.open(&a.slug);
                }
                None => return false,
            },
            _ => return false,
        }
        true
    }

    fn schedules_key(&mut self, k: KeyEvent) -> bool {
        if self.sv.table.key::<Schedule>(k.code) != Took::No {
            return true;
        }
        let rows = self
            .schedules
            .as_ref()
            .map_or(0, |s| self.sv.shown(s).len());
        let before = self.sv.table.sel;
        let sv = &mut self.sv;
        match k.code {
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
                }
            }
            KeyCode::Char('o') => {
                let run = self.selected_schedule().and_then(|r| r.runs.first());
                if let Some(u) = run.filter(|u| !u.url.is_empty()) {
                    open(&u.url);
                }
            }
            _ if sv.table.moves(k, rows, self.page) => {}
            _ => return false,
        }
        if self.sv.table.sel != before {
            self.sv.down = 0;
        }
        true
    }

    fn selected_release(&self) -> Option<&ReleaseApp> {
        let s = self.releases.as_ref()?;
        self.rv.shown(s).get(self.rv.table.sel).copied()
    }

    /// The Releases tab, on one project's app: where a Projects card's badge leads.
    fn open_releases(&mut self, project: &str) {
        self.rv.open_view(format!("project:{project}"));
        self.go(Tab::Releases);
    }

    /// The Alerts tab, on one project's rows: where a Projects card's count line leads.
    fn open_alerts(&mut self, project: &str) {
        self.av.table.clear();
        self.av.table.view.q = format!("project:{project}");
        self.av.open = false;
        self.av.follow = true;
        self.go(Tab::Alerts);
    }

    /// The runs table this tab shows: Infra's CI runs (every run), or Releases' Release runs
    /// (the runs tied to a release), both over `builds`.
    fn runs(&self) -> &bv::BuildsView {
        if self.tab == Tab::Infra {
            &self.ci
        } else {
            &self.rv.runs
        }
    }

    fn runs_mut(&mut self) -> &mut bv::BuildsView {
        if self.tab == Tab::Infra {
            &mut self.ci
        } else {
            &mut self.rv.runs
        }
    }

    fn selected_build(&self) -> Option<&hub_core::builds::Run> {
        self.runs().selected(self.builds.as_ref()?)
    }

    /// Enter on a run: its detail and failed-job log, read now and never before. The detail is
    /// priced with the rates the Infra board last read; before its first read, nothing is priced.
    fn open_build_log(&mut self) {
        let Some(r) = self.selected_build() else {
            return;
        };
        let (title, key, url) = (bv::log_title(r), r.key(), r.url.clone());
        self.log_gen += 1;
        let gen = self.log_gen;
        let v = self.runs_mut();
        v.log = Some(LogPane {
            title,
            text: None,
            back: 0,
            gen,
        });
        v.detail = Some(bv::DetailPane {
            gen,
            read: None,
            top: 0,
        });
        let rates = self.infra.as_ref().map_or_else(
            || hub_core::run_detail::Rates {
                error: Some("the infra board has not been read yet".into()),
                ..Default::default()
            },
            Infra::rates,
        );
        let (tx, paths, dkey) = (self.tx.clone(), self.files.builds.clone(), key.clone());
        std::thread::spawn(move || {
            let d = builds::detail(&paths, &rates, &dkey, jobs::now());
            let _ = tx.send(Msg::BuildDetail(gen, Box::new(d)));
        });
        let (tx, paths, jobs_paths) = (
            self.tx.clone(),
            self.files.builds.clone(),
            self.paths.clone(),
        );
        std::thread::spawn(move || {
            let text = builds::log(&paths, &jobs_paths, &key, jobs::now()).map_err(|e| {
                if url.is_empty() {
                    e
                } else {
                    format!("{e}; o opens the run in the browser")
                }
            });
            let _ = tx.send(Msg::Log(gen, text));
        });
    }

    /// A runs table's keys while it has them: Enter reads the run's log, `o` opens its page.
    fn builds_key(&mut self, k: KeyEvent) -> bool {
        if self.runs_mut().table.key::<hub_core::builds::Run>(k.code) != Took::No {
            return true;
        }
        let rows = self
            .builds
            .as_ref()
            .map_or(0, |b| self.runs().shown(b).len());
        let n = self.page.max(1);
        let bv = self.runs_mut();
        match k.code {
            c @ (KeyCode::PageDown | KeyCode::PageUp | KeyCode::Char('J' | 'K'))
                if bv.log.as_mut().is_some_and(|l| l.scroll(c, n)) => {}
            KeyCode::Char(c @ ('[' | ']')) if bv.detail.is_some() => {
                if let Some(d) = bv.detail.as_mut() {
                    d.top = if c == ']' {
                        d.top + n
                    } else {
                        d.top.saturating_sub(n)
                    };
                }
            }
            KeyCode::Enter => self.open_build_log(),
            KeyCode::Esc => {
                if bv.log.is_some() {
                    bv.log = None;
                    bv.detail = None;
                } else {
                    bv.table.clear();
                }
            }
            KeyCode::Char('o') => {
                if let Some(u) = self
                    .selected_build()
                    .map(|r| r.url.clone())
                    .filter(|u| !u.is_empty())
                {
                    open(&u);
                }
            }
            _ => return bv.table.moves(k, rows, n),
        }
        true
    }

    /// The Releases keys: Left/Right switch the inner tab, whose own table takes the rest; on
    /// Apps, Enter opens the app's pane, `F` folds its other envs (open at first), `[` and `]` read an older or
    /// newer tag's changelog in it.
    fn releases_key(&mut self, k: KeyEvent) -> bool {
        let typing = self.rv.runs.table.typing.is_some() || self.rv.table.typing.is_some();
        let on = self.rv.on();
        // Left and Right switch the inner tabs (Apps, Release runs).
        if !typing && matches!(k.code, KeyCode::Left | KeyCode::Right) {
            let to = crate::innertabs::step(releases::tab(), on, k.code == KeyCode::Left);
            self.rv.show(to);
            return true;
        }
        if on == "runs" {
            return self.builds_key(k);
        }
        if self.rv.table.key::<ReleaseApp>(k.code) != Took::No {
            self.sync_changelog();
            return true;
        }
        let by = match k.code {
            KeyCode::Char('[') => 1,
            KeyCode::Char(']') => -1,
            _ => 0,
        };
        if by != 0 && self.rv.open {
            if let Some(tag) = self.rv.pick(by) {
                self.rv.down = 0;
                self.read_changelog(Some(tag));
            }
            return true;
        }
        let rows = self.releases.as_ref().map_or(0, |s| self.rv.shown(s).len());
        let before = self.rv.table.sel;
        let rv = &mut self.rv;
        match k.code {
            KeyCode::Char('J') if rv.open => rv.down += 1,
            KeyCode::Char('K') if rv.open => rv.down = rv.down.saturating_sub(1),
            KeyCode::Char('F') if rv.open => rv.others = !rv.others,
            KeyCode::Enter => {
                rv.open = !rv.open;
                rv.others = true;
                // Opening asks for the newest release again, whatever was read before.
                rv.cl.project.clear();
            }
            KeyCode::Esc => {
                if rv.open {
                    rv.open = false;
                } else {
                    rv.table.clear();
                }
            }
            _ if rv.table.moves(k, rows, self.page) => {}
            _ => return false,
        }
        if self.rv.table.sel != before {
            self.rv.down = 0;
        }
        self.sync_changelog();
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
        if self.tab == Tab::Infra && self.infra_open == Some(Opened::Jobs) {
            self.draw_jobs(f, body);
        } else if self.tab == Tab::Infra && self.infra_open == Some(Opened::Runs) {
            self.draw_runs(f, body, "Runs");
        } else if self.tab == Tab::Schedules {
            self.draw_schedules(f, body);
        } else if self.tab == Tab::Releases {
            self.draw_releases(f, body);
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
            // The selected row (Alerts, Infra) is kept in view after a key moved it, and is no
            // section for n/N.
            let mut sections = sections;
            let pick = match self.tab {
                Tab::Home => Some((crate::datatable::ROW, &mut self.hv.follow)),
                Tab::Alerts => Some((crate::datatable::ROW, &mut self.av.follow)),
                Tab::Infra => Some((crate::datatable::ROW, &mut self.itab.follow)),
                _ => None,
            };
            if let Some((row, follow)) = pick {
                if let Some(i) = sections.iter().position(|s| s.0 == row) {
                    let (_, at) = sections.remove(i);
                    let h = (body.height as usize).max(1);
                    if std::mem::take(follow) {
                        if at < self.scroll {
                            self.scroll = at.saturating_sub(2);
                        } else if at >= self.scroll + h {
                            self.scroll = (at + 1 - h).min(max);
                        }
                    }
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
        let full: usize = Tab::SHOWN.iter().map(|t| t.title().len() + 4).sum();
        let tight = " HUB ".len() + full > w;
        for t in Tab::SHOWN.iter() {
            // A tab with no digit shows its title alone.
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
        let tabs = "0-9";
        let runs = self.infra_open == Some(Opened::Runs);
        match self.tab {
            Tab::Home if self.hv.typing() || self.prv.table.typing.is_some() => {
                "type a query (word, key:value, -key:value), Enter applies, Esc cancels".into()
            }
            Tab::Home if self.prv.open => format!(
                "a accept  d reject  Enter record  / query  f state  s sort  S asc/desc  x clear  Esc back  r refresh  {tabs} tabs  q quit"
            ),
            Tab::Alerts if self.av.table.typing.is_some() => QUERY_HINT.into(),
            Tab::Alerts if self.av.on() == "firing" => format!(
                "<-/-> view  j/k move  Enter open  o fix PR  i its item  w ok watches  / query  f state  s sort  S asc/desc  x clear  r refresh  {tabs} tabs  q quit"
            ),
            Tab::Alerts => format!(
                "<-/-> view  j/k PgUp/PgDn scroll  w ok watches  r refresh  {tabs} tabs  q quit"
            ),
            Tab::Infra if self.infra_page.is_some() && self.infra_open != Some(Opened::Jobs) => format!(
                "Esc {}  o Grafana  <-/-> view  j/k PgUp/PgDn ^d/^u scroll  r refresh  {tabs} tabs  q quit",
                self.infra_page.as_ref().map_or(String::new(), InfraPage::back)
            ),
            Tab::Infra if runs && self.ci.table.typing.is_some() => QUERY_HINT.into(),
            Tab::Infra if runs && self.ci.log.is_some() => {
                "Esc close  [ ] scroll jobs  J/K PgUp/PgDn scroll log  j/k move  o open run  q quit".into()
            }
            Tab::Infra if runs => format!(
                "Enter log  / query  f state  s sort  S asc/desc  x clear  o open run  Esc back  r refresh  {tabs} tabs  q quit"
            ),
            Tab::Infra if self.infra_open.is_none() && self.infra_inner == "runs" => format!(
                "<-/-> view  Enter runs table  j/k PgUp/PgDn ^d/^u scroll  r refresh  o Grafana  {tabs} tabs  q quit"
            ),
            Tab::Infra
                if self.infra_open.is_none()
                    && self.infra_inner == "pipelines"
                    && self.plv.table.typing.is_some() =>
            {
                QUERY_HINT.into()
            }
            Tab::Infra if self.infra_open.is_none() && self.infra_inner == "pipelines" => format!(
                "<-/-> view  j/k pick  Enter detail  / query  f state  s sort  S asc/desc  x clear  Esc close  PgUp/PgDn ^d/^u scroll  r refresh  {tabs} tabs  q quit"
            ),
            Tab::Infra
                if self.infra_open != Some(Opened::Jobs)
                    && crate::infratables::InfraTables::picks(self.infra_inner) =>
            {
                format!(
                    "<-/-> view  n/N section  j/k pick  Enter open  / f s S x table  c next table  PgUp/PgDn ^d/^u scroll  r refresh  o Grafana  {tabs} tabs  q quit"
                )
            }
            Tab::Infra if self.infra_open != Some(Opened::Jobs) => format!(
                "<-/-> view  n/N section  Enter jobs table  j/k PgUp/PgDn ^d/^u scroll  r refresh  o Grafana  {tabs} tabs  q quit"
            ),
            Tab::Infra if self.jv.table.typing.is_some() => QUERY_HINT.into(),
            Tab::Log
                if (self.log_actions && self.actions_table.typing.is_some())
                    || (self.log_work && self.work_table.typing.is_some()) =>
            {
                QUERY_HINT.into()
            }
            Tab::Log if self.log_work => format!(
                "/ query  f state  s sort  S asc/desc  x clear  d window  Esc back  j/k PgUp/PgDn ^d/^u scroll  {tabs} tabs  q quit"
            ),
            Tab::Log if self.log_actions => format!(
                "/ query  f state  s sort  S asc/desc  x clear  Esc back  j/k PgUp/PgDn ^d/^u scroll  {tabs} tabs  q quit"
            ),
            Tab::Infra if self.jv.log.is_some() => {
                "Esc close log  J/K PgUp/PgDn scroll log  j/k move  o open url  q quit".into()
            }
            Tab::Infra => format!(
                "Enter log  / query  f state  s sort  S asc/desc  x clear  h history  o open url  Esc back  r refresh  {tabs} tabs  q quit"
            ),
            Tab::Releases if self.rv.table.typing.is_some() || self.rv.runs.table.typing.is_some() => QUERY_HINT.into(),
            Tab::Releases if self.rv.on() == "runs" && self.rv.runs.log.is_some() => {
                "Esc close  [ ] scroll jobs  J/K PgUp/PgDn scroll log  j/k move  o open run  <-/-> view  q quit".into()
            }
            Tab::Releases if self.rv.on() == "runs" => format!(
                "<-/-> view  Enter log  / query  f state  s sort  S asc/desc  x clear  o open run  r refresh  {tabs} tabs  q quit"
            ),
            Tab::Releases if self.rv.open => {
                "Esc close  F other envs  J/K scroll pane  [ ] older/newer tag  j/k move  <-/-> view  q quit".into()
            },
            Tab::Releases => format!(
                "<-/-> view  Enter open  / query  f state  s sort  S asc/desc  x clear  r refresh  {tabs} tabs  q quit"
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
            Tab::Costs if self.cv.typing.is_some() => {
                "type a query (word, key:value, -key:value), Enter applies, Esc cancels".into()
            }
            Tab::Costs => format!(
                "<-/-> view  b/B cut  w window  / query  s sort  S asc/desc  K keys  y spend  u tokens  U day/7d  l langfuse  e sections  t/T sort them  x clear  o Grafana  j/k PgUp/PgDn scroll  r refresh  {tabs} tabs  q quit"
            ),
            Tab::Fleet if self.fleet_table.typing.is_some() => {
                "type a query (kind:session state:failed -who:x), Enter applies, Esc drops it".into()
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
            // Each inner tab's own keys only where they act: the day's on Day, a table's on
            // Work and Actions, the verdict filter on Judges.
            Tab::Log => format!(
                "<-/-> view  {}h days  {}W work  A actions  a c s v w f go to  {}n/N section  j/k PgUp/PgDn ^d/^u scroll  r refresh  {tabs} tabs  q quit",
                match (self.log_shows("day"), self.day.is_some()) {
                    (true, true) => "[ ] day  t today  ",
                    (true, false) => "[ ] day  ",
                    _ => "",
                },
                if self.log_shows("work") || self.log_shows("actions") { "Enter table  " } else { "" },
                if self.log_shows("verdicts") { "V verdict filter  " } else { "" },
            ),
            Tab::Queue if self.qv.confirm.is_some() => "y/Enter yes  n/Esc no".into(),
            Tab::Queue if self.qv.table.typing.is_some() => {
                "type a query (word, key:value, -key:value), Enter applies, Esc cancels".into()
            }
            Tab::Queue if self.qv.detail => format!(
                "j/k another row  l link, Enter opens it  c cancel  +/- priority  Esc close  o Grafana  r refresh  {tabs} tabs  q quit"
            ),
            Tab::Queue => format!(
                "j/k PgUp/PgDn ^d/^u pick  Enter detail  [ ] step  {{ }} problem  / f s S x table  c cancel  +/- priority  C candidates  p promote  o Grafana  r refresh  {tabs} tabs  q quit"
            ),
            Tab::Projects
                if self.tv.typing()
                    || self.pv.table.typing.is_some()
                    || self.pv.dv.typing.is_some()
                    || self.pv.bv.typing.is_some() =>
            {
                "type, Enter submits, Esc cancels".into()
            }
            Tab::Projects if self.pv.dfocus && !self.pv.open => format!(
                "j/k pick  Enter open the epic's project  / search  f chip  s sort  S flip  x clear  d/Esc back to projects  r refresh  {tabs} tabs  q quit"
            ),
            Tab::Projects if self.pv.open && !self.pv.rows_shown(&self.tv) => format!(
                "<- -> inner tabs  {}r refresh  {tabs} tabs  q quit",
                match self.pv.inner {
                    "overview" => "j/k pick a system  Enter its epics  F lists Needs you  Esc back  ",
                    "build" => "j/k pick  Enter the epic's rows  / search  f chip  s sort  S flip  x clear  Esc clear, back  ",
                    _ => "j/k scroll  Esc back  ",
                }
            ),
            Tab::Projects if self.pv.open => format!(
                "j/k pick  / search  f chip  c sort  S flip  {}a add  s start  d done  D unverified  x drop  X dup  m move  e edit  t/T tag  +/- release  o open  Esc clear, back  r refresh  {tabs} tabs  q quit",
                if self.tv.project.is_some() { "<- -> inner tabs  " } else { "" }
            ),
            Tab::Projects => format!(
                "j/k pick  Enter open  a all rows  d deliverables  / search  f chip  s sort  S flip  x clear  P priority  r refresh  {tabs} tabs  q quit"
            ),
            Tab::Home if self.hv.on_running && !self.home_build().running.is_empty() => format!(
                "Running: j/k pick  Enter open  / query  f state  s/S sort  x clear  Esc/Tab Needs you  u w n e m b flow  F fix  {tabs} pages  r refresh  q quit"
            ),
            Tab::Home => format!(
                "/ query  f state  s/S sort  x clear  Tab Running  u w n e m b flow  F fix  {}{tabs} pages  j/k scroll  r refresh  o Grafana  q quit",
                if open_rows(&self.proposals).is_empty() { "" } else { "Enter proposals  " }
            ),
        }
    }

    /// The selected row in full, when one project's rows (or All) are open on Projects.
    fn preview(&self, w: usize) -> Option<Vec<Line<'static>>> {
        if self.tab != Tab::Projects || !self.pv.open || !self.pv.rows_shown(&self.tv) {
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
        out.push(crate::fit::clip_line(
            Line::styled(
                format!(
                    "  {} rows; Enter opens the table (/ search, s source, f state, h history, Enter log)",
                    rows
                ),
                self.p.dim(),
            ),
            w,
        ));
        out
    }

    /// Infra's sections needing a look, for the strip's counts: the CI lines `hub_core::ci`
    /// judged red (a queued job no online runner can take) and a red run of the last day. The
    /// TUI reads no tests run, so Tests carries no count here.
    fn infra_flagged(&self, i: Option<&hub_core::infra::Infra>) -> Vec<&'static str> {
        let mut out = vec![];
        if i.is_some_and(|i| !i.ci.red.is_empty()) {
            out.push("ci");
        }
        if self.pipes.as_ref().is_some_and(|p| p.red > 0) {
            out.push("pipelines");
        }
        if self
            .builds
            .as_ref()
            .is_some_and(|b| b.needs_look(Scope::All))
        {
            out.push("runs");
        }
        out
    }

    /// Infra's CI Runs section: the runs line and the first rows; Enter opens the whole table.
    fn runs_section(&self, w: usize) -> Vec<Line<'static>> {
        let Some(b) = &self.builds else {
            return vec![
                Line::styled("RUNS", self.p.head()),
                Line::styled("Reading runs...", self.p.dim()),
            ];
        };
        let now = jobs::now();
        let mut out = self.ci.status("RUNS", b, self.p, now);
        let (table, rows) = self.ci.preview(b, JOBS_SHOWN, self.p, w, now);
        out.extend(table);
        out.push(crate::fit::clip_line(
            Line::styled(
                format!("  {rows} rows; Enter opens the table (/ search, f state, Enter log)"),
                self.p.dim(),
            ),
            w,
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
            (Tab::Home, _, i) => {
                let mut home = self.home_build();
                match &self.proposals {
                    Some(open) => home.set_proposals(open),
                    None => home.proposals_unread = true,
                }
                if let Some(r) = &self.pipeline {
                    home.set_pipeline(r);
                }
                let night = hometab::NightView {
                    night: self.night.as_ref(),
                    fixes: &self.fixes,
                };
                let graph = i.as_ref().is_some_and(|i| i.grafana.is_some());
                let flow = (self.pipeline.is_none(), graph);
                let (l, sel) = hometab::page(&home, &self.hv, &night, self.p, now, w, flow);
                (
                    l,
                    sel.map_or(vec![], |at| vec![(crate::datatable::ROW, at)]),
                )
            }
            (Tab::Projects, ..) if !self.pv.open => match &self.projects {
                None => reading("notes projects"),
                Some(_) => {
                    let feed = match &self.tasks {
                        Some(Ok(f)) => Some(f),
                        _ => None,
                    };
                    let (l, at) = projtab::page(
                        &self.cards(),
                        feed,
                        self.deliverables.as_ref(),
                        &self.pv,
                        self.p,
                        w,
                    );
                    (l, at.map(|a| ("", a)).into_iter().collect())
                }
            },
            // One project's card stays on top of its rows; All has none. Only Rows reads the
            // board, so the other inner tabs draw while it is read or failed.
            (Tab::Projects, ..) => {
                let mut l = vec![];
                if let Some((profile, name)) = &self.tv.project {
                    let cards = self.cards().cards;
                    if let Some(c) = cards
                        .iter()
                        .find(|c| c.profile == *profile && c.name == *name)
                    {
                        let pg = self.proj_page.as_ref().filter(|pg| pg.project == c.name);
                        let (page, at) = projtab::open_lines(c, pg, &self.pv, self.p, w);
                        if !self.pv.rows_shown(&self.tv) {
                            return (page, at.map(|a| ("", a)).into_iter().collect());
                        }
                        l = page;
                    }
                }
                match &self.tasks {
                    None => {
                        l.extend(reading("notes board").0);
                        (l, vec![])
                    }
                    Some(Err(e)) => {
                        l.push(Line::styled(e.clone(), self.p.warn()));
                        (l, vec![])
                    }
                    Some(Ok(f)) => {
                        let top = l.len();
                        let (rows, at) = tasktab::page(f, &self.tv, self.p, w);
                        l.extend(rows);
                        (l, at.map(|a| ("", a + top)).into_iter().collect())
                    }
                }
            }
            (Tab::Queue, ..) => match &self.queue {
                None => reading("agent-queue"),
                Some(q) => {
                    let rail = hub_core::flow::Rail::build(Some(q), self.pipeline.as_ref(), now);
                    let (l, at) = queuetab::page(
                        q,
                        &self.qv,
                        self.candidates.as_ref(),
                        (
                            &rail,
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
                    Some(b) => fleet::page(&b.watch, table, self.p, now),
                };
                // From the status line, two above, so an armed action's confirm stays on screen.
                let at = self.controls.open.then(|| {
                    l.iter().position(|x| {
                        crate::fit::plain(x).starts_with(crate::controls::DETAIL_HEAD)
                    })
                });
                let at = at.flatten().map(|at| (DETAIL, at.saturating_sub(2)));
                (l, at.into_iter().collect())
            }
            // Every dollar, cut eight ways (coststab.rs, the same board agent-web draws).
            (Tab::Costs, ..) => match &self.costs {
                None => reading("the costs"),
                Some(c) => self.cv.lines(c, self.p, now, w),
            },
            // Who is working: runners by tier, then the live sessions.
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
                    fleettab::page(f, &self.fleet_table, &self.fleet_folded, self.p, now, w),
                    vec![("workers", 0)],
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
            // A failed Prometheus read is the join's own error line, so only the first read waits.
            (Tab::Alerts, _, _) => match &self.alerts {
                Some(a) => self.av.page(a, self.p, now, w),
                None => reading("Prometheus and fleet-bench reds"),
            },
            // A machine's or a pool's page in place of the Machines tables, under the strip.
            (Tab::Infra, ..)
                if self.infra_page.is_some() && self.infra_open != Some(Opened::Jobs) =>
            {
                let strip = crate::innertabs::strip(
                    infra_tab(),
                    self.infra_inner,
                    &self.infra_flagged(self.infra.as_ref()),
                    self.p,
                    w,
                );
                let mut l = vec![strip];
                if let Some(page) = &self.infra_page {
                    l.extend(page.lines(self.p, now, w));
                }
                (l, vec![])
            }
            // Infra: the strip first, while Prometheus is read too, then the inner tab shown, each section in hub_core::layout order with a blank line
            // between them.
            (_, _, None) => {
                let tab = infra_tab();
                let strip = crate::innertabs::strip(
                    tab,
                    self.infra_inner,
                    &self.infra_flagged(None),
                    self.p,
                    w,
                );
                let (mut l, at) = reading("Prometheus");
                l.insert(0, strip);
                (l, at)
            }
            (_, _, Some(i)) => {
                let tab = infra_tab();
                let shown = if self.infra_all {
                    tab.sections
                } else {
                    hub_core::layout::inner_tab(tab, Some(self.infra_inner))
                        .map_or(&[][..], |i| i.sections)
                };
                let failed = self.builds.as_ref().map(|b| b.counts.recent_red);
                let mut secs =
                    board::infra(i, self.p, now, w, &self.itab, self.infra_inner, failed);
                // Jobs is read on its own, and built only on the inner tab that shows it: the
                // jobs table walks every job in the window on each draw.
                if shown.contains(&"jobs") {
                    secs.push(("jobs", self.jobs_section(w)));
                }
                if shown.contains(&"runs") {
                    secs.push(("runs", self.runs_section(w)));
                }
                if shown.contains(&"pipelines") {
                    let on = self.infra_inner == "pipelines";
                    let mut l = self.plv.lines(self.pipes.as_ref(), self.p, w);
                    // The selection is drawn only where the keys are.
                    if !on {
                        for x in &mut l {
                            if x.style == self.p.sel() {
                                x.style = ratatui::style::Style::default();
                            }
                        }
                    }
                    secs.push(("pipelines", l));
                }
                if shown.contains(&"tests") {
                    let mut tests = bv::tests_note(self.p, w);
                    if let Some(b) = &self.builds {
                        tests.extend(bv::quarantine(b, self.p, w, JOBS_SHOWN));
                    }
                    secs.push(("tests", tests));
                }
                let strip = crate::innertabs::strip(
                    tab,
                    self.infra_inner,
                    &self.infra_flagged(Some(i)),
                    self.p,
                    w,
                );
                let (mut l, mut at) = (vec![strip], vec![]);
                let mut put = |name: &'static str, l: &mut Vec<Line<'static>>| {
                    if let Some((_, lines)) = secs.iter_mut().find(|s| s.0 == name) {
                        if l.len() > 1 {
                            l.push(Line::raw(""));
                        }
                        at.push((name, l.len()));
                        l.append(lines);
                    }
                };
                for name in shown {
                    put(name, &mut l);
                }
                // The selected row of the table with the keys, kept in view after a key moves it.
                if let Some(r) = l.iter().position(|x| x.style == self.p.sel()) {
                    at.push((crate::datatable::ROW, r));
                }
                (l, at)
            }
        };
        (lines, sections)
    }

    /// Log's Work table under its heading: a past day in the stepper is its window, as on the web,
    /// and `d` picks among the rest. The whole list only while it has the keys.
    fn work_lines(&self, w: usize) -> Vec<Line<'static>> {
        let asked = self
            .day
            .as_deref()
            .unwrap_or(logtab::WORK_WINDOWS[self.work_window]);
        let keys = if self.log_work {
            "d window, Esc back"
        } else {
            "W filters it"
        };
        let title = format!(
            "WORK ({})  {keys}",
            if asked.is_empty() { "7d" } else { asked }
        );
        let mut l = vec![crate::fit::clip_line(Line::styled(title, self.p.head()), w)];
        let Some(g) = &self.work else {
            l.push(Line::styled("  Reading the work...", self.p.dim()));
            return l;
        };
        let today = chrono::Local::now().date_naive();
        let cap = if self.log_work {
            hub_core::worklog::SHOWN
        } else {
            hub_core::layout::FOLD_ROWS
        };
        let day = today.format("%Y-%m-%d").to_string();
        let window = hub_core::worklog::Window::parse(asked, today);
        l.extend(logtab::work(
            g,
            &window,
            &self.work_table,
            cap,
            &day,
            self.p,
            w,
        ));
        l
    }

    /// Log: the inner tab strip, then the shown inner tab's sections in layout order (Work, the
    /// day and its history, or a `FOLDS` section, a heading with its count when it is known and
    /// its rows); the section names are hub_core::layout's.
    fn log_page(
        &self,
        b: &Boards,
        now: i64,
        w: usize,
    ) -> (Vec<Line<'static>>, Vec<(&'static str, usize)>) {
        let head = |t: String| crate::fit::clip_line(Line::styled(t, self.p.head()), w);
        let mut l = vec![crate::innertabs::strip(
            log_tab(),
            self.log_inner,
            &[],
            self.p,
            w,
        )];
        let mut at: Vec<(&'static str, usize)> = vec![];
        let shown = hub_core::layout::inner_tab(log_tab(), Some(self.log_inner));
        for name in shown.map_or(&[][..], |i| i.sections) {
            l.push(Line::raw(""));
            at.push((name, l.len()));
            match *name {
                "work" => l.extend(self.work_lines(w)),
                "day" => {
                    let base = l.len();
                    let pg = day::today(b.rec.as_ref(), self.p, now, w);
                    at.extend(
                        pg.sections
                            .into_iter()
                            .filter(|s| *s > 0)
                            .map(|s| ("", s + base)),
                    );
                    l.extend(pg.lines);
                }
                "history" => l.push(head(format!(
                    "HISTORY ({})  h lists the days",
                    b.hist.len()
                ))),
                _ => l.extend(self.log_fold(name, b, now, w)),
            }
        }
        (l, at)
    }

    /// One of Log's `FOLDS` sections: its heading, with its count when it is known, and its rows.
    fn log_fold(&self, name: &str, b: &Boards, now: i64, w: usize) -> Vec<Line<'static>> {
        let Some(&(_, _, title)) = FOLDS.iter().find(|f| f.0 == name) else {
            return vec![];
        };
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
        let keys = match name {
            "actions" => "  Enter filters",
            "verdicts" => "  V filters",
            _ => "",
        };
        let mut l = vec![crate::fit::clip_line(
            Line::styled(format!("{title}{count}{keys}"), self.p.head()),
            w,
        )];
        let reading = |what: &str| vec![Line::styled(format!("  Reading {what}..."), self.p.dim())];
        l.extend(match name {
            "actions" => match &self.actions {
                None => reading("the actions"),
                Some(g) => logtab::actions(g, &self.actions_table, self.p, now, w),
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
        l
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
        let mut lines = status;
        lines.extend(self.sv.table.window(table, h));
        f.render_widget(Paragraph::new(lines), list);
        let row = self.sv.shown(s).get(self.sv.table.sel).copied();
        if let (Some(area), Some(r)) = (pane, row) {
            let lines = schedules::detail(r, self.p, s.at, area.width as usize);
            let max = lines.len().saturating_sub(area.height as usize);
            self.sv.down = self.sv.down.min(max);
            let shown: Vec<Line> = lines.into_iter().skip(self.sv.down).collect();
            f.render_widget(Paragraph::new(shown), area);
        }
    }

    fn draw_releases(&mut self, f: &mut Frame, area: Rect) {
        let Some(s) = &self.releases else {
            f.render_widget(
                Paragraph::new(Line::styled("Reading releases...", self.p.dim())),
                area,
            );
            return;
        };
        let on = self.rv.on();
        let w = area.width as usize;
        let flagged = releases::flagged(s, self.builds.as_ref());
        let strip = crate::innertabs::strip(releases::tab(), on, &flagged, self.p, w);
        if on == "runs" {
            let [top, rest] =
                Layout::vertical([Constraint::Length(1), Constraint::Min(0)]).areas(area);
            f.render_widget(Paragraph::new(strip), top);
            self.draw_runs(f, rest, "Release runs");
            return;
        }
        // The strip, then the apps, with the app's pane under them when it is open.
        let (list, pane) = if self.rv.open {
            let [a, b] = Layout::vertical([Constraint::Percentage(50), Constraint::Percentage(50)])
                .areas(area);
            (a, Some(b))
        } else {
            (area, None)
        };
        let now = jobs::now();
        let mut lines = vec![strip];
        let head = self.rv.status(s, self.p, now);
        let table = self.rv.table(s, self.p, w, true);
        // The rows under the table's header line.
        let h = (list.height as usize)
            .saturating_sub(lines.len() + head.len() + 1)
            .max(1);
        self.page = h.saturating_sub(1).max(1);
        lines.extend(head);
        lines.extend(self.rv.table.window(table, h));
        f.render_widget(Paragraph::new(lines), list);
        let Some(area) = pane else { return };
        if let Some(r) = self.rv.shown(s).get(self.rv.table.sel).copied() {
            let cl = self
                .rv
                .cl
                .read
                .as_ref()
                .filter(|_| self.rv.cl.project == r.project);
            let st = self
                .rv
                .st
                .read
                .as_ref()
                .filter(|_| self.rv.st.project == r.project);
            let lines =
                releases::detail(r, self.rv.others, self.p, now, area.width as usize, cl, st);
            let max = lines.len().saturating_sub(area.height as usize);
            self.rv.down = self.rv.down.min(max);
            let shown: Vec<Line> = lines.into_iter().skip(self.rv.down).collect();
            f.render_widget(Paragraph::new(shown), area);
        }
    }

    /// The tab's runs table (`runs`) under its `title`, with the opened run's detail and log in a
    /// pane under it.
    fn draw_runs(&mut self, f: &mut Frame, area: Rect, title: &str) {
        let infra = self.tab == Tab::Infra;
        let v = if infra {
            &mut self.ci
        } else {
            &mut self.rv.runs
        };
        let b = self.builds.as_ref();
        let Some(b) = b else {
            f.render_widget(
                Paragraph::new(Line::styled("Reading runs...", self.p.dim())),
                area,
            );
            return;
        };
        let pane = v.log.is_some();
        let (list, pane) = if pane {
            let [a, b] = Layout::vertical([Constraint::Percentage(50), Constraint::Percentage(50)])
                .areas(area);
            (a, Some(b))
        } else {
            (area, None)
        };
        let now = jobs::now();
        let w = list.width as usize;
        let head = v.status(title, b, self.p, now);
        let table = v.table(b, self.p, w, true, now);
        let h = (list.height as usize).saturating_sub(head.len() + 1).max(1);
        self.page = h.saturating_sub(1).max(1);
        let mut lines = head;
        lines.extend(v.table.window(table, h));
        f.render_widget(Paragraph::new(lines), list);
        let Some(area) = pane else { return };
        let (w, h) = (area.width as usize, area.height as usize);
        // The run's detail on top, as tall as it is up to all but the log's few lines.
        let mut rest = area;
        if let Some(d) = &mut v.detail {
            let lines = bv::detail_pane(d, self.p, w, h.saturating_sub(BUILD_LOG_MIN));
            let [top, bottom] =
                Layout::vertical([Constraint::Length(lines.len() as u16), Constraint::Min(0)])
                    .areas(area);
            f.render_widget(Paragraph::new(lines), top);
            rest = bottom;
        }
        if let Some(l) = &mut v.log {
            let lines = log_lines(l, rest.width as usize, rest.height as usize, self.p);
            f.render_widget(Paragraph::new(lines), rest);
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
        self.page = h;
        lines.extend(self.prv.table.window(table, h));
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
        let mut lines = status;
        lines.extend(self.jv.table.window(table, h));
        f.render_widget(Paragraph::new(lines), list);
        if let (Some(area), Some(l)) = (log, &mut self.jv.log) {
            let lines = log_lines(l, area.width as usize, area.height as usize, self.p);
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
            // Every other reader takes empty output as nothing found; JSON has no empty document.
            let release_state = argv.first().is_some_and(|c| c == "release-state");
            Ok(if release_state { "{}" } else { "" }.to_string())
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
        assert!(
            !ran.contains("fleet-dispatch headroom"),
            "the header reads headroom.json: {ran}"
        );
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
                10,
                jobs::now()
            ),
            queuetab::Ask::Pass
        );
        // With no Grafana known nothing opens and nothing is spawned.
        a.handle(key('o'));
        assert!(!a.quit);
    }

    #[test]
    fn a_queue_request_opens_the_table_on_the_chip_an_old_section_id_names() {
        let mut a = app(Tab::Queue);
        a.handle(Msg::Queue(Box::new(queuetab::tests::fixture())));
        a.open_query(Some("waiting".into()));
        assert_eq!(a.qv.table.view.state, "needs you");
        let s = screen(&mut a, 140, 30);
        assert!(
            s.contains("Pick a side") && !s.contains("Fix the menu"),
            "{s}"
        );
        // Any other word is the query, from the table's own view.
        a.open_query(Some("project:dotfiles".into()));
        assert_eq!(
            (a.qv.table.view.state.as_str(), a.qv.table.view.q.as_str()),
            ("", "project:dotfiles")
        );
        let s = screen(&mut a, 140, 30);
        assert!(s.contains("Next") && !s.contains("Pick a side"), "{s}");
        // No query leaves the view as it is.
        a.open_query(None);
        assert_eq!(a.qv.table.view.q, "project:dotfiles");
    }

    #[test]
    fn typing_a_queue_query_keeps_every_key_for_the_query_and_the_footer_says_so() {
        let esc = || Msg::Input(Event::Key(KeyEvent::from(KeyCode::Esc)));
        let mut a = app(Tab::Queue);
        a.handle(Msg::Queue(Box::new(queuetab::tests::fixture())));
        a.handle(key('/'));
        a.handle(key('3'));
        a.handle(key('q'));
        a.handle(key('g'));
        assert!(a.qv.table.typing.as_deref() == Some("3qg") && a.tab == Tab::Queue && !a.quit);
        let s = screen(&mut a, 140, 30);
        assert!(
            s.lines()
                .last()
                .unwrap()
                .contains("Enter applies, Esc cancels"),
            "{s}"
        );
        a.handle(esc());
        assert!(a.qv.table.typing.is_none() && !a.quit);
        // Enter opens the selected row's detail, Esc closes it.
        a.handle(Msg::Input(Event::Key(KeyEvent::from(KeyCode::Enter))));
        let s = screen(&mut a, 140, 40);
        assert!(
            s.contains("log: notes log --item pick-sides") && s.contains("timeline"),
            "{s}"
        );
        a.handle(esc());
        assert!(!a.qv.detail && !a.quit);
    }

    #[test]
    fn the_queue_tab_leads_with_the_line_and_its_keys_walk_it() {
        let mut a = app(Tab::Queue);
        a.handle(Msg::Queue(Box::new(queuetab::tests::fixture())));
        let top = |a: &mut App| {
            a.page_lines(100)
                .iter()
                .take(5)
                .map(|l| l.to_string())
                .collect::<Vec<_>>()
        };
        let t = top(&mut a);
        assert!(t[0].starts_with("PIPELINE  reading"), "{t:?}");
        assert!(t[1].starts_with("INBOX -> board -> up next"), "{t:?}");
        a.handle(Msg::Pipeline(Ok(None)));
        let t = top(&mut a);
        assert!(t[1].contains("no snapshot"), "{t:?}");
        press(&mut a, KeyCode::Char(']'));
        let t = top(&mut a);
        assert!(t[2].starts_with("inbox -> BOARD"), "{t:?}");
    }

    #[test]
    fn a_flow_chip_key_on_home_opens_the_queue_on_its_filter() {
        let mut a = app(Tab::Home);
        a.handle(Msg::Queue(Box::new(queuetab::tests::fixture())));
        a.handle(key('w'));
        assert_eq!(a.tab, Tab::Queue);
        assert_eq!(a.qv.table.view.state, "running");
        a.handle(key('1'));
        a.handle(key('b'));
        assert_eq!(a.tab, Tab::Projects);
        // Negative control: a key that is not a chip leaves Home where it is.
        a.handle(key('1'));
        a.handle(key('x'));
        assert_eq!(a.tab, Tab::Home);
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
        assert!(!screen(&mut a, 80, 20).contains("Task 30"));
        for _ in 0..30 {
            a.handle(key('j'));
        }
        let s = screen(&mut a, 80, 20);
        assert_eq!(a.qv.table.sel, 30);
        assert!(a.scroll > 0, "the page scrolled with the selection");
        assert!(s.contains("Task 30"), "the selected row is on screen:\n{s}");
        a.handle(key('k'));
        assert!(screen(&mut a, 80, 20).contains("Task 29"));
    }

    #[test]
    fn g_and_shift_g_jump_the_queue_selection_and_the_page_with_it() {
        let mut a = app(Tab::Queue);
        a.handle(Msg::Queue(Box::new(long_queue(40))));
        screen(&mut a, 80, 20);
        a.handle(key('G'));
        let s = screen(&mut a, 80, 20);
        assert_eq!(a.qv.table.sel, 39);
        assert!(s.contains("Task 39"), "{s}");
        assert!(s.contains("CANDIDATES"), "G reaches the page's end:\n{s}");
        a.handle(key('g'));
        let s = screen(&mut a, 80, 20);
        assert_eq!((a.qv.table.sel, a.scroll), (0, 0));
        assert!(s.contains("Task 0"), "{s}");
        // PgDn and space move the selection a page; the page follows rather than snapping back.
        a.handle(Msg::Input(Event::Key(KeyEvent::from(KeyCode::PageDown))));
        assert_eq!(a.qv.table.sel, a.page);
        let want = format!("Task {}", a.page);
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
        assert_eq!(a.qv.table.sel, half);
        a.handle(ctrl('d'));
        assert_eq!(a.qv.table.sel, 2 * half);
        a.handle(ctrl('u'));
        assert_eq!(a.qv.table.sel, half);
        // NEGATIVE CONTROL: a plain d or u is no move.
        a.handle(key('d'));
        a.handle(key('u'));
        assert_eq!(a.qv.table.sel, half);
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

    #[test]
    fn a_link_opens_the_tab_and_the_word_its_tab_args_name() {
        use hub_core::links::{Kind, Link};
        let mut a = app(Tab::Home);
        a.follow(&Link::to(Kind::Runner, "inbox-triage"));
        assert_eq!(
            (a.tab, a.fleet_page.as_deref()),
            (Tab::Fleet, Some("inbox-triage"))
        );
        a.follow(&Link::to(Kind::Runner, "workers"));
        assert_eq!(
            (a.tab, a.fleet_page.as_deref()),
            (Tab::Fleet, Some("workers")),
            "a runner named like a Fleet section still opens its page"
        );
        a.follow(&Link::to(Kind::Session, "lab/x:1"));
        assert_eq!(a.tab, Tab::Sessions);
        a.follow(&Link::to(Kind::Queue, "the-item"));
        assert_eq!(a.tab, Tab::Queue);
        a.follow(&Link::to(Kind::Row, "ar-1"));
        assert_eq!(a.tab, Tab::Projects, "the Board is the Projects tab's rows");
        a.follow(&Link::to(Kind::CiRun, "4412"));
        assert_eq!(
            (a.tab, a.ci.table.view.q.as_str()),
            (Tab::Infra, "id:=4412")
        );
        assert!(
            a.infra_open == Some(Opened::Runs),
            "a run's record is the runs table at that run"
        );
        a.follow(&Link::to(Kind::PrRuns, "o/r#7"));
        assert_eq!(a.ci.table.view.q, "pr:=o/r#7", "a PR's CI runs");
        assert!(a.infra_open == Some(Opened::Runs) && a.run_want.is_none());
        a.follow(&Link::to(Kind::Job, "agentctl-dream"));
        assert_eq!(a.jv.history.as_deref(), Some("agentctl-dream"));
        assert!(
            a.infra_open == Some(Opened::Jobs) && a.infra_inner == "jobs",
            "a job's page is every run of it"
        );
        a.follow(&Link::tab("nope"));
        assert_eq!(
            a.tab,
            Tab::Infra,
            "a link to no tab leaves the page where it is"
        );
    }

    #[test]
    fn a_run_link_opens_its_record_now_or_once_the_ledger_is_read() {
        use hub_core::links::{Kind, Link};
        let mut a = app(Tab::Home);
        a.files.builds.ledger = "/nonexistent/ci/runs.jsonl".into();
        a.follow(&Link::to(Kind::CiRun, "2"));
        assert!(a.ci.log.is_none(), "no ledger read yet: nothing to open");
        a.handle(Msg::Builds(Box::new(bv::tests::fixture())));
        assert_eq!(a.selected_build().map(|r| r.id), Some(2));
        assert!(
            a.ci.log.is_some() && a.ci.detail.is_some(),
            "the read opens it"
        );
        let page = |id: u64| {
            let b = bv::tests::fixture();
            let r = b.rows.iter().find(|r| r.id == id).unwrap();
            Link::to(Kind::CiRun, format!("{}/{}", r.project(), r.id))
        };
        a.follow(&page(3));
        assert_eq!(a.selected_build().map(|r| r.id), Some(3));
        assert!(
            a.ci.log.is_some(),
            "with the ledger on hand it opens at once"
        );

        // A run the ledger does not have yet waits for the read that brings it.
        let mut a = app(Tab::Home);
        a.files.builds.ledger = "/nonexistent/ci/runs.jsonl".into();
        a.follow(&page(1));
        let mut b = bv::tests::fixture();
        b.rows.retain(|r| r.id != 1);
        a.handle(Msg::Builds(Box::new(b)));
        assert!(a.ci.log.is_none() && a.run_want.is_some());
        a.handle(Msg::Builds(Box::new(bv::tests::fixture())));
        assert_eq!(a.selected_build().map(|r| r.id), Some(1));
        assert!(a.ci.log.is_some() && a.run_want.is_none());

        // NEGATIVE CONTROL: a page left before the read does not open the run there.
        let mut a = app(Tab::Home);
        a.files.builds.ledger = "/nonexistent/ci/runs.jsonl".into();
        a.follow(&Link::to(Kind::CiRun, "2"));
        a.follow(&Link::to(Kind::Queue, "x"));
        a.handle(Msg::Builds(Box::new(bv::tests::fixture())));
        assert!(a.ci.log.is_none() && a.run_want.is_none());
    }

    #[test]
    fn a_session_link_opens_by_its_target_or_its_queue_item() {
        use hub_core::links::{Kind, Link};
        let mut a = app(Tab::Queue);
        a.controls.set(crate::controls::tests::fixture());
        a.follow(&Link::to(Kind::Session, "fix-the-thing"));
        assert_eq!(a.tab, Tab::Sessions);
        assert!(a.controls.open, "the item's session opens");
        let sel = a.controls.rows()[a.controls.table.sel].row.target.clone();
        assert_eq!(sel, "lab/dotfiles-agent-3:2");
        a.controls.open = false;
        a.follow(&Link::to(Kind::Session, "no-such-item"));
        assert!(!a.controls.open, "no row names it: nothing opens");
    }

    fn app(tab: Tab) -> App {
        let (tx, _rx) = std::sync::mpsc::channel();
        with_tx(tab, tx)
    }

    fn with_tx(tab: Tab, tx: Sender<Msg>) -> App {
        let mut a = App::new(tab, tx);
        a.p = Palette { no_color: true };
        a.runner = Arc::new(Fake::default());
        a.gather = no_sessions;
        // No test reaches Prometheus: a read in flight is never started again.
        a.pipeline_read.busy = true;
        a.night_read.busy = true;
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
        assert!(lines[0].contains("4 Sessions"), "{s}");
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
        // HARNESS gives way before YOU and ASK; a wide screen names each row's.
        let wide = screen(&mut a, 220, 30);
        let wl: Vec<&str> = wide.lines().collect();
        assert!(wl[3].contains("ACCOUNT  HARNESS  CLOSE"), "{wide}");
        assert!(wl[4].contains("bnb      claude"), "{wide}");

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
        assert!(!s.contains("CHANGES"), "the changes are Log's: {s}");
        assert!(!s.contains("ASKS ("), "the asks are Home's: {s}");

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
    fn a_scrolled_detail_stays_put_until_a_confirm_is_armed_and_a_close_drops_the_seek() {
        let k = |c| Msg::Input(Event::Key(KeyEvent::from(c)));
        let mut a = app(Tab::Sessions);
        a.controls.set(crate::controls::tests::fixture());
        screen(&mut a, 140, 7);
        a.handle(k(KeyCode::Enter));
        screen(&mut a, 140, 7);
        a.handle(k(KeyCode::PageDown));
        screen(&mut a, 140, 7);
        let read_to = a.scroll;
        a.handle(key('s'));
        screen(&mut a, 140, 7);
        assert_eq!(a.scroll, read_to, "a sort is not a move");
        a.handle(key('x'));
        assert!(screen(&mut a, 140, 7).contains("It will"));
        a.handle(k(KeyCode::Esc));
        a.handle(k(KeyCode::Enter));
        assert!(!a.controls.open);
        a.handle(k(KeyCode::Enter));
        assert_eq!(a.seek, Some(DETAIL), "opened, not drawn yet");
        a.handle(k(KeyCode::Esc));
        assert_eq!(a.seek, None);
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
        use hub_core::links::{Kind, Link};
        let part = |label, text: &str, link: Option<Link>, warn| Part {
            label,
            text: text.into(),
            link,
            warn,
        };
        let page = SessionPage {
            parts: vec![
                part(
                    "Queue item",
                    "the-item (running)",
                    Some(Link::to(Kind::Queue, "the-item")),
                    false,
                ),
                part("Worktree", "~/w  branch feat/x", None, false),
                part(
                    "PR",
                    "#12 open",
                    Some(Link::Url("https://github.com/o/r/pull/12".into())),
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
        a.runner = Arc::new(Fake::default());
        a.forecast = Some(forecast::tests::fixture());
        assert!(
            !screen(&mut a, 200, 160).contains("FORECAST"),
            "Work does not draw it"
        );
        a.handle(key('f'));
        assert_eq!(a.log_inner, "ranked", "f opens the inner tab holding it");
        let s = screen(&mut a, 200, 160);
        assert!(s.contains("FORECAST"), "{s}");
        assert!(s.contains("not draining (in 10.63/h, out 6.88/h)"), "{s}");
        assert!(s.contains("BURN-UP 24h"), "{s}");
        assert!(
            s.find("RANKED SESSIONS") < s.find("FORECAST"),
            "Ranked leads: {s}"
        );
    }

    #[test]
    fn the_ranked_sessions_are_read_only_when_their_inner_tab_opens() {
        let (tx, rx) = std::sync::mpsc::channel();
        let mut a = log_app(tx);
        let fake = Arc::new(Fake::default());
        a.runner = fake.clone();
        let s = screen(&mut a, 200, 80);
        assert!(!s.contains("RANKED SESSIONS"), "{s}");
        assert!(
            fake.0.lock().unwrap().is_empty(),
            "nothing is read while another inner tab shows"
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
        assert!(s.contains("RANKED SESSIONS (1)"), "{s}");
        assert!(s.contains(" 11  6f296b73  dotfiles"), "{s}");
        assert!(s.contains("agentctl-session-outcomes card <id>"), "{s}");
    }

    #[test]
    fn log_is_a_strip_of_inner_tabs_each_drawing_only_its_own_sections() {
        let (tx, _rx) = std::sync::mpsc::channel();
        let mut a = log_app(tx);
        a.runner = Arc::new(Fake::default());
        // Each inner tab in strip order, the headings it draws, and one it must not.
        let pages: [(&str, &[&str], &str); 7] = [
            ("[Work]", &["WORK ("], "HISTORY ("),
            ("[Day]", &["HISTORY (0)  h lists the days"], "WORK ("),
            ("[Actions]", &["ACTIONS  Enter filters"], "CHANGES ("),
            ("[Changes]", &["CHANGES ("], "ACTIONS"),
            ("[Rundowns]", &["RUNDOWNS (0)"], "CHANGES ("),
            ("[Judges]", &["JUDGES' VERDICTS  V filters"], "RUNDOWNS"),
            ("[Ranked]", &["RANKED SESSIONS", "FORECAST"], "JUDGES"),
        ];
        for (open, heads, not) in pages {
            let s = screen(&mut a, 160, 200);
            let first = s.lines().find(|l| !l.trim().is_empty()).unwrap_or("");
            assert!(
                s.contains(open) && s.find(open) < s.find(heads[0]),
                "{open} leads: {s}"
            );
            assert!(
                !first.contains("WORK ("),
                "the strip is the first line: {s}"
            );
            for h in heads {
                assert!(s.contains(h), "{open} lacks {h}: {s}");
            }
            assert!(!s.contains(not), "{open} draws {not}: {s}");
            a.handle(Msg::Input(Event::Key(KeyEvent::from(KeyCode::Right))));
        }
        assert_eq!(a.log_inner, "work", "Right wraps from Ranked to Work");
        a.handle(Msg::Input(Event::Key(KeyEvent::from(KeyCode::Left))));
        assert_eq!(a.log_inner, "ranked", "Left wraps back");
        // h opens the day list on Day, Esc brings the day back.
        a.handle(key('h'));
        assert!(a.log_days && a.log_inner == "day");
        a.handle(Msg::Input(Event::Key(KeyEvent::from(KeyCode::Esc))));
        assert!(!a.log_days);
        // c opens Changes at the section.
        a.handle(key('c'));
        assert_eq!(a.log_inner, "changes");
    }

    #[test]
    fn log_folds_are_the_layout() {
        let log = hub_core::layout::resolve("log").unwrap();
        let mut want = vec!["work", "day", "history"];
        want.extend(FOLDS.iter().map(|f| f.0));
        assert_eq!(log.sections, want.as_slice());
    }

    #[test]
    fn the_days_keys_act_only_on_day() {
        let (tx, _rx) = std::sync::mpsc::channel();
        let mut a = log_app(tx);
        a.runner = Arc::new(Fake::default());
        a.boards.as_mut().unwrap().days = vec!["2026-11-04".into(), "2026-11-05".into()];
        a.scroll = 5;
        for c in ['[', ']', 't'] {
            a.handle(key(c));
        }
        assert_eq!(
            (a.day.as_deref(), a.scroll),
            (None, 5),
            "on Work they move neither the day nor the page"
        );
        assert!(
            !screen(&mut a, 400, 40).contains("[ ] day"),
            "nor are they in the hint"
        );
        a.log_go("day");
        a.handle(key('['));
        assert!(a.day.is_some(), "on Day [ steps back a day");
        assert!(screen(&mut a, 400, 40).contains("[ ] day  t today"));
    }

    #[test]
    fn capital_v_steps_the_verdict_filter_only_while_judges_shows() {
        let (tx, _rx) = std::sync::mpsc::channel();
        let mut a = log_app(tx);
        a.tab = Tab::Log;
        let key =
            |a: &mut App, c| a.handle(Msg::Input(Event::Key(KeyEvent::from(KeyCode::Char(c)))));
        key(&mut a, 'V');
        assert_eq!(a.ask_filter, 0);
        a.log_go("judges");
        key(&mut a, 'V');
        assert_eq!(ASK_FILTERS[a.ask_filter], "answered");
        for _ in 1..ASK_FILTERS.len() {
            key(&mut a, 'V');
        }
        assert_eq!(a.ask_filter, 0);
    }

    #[test]
    fn logs_actions_table_takes_its_keys_and_gives_them_back() {
        let (tx, _rx) = std::sync::mpsc::channel();
        let mut a = log_app(tx);
        let at = |i, verb: &str| hub_core::actions::Action {
            at: i,
            actor: "shepherd".into(),
            verb: verb.into(),
            text: format!("row {verb}"),
            priority: None,
            reference: None,
            source: "shepherd".into(),
        };
        a.actions = Some(hub_core::actions::Gathered {
            actions: vec![at(2, "nudge"), at(1, "failed")],
            ..Default::default()
        });
        a.runner = Arc::new(Fake::default());
        a.handle(key('A'));
        assert!(
            a.log_inner == "actions" && a.log_actions,
            "A opens Actions and gives it the keys"
        );
        a.handle(key('f'));
        a.handle(key('f'));
        assert_eq!(a.actions_table.view.state, "failed");
        assert_eq!(a.log_inner, "actions", "f is the chip, not the Ranked tab");
        let s = screen(&mut a, 160, 60);
        assert!(s.contains("row failed") && !s.contains("row nudge"), "{s}");
        a.handle(Msg::Input(Event::Key(KeyEvent::from(KeyCode::Esc))));
        assert!(
            a.actions_table.is_default(),
            "the first Esc clears the view"
        );
        a.handle(Msg::Input(Event::Key(KeyEvent::from(KeyCode::Esc))));
        a.handle(key('f'));
        assert_eq!(a.log_inner, "ranked", "the keys went back to Log");
        a.handle(Msg::Input(Event::Key(KeyEvent::from(KeyCode::Left))));
        a.handle(Msg::Input(Event::Key(KeyEvent::from(KeyCode::Enter))));
        assert!(
            a.log_inner == "judges" && !a.log_actions && !a.log_work,
            "Enter on Judges is no table's"
        );
        a.handle(key('A'));
        a.handle(key('/'));
        a.handle(key('n'));
        a.handle(Msg::Input(Event::Key(KeyEvent::from(KeyCode::Enter))));
        assert_eq!(
            a.actions_table.view.q, "n",
            "after A, / is the Actions query"
        );
        a.handle(key('/'));
        a.handle(key('q'));
        assert!(!a.quit, "q is typed into the query");
        a.handle(Msg::Input(Event::Key(KeyEvent::from(KeyCode::Esc))));
        a.handle(key('3'));
        a.handle(key('2'));
        assert_eq!(
            a.log_inner, "actions",
            "coming back shows the inner tab it left"
        );
        a.handle(key('f'));
        assert_eq!(a.log_inner, "ranked", "leaving the tab left the table");
        a.handle(key('a'));
        a.handle(Msg::Input(Event::Key(KeyEvent::from(KeyCode::Enter))));
        assert!(a.log_actions, "Enter on Actions gives its table the keys");
    }

    #[test]
    fn work_keeps_its_keys_and_d_leaves_a_past_day() {
        let (tx, _rx) = std::sync::mpsc::channel();
        let mut a = log_app(tx);
        a.log_work = true;
        a.log_key(KeyEvent::from(KeyCode::Enter));
        assert!(a.log_work && !a.log_actions, "Enter stays in Work");
        a.day = Some("2026-11-01".into());
        a.log_key(KeyEvent::from(KeyCode::Char('d')));
        assert_eq!((a.day.as_deref(), a.work_window), (None, 0));
        a.log_key(KeyEvent::from(KeyCode::Char('d')));
        assert_eq!(a.work_window, 1);
    }

    #[test]
    fn logs_work_table_leads_takes_its_keys_and_steps_its_window() {
        let (tx, _rx) = std::sync::mpsc::channel();
        let mut a = log_app(tx);
        a.runner = Arc::new(Fake::default());
        assert!(screen(&mut a, 160, 60).contains("Reading the work..."));
        let today = chrono::Local::now().format("%Y-%m-%dT09:30").to_string();
        let row = |state, what: &str, when: String| hub_core::worklog::Work {
            state,
            when: Some(when),
            project: "notes".into(),
            what: what.into(),
            plan: None,
            kind: None,
            ci: None,
            pr: None,
            url: None,
            cost: None,
            slug: None,
            unproven: false,
        };
        a.handle(Msg::Work(Box::new(hub_core::worklog::Gathered {
            rows: vec![
                row("failed", "row broke", today.clone()),
                row("done", "row shipped", today),
                row("done", "row ancient", "2020-01-02T09:30".into()),
            ],
            ..Default::default()
        })));
        let s = screen(&mut a, 160, 60);
        assert!(s.contains("WORK (7d)  W filters it"), "{s}");
        assert!(s.contains("row broke") && !s.contains("row ancient"), "{s}");
        assert!(
            s.find("[Work]").unwrap() < s.find("WORK (7d)").unwrap() && !s.contains("HISTORY ("),
            "Work leads the tab, under the strip, on a page of its own: {s}"
        );
        a.handle(key('W'));
        a.handle(key('f'));
        assert_eq!(a.log_inner, "work", "f is the chip, not the Ranked tab");
        assert_eq!(a.work_table.view.state, "done");
        a.handle(key('d'));
        a.handle(key('d'));
        a.handle(key('d'));
        let s = screen(&mut a, 160, 60);
        assert!(s.contains("WORK (all)  d window, Esc back"), "{s}");
        assert!(s.contains("row ancient") && !s.contains("row broke"), "{s}");
        a.handle(Msg::Input(Event::Key(KeyEvent::from(KeyCode::Esc))));
        assert!(a.work_table.is_default(), "the first Esc clears the view");
        a.handle(Msg::Input(Event::Key(KeyEvent::from(KeyCode::Esc))));
        a.handle(key('f'));
        assert_eq!(a.log_inner, "ranked", "the keys went back to Log");
        a.handle(Msg::Input(Event::Key(KeyEvent::from(KeyCode::Right))));
        a.handle(key('/'));
        a.handle(key('q'));
        assert!(!a.quit, "/ is Work's query on Work");
        a.handle(Msg::Input(Event::Key(KeyEvent::from(KeyCode::Enter))));
        assert_eq!(a.work_table.view.q, "q");
    }

    #[test]
    fn hub_tab_actions_opens_logs_actions_inner_tab() {
        let (tx, _rx) = std::sync::mpsc::channel();
        let mut a = log_app(tx);
        a.tab = Tab::Home;
        let (t, q) = crate::tabreq::parse("actions").unwrap();
        a.handle(Msg::Tab(t, q));
        assert_eq!((a.tab, a.log_inner), (Tab::Log, "actions"));
        assert!(screen(&mut a, 160, 60).contains("Reading the actions..."));
        a.handle(Msg::Actions(Box::default()));
        let s = screen(&mut a, 160, 60);
        assert!(s.contains("ACTIONS (0)  Enter filters"), "{s}");
        assert!(s.contains("nothing in the last 24h"), "{s}");
        // A retired day-list name opens the list itself, on Day.
        let (t, q) = crate::tabreq::parse("history").unwrap();
        a.handle(Msg::Tab(t, q));
        assert!(a.log_days && a.log_inner == "day");
        // An inner tab's own name, and a section's, open that inner tab.
        for (req, inner) in [
            ("log judges", "judges"),
            ("log verdicts", "judges"),
            ("log forecast", "ranked"),
            ("forecast", "ranked"),
        ] {
            a.runner = Arc::new(Fake::default());
            let (t, q) = crate::tabreq::parse(req).unwrap();
            a.handle(Msg::Tab(t, q));
            assert_eq!(a.log_inner, inner, "{req}");
        }
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
            lines[0].contains("1 Home  2 Log  3 Queue  4 Sessions  5 Fleet  6 Projects"),
            "{s}"
        );
        assert!(
            s.contains("FLOW  inbox - | board - | up next 1 ready, 1 held")
                && s.contains("running 1 | on a PR 0 | needs you 1"),
            "{s}"
        );
        assert!(
            !s.contains("done today") && !s.contains("queue 1 running"),
            "{s}"
        );
        assert!(s.contains("RUNNING (1)"), "{s}");

        a.handle(key('3'));
        assert_eq!(a.tab, Tab::Queue);
        let s = screen(&mut a, 140, 30);
        assert!(
            s.contains("all 5  needs you 1  running 1  on a PR 0  up next 2  done 1"),
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
        let dir = std::env::temp_dir().join(format!("hub-tui-cands-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        a.files.candidates = dir.join("candidates.jsonl");
        std::fs::write(&a.files.candidates, "").unwrap();
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
        assert!(
            !ran.iter().any(|c| c.contains("suggest")),
            "the snapshot is read, never a live suggest: {ran:?}"
        );
        assert!(screen(&mut a, 160, 40).contains("- CANDIDATES (0, 0 auto)"));
        a.handle(Msg::Candidates(Ok(queuetab::tests::cands())));
        for _ in 0..5 {
            a.handle(key('j'));
        }
        let s = screen(&mut a, 160, 40);
        assert!(s.contains("bar-17") && s.contains("auto dispatch"), "{s}");
        assert!(s.contains("C candidates  p promote"), "{s}");
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
    fn p_on_a_row_steps_its_priority_through_the_cli_and_an_empty_view_writes_nothing() {
        let (tx, rx) = std::sync::mpsc::channel();
        let mut a = with_tx(Tab::Home, tx);
        let fake = Arc::new(Fake::default());
        a.runner = fake.clone();
        a.handle(key('6'));
        settle(&mut a, &rx);
        a.handle(Msg::Tasks(Box::new(Ok(crate::tasktab::tests::fixture()))));
        let mut l = loaded();
        if let Ok(st) = l.stats.as_mut() {
            st[1].prio = "focus".into();
        }
        a.handle(Msg::Projects(Box::new(l)));
        let s = screen(&mut a, 140, 30);
        assert!(s.contains("v0.1.0   focus"), "{s}");
        assert!(s.lines().last().unwrap().contains("P priority"), "{s}");
        fake.0.lock().unwrap().clear();
        // Typed, P is a letter of the search; with no row kept it has nothing to step.
        for c in "/P".chars() {
            a.handle(key(c));
        }
        a.handle(Msg::Input(Event::Key(KeyEvent::from(KeyCode::Enter))));
        assert_eq!(a.pv.table.view.q, "P");
        a.handle(key('P'));
        assert!(fake.0.lock().unwrap().is_empty(), "no row, no write");
        a.handle(key('x'));
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
        assert_eq!(
            Tab::parse("board"),
            Some(Tab::Projects),
            "`a` opens it there"
        );
        // Projects is the sixth tab on the bar, so 6 opens it.
        a.handle(key('6'));
        assert_eq!(a.tab, Tab::Projects);
        let s = screen(&mut a, 140, 30);
        let bar = s.lines().next().unwrap();
        assert!(
            bar.contains("5 Fleet  6 Projects") && bar.contains("4 Sessions"),
            "{s}"
        );
        assert!(s.contains("Reading notes projects..."), "{s}");
        settle(&mut a, &rx);
        assert!(screen(&mut a, 140, 30).contains("notes projects --stats --json"));

        a.handle(Msg::Tasks(Box::new(Ok(crate::tasktab::tests::fixture()))));
        a.handle(Msg::Projects(Box::new(loaded())));
        let s = screen(&mut a, 140, 30);
        let at = |t: &str| s.find(t).unwrap_or_else(|| panic!("{t} missing:\n{s}"));
        assert!(at("ALL ROWS  4 open rows") < at("PROJECT "), "{s}");
        assert!(
            at("demo  ") < at("garden  "),
            "by name when none is in flight"
        );
        assert!(s.contains("25%"), "{s}");
        assert!(s.lines().last().unwrap().contains("a all rows"), "{s}");

        // The card's numbers stay on top of its rows.
        let ran = |f: &Fake| f.0.lock().unwrap().join("\n");
        // The Deliverables section reads every project's epics; only the opened card reads its own.
        assert!(
            !ran(&fake).contains("--project"),
            "the list reads no page: {}",
            ran(&fake)
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
        assert!(s.contains("NEEDS YOU") && s.contains("[Overview"), "{s}");
        assert!(
            !s.contains("ROWS  "),
            "the rows wait for their inner tab:\n{s}"
        );
        // Only Rows reads the board: Overview draws while it is read.
        let board = a.tasks.take();
        let s = screen(&mut a, 140, 40);
        assert!(
            s.contains("NEEDS YOU") && !s.contains("Reading notes board"),
            "{s}"
        );
        a.tasks = board;
        assert!(
            s.lines().last().unwrap().contains("<- -> inner tabs"),
            "{s}"
        );
        // Row keys do nothing off Rows; Right opens Rows.
        a.handle(key('x'));
        assert!(a.tv.prompt.is_none());
        a.handle(Msg::Input(Event::Key(KeyEvent::from(KeyCode::Right))));
        assert_eq!(a.pv.inner, "rows");
        let s = screen(&mut a, 140, 30);
        assert!(
            at_line(&s, "DEMO  bnb, alpha") < at_line(&s, "ROWS  4 of 4 rows"),
            "{s}"
        );
        assert!(!s.contains("water the beds"), "only demo's rows:\n{s}");
        assert!(s.lines().last().unwrap().contains("t/T tag"), "{s}");
        // The selected row in full sits under the rows, above the keys.
        assert!(
            at_line(&s, "ROWS  ") < at_line(&s, "no id  bnb/demo  human  v0.1.0  open  urgent"),
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
        assert_eq!(a.pv.table.sel, 0);

        // All keeps the cross-project board, the last row scrolled into view.
        a.handle(key('a'));
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

    /// Home with two running items: `fix-menu` in the live session `lab/dotfiles-agent-3:2`
    /// (`boards()`), `no-session` in none.
    fn home_running() -> App {
        let mut a = app(Tab::Home);
        a.boards = Some(boards());
        let jsonl = concat!(
            r#"{"slug":"fix-menu","project":"game","mode":"oneshot","queued":"2026-11-03T10:10:00Z","started":"2026-11-03T10:20:00Z","session":"lab:dotfiles-agent-3","state":"running","task":"Fix the menu"}"#,
            "\n",
            r#"{"slug":"no-session","project":"dotfiles","mode":"oneshot","queued":"2026-11-03T10:30:00Z","started":"2026-11-03T10:40:00Z","state":"running","task":"Sweep the logs"}"#,
            "\n",
        );
        a.queue = Some(Queue {
            items: hub_core::queue::parse(jsonl),
            stats: None,
            errors: vec![],
        });
        a
    }

    /// Put Running's selection on `slug` with j/k, as the human would.
    fn pick_running(a: &mut App, slug: &str) {
        let at =
            a.hv.running_rows(&a.home_build())
                .iter()
                .position(|r| r.slug == slug)
                .unwrap_or_else(|| panic!("{slug} is not drawn"));
        a.handle(Msg::Input(Event::Key(KeyEvent::from(KeyCode::Char('g')))));
        for _ in 0..at {
            a.handle(key('j'));
        }
        assert_eq!(a.hv.running.sel, at);
    }

    #[test]
    fn tab_moves_the_keys_to_running_and_enter_opens_its_session_else_its_queue_item() {
        let tab = || Msg::Input(Event::Key(KeyEvent::from(KeyCode::Tab)));
        let enter = || Msg::Input(Event::Key(KeyEvent::from(KeyCode::Enter)));
        let mut a = home_running();
        let s = screen(&mut a, 120, 60);
        assert!(
            s.contains("RUNNING (2)") && s.contains("Sweep the logs"),
            "{s}"
        );

        // Negative control: with Needs you holding the keys, Enter opens no running row and j
        // scrolls the page, not Running's selection.
        a.handle(key('j'));
        a.handle(enter());
        assert_eq!((a.tab, a.hv.running.sel), (Tab::Home, 0));
        assert!(!a.hints().contains("Running:"), "{}", a.hints());

        // Tab gives Running the keys and stays on Home.
        a.handle(tab());
        assert!(a.hv.on_running && a.tab == Tab::Home);
        assert!(a.hints().starts_with("Running: j/k pick  Enter open"));

        // No session: Enter opens the queue item's record.
        pick_running(&mut a, "no-session");
        a.handle(enter());
        assert_eq!(a.tab, Tab::Queue);
        let now = jobs::now();
        let q = a.queue.as_ref().unwrap();
        let shown = a.qv.shown(q, now);
        assert!(a.qv.detail, "the item's record is open");
        assert_eq!(shown[a.qv.table.sel].item.slug, "no-session");

        // A live session: Enter opens its page on Sessions, once the feed has it.
        a.handle(key('1'));
        assert!(a.hv.on_running, "Running keeps the keys across pages");
        pick_running(&mut a, "fix-menu");
        a.handle(enter());
        assert_eq!(a.tab, Tab::Sessions);
        assert_eq!(a.session_want.as_deref(), Some("lab/dotfiles-agent-3:2"));
        a.controls.set(crate::controls::tests::fixture());
        a.handle(Msg::SessionFeed(Box::default()));
        assert!(a.controls.open && a.session_want.is_none());
        assert_eq!(
            a.controls.position("lab/dotfiles-agent-3:2"),
            Some(a.controls.table.sel)
        );

        // Tab again gives the keys back to Needs you; Esc does too.
        a.handle(key('1'));
        a.handle(tab());
        assert!(!a.hv.on_running);
        a.handle(Msg::Input(Event::Key(KeyEvent::from(KeyCode::BackTab))));
        assert!(a.hv.on_running && a.tab == Tab::Home);
        a.handle(Msg::Input(Event::Key(KeyEvent::from(KeyCode::Esc))));
        assert!(!a.hv.on_running);
    }

    #[test]
    fn running_has_its_own_view_and_a_session_left_behind_is_not_opened() {
        let mut a = home_running();
        a.handle(Msg::Input(Event::Key(KeyEvent::from(KeyCode::Tab))));
        a.handle(key('f'));
        assert_eq!(a.hv.running.view.state, "No session");
        assert!(a.hv.needs.is_default(), "Needs you's view is untouched");
        let s = screen(&mut a, 120, 60);
        let running = &s[s
            .find("RUNNING (1 of 2)")
            .expect("the view counts what it keeps")..];
        assert!(
            running.contains("Sweep the logs") && !running.contains("Fix the menu"),
            "{s}"
        );
        // A selection a re-read left past the rows opens the last row drawn, as it is marked.
        a.handle(key('x'));
        a.hv.running.sel = 9;
        a.handle(Msg::Input(Event::Key(KeyEvent::from(KeyCode::Enter))));
        assert_ne!(a.tab, Tab::Home, "Enter opened the last row");

        // A session asked for before the feed has it stays wanted through a feed without it,
        // and is dropped once the page moves on.
        a.follow(&hub_core::links::Link::to(
            hub_core::links::Kind::Session,
            "lab/dotfiles-agent-3:2",
        ));
        a.handle(Msg::SessionFeed(Box::default()));
        assert!(!a.controls.open && a.session_want.is_some());
        a.handle(key('1'));
        a.controls.set(crate::controls::tests::fixture());
        a.handle(Msg::SessionFeed(Box::default()));
        assert!(!a.controls.open && a.session_want.is_none());
    }

    #[test]
    fn with_nothing_running_tab_turns_the_page_and_running_lets_the_keys_go() {
        let tab = || Msg::Input(Event::Key(KeyEvent::from(KeyCode::Tab)));
        let mut a = app(Tab::Home);
        a.handle(tab());
        assert!(!a.hv.on_running);
        assert_ne!(
            a.tab,
            Tab::Home,
            "nothing to give the keys to: Tab turns the page"
        );

        // The last running item finishes while Running has the keys: j scrolls the page again.
        let mut a = home_running();
        a.handle(tab());
        assert!(a.hv.on_running);
        a.queue = Some(Queue {
            items: vec![],
            stats: None,
            errors: vec![],
        });
        assert!(!a.hints().starts_with("Running:"), "{}", a.hints());
        let before = a.scroll;
        a.handle(key('j'));
        assert!(!a.hv.on_running && a.scroll == before + 1);
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
    fn table_keys_on_home_drive_needs_you_and_only_enter_opens_proposals() {
        let (tx, _rx) = std::sync::mpsc::channel();
        let mut a = with_tx(Tab::Home, tx);
        a.proposals = Some(Ok(vec![proposal("aa", "dream")]));
        let key = |a: &mut App, c| a.handle(Msg::Input(Event::Key(KeyEvent::from(c))));
        for c in ['s', 'f', '/', 'u'] {
            key(&mut a, KeyCode::Char(c));
        }
        // The flow key u is typed into the query, not taken as a chip.
        assert_eq!(a.hv.needs.typing.as_deref(), Some("u"));
        key(&mut a, KeyCode::Enter);
        assert!(!a.prv.open && a.prv.table.is_default() && !a.hv.needs.is_default());
        // Esc clears the Needs you view first; Enter then opens the proposals table.
        key(&mut a, KeyCode::Esc);
        assert!(a.hv.needs.is_default() && !a.prv.open);
        key(&mut a, KeyCode::Enter);
        assert!(a.prv.open);
    }

    #[test]
    fn the_home_hint_offers_enter_only_with_something_proposed() {
        let (tx, _rx) = std::sync::mpsc::channel();
        let mut a = with_tx(Tab::Home, tx);
        assert!(!a.hints().contains("Enter proposals"));
        a.proposals = Some(Ok(vec![proposal("aa", "dream")]));
        assert!(a.hints().contains("Enter proposals"));
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
    fn f_on_home_queues_the_next_bad_area_once_through_agent_queue() {
        let (tx, rx) = std::sync::mpsc::channel();
        let mut a = with_tx(Tab::Home, tx);
        let fake = Arc::new(Fake::default());
        a.runner = fake.clone();
        a.night = Some(hub_core::briefing::Night {
            rows: vec![hub_core::briefing::NightRow {
                area: hub_core::briefing::Area {
                    name: "Nightly",
                    level: hub_core::briefing::Level::Bad,
                    line: "red".into(),
                    details: vec![],
                    link: "#infra",
                },
                fix: Some(hub_core::briefing::Fix {
                    project: "agent-runtime",
                    task: "Fix the nightly".into(),
                    queued: None,
                }),
            }],
            ..Default::default()
        });
        for _ in 0..2 {
            a.handle(Msg::Input(Event::Key(KeyEvent::from(KeyCode::Char('F')))));
        }
        loop {
            if let Msg::FixQueued(name, r) = rx.recv().unwrap() {
                assert_eq!(name, "Nightly");
                assert!(r.is_ok(), "{r:?}");
                a.handle(Msg::FixQueued(name, r));
                break;
            }
        }
        let calls = fake.0.lock().unwrap();
        let added: Vec<_> = calls.iter().filter(|c| c.contains(" add ")).collect();
        assert_eq!(
            added,
            ["agent-queue add --from human --project agent-runtime --mode oneshot --priority high -- Fix the nightly"],
            "the second F finds it in flight: {calls:?}"
        );
        drop(calls);
        assert!(matches!(a.fixes.get("Nightly"), Some(Some(Ok(_)))));
    }

    #[test]
    fn home_draws_what_needs_you_and_green_collapses() {
        let mut a = app(Tab::Home);
        a.infra = Some(board::tests::fixture());
        let s = screen(&mut a, 120, 40);
        let first = s.lines().next().unwrap();
        assert!(
            first.contains("1 Home") && first.contains("9 Infra") && first.contains(" RED"),
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
        // and the digits follow that order along the number row, 1 for the first, 0 the tenth;
        // a tab past the tenth has none, and Tab reaches it.
        let titles: Vec<&str> = Tab::ALL.iter().map(|t| t.title()).collect();
        // Less Board: agent-web's tab for what `a` on Projects opens here.
        let layout: Vec<&str> = hub_core::layout::TABS
            .iter()
            .map(|t| t.title)
            .filter(|t| *t != "Board")
            .collect();
        assert_eq!(titles, layout);
        // The bar is the layout less Daily, which only agent-web shows; the digits follow it.
        let shown: Vec<&str> = Tab::SHOWN.iter().map(|t| t.title()).collect();
        let bar: Vec<&str> = layout.iter().copied().filter(|t| *t != "Daily").collect();
        assert_eq!(shown, bar);
        for (i, t) in Tab::SHOWN.iter().enumerate() {
            let id = t.title().to_lowercase();
            if i >= 10 {
                assert_eq!((t.digit(), hub_core::layout::bar_digit(&id)), (' ', None));
                continue;
            }
            let d = char::from_digit((i as u32 + 1) % 10, 10).unwrap();
            assert_eq!((t.digit(), Tab::by_digit(d)), (d, Some(*t)));
            assert_eq!(
                hub_core::layout::bar_digit(&id),
                d.to_digit(10).map(|n| n as usize),
                "the badges name this digit"
            );
        }
        assert_eq!((Tab::Alerts.digit(), Tab::Infra.digit()), ('8', '9'));
        assert_eq!(
            (Tab::Schedules.digit(), Tab::by_digit('0')),
            ('0', Some(Tab::Schedules))
        );
        assert_eq!(Tab::Costs.digit(), ' ');
        assert_eq!(Tab::Daily.digit(), ' ');
        assert_eq!(Tab::by_digit('2'), Some(Tab::Log));
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

        // f steps the chips: the kinds (lead first), then the states (held leads them); s the sort.
        a.handle(ch('f'));
        assert_eq!(a.fleet_table.view.state, "lead");
        let s = screen(&mut a, 160, 40);
        assert!(s.contains("dream") && !s.contains("idle-one"), "{s}");
        for _ in 0..6 {
            a.handle(ch('f'));
        }
        assert_eq!(a.fleet_table.view.state, "held");
        a.handle(ch('f'));
        assert_eq!(a.fleet_table.view.state, "failed");
        let s = screen(&mut a, 160, 40);
        assert!(s.contains("dream") && !s.contains("idle-one"), "{s}");
        a.handle(ch('x'));
        a.handle(ch('s'));
        assert_eq!(a.fleet_table.view.sort, "kind");
    }

    #[test]
    fn the_fleet_tab_draws_the_table_and_a_moved_section_opens_on_costs() {
        let mut a = app(Tab::Fleet);
        assert!(screen(&mut a, 120, 10).contains("Reading the fleet..."));
        a.handle(Msg::Fleet(Box::new(fleettab::tests::fixture())));
        let s = screen(&mut a, 160, 40);
        assert!(s.lines().next().unwrap().contains("5 Fleet"), "{s}");
        assert!(
            !s.contains("WHERE THE TOKENS GO"),
            "tokens are Costs' now\n{s}"
        );
        a.fleet_read.busy = true;
        let (t, q) = crate::tabreq::parse("fleet inbox-triage").unwrap();
        a.handle(Msg::Tab(t, q));
        assert!(a.tab == Tab::Fleet);
        assert_eq!(a.fleet_page.as_deref(), Some("inbox-triage"));
        a.handle(Msg::Input(Event::Key(KeyEvent::from(KeyCode::Esc))));
        a.costs_read.busy = true;
        let (t, q) = crate::tabreq::parse("fleet accounts").unwrap();
        a.handle(Msg::Tab(t, q));
        assert!(a.fleet_page.is_none());
        assert_eq!((a.tab, a.seek), (Tab::Costs, Some("burn")));
    }

    #[test]
    fn only_a_finished_snapshot_is_a_token_file() {
        let f = BoardFiles {
            tokens: "/a/token-usage".into(),
            ..BoardFiles::from_env()
        };
        assert!(f.is_token_file(Path::new("/a/token-usage/2027-01-15.json")));
        assert!(!f.is_token_file(Path::new("/a/token-usage/2027-01-15.json.tmp")));
        assert!(!f.is_token_file(Path::new("/a/other/2027-01-15.json")));
    }

    #[test]
    fn only_the_replaced_snapshot_is_a_release_file() {
        let f = BoardFiles {
            releases: "/a/releases".into(),
            ..BoardFiles::from_env()
        };
        assert!(f.is_release_file(Path::new("/a/releases/state.json")));
        assert!(!f.is_release_file(Path::new("/a/releases/.state.123")));
        assert!(!f.is_release_file(Path::new("/a/other/state.json")));
    }

    /// The fixture's runs with #3 (red) and #2 tied to binks releases, as the graph joins them.
    fn release_fixture() -> Builds {
        let mut b = bv::tests::fixture();
        for (r, tag) in b.rows.iter_mut().zip(["v1.2.0", "v1.1.0"]) {
            r.release = Some(hub_core::release_graph::RunRelease {
                project: "binks".into(),
                tag: tag.into(),
            });
        }
        b.released = hub_core::builds::Counts {
            total: 2,
            red: 1,
            recent_red: 1,
            ..Default::default()
        };
        b
    }

    fn builds_app() -> App {
        let mut a = app(Tab::Releases);
        a.files.builds.ledger = "/nonexistent/ci/runs.jsonl".into();
        a.releases = Some(Releases::default());
        a.builds = Some(release_fixture());
        a
    }

    fn press(a: &mut App, c: KeyCode) {
        a.handle(Msg::Input(Event::Key(KeyEvent::from(c))));
    }

    #[test]
    fn an_apps_build_runs_are_the_builds_rows_whichever_read_lands_last() {
        let mut a = app(Tab::Releases);
        let game = hub_core::releases::App {
            project: "game".into(),
            ..Default::default()
        };
        let releases = || Releases {
            apps: vec![game.clone()],
            ..Default::default()
        };
        let mut b = bv::tests::fixture();
        b.rows[0].release = Some(hub_core::release_graph::RunRelease {
            project: "game".into(),
            tag: "v0.5.0-game7".into(),
        });
        a.handle(Msg::Releases(Box::new(releases())));
        a.handle(Msg::Builds(Box::new(b.clone())));
        let tags = |a: &App| -> Vec<String> {
            a.releases.as_ref().unwrap().apps[0]
                .builds
                .iter()
                .map(|x| x.tag.clone())
                .collect()
        };
        assert_eq!(tags(&a), ["v0.5.0-game7"]);
        // A newer apps read keeps them, and a second put does not double them.
        a.handle(Msg::Releases(Box::new(releases())));
        a.handle(Msg::Builds(Box::new(b)));
        assert_eq!(tags(&a), ["v0.5.0-game7"]);
    }

    #[test]
    fn only_an_append_to_the_run_ledger_is_a_build_file() {
        let f = BoardFiles {
            builds: builds::Paths {
                ledger: "/a/ci/runs.jsonl".into(),
                ..builds::Paths::from_env()
            },
            ..BoardFiles::from_env()
        };
        assert!(f.is_build_file(Path::new("/a/ci/runs.jsonl")));
        assert!(!f.is_build_file(Path::new("/a/ci/sync.json")));
        assert!(!f.is_build_file(Path::new("/a/other/runs.jsonl")));
    }

    #[test]
    fn release_runs_lists_the_runs_tied_to_a_release_and_counts_a_red_on_the_strip() {
        let mut a = builds_app();
        let s = screen(&mut a, 120, 30);
        assert!(
            s.contains("[Apps] Release runs 1"),
            "a recent red release run counts: {s}"
        );
        assert!(!s.contains("Builds") && !s.contains("Tests"), "{s}");
        press(&mut a, KeyCode::Right);
        let s = screen(&mut a, 120, 30);
        assert!(s.contains("[Release runs 1]"), "{s}");
        assert!(s.contains("Release runs  2 runs in 30 days"), "{s}");
        let red = s
            .lines()
            .find(|l| l.contains("red") && l.contains("binks"))
            .unwrap();
        assert!(red.contains("agent-3") && red.contains("v1.2.0"), "{red}");
        assert!(
            !s.contains("dotfiles"),
            "a run of no release is Infra's: {s}"
        );
        let mut b = app(Tab::Releases);
        b.releases = Some(Releases::default());
        b.rv.show("runs");
        assert!(screen(&mut b, 110, 30).contains("Reading runs..."));
    }

    #[test]
    fn right_hands_the_keys_to_release_runs_and_enter_reads_that_runs_log_then() {
        let mut a = builds_app();
        press(&mut a, KeyCode::Right);
        assert_eq!(a.rv.on(), "runs");
        press(&mut a, KeyCode::Char('j'));
        assert_eq!(a.rv.runs.table.sel, 1, "j moves the runs, not the apps");
        assert_eq!(a.rv.table.sel, 0);
        press(&mut a, KeyCode::Char('k'));
        assert!(a.rv.runs.log.is_none(), "selecting reads no log");
        press(&mut a, KeyCode::Enter);
        let gen = a.rv.runs.log.as_ref().unwrap().gen;
        let s = screen(&mut a, 110, 30);
        assert!(
            s.contains("--- log: github.com binks Tests #3 agent-3/work owner agent-3"),
            "{s}"
        );
        a.handle(Msg::Log(gen, Ok("step 3 failed\nexit 1\n".into())));
        assert!(screen(&mut a, 110, 30).contains("step 3 failed"));
        a.handle(Msg::Log(gen + 9, Ok("stale".into())));
        assert!(!screen(&mut a, 110, 30).contains("stale"));
        let opened = |title: &str| hub_core::run_detail::RunDetail {
            title: title.into(),
            header: "end to end 46m | complete".into(),
            coverage: "complete".into(),
            ..Default::default()
        };
        a.handle(Msg::BuildDetail(gen + 9, Box::new(Ok(opened("#9 stale")))));
        a.handle(Msg::BuildDetail(
            gen,
            Box::new(Ok(opened("#3 Tests  red  2m  $0.20"))),
        ));
        let s = screen(&mut a, 80, 30);
        assert!(
            s.contains("#3 Tests  red  2m  $0.20") && !s.contains("#9 stale"),
            "{s}"
        );
        assert!(
            s.contains("step 3 failed"),
            "the log stays under the detail: {s}"
        );
        press(&mut a, KeyCode::Esc);
        assert!(a.rv.runs.log.is_none() && a.rv.runs.detail.is_none() && a.rv.on() == "runs");
        press(&mut a, KeyCode::Left);
        assert_eq!(a.rv.on(), "apps");
    }

    #[test]
    fn left_and_right_walk_releases_inner_tabs_and_hub_tab_names_one() {
        let mut a = builds_app();
        assert_eq!(a.rv.on(), "apps");
        press(&mut a, KeyCode::Left);
        assert_eq!(a.rv.on(), "runs", "Left wraps before the first");
        press(&mut a, KeyCode::Right);
        assert_eq!(a.rv.on(), "apps", "Right wraps past the last");
        // An open app pane belongs to Apps: another inner tab closes it.
        a.rv.open = true;
        press(&mut a, KeyCode::Right);
        assert!(!a.rv.open);
        // `hub --tab 'releases runs'` and the section words land on the inner tab holding them;
        // any other word is the apps' query, on Apps.
        for (word, on, q) in [
            ("runs", "runs", ""),
            ("detail", "apps", ""),
            ("project:binks", "apps", "project:binks"),
        ] {
            let mut a = builds_app();
            a.rv.show("runs");
            a.open_query(Some(word.to_string()));
            assert_eq!((a.rv.on(), a.rv.table.view.q.as_str()), (on, q), "{word}");
        }
    }

    /// Infra on its Runs inner tab, with every run read.
    fn ci_app() -> App {
        let mut a = infra_app();
        a.tab = Tab::Infra;
        a.infra_inner = "runs";
        a.files.builds.ledger = "/nonexistent/ci/runs.jsonl".into();
        a.builds = Some(release_fixture());
        a
    }

    #[test]
    fn infra_runs_shows_every_run_and_counts_a_red_and_tests_its_note() {
        let mut a = ci_app();
        let s = screen(&mut a, 160, 80);
        assert!(s.contains("[Runs 1]") || s.contains("[Runs 2]"), "{s}");
        assert!(
            s.contains("RUNS  3 runs in 30 days: 0 running, 1 queued, 1 red"),
            "{s}"
        );
        assert!(s.contains("dotfiles"), "a run of no release is listed: {s}");
        assert!(
            !s.contains("Releases, Builds") && !s.contains("run times"),
            "{s}"
        );
        a.infra_inner = "tests";
        let s = screen(&mut a, 160, 80);
        assert!(s.contains("TESTS") && s.contains("Infra, Tests"), "{s}");
        a.infra_inner = "runs";
        a.builds = None;
        assert!(screen(&mut a, 160, 80).contains("Reading runs..."));
    }

    #[test]
    fn enter_on_infra_runs_opens_the_runs_table_and_t_is_no_key() {
        let mut a = ci_app();
        press(&mut a, KeyCode::Enter);
        assert_eq!(a.infra_open, Some(Opened::Runs));
        let s = screen(&mut a, 120, 30);
        assert!(
            s.contains("Runs  3 runs in 30 days") && s.contains("RELEASE"),
            "{s}"
        );
        press(&mut a, KeyCode::Char('j'));
        assert_eq!(a.ci.table.sel, 1);
        assert_eq!(a.rv.runs.table.sel, 0, "Infra's table is its own");
        press(&mut a, KeyCode::Esc);
        assert_eq!(a.infra_open, None, "Esc with nothing open goes back");
        // Run times retired to Pipelines: `t` on Runs opens nothing.
        press(&mut a, KeyCode::Char('t'));
        assert_eq!(a.infra_open, None);
        // Runners has no runs table under Enter: its tables have the keys.
        a.infra_inner = "runners";
        press(&mut a, KeyCode::Enter);
        assert_ne!(a.infra_open, Some(Opened::Runs));
        // A key from the Jobs inner tab still opens the jobs table.
        let mut b = ci_app();
        b.infra_inner = "jobs";
        press(&mut b, KeyCode::Enter);
        assert_eq!(b.infra_open, Some(Opened::Jobs));
    }

    #[test]
    fn pipelines_keys_pick_a_row_and_enter_opens_its_detail() {
        let mut a = ci_app();
        a.infra_inner = "pipelines";
        let ci = hub_core::schedules::ci_state(
            &serde_json::json!({"repos": [{
                "repo": "Org/game", "base": "main",
                "workflows": [
                    {"path": ".github/workflows/scan.yml", "name": "Vuln scan",
                     "crons": ["0 9 * * 1"], "purpose": "Scan the lockfiles"},
                    {"path": ".github/workflows/gates.yml", "name": "Drop gates",
                     "crons": ["0 6 * * *"]}
                ]
            }]})
            .to_string(),
        )
        .unwrap();
        a.handle(Msg::Pipes(Box::new(hub_core::pipelines::Sources {
            ci,
            at: jobs::now(),
            ..Default::default()
        })));
        // The two from state.json, and a row for each workflow the runs read names.
        assert!(a.pipes.as_ref().is_some_and(|p| p.rows.len() >= 2));
        let s = screen(&mut a, 160, 60);
        assert!(s.contains("PIPELINES") && s.contains("Vuln scan"), "{s}");
        // j picks the next row; Enter opens it, Enter again closes it.
        let first = a.pipes.as_ref().and_then(|p| a.plv.selected(p)).cloned();
        press(&mut a, KeyCode::Char('j'));
        assert_eq!(a.plv.table.sel, 1);
        press(&mut a, KeyCode::Char('k'));
        press(&mut a, KeyCode::Enter);
        let open = a.plv.open.as_ref().map(|d| d.row.pipeline.clone());
        assert_eq!(open, first.map(|r| r.pipeline));
        let s = screen(&mut a, 160, 60);
        assert!(s.contains("> ") && s.contains("File"), "{s}");
        press(&mut a, KeyCode::Enter);
        assert!(a.plv.open.is_none());
        // Esc closes the detail first, then clears the view, then is the page's.
        press(&mut a, KeyCode::Enter);
        press(&mut a, KeyCode::Char('f'));
        assert!(!a.plv.table.is_default());
        press(&mut a, KeyCode::Esc);
        assert!(a.plv.open.is_none() && !a.plv.table.is_default());
        press(&mut a, KeyCode::Esc);
        assert!(a.plv.table.is_default());
        assert_eq!(a.infra_open, None, "Enter on Pipelines opens no runs table");
    }

    #[test]
    fn the_moved_releases_sections_open_infra_runs_and_tests() {
        for (req, inner, runs) in [
            ("releases builds", "runs", true),
            ("releases tests", "tests", false),
        ] {
            let (t, q) = crate::tabreq::parse(req).unwrap();
            assert_eq!(t, Tab::Infra, "{req}");
            let mut a = ci_app();
            a.infra_inner = "machines";
            a.open_query(q);
            let opened = a.infra_open == Some(Opened::Runs);
            assert_eq!((a.infra_inner, opened), (inner, runs), "{req}");
        }
    }

    #[test]
    fn a_ledger_append_rereads_builds_only_while_the_tab_is_shown() {
        let (tx, rx) = std::sync::mpsc::channel();
        let mut a = builds_app();
        a.tx = tx;
        a.handle(Msg::BuildFile);
        assert!(matches!(
            rx.recv_timeout(Duration::from_secs(5)),
            Ok(Msg::Builds(_))
        ));
        let (tx, rx) = std::sync::mpsc::channel();
        let mut c = builds_app();
        c.tab = Tab::Infra;
        c.tx = tx;
        c.handle(Msg::BuildFile);
        assert!(
            matches!(rx.recv_timeout(Duration::from_secs(5)), Ok(Msg::Builds(_))),
            "Infra's Runs shows the runs too"
        );
        let (tx, rx) = std::sync::mpsc::channel();
        let mut b = builds_app();
        b.tab = Tab::Home;
        b.tx = tx;
        b.handle(Msg::BuildFile);
        assert!(!b.builds_read.busy, "nothing to read off the tab");
        assert!(rx.try_recv().is_err());
    }

    #[test]
    fn a_new_snapshot_rereads_the_releases_tab_only_while_it_is_shown() {
        let (tx, rx) = std::sync::mpsc::channel();
        let mut a = with_tx(Tab::Releases, tx);
        a.handle(Msg::ReleaseFile);
        assert!(matches!(
            rx.recv_timeout(Duration::from_secs(5)),
            Ok(Msg::Releases(_))
        ));
        a.handle(Msg::Releases(Box::default()));
        let (tx, rx) = std::sync::mpsc::channel();
        let mut b = with_tx(Tab::Costs, tx);
        b.handle(Msg::ReleaseFile);
        assert!(!b.releases_read.busy, "nothing to read off the tab");
        assert!(rx.try_recv().is_err());
    }

    /// `release-state`: two projects' channels, and for `changelog` the tags v3 v2 v1 with the one
    /// asked for (the newest when none), every `changelog` argv recorded. The pane's app status
    /// read (`release-state show`, then kubectl, which answers not read) is not what these count.
    #[derive(Default)]
    struct Rel(std::sync::Mutex<Vec<String>>);

    impl Runner for Rel {
        fn run(&self, argv: &[String]) -> Result<String, String> {
            if argv.first().map(String::as_str) != Some("release-state") {
                return Err("no cluster in tests".into());
            }
            if argv.get(1).map(String::as_str) == Some("changelog") {
                self.0.lock().unwrap().push(argv.join(" "));
            }
            let row = |p: &str| {
                serde_json::json!({"project": p, "id": format!("{p}-prod"), "channel": "prod",
                    "pinned": {"value": "v2", "source": "manifest"}, "status": "drift"})
            };
            Ok(match argv.get(1).map(String::as_str) {
                Some("changelog") => {
                    let tag = argv.get(4).map_or("v3", String::as_str);
                    serde_json::json!({"project": argv[3], "tag": tag, "source": "merged PRs",
                        "range": format!("prev..{tag}"), "text": "- a fix (#1)",
                        "tags": ["v3", "v2", "v1"]})
                }
                _ => serde_json::json!({"generated_epoch": 1, "rows": [row("alpha"), row("beta")]}),
            }
            .to_string())
        }
    }

    fn with_releases() -> (App, Arc<Rel>, std::sync::mpsc::Receiver<Msg>) {
        let (tx, rx) = std::sync::mpsc::channel();
        let mut a = with_tx(Tab::Releases, tx);
        let rel = Arc::new(Rel::default());
        a.runner = rel.clone();
        a.releases = Some(hub_core::releases::read(rel.as_ref(), &[]));
        (a, rel, rx)
    }

    /// The next changelog answer; app status answers on the way are handled, not counted.
    fn changelog(a: &mut App, rx: &std::sync::mpsc::Receiver<Msg>) -> Msg {
        loop {
            match rx.recv_timeout(Duration::from_secs(5)) {
                Ok(m @ Msg::Changelog(..)) => return m,
                Ok(m @ Msg::AppStatus(..)) => a.handle(m),
                _ => panic!("no changelog answer"),
            }
        }
    }

    fn answer(a: &mut App, rx: &std::sync::mpsc::Receiver<Msg>) {
        let m = changelog(a, rx);
        a.handle(m);
    }

    #[test]
    fn enter_reads_the_changelog_of_the_selected_app_and_brackets_walk_its_tags() {
        let (mut a, rel, rx) = with_releases();
        press(&mut a, KeyCode::Char(']'));
        assert!(rx.try_recv().is_err(), "a closed pane reads nothing");
        press(&mut a, KeyCode::Enter);
        assert!(
            a.rv.open && a.rv.cl.read.is_none(),
            "reading until it answers"
        );
        answer(&mut a, &rx);
        assert_eq!(a.rv.cl.read.as_ref().unwrap().as_ref().unwrap().tag, "v3");
        press(&mut a, KeyCode::Char('['));
        answer(&mut a, &rx);
        assert_eq!(a.rv.cl.read.as_ref().unwrap().as_ref().unwrap().tag, "v2");
        press(&mut a, KeyCode::Char(']'));
        answer(&mut a, &rx);
        assert_eq!(a.rv.cl.read.as_ref().unwrap().as_ref().unwrap().tag, "v3");
        press(&mut a, KeyCode::Char(']'));
        while let Ok(m) = rx.try_recv() {
            assert!(
                matches!(m, Msg::AppStatus(..)),
                "nothing newer than the newest tag"
            );
        }
        let log = rel.0.lock().unwrap().clone();
        let cl = [
            "release-state changelog --json alpha",
            "release-state changelog --json alpha v2",
            "release-state changelog --json alpha v3",
        ];
        assert_eq!(log, cl, "one read each, for the app the row is on");
    }

    #[test]
    fn the_other_envs_start_open_f_folds_them_and_another_app_starts_open() {
        let (mut a, _rel, rx) = with_releases();
        press(&mut a, KeyCode::Char('F'));
        assert!(!a.rv.others, "a closed pane has no fold to fold");
        press(&mut a, KeyCode::Enter);
        answer(&mut a, &rx);
        assert!(a.rv.others, "the other envs start open");
        press(&mut a, KeyCode::Char('F'));
        assert!(!a.rv.others);
        press(&mut a, KeyCode::Char('j'));
        assert!(a.rv.others, "beta's pane starts open");
        answer(&mut a, &rx);
        press(&mut a, KeyCode::Char('F'));
        press(&mut a, KeyCode::Enter);
        assert!(!a.rv.open && a.rv.others, "closing resets the fold to open");
    }

    #[test]
    fn moving_to_another_project_waits_for_the_read_going_then_reads_the_one_it_rests_on() {
        let (mut a, rel, rx) = with_releases();
        press(&mut a, KeyCode::Enter);
        press(&mut a, KeyCode::Char('j'));
        press(&mut a, KeyCode::Char('k'));
        press(&mut a, KeyCode::Char('j'));
        assert!(a.rv.cl.busy, "one worker, however many moves");
        let alpha = changelog(&mut a, &rx);
        a.handle(alpha);
        assert_eq!(
            a.rv.cl.project, "beta",
            "the answer is for alpha, the row rests on beta"
        );
        assert!(a.rv.cl.read.is_none(), "so beta is being read");
        answer(&mut a, &rx);
        assert_eq!(
            a.rv.cl.read.as_ref().unwrap().as_ref().unwrap().project,
            "beta"
        );
        assert_eq!(rel.0.lock().unwrap().len(), 2);
    }

    #[test]
    fn a_query_that_moves_the_selection_to_another_project_rereads_too() {
        let (mut a, _rel, rx) = with_releases();
        press(&mut a, KeyCode::Enter);
        answer(&mut a, &rx);
        assert_eq!(a.rv.cl.project, "alpha");
        for c in ['/', 'b', 'e', 't', 'a'] {
            press(&mut a, KeyCode::Char(c));
        }
        press(&mut a, KeyCode::Enter);
        assert_eq!(
            a.selected_release().unwrap().project,
            "beta",
            "the query left beta only"
        );
        assert!(a.rv.cl.read.is_none(), "so beta's changelog is being read");
        answer(&mut a, &rx);
        assert_eq!(
            a.rv.cl.read.as_ref().unwrap().as_ref().unwrap().project,
            "beta"
        );
    }

    #[test]
    fn r_on_an_opened_card_opens_that_projects_releases() {
        let mut a = app(Tab::Projects);
        a.pv.open = true;
        a.tv.project = Some(("personal".into(), "garden".into()));
        a.rv.table.view.state = "green".into();
        a.rv.table.view.sort = "status".into();
        a.rv.open = true;
        a.handle(Msg::Input(Event::Key(KeyEvent::from(KeyCode::Char('R')))));
        assert_eq!(a.tab, Tab::Releases);
        assert_eq!(a.rv.table.view.q, "project:garden");
        assert!(a.rv.table.view.state.is_empty() && a.rv.table.view.sort.is_empty());
        assert!(!a.rv.open, "the promise is this project's app, unfiltered");
    }

    #[test]
    fn a_on_an_opened_card_opens_alerts_for_that_project() {
        let mut a = app(Tab::Projects);
        a.pv.open = true;
        a.tv.project = Some(("personal".into(), "garden".into()));
        a.av.table.view.state = "trip".into();
        a.av.open = true;
        a.handle(Msg::Input(Event::Key(KeyEvent::from(KeyCode::Char('A')))));
        assert_eq!(a.tab, Tab::Alerts);
        assert_eq!(a.av.table.view.q, "project:garden");
        assert!(
            a.av.table.view.state.is_empty(),
            "the count line is every row of the project"
        );
        assert!(!a.av.open);
    }

    #[test]
    fn a_query_for_the_releases_tab_sets_its_view_and_opens_no_project() {
        let mut a = app(Tab::Releases);
        a.open_query(Some("project:garden".into()));
        assert_eq!(a.rv.table.view.q, "project:garden");
        assert!(a.pv.want.is_none());
    }

    /// Costs with a token snapshot read, no read left to start.
    fn costs_app(tokens: bool) -> App {
        let mut a = app(Tab::Costs);
        a.costs_read.busy = true;
        let c = hub_core::costs::Costs {
            tokens: tokens.then(Default::default),
            ..Default::default()
        };
        a.handle(Msg::Costs(Box::new(c)));
        a.costs_read.busy = true;
        a
    }

    #[test]
    fn big_k_folds_consumers_on_costs() {
        let k = || Msg::Input(Event::Key(KeyEvent::from(KeyCode::Char('K'))));
        let mut a = costs_app(true);
        assert_eq!(a.cv.consumers, None);
        // Costs opens on Spend: the first K switches to Limits with Consumers open, the second
        // folds it and the third opens it again.
        assert_eq!(a.cv.inner, "spend");
        a.handle(k());
        assert_eq!((a.cv.inner, a.cv.consumers), ("limits", Some(true)));
        a.handle(k());
        assert_eq!(a.cv.consumers, Some(false));
        a.handle(k());
        assert_eq!(a.cv.consumers, Some(true));
    }

    #[test]
    fn a_costs_table_key_seeks_the_table_under_spends_other_sections() {
        let k = |c| Msg::Input(Event::Key(KeyEvent::from(KeyCode::Char(c))));
        let mut a = costs_app(true);
        a.handle(k('w'));
        assert_eq!(
            a.seek,
            Some("table"),
            "w changes the table, so the page shows it"
        );
        a.handle(k('t'));
        assert_eq!((a.cv.inner, a.seek), ("models", Some("sections")));
        // the control: a fold key seeks its own section, not the table
        a.handle(k('y'));
        assert_ne!(a.seek, Some("table"));
    }

    #[test]
    fn left_and_right_switch_costs_inner_tabs_and_hub_tab_names_one() {
        let k = |c| Msg::Input(Event::Key(KeyEvent::from(c)));
        let mut a = costs_app(true);
        assert_eq!(a.cv.inner, "spend", "Costs opens on Spend");
        assert!(screen(&mut a, 100, 60).contains("window:"));
        a.handle(k(KeyCode::Right));
        assert_eq!(a.cv.inner, "limits");
        assert!(
            !screen(&mut a, 100, 60).contains("FLEET 24H"),
            "the fleet figure is Spend's"
        );
        a.handle(k(KeyCode::Left));
        a.handle(k(KeyCode::Left));
        assert_eq!(a.cv.inner, "budget");
        let (t, q) = crate::tabreq::parse("costs budget").unwrap();
        a.handle(Msg::Tab(t, q));
        assert_eq!(a.cv.inner, "budget", "`hub --tab 'costs budget'` opens it");
        // `hub --tab 'costs burn'` and the moved `fleet tokens` land on the holding inner tab
        let (t, q) = crate::tabreq::parse("costs burn").unwrap();
        a.handle(Msg::Tab(t, q));
        assert_eq!((a.cv.inner, a.seek), ("limits", Some("burn")));
        let (t, q) = crate::tabreq::parse("fleet tokens").unwrap();
        a.handle(Msg::Tab(t, q));
        assert_eq!((a.cv.inner, a.seek), ("models", Some("tokens")));
    }

    #[test]
    fn u_folds_and_opens_the_tokens_fold_on_costs_and_goes_to_it_and_big_u_switches_its_window() {
        let k = |c| Msg::Input(Event::Key(KeyEvent::from(c)));
        let mut a = costs_app(true);
        a.cv.inner = "models";
        let s = screen(&mut a, 100, 60);
        assert!(
            s.contains("- WHERE THE TOKENS GO") && s.contains("u folds it"),
            "it starts open: {s}"
        );
        a.handle(k(KeyCode::Char('u')));
        assert_eq!(a.cv.tokens.open, Some(false));
        let s = screen(&mut a, 100, 60);
        assert!(
            s.contains("+ WHERE THE TOKENS GO") && s.contains("u opens it"),
            "{s}"
        );
        a.handle(k(KeyCode::Char('u')));
        assert_eq!(a.cv.tokens.open, Some(true));
        assert_eq!(a.seek, Some("tokens"));
        let s = screen(&mut a, 100, 12);
        assert!(s.contains("WHERE THE TOKENS GO"), "{s}");
        assert_eq!(a.seek, None, "the section is on the page, so seek lands");
        a.handle(k(KeyCode::Char('U')));
        assert!(a.cv.tokens.day);
        assert!(screen(&mut a, 100, 60).contains("yesterday:"));
        a.handle(k(KeyCode::Char('u')));
        assert_eq!(a.cv.tokens.open, Some(false));
        // x clears the view, not the folds.
        a.handle(k(KeyCode::Char('x')));
        assert!(a.cv.tokens.day && a.cv.tokens.open == Some(false));
    }

    #[test]
    fn l_opens_the_langfuse_fold_on_costs_and_typing_keeps_u_and_l_as_text() {
        let k = |c| Msg::Input(Event::Key(KeyEvent::from(c)));
        let mut a = costs_app(true);
        a.cv.inner = "models";
        a.handle(k(KeyCode::Char('l')));
        assert_eq!(a.cv.langfuse, Some(false), "it starts open, so l folds it");
        a.handle(k(KeyCode::Char('l')));
        assert_eq!((a.cv.langfuse, a.seek), (Some(true), Some("langfuse")));
        a.handle(k(KeyCode::Char('/')));
        for c in "ul".chars() {
            a.handle(k(KeyCode::Char(c)));
        }
        assert_eq!(a.cv.typing.as_deref(), Some("ul"), "a query types u and l");
        assert_eq!((a.cv.langfuse, a.cv.tokens.open), (Some(true), None));
    }

    #[test]
    fn u_and_l_wait_for_a_snapshot_so_the_first_one_lands_folded() {
        let k = |c| Msg::Input(Event::Key(KeyEvent::from(c)));
        let mut a = costs_app(false);
        a.cv.inner = "models";
        a.handle(k(KeyCode::Char('u')));
        a.handle(k(KeyCode::Char('U')));
        a.handle(k(KeyCode::Char('l')));
        assert_eq!(
            (a.cv.tokens.open, a.cv.tokens.day, a.cv.langfuse),
            (None, false, None)
        );
        assert!(screen(&mut a, 100, 60).contains("no snapshot in ~/.agent/token-usage"));
    }

    #[test]
    fn hub_tab_fleet_tokens_opens_the_fold_on_costs() {
        let mut a = app(Tab::Home);
        a.costs_read.busy = true;
        let (t, q) = crate::tabreq::parse("fleet tokens").unwrap();
        a.handle(Msg::Tab(t, q));
        assert_eq!(a.tab, Tab::Costs);
        assert!(a.fleet_page.is_none());
        assert_eq!(a.cv.tokens.open, Some(true));
        assert_eq!(a.seek, Some("tokens"));
        assert!(a.cv.q.is_empty(), "a section's name is no query");
    }

    #[test]
    fn a_new_token_snapshot_rereads_costs_only_while_it_is_shown() {
        let mut a = costs_app(true);
        a.handle(Msg::TokenFiles);
        assert!(a.costs_read.again, "Costs asks for its read again");
        // Negative control: on Fleet a snapshot is nothing to read.
        let mut a = app(Tab::Fleet);
        a.fleet_read.busy = true;
        a.costs_read.busy = true;
        a.handle(Msg::TokenFiles);
        assert!(!a.costs_read.again && !a.fleet_read.again);
    }

    #[test]
    fn before_the_first_answer_it_says_it_is_reading() {
        let mut a = app(Tab::Infra);
        assert!(screen(&mut a, 80, 10).contains("Reading Prometheus..."));
        a.infra_open = Some(Opened::Jobs);
        assert!(screen(&mut a, 80, 10).contains("Reading jobs..."));
    }

    #[test]
    fn a_failed_fleet_bench_draws_the_fallbacks() {
        let (tx, _rx) = std::sync::mpsc::channel();
        let mut a = log_app(tx);
        a.forecast = Some(Forecast::read_with("hub-test-no-such-fleet-bench"));
        a.runner = Arc::new(Fake::default());
        a.handle(key('f'));
        let s = screen(&mut a, 160, 200);
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
        a.infra_open = Some(Opened::Jobs);
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
        a.handle(key('4'));
        assert_eq!(a.tab, Tab::Sessions);
        a.handle(key('2'));
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
        a.infra = Some(board::tests::built(&board::tests::fixture()));
        a.jobs = Some(Jobs {
            at: 0,
            window_secs: 86400,
            jobs: vec![hub_core::jobs::Job::new(
                hub_core::jobs::Source::Unity,
                "gate",
                hub_core::jobs::State::Done,
            )],
            errors: vec![],
            ci: None,
        });
        a
    }

    /// The first body line under the tab bar.
    fn top(s: &str) -> &str {
        s.lines().nth(1).unwrap_or("")
    }

    #[test]
    fn entering_alerts_reads_the_reds_then_draws_the_join() {
        let (tx, rx) = std::sync::mpsc::channel();
        let mut a = with_tx(Tab::Home, tx);
        a.infra = Some(board::tests::fixture());
        // The join's file reads are hub_core::alerts', tested there: no real watch dir here.
        a.alerts_read.busy = true;
        a.handle(Msg::Tab(Tab::Alerts, None));
        // The read went through the app's runner (the Fake), never a real fleet-bench.
        let m = rx.recv_timeout(std::time::Duration::from_secs(5)).unwrap();
        assert!(matches!(m, Msg::Reds(Ok(_))));
        assert!(screen(&mut a, 160, 20).contains("Reading Prometheus and fleet-bench reds..."));
        a.handle(Msg::Reds(Err("reds: cannot read the queue".into())));
        // Both held, the join is asked for (here: queued behind the one marked running).
        assert!(a.alerts_read.again);
        a.alerts = Some(hub_core::alerts::join(
            a.infra.as_ref().unwrap(),
            Ok(vec![]),
            a.reds.clone().unwrap(),
            Ok(String::new()),
            0,
        ));
        let s = screen(&mut a, 160, 80);
        let at = |w: &str| s.find(w).unwrap_or_else(|| panic!("no {w} in {s}"));
        assert!(
            at("HEALTH") < at("FIRING  3") && at("FIRING  3") < at("watch mac_studio_mlx"),
            "{s}"
        );
        assert!(!s.contains("FIXES"), "Fixes is its own inner tab: {s}");
        a.av.inner = "fixes";
        assert!(screen(&mut a, 160, 80).contains("FIXES  read failed"));
        assert!(
            s.contains("fleet-bench reds: reds: cannot read the queue"),
            "{s}"
        );
        assert!(!s.contains("MACHINE "), "the machines are Infra's: {s}");
    }

    /// The open Infra page's kind and name.
    fn open(a: &App) -> Option<(Kind, &str)> {
        a.infra_page.as_ref().map(|p| (p.kind(), p.name()))
    }

    #[test]
    fn enter_on_a_machines_row_opens_its_page_and_esc_comes_back() {
        let mut a = infra_app();
        a.go(Tab::Infra);
        a.infra_inner = "machines";
        // No Prometheus in a test: the page's read is held, and its answer handed in below.
        a.infra_page_read.busy = true;
        assert!(a.hints().contains("j/k pick  Enter open"), "{}", a.hints());
        let n = a.infra.as_ref().unwrap().machines.len();
        // G comes with SHIFT, as a terminal sends it: it still picks the last row.
        a.handle(Msg::Input(Event::Key(KeyEvent::new(
            KeyCode::Char('G'),
            KeyModifiers::SHIFT,
        ))));
        assert_eq!(a.itab.views[0].sel, n - 1, "G picks the last machine");
        a.handle(key('g'));
        let want = a.infra.as_ref().unwrap().machines[1].host.clone();
        a.handle(key('j'));
        assert!(a.itab.follow, "a moved selection is kept in view");
        a.handle(Msg::Input(Event::Key(KeyEvent::from(KeyCode::Enter))));
        assert_eq!(open(&a), Some((Kind::Machine, want.as_str())));
        assert!(screen(&mut a, 160, 30).contains(&format!("Reading {want}...")));
        let page = hub_core::machine_page::MachinePage {
            host: want.clone(),
            head: format!("{want}, local, up"),
            ..Default::default()
        };
        a.handle(Msg::InfraPage(Box::new(InfraPage::Machine(
            want.clone(),
            Some(Ok(page)),
        ))));
        let s = screen(&mut a, 160, 40);
        assert!(
            s.contains(&want.to_uppercase()) && s.contains("SHARE"),
            "{s}"
        );
        assert!(a.hints().contains("Esc all machines"), "{}", a.hints());
        a.handle(Msg::Input(Event::Key(KeyEvent::from(KeyCode::Esc))));
        assert!(a.infra_page.is_none());
        assert!(screen(&mut a, 160, 40).contains("MACHINES"));
    }

    #[test]
    fn a_link_to_a_machine_and_its_tab_request_open_its_page_and_a_wrong_name_says_so() {
        let mut a = infra_app();
        a.infra_page_read.busy = true;
        a.follow(&hub_core::links::Link::to(Kind::Machine, "workstation"));
        assert_eq!(
            (a.tab, a.infra_inner, open(&a)),
            (Tab::Infra, "machines", Some((Kind::Machine, "workstation")))
        );
        a.close_infra_page();
        a.go(Tab::Home);
        a.handle(Msg::Tab(Tab::Infra, Some("machines/nope".into())));
        assert_eq!(open(&a), Some((Kind::Machine, "nope")));
        a.handle(Msg::InfraPage(Box::new(InfraPage::Machine(
            "nope".into(),
            Some(Err("no machine named nope".into())),
        ))));
        assert!(screen(&mut a, 160, 30).contains("no machine named nope"));
        // A late answer for another host does not land on this page.
        a.handle(Msg::InfraPage(Box::new(InfraPage::Machine(
            "other".into(),
            Some(Ok(Default::default())),
        ))));
        assert!(matches!(
            a.infra_page,
            Some(InfraPage::Machine(_, Some(Err(_))))
        ));
        // Nor does one for a pool of the same name.
        a.handle(Msg::InfraPage(Box::new(InfraPage::Pool(
            "nope".into(),
            Some(Ok(Default::default())),
        ))));
        assert!(matches!(
            a.infra_page,
            Some(InfraPage::Machine(_, Some(Err(_))))
        ));
    }

    #[test]
    fn enter_on_a_pools_row_opens_its_page_a_link_and_tab_request_do_too_and_esc_comes_back() {
        let mut a = infra_app();
        a.go(Tab::Infra);
        a.infra_inner = "machines";
        // No Prometheus in a test: the page's read is held, and its answer handed in below.
        a.infra_page_read.busy = true;
        // c hands the table keys to Pools, the next table on Machines.
        a.handle(key('c'));
        let want = a.infra.as_ref().unwrap().pools[0].pool.clone();
        a.handle(Msg::Input(Event::Key(KeyEvent::from(KeyCode::Enter))));
        assert_eq!(open(&a), Some((Kind::Pool, want.as_str())));
        assert!(screen(&mut a, 160, 30).contains(&format!("Reading {want}...")));
        let page = hub_core::pool_page::PoolPage {
            pool: want.clone(),
            head: format!("{want}, 1/3 busy, 2 waiting"),
            ..Default::default()
        };
        a.handle(Msg::InfraPage(Box::new(InfraPage::Pool(
            want.clone(),
            Some(Ok(page)),
        ))));
        let s = screen(&mut a, 160, 40);
        assert!(
            s.contains(&want.to_uppercase()) && s.contains("WAITING"),
            "{s}"
        );
        assert!(a.hints().contains("Esc all pools"), "{}", a.hints());
        a.handle(Msg::Input(Event::Key(KeyEvent::from(KeyCode::Esc))));
        assert!(a.infra_page.is_none());
        assert!(screen(&mut a, 160, 40).contains("POOLS"));
        // A link opens it, and a machine's page then closes it: one page at a time.
        a.follow(&hub_core::links::Link::to(Kind::Pool, "unity"));
        assert_eq!(
            (a.tab, a.infra_inner, open(&a)),
            (Tab::Infra, "machines", Some((Kind::Pool, "unity")))
        );
        a.follow(&hub_core::links::Link::to(Kind::Machine, "workstation"));
        assert_eq!(open(&a), Some((Kind::Machine, "workstation")));
        a.go(Tab::Home);
        a.handle(Msg::Tab(Tab::Infra, Some("pools/nope".into())));
        assert_eq!(open(&a), Some((Kind::Pool, "nope")));
        a.handle(Msg::InfraPage(Box::new(InfraPage::Pool(
            "nope".into(),
            Some(Err("no pool named nope".into())),
        ))));
        assert!(screen(&mut a, 160, 30).contains("no pool named nope"));
        // A late answer for another pool does not land on this page.
        a.handle(Msg::InfraPage(Box::new(InfraPage::Pool(
            "other".into(),
            Some(Ok(Default::default())),
        ))));
        assert!(matches!(
            a.infra_page,
            Some(InfraPage::Pool(_, Some(Err(_))))
        ));
    }

    #[test]
    fn the_alerts_keys_switch_inner_tabs_move_open_filter_and_follow_a_fix_to_its_queue_item() {
        let mut a = app(Tab::Alerts);
        a.alerts = Some(crate::alertstab::tests::sample());
        let enter = || Msg::Input(Event::Key(KeyEvent::from(KeyCode::Enter)));
        let esc = || Msg::Input(Event::Key(KeyEvent::from(KeyCode::Esc)));
        assert!(a.hints().contains("Enter open"), "{}", a.hints());
        // Enter opens the selected row's watch under it; j moves to the next row.
        a.handle(enter());
        assert!(screen(&mut a, 160, 60).contains("What it checks the nightly on main"));
        a.handle(key('j'));
        assert_eq!(
            a.av.selected(a.alerts.as_ref().unwrap())
                .map(|r| r.what.as_str()),
            Some("dream")
        );
        // Esc shuts the row first, then clears a view, then is no longer the tab's.
        a.handle(esc());
        assert!(!a.av.open);
        a.handle(key('f'));
        assert_eq!(a.av.table.view.state, "trip");
        assert!(!screen(&mut a, 160, 60).contains("dream  sentinel"));
        a.handle(esc());
        assert!(a.av.table.is_default());
        assert!(!a.alerts_key(KeyEvent::from(KeyCode::Esc)));
        // Right shows Watches in place of the firing table, whose keys rest there; Left is back.
        assert!(!screen(&mut a, 160, 80).contains("LAST RUN"));
        a.scroll = 5;
        a.handle(Msg::Input(Event::Key(KeyEvent::from(KeyCode::Right))));
        a.handle(Msg::Input(Event::Key(KeyEvent::from(KeyCode::Right))));
        assert_eq!((a.av.on(), a.scroll), ("watches", 0));
        let s = screen(&mut a, 160, 80);
        assert!(s.contains("LAST RUN") && !s.contains("SOURCE"), "{s}");
        assert!(
            s.contains("+1 ok (w shows them)") && !s.contains("disk"),
            "{s}"
        );
        a.handle(key('w'));
        assert!(
            screen(&mut a, 160, 80).contains("disk"),
            "w shows the ok watches"
        );
        a.handle(key('w'));
        assert!(
            !screen(&mut a, 160, 80).contains("disk"),
            "and folds them again"
        );
        assert!(
            !a.alerts_key(KeyEvent::from(KeyCode::Char('f'))),
            "no table here"
        );
        assert!(a.hints().contains("<-/-> view") && !a.hints().contains("Enter open"));
        assert!(!a.hints().contains("n/N"), "Left/Right step the inner tabs");
        a.handle(Msg::Input(Event::Key(KeyEvent::from(KeyCode::Left))));
        a.handle(Msg::Input(Event::Key(KeyEvent::from(KeyCode::Left))));
        assert_eq!(a.av.on(), "firing");
        assert!(!a.hints().contains("n/N"), "{}", a.hints());
        // `w` from another inner tab opens Watches at its top, as Left/Right do.
        a.scroll = 7;
        a.handle(key('w'));
        assert_eq!((a.av.on(), a.scroll), ("watches", 0));
        a.av.inner = "firing";
        // A section word opens the inner tab holding it, as `hub --tab 'alerts history'` does.
        a.open_query(Some("history".into()));
        assert_eq!((a.av.on(), a.seek), ("history", Some("history")));
        a.open_query(Some("health".into()));
        assert_eq!(a.av.on(), "firing", "Health opens with Firing");
        a.av.inner = "firing";
        // i takes the selected row's fix to its queue item; a row with no fix keeps the key.
        a.av.table.sel = 0;
        a.handle(key('i'));
        assert_eq!((a.tab, a.qv.table.view.q.as_str()), (Tab::Queue, "ar-9"));
    }

    #[test]
    fn d_takes_the_keys_only_for_a_read_deliverables_table_and_p_leaves_its_search_alone() {
        let (tx, _rx) = std::sync::mpsc::channel();
        let mut a = with_tx(Tab::Projects, tx);
        a.deliverables_read.busy = true;
        a.handle(Msg::Projects(Box::new(loaded())));
        // still reading, or failed: d does nothing, the list keeps the keys
        a.handle(key('d'));
        assert!(!a.pv.dfocus);
        a.deliverables = Some(Err("fleet-bench epics: exit 2".into()));
        a.handle(key('d'));
        assert!(!a.pv.dfocus);
        // read: d moves the keys, / types into the table's search (a capital P is text there)
        a.deliverables = Some(Ok(hub_core::deliverables::Deliverables::default()));
        a.handle(key('d'));
        assert!(a.pv.dfocus);
        a.handle(key('/'));
        assert!(a.hints().contains("type, Enter submits"), "{}", a.hints());
        a.handle(key('P'));
        assert_eq!(a.pv.dv.typing.as_deref(), Some("P"));
        assert!(a.prv.said.is_none() && a.tv.said.is_none());
    }

    #[test]
    fn the_tick_rereads_red_fixes_only_after_reds_refresh_and_r_reads_at_once() {
        let (tx, _rx) = std::sync::mpsc::channel();
        let mut a = with_tx(Tab::Alerts, tx);
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
        let s = screen(&mut a, 160, 12);
        assert_eq!(a.tab, Tab::Infra);
        assert!(top(&s).starts_with("CI RUNNERS  2 hosts"), "{s}");
        // Machines the same way, its headline numbers first, and n/N step between the section
        // headings from there (a short screen, so the pools are a scroll away).
        let (t, q) = crate::tabreq::parse("machines").unwrap();
        a.handle(Msg::Tab(t, q));
        let s = screen(&mut a, 160, 6);
        assert!(top(&s).starts_with("nodes "), "{s}");
        a.handle(key('n'));
        let s = screen(&mut a, 160, 6);
        assert!(top(&s).starts_with("POOLS  all"), "{s}");
        a.handle(key('N'));
        assert!(top(&screen(&mut a, 160, 6)).starts_with("nodes "));
    }

    #[test]
    fn printed_infra_shows_every_inner_tab_under_the_strip() {
        let mut a = infra_app();
        a.handle(key('9'));
        a.infra_all = true;
        let s = screen(&mut a, 160, 400);
        let at = |t: &str| s.find(t).unwrap_or_else(|| panic!("{t} missing: {s}"));
        for w in [
            "[Machines]",
            "MACHINES  all",
            "POOLS  all",
            "CI RUNNERS",
            "RUNNERS  all",
            "WAITING  all",
            "LOCAL UNITY",
            "PIPELINES",
            "Enter opens",
        ]
        .windows(2)
        {
            assert!(at(w[0]) < at(w[1]), "{} after {}: {s}", w[1], w[0]);
        }
    }

    #[test]
    fn infra_leads_with_its_strip_and_left_right_switch() {
        let mut a = infra_app();
        a.handle(key('9'));
        let s = screen(&mut a, 160, 200);
        let bar = s.lines().next().unwrap();
        assert!(
            bar.contains("8 Alerts  9 Infra") && !bar.contains("Machines"),
            "{s}"
        );
        assert!(
            top(&s).starts_with("[Machines] Runners  Runs  Pipelines  Tests  Jobs   <- -> switch"),
            "the strip is the first line: {s}"
        );
        // What is red is Alerts' now: no health, red now or fixes here.
        assert!(
            !s.contains("HEALTH") && !s.contains("RED NOW") && !s.contains("RED FIXES"),
            "{s}"
        );
        // Machines holds the machines and the pools, in that order; CI is its own. The governor
        // and cloud power are machine columns.
        assert_eq!(a.infra_inner, "machines");
        let at = |s: &str, t: &str| s.find(t).unwrap_or_else(|| panic!("{t} missing: {s}"));
        assert!(at(&s, "MACHINES  all") < at(&s, "POOLS  all"), "{s}");
        assert!(at(&s, "GOVERNOR") < at(&s, "POOLS  all"), "{s}");
        assert!(!s.contains("CI RUNNERS"), "{s}");
        let right = || Msg::Input(Event::Key(KeyEvent::from(KeyCode::Right)));
        a.handle(right());
        let s = screen(&mut a, 160, 200);
        assert!(top(&s).starts_with(" Machines [Runners]"), "{s}");
        assert!(s.contains("CI RUNNERS") && !s.contains("POOLS  all"), "{s}");
        // Runs, Pipelines and Tests, then Jobs.
        for (inner, title) in [
            ("runs", "RUNS"),
            ("pipelines", "PIPELINES"),
            ("tests", "TESTS"),
        ] {
            a.handle(right());
            assert_eq!(a.infra_inner, inner);
            let s = screen(&mut a, 160, 200);
            assert!(s.contains(title) && !s.contains("CI RUNNERS"), "{s}");
        }
        a.handle(right());
        let s = screen(&mut a, 160, 200);
        assert!(
            top(&s).starts_with(" Machines  Runners  Runs  Pipelines  Tests [Jobs]"),
            "{s}"
        );
        assert!(
            s.contains("Enter opens the table") && !s.contains("POOLS  all"),
            "{s}"
        );
        // Right from the last wraps to the first, Left back again.
        a.handle(right());
        assert_eq!(a.infra_inner, "machines");
        a.handle(Msg::Input(Event::Key(KeyEvent::from(KeyCode::Left))));
        assert_eq!(a.infra_inner, "jobs");
        // An inner tab's own name opens it; a name that moved goes to its new tab.
        let (t, q) = crate::tabreq::parse("infra machines").unwrap();
        a.handle(Msg::Tab(t, q));
        assert_eq!(a.infra_inner, "machines");
        // The old CI inner tab's words land on Runners; each new inner tab's name opens it.
        for (req, inner) in [
            ("infra ci", "runners"),
            ("ci", "runners"),
            ("infra runners", "runners"),
            ("infra pipelines", "pipelines"),
            ("infra runs", "runs"),
            ("infra tests", "tests"),
        ] {
            let (t, q) = crate::tabreq::parse(req).unwrap();
            a.handle(Msg::Tab(t, q));
            assert_eq!((a.tab, a.infra_inner), (Tab::Infra, inner), "{req}");
            a.infra_open = None;
        }
        a.alerts_read.busy = true;
        a.reds_read.busy = true;
        let (t, q) = crate::tabreq::parse("infra red").unwrap();
        a.handle(Msg::Tab(t, q));
        assert_eq!((a.tab, a.seek), (Tab::Alerts, Some("firing")));
    }

    #[test]
    fn infra_table_keys_go_to_the_inner_tabs_table_and_c_passes_them_on() {
        let mut a = infra_app();
        a.handle(key('9'));
        assert_eq!(a.infra_inner, "machines");
        a.handle(key('f'));
        assert_eq!(a.itab.views[0].view.state, "busy");
        assert!(
            a.infra_open != Some(Opened::Jobs),
            "f is the machines table's, not the jobs table's"
        );
        a.handle(key('c'));
        a.handle(key('f'));
        assert!(
            !a.itab.views[1].view.is_default(),
            "c gave the keys to the pools"
        );
        // A `c` typed into a query is the query's.
        a.handle(key('/'));
        a.handle(key('c'));
        assert_eq!(a.itab.views[1].typing.as_deref(), Some("c"));
        // Esc drops the draft, then clears the view, then is the page's again.
        for _ in 0..2 {
            a.handle(Msg::Input(Event::Key(KeyEvent::from(KeyCode::Esc))));
        }
        assert!(a.itab.views[1].is_default());
        // The old Governor and Cloud names open Machines under their chips.
        for (word, chip) in [("infra governor", "governed"), ("infra cloud", "cloud")] {
            let (t, q) = crate::tabreq::parse(word).unwrap();
            a.handle(Msg::Tab(t, q));
            assert_eq!((a.tab, a.infra_inner), (Tab::Infra, "machines"), "{word}");
            assert_eq!(a.itab.views[0].view.state, chip, "{word}");
            assert_eq!(a.itab.focus("machines"), Some(0), "{word}");
        }
    }

    #[test]
    fn infra_draws_its_strip_first_while_prometheus_is_still_read() {
        let mut a = app(Tab::Infra);
        a.infra = None;
        let body: Vec<String> = a.body(160).0.iter().map(crate::fit::plain).collect();
        assert!(
            body[0].starts_with("[Machines] Runners  Runs  Pipelines  Tests  Jobs"),
            "{body:?}"
        );
        assert_eq!(body[1], "Reading Prometheus...");
    }

    #[test]
    fn infra_strip_counts_red_ci_lines_on_runners_and_red_pipelines() {
        let mut a = infra_app();
        a.tab = Tab::Infra;
        let strip = |a: &App| {
            a.body(160)
                .0
                .iter()
                .map(crate::fit::plain)
                .find(|l| l.contains("<- -> switch"))
                .unwrap()
        };
        assert!(
            strip(&a).starts_with("[Machines] Runners  Runs  Pipelines  Tests  Jobs"),
            "{}",
            strip(&a)
        );
        if let Some(i) = a.infra.as_mut() {
            i.ci.red = vec!["queued job needs gpu".into()];
        }
        assert!(
            strip(&a).starts_with("[Machines] Runners 1  Runs"),
            "{}",
            strip(&a)
        );
        // A red pipeline counts on Pipelines.
        a.pipes = Some(hub_core::pipelines::Pipelines {
            red: 2,
            ..Default::default()
        });
        assert!(strip(&a).contains("  Pipelines 1  "), "{}", strip(&a));
    }

    #[test]
    fn infra_body_fits_80_columns() {
        // `hub --once` prints body lines as they are, with no terminal to cut them (rule 11).
        let mut a = infra_app();
        a.tab = Tab::Infra;
        a.infra_inner = "jobs";
        let lines = a.body(80).0;
        assert!(lines
            .iter()
            .any(|l| crate::fit::plain(l).contains("Enter opens")));
        for l in lines {
            let t = crate::fit::plain(&l);
            assert!(
                unicode_width::UnicodeWidthStr::width(t.as_str()) <= 80,
                "{t}"
            );
        }
    }

    #[test]
    fn enter_opens_the_jobs_table_and_esc_comes_back() {
        let mut a = infra_app();
        a.handle(key('9'));
        // On Machines and CI, Enter opens the selected row's record; on Jobs, the jobs table.
        a.infra_inner = "jobs";
        a.handle(Msg::Input(Event::Key(KeyEvent::from(KeyCode::Enter))));
        assert_eq!(a.infra_open, Some(Opened::Jobs));
        let s = screen(&mut a, 120, 20);
        assert!(top(&s).starts_with("all 1  running 0"), "{s}");
        assert!(s.lines().last().unwrap().contains("Esc back"), "{s}");
        // A filter clears first; the next Esc goes back to the summary.
        a.handle(key('f'));
        a.handle(Msg::Input(Event::Key(KeyEvent::from(KeyCode::Esc))));
        assert_eq!(a.infra_open, Some(Opened::Jobs));
        a.handle(Msg::Input(Event::Key(KeyEvent::from(KeyCode::Esc))));
        assert_ne!(a.infra_open, Some(Opened::Jobs));
        assert_eq!(
            a.infra_inner, "jobs",
            "Esc comes back to the Jobs inner tab"
        );
        // `hub --tab jobs` opens the table straight away.
        let (t, q) = crate::tabreq::parse("jobs").unwrap();
        a.handle(Msg::Tab(t, q));
        assert_eq!(a.infra_open, Some(Opened::Jobs));
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
            bar.starts_with(" HUB  1  2  3  4  5  6  7  8  9  0 Schedules  Costs "),
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
        (a.alerts_read.busy, a.reds_read.busy) = (true, true);
        a.handle(key('8'));
        assert_eq!((a.tab, a.seek), (Tab::Alerts, None));
        a.handle(key('9'));
        assert_eq!((a.tab, a.seek), (Tab::Infra, None));
        a.handle(key('2'));
        assert_eq!(a.tab, Tab::Log);
        a.schedules_read.busy = true;
        a.handle(key('0'));
        assert_eq!(a.tab, Tab::Schedules, "0 opens the tenth tab");
        a.costs_read.busy = true;
        a.handle(Msg::Input(Event::Key(KeyEvent::from(KeyCode::Tab))));
        assert_eq!(
            a.tab,
            Tab::Costs,
            "Tab reaches the eleventh, which has no digit"
        );
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
        assert_eq!(a.infra_open, Some(Opened::Jobs));
        a.handle(esc());
        assert!(a.infra_open != Some(Opened::Jobs) && !a.quit);
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
            hub_core::jobs::Source::Unity,
            "gate",
            hub_core::jobs::State::Done,
        );
        j.url = Some("https://example.test/run/1".into());
        a.jobs = Some(Jobs {
            at: 0,
            window_secs: 86400,
            jobs: vec![j],
            errors: vec![],
            ci: None,
        });
        a.handle(Msg::Input(Event::Key(KeyEvent::from(KeyCode::Enter))));
        let s = screen(&mut a, 100, 20);
        assert!(s.contains("--- log: unity gate"), "{s}");
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
            ci: None,
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
