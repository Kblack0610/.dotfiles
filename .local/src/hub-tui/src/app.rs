//! `hub`: the state, the keys and the drawing. Reads run in worker threads and come back as
//! messages; a read asked for while one is running is coalesced into one more after it.

use std::path::{Path, PathBuf};
use std::sync::mpsc::Sender;
use std::sync::Arc;
use std::time::Duration;

use hub_core::boards::{self, DayRow, Watch};
use hub_core::infra::Infra;
use hub_core::jobs::{self, Jobs, LogRef, Opts, Paths};
use hub_core::session_actions::{self as actions, Action, Runner, Snapshot};
use ratatui::crossterm::event::{Event, KeyCode, KeyEvent, KeyEventKind, KeyModifiers};
use ratatui::layout::{Constraint, Layout, Rect};
use ratatui::text::{Line, Span};
use ratatui::widgets::Paragraph;
use ratatui::Frame;

use crate::controls::{Ask, Controls};
use crate::fmt::{clock, Palette};
use crate::forecast::{self, Forecast};
use crate::jobs::{clean, row_id, JobsView, LogPane};
use crate::{board, day, fleet, fleettab};

/// How often Prometheus is read again, and the job sources with no file to watch (CI, k8s,
/// timers in the journal). A genuine UI cadence: Prometheus has no push, and its rules
/// evaluate every 30-60s anyway.
pub const PROM_REFRESH: Duration = Duration::from_secs(60);

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Tab {
    Overview,
    Jobs,
    Ci,
    Machines,
    Sessions,
    Forecast,
    Today,
    History,
    Fleet,
}

impl Tab {
    pub const ALL: [Tab; 9] = [
        Tab::Overview,
        Tab::Jobs,
        Tab::Ci,
        Tab::Machines,
        Tab::Sessions,
        Tab::Forecast,
        Tab::Today,
        Tab::History,
        Tab::Fleet,
    ];
    pub fn title(self) -> &'static str {
        match self {
            Tab::Overview => "Overview",
            Tab::Jobs => "Jobs",
            Tab::Ci => "CI",
            Tab::Machines => "Machines",
            Tab::Sessions => "Sessions",
            Tab::Forecast => "Forecast",
            Tab::Today => "Today",
            Tab::History => "History",
            Tab::Fleet => "Fleet",
        }
    }
    pub fn parse(s: &str) -> Option<Tab> {
        Tab::ALL
            .into_iter()
            .find(|t| t.title().eq_ignore_ascii_case(s))
    }
    fn index(self) -> usize {
        Tab::ALL.iter().position(|t| *t == self).unwrap_or(0)
    }
    /// The Grafana dashboard that keeps this page's trends; the file-fed pages have none.
    fn dashboard(self) -> Option<&'static str> {
        match self {
            Tab::Overview => Some("kb-command-center"),
            Tab::Jobs | Tab::Ci => Some("kb-ci-runners"),
            Tab::Machines => Some("kb-fleet"),
            Tab::Sessions | Tab::Forecast | Tab::Today | Tab::History | Tab::Fleet => None,
        }
    }
}

/// The files the Sessions, Today and History tabs are read from.
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
    /// `hub tab <name>` asked for a page (tabreq.rs).
    Tab(Tab),
    Boards(Box<Boards>),
    Infra(Box<Infra>),
    Jobs(Box<Jobs>),
    Forecast(Box<Forecast>),
    Fleet(Box<hub_core::fleet::Fleet>),
    Log(u64, Result<String, String>),
    /// The live and parked agent sessions, for the Sessions tab's controls.
    Sessions(Box<Snapshot>),
    /// A session action ended: its output, or why it failed.
    Acted(Result<String, String>),
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
    /// Where the Today tab's sections start, from the last draw (n/N jump between them).
    sections: Vec<usize>,
    /// Lines scrolled down on every page but Jobs.
    pub scroll: usize,
    pub quit: bool,
    tx: Sender<Msg>,
    infra_read: Read,
    jobs_read: Read,
    boards_read: Read,
    forecast_read: Read,
    fleet_read: Read,
    sessions_read: Read,
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
            controls: Controls::default(),
            runner: Arc::new(actions::System),
            gather: actions::gather,
            day: None,
            hist_sel: 0,
            sections: vec![],
            scroll: 0,
            quit: false,
            tx,
            infra_read: Read::default(),
            jobs_read: Read::default(),
            boards_read: Read::default(),
            forecast_read: Read::default(),
            fleet_read: Read::default(),
            sessions_read: Read::default(),
            log_gen: 0,
            page: 20,
            watch_failed: None,
            tab_failed: None,
        }
    }

    /// The directories to watch: agentctl's ledger and run markers and the Unity gate ledger (a
    /// job started or ended), then the board files.
    pub fn watched(&self) -> Vec<(PathBuf, bool)> {
        let mut v = vec![
            (self.paths.agentctl.clone(), true),
            (self.files.shepherd.clone(), false),
            (self.files.daylog.clone(), false),
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

    /// fleet-bench writes no file to watch, so the Forecast tab is read on the tick, and only
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
            let r = match r {
                Ok(out) if out.trim().is_empty() => Ok(format!("{label}: done")),
                Ok(out) => Ok(format!(
                    "{label}: {}",
                    out.lines().collect::<Vec<_>>().join("; ")
                )),
                Err(e) => Err(format!("{label}: {e}")),
            };
            let _ = tx.send(Msg::Acted(r));
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
                }
                if self.tab == Tab::Forecast {
                    self.read_forecast();
                }
                if self.tab == Tab::Fleet {
                    self.read_fleet();
                }
                if self.tab == Tab::Sessions {
                    self.read_sessions();
                }
            }
            Msg::Files => {
                self.read_jobs();
                if self.tab == Tab::Fleet {
                    self.read_fleet();
                }
            }
            Msg::BoardFiles => self.read_boards(),
            Msg::Tab(t) => self.go(t),
            Msg::Boards(b) => {
                self.boards = Some(*b);
                if self.boards_read.done() {
                    self.read_boards();
                }
            }
            Msg::Forecast(f) => {
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
        if self.tab == Tab::Jobs && self.jobs_key(k) {
            return;
        }
        if self.tab == Tab::Today && self.today_key(k) {
            return;
        }
        if self.tab == Tab::History && self.history_key(k) {
            return;
        }
        if self.tab == Tab::Sessions && self.sessions_key(k) {
            return;
        }
        let n = self.page.max(1);
        let tabs = Tab::ALL.len();
        match k.code {
            KeyCode::Char('q') => self.quit = true,
            KeyCode::Char(c @ '1'..='9') => {
                if let Some(t) = Tab::ALL.get(c as usize - '1' as usize) {
                    self.go(*t);
                }
            }
            KeyCode::Tab => self.go(Tab::ALL[(self.tab.index() + 1) % tabs]),
            KeyCode::BackTab => self.go(Tab::ALL[(self.tab.index() + tabs - 1) % tabs]),
            KeyCode::Char('r') => {
                self.read_infra();
                self.read_jobs();
                self.read_boards();
                if self.tab == Tab::Forecast {
                    self.read_forecast();
                }
                if self.tab == Tab::Fleet {
                    self.read_fleet();
                }
                if self.tab == Tab::Sessions {
                    self.read_sessions();
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

    fn go(&mut self, t: Tab) {
        self.tab = t;
        self.scroll = 0;
        if t == Tab::Forecast {
            self.read_forecast();
        }
        if t == Tab::Fleet {
            self.read_fleet();
        }
        if t == Tab::Sessions {
            self.read_sessions();
        }
    }

    /// Sessions' own keys (controls.rs): j/k pick a session, a letter arms an action's
    /// confirm, and with one armed every key is the confirm's. The page scrolls with
    /// PgUp/PgDn, space and g/G, and keeps the selected row in view.
    fn sessions_key(&mut self, k: KeyEvent) -> bool {
        match self.controls.key(k) {
            Ask::Pass => return false,
            Ask::Done => {}
            Ask::Run(t, a, acct) => self.act(t, a, acct),
        }
        // The title and the table header sit above the first row.
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
            KeyCode::Char('n') => {
                if let Some(s) = self.sections.iter().find(|s| **s > self.scroll) {
                    self.scroll = *s;
                }
            }
            KeyCode::Char('N') => {
                if let Some(s) = self.sections.iter().rev().find(|s| **s < self.scroll) {
                    self.scroll = *s;
                } else {
                    self.scroll = 0;
                }
            }
            _ => return false,
        }
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
        self.page = body.height.saturating_sub(2) as usize;
        if self.tab == Tab::Jobs {
            self.draw_jobs(f, body);
        } else if self.tab == Tab::History && self.boards.is_some() {
            self.draw_history(f, body);
        } else {
            let (lines, sections) = self.body(body.width as usize);
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
        for (i, t) in Tab::ALL.iter().enumerate() {
            let label = format!(" {} {} ", i + 1, t.title());
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
        let tabs = format!("1-{}", Tab::ALL.len());
        match self.tab {
            Tab::Jobs if self.jv.typing.is_some() => "type to search, Enter applies, Esc clears".into(),
            Tab::Jobs if self.jv.log.is_some() => {
                "Esc close log  J/K PgUp/PgDn scroll log  j/k move  o open url  q quit".into()
            }
            Tab::Jobs => format!(
                "Enter log  s source  f state  / search  h history  o open url  r refresh  {tabs} tabs  q quit"
            ),
            Tab::Sessions if self.controls.confirm.is_some() => {
                "y/Enter yes  n/Esc no  Left/Right account (move)".into()
            }
            Tab::Sessions => format!(
                "j/k pick  i p u m x c act  PgUp/PgDn scroll  r refresh  {tabs} tabs  q quit"
            ),
            Tab::Forecast | Tab::Fleet => {
                format!("{tabs}/Tab pages  j/k PgUp/PgDn scroll  r refresh  q quit")
            }
            Tab::Today if self.day.is_some() => {
                format!("[ ] day  t today  n/N section  j/k PgUp/PgDn scroll  {tabs} tabs  q quit")
            }
            Tab::Today => format!("[ ] day  n/N section  j/k PgUp/PgDn scroll  {tabs} tabs  q quit"),
            Tab::History => format!("j/k pick a day  Enter open it in Today  {tabs} tabs  q quit"),
            _ => format!("{tabs}/Tab pages  j/k PgUp/PgDn scroll  r refresh  o Grafana  q quit"),
        }
    }

    /// A page as lines (or what is being waited for), and where its sections start.
    pub fn body(&self, w: usize) -> (Vec<Line<'static>>, Vec<usize>) {
        let now = jobs::now();
        let reading = |what: &str| {
            (
                vec![Line::styled(format!("Reading {what}..."), self.p.dim())],
                vec![],
            )
        };
        match (self.tab, &self.boards, &self.infra) {
            (Tab::Forecast, ..) => match &self.forecast {
                None => reading("fleet-bench forecast"),
                Some(f) => (forecast::page(f, self.p, now, w), vec![]),
            },
            (Tab::Fleet, ..) => match &self.fleet {
                None => reading("the fleet"),
                Some(f) => (fleettab::page(f, self.p, now, w), vec![]),
            },
            (Tab::Sessions, b, _) => {
                let mut l = self.controls.lines(self.p, w);
                l.push(Line::raw(""));
                match b {
                    None => l.extend(reading("the board files").0),
                    Some(b) => l.extend(fleet::page(&b.watch, self.p, now, w)),
                }
                (l, vec![])
            }
            (Tab::Today | Tab::History, None, _) => reading("the board files"),
            (Tab::Today, Some(b), _) => {
                let pg = day::today(b.rec.as_ref(), self.p, now, w);
                (pg.lines, pg.sections)
            }
            (Tab::History, Some(b), _) => (day::history(&b.hist, self.hist_sel, self.p, w), vec![]),
            (_, _, None) => reading("Prometheus"),
            (t, _, Some(i)) => (board::page(t, i, self.p, now, w, &self.hosts), vec![]),
        }
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

/// Whether a changed path means a job started or ended (agentctl's stdout logs change all the
/// time and mean neither).
pub fn is_job_file(paths: &Paths, p: &std::path::Path) -> bool {
    p == paths.unity_runs
        || matches!(
            p.file_name().and_then(|n| n.to_str()),
            Some("runs.jsonl" | "run")
        ) && p.starts_with(&paths.agentctl)
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

    #[test]
    fn the_sessions_tab_lists_the_sessions_above_the_board_with_a_confirm() {
        let mut a = app(Tab::Sessions);
        a.controls.set(crate::controls::tests::fixture());
        let s = screen(&mut a, 140, 30);
        let lines: Vec<&str> = s.lines().collect();
        assert!(lines[1].starts_with("SESSION CONTROLS  i interrupt"), "{s}");
        assert!(
            lines[2].starts_with("SESSION") && lines[2].contains("ACCOUNT"),
            "{s}"
        );
        let live = lines[3];
        for want in [
            "lab/dotfiles-agent-3:2",
            "here",
            "idle",
            "bnb",
            "new-curious-garden",
            "a1",
            "fix-the-thing",
        ] {
            assert!(live.contains(want), "{want} missing from {live:?}");
        }
        assert!(
            lines[4].contains("lab/dotfiles-agent-9:1") && lines[4].contains("parked"),
            "{s}"
        );
        assert!(s.contains("Reading the board files..."), "{s}");
        assert!(lines[29].contains("j/k pick  i p u m x c act"), "{s}");

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
    fn the_overview_draws_the_board_under_the_tab_bar() {
        let mut a = app(Tab::Overview);
        a.infra = Some(board::tests::fixture());
        let s = screen(&mut a, 120, 40);
        let first = s.lines().next().unwrap();
        assert!(
            first.contains("1 Overview") && first.contains("4 Machines") && first.contains(" RED "),
            "{s}"
        );
        assert!(s.contains("OVERALL RED"), "{s}");
        assert!(s.lines().last().unwrap().contains("r refresh"));
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
        let mut a = app(Tab::Machines);
        assert!(screen(&mut a, 80, 10).contains("Reading Prometheus..."));
        a.tab = Tab::Jobs;
        assert!(screen(&mut a, 80, 10).contains("Reading jobs..."));
    }

    #[test]
    fn the_forecast_tab_draws_the_drain_and_each_sessions_phases() {
        let mut a = app(Tab::Forecast);
        assert!(screen(&mut a, 100, 10).contains("Reading fleet-bench forecast..."));
        a.handle(Msg::Forecast(Box::new(forecast::tests::fixture())));
        let s = screen(&mut a, 200, 60);
        assert!(s.lines().next().unwrap().contains("6 Forecast"), "{s}");
        assert!(s.contains("not draining (in 10.63/h, out 6.88/h)"), "{s}");
        assert!(
            s.contains("dotfiles:4") && s.contains("Step 0 board row"),
            "{s}"
        );
        assert!(s.lines().last().unwrap().contains("1-9/Tab pages"), "{s}");
    }

    #[test]
    fn a_failed_fleet_bench_draws_the_fallbacks() {
        let mut a = app(Tab::Forecast);
        let f = Forecast::read_with("hub-test-no-such-fleet-bench");
        a.handle(Msg::Forecast(Box::new(f)));
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

    fn key(c: char) -> Msg {
        Msg::Input(Event::Key(KeyEvent::from(KeyCode::Char(c))))
    }

    #[test]
    fn a_tab_request_switches_the_running_board() {
        let mut a = app(Tab::Overview);
        a.handle(Msg::Tab(Tab::Sessions));
        assert_eq!(a.tab, Tab::Sessions);
        // Entering Forecast reads fleet-bench; mark it already reading so no test runs it.
        a.forecast_read.busy = true;
        a.handle(key('6'));
        assert_eq!(a.tab, Tab::Forecast);
        a.handle(key('7'));
        assert_eq!(a.tab, Tab::Today);
    }

    #[test]
    fn a_failed_watch_or_socket_is_on_screen_and_the_tick_reads_the_boards() {
        let mut a = app(Tab::Sessions);
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
        a.handle(Msg::Tick);
        assert!(a.boards_read.busy, "the tick stands in for the watch");
    }

    #[test]
    fn number_keys_switch_pages_and_q_quits() {
        let mut a = app(Tab::Overview);
        let key = |c| Msg::Input(Event::Key(KeyEvent::from(KeyCode::Char(c))));
        a.handle(key('3'));
        assert_eq!(a.tab, Tab::Ci);
        a.handle(Msg::Input(Event::Key(KeyEvent::from(KeyCode::Tab))));
        assert_eq!(a.tab, Tab::Machines);
        a.handle(key('q'));
        assert!(a.quit);
    }

    #[test]
    fn only_a_run_starting_or_ending_wakes_the_jobs_page() {
        let a = app(Tab::Jobs);
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
        let mut a = app(Tab::Jobs);
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
        let mut a = app(Tab::Jobs);
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
