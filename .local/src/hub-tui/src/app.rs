//! `hub infra`: the state, the keys and the drawing. Reads run in worker threads and come back
//! as messages; a read asked for while one is running is coalesced into one more after it.

use std::path::PathBuf;
use std::sync::mpsc::Sender;
use std::time::Duration;

use hub_core::infra::Infra;
use hub_core::jobs::{self, Jobs, LogRef, Opts, Paths};
use ratatui::crossterm::event::{Event, KeyCode, KeyEvent, KeyEventKind, KeyModifiers};
use ratatui::layout::{Constraint, Layout, Rect};
use ratatui::text::{Line, Span};
use ratatui::widgets::Paragraph;
use ratatui::Frame;

use crate::board;
use crate::fmt::{clock, Palette};
use crate::jobs::{clean, row_id, JobsView, LogPane};

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
}

impl Tab {
    pub const ALL: [Tab; 4] = [Tab::Overview, Tab::Jobs, Tab::Ci, Tab::Machines];
    pub fn title(self) -> &'static str {
        match self {
            Tab::Overview => "Overview",
            Tab::Jobs => "Jobs",
            Tab::Ci => "CI",
            Tab::Machines => "Machines",
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
    /// The Grafana dashboard that keeps this page's trends.
    fn dashboard(self) -> &'static str {
        match self {
            Tab::Overview => "kb-command-center",
            Tab::Jobs | Tab::Ci => "kb-ci-runners",
            Tab::Machines => "kb-fleet",
        }
    }
}

pub enum Msg {
    Input(Event),
    Tick,
    /// A job source's file changed (a run started or ended).
    Files,
    Infra(Box<Infra>),
    Jobs(Box<Jobs>),
    Log(u64, Result<String, String>),
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
    /// Lines scrolled down on the Prometheus pages.
    pub scroll: usize,
    pub quit: bool,
    tx: Sender<Msg>,
    infra_read: Read,
    jobs_read: Read,
    log_gen: u64,
    /// The body's last height, for paging.
    page: usize,
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
            scroll: 0,
            quit: false,
            tx,
            infra_read: Read::default(),
            jobs_read: Read::default(),
            log_gen: 0,
            page: 20,
        }
    }

    /// The files whose change means a job started or ended: agentctl's ledger and run
    /// markers, the night-shift queue, the Unity gate ledger.
    pub fn watched(&self) -> Vec<(PathBuf, bool)> {
        let mut v = vec![
            (self.paths.agentctl.clone(), true),
            (self.paths.night.clone(), true),
        ];
        if let Some(d) = self.paths.unity_runs.parent() {
            v.push((d.to_path_buf(), false));
        }
        v
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
            }
            Msg::Files => self.read_jobs(),
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
        let n = self.page.max(1);
        match k.code {
            KeyCode::Char('q') => self.quit = true,
            KeyCode::Char(c @ '1'..='4') => self.go(Tab::ALL[c as usize - '1' as usize]),
            KeyCode::Tab => self.go(Tab::ALL[(self.tab.index() + 1) % 4]),
            KeyCode::BackTab => self.go(Tab::ALL[(self.tab.index() + 3) % 4]),
            KeyCode::Char('r') => {
                self.read_infra();
                self.read_jobs();
            }
            KeyCode::Char('o') => {
                if let Some(g) = self.infra.as_ref().and_then(|i| i.grafana.clone()) {
                    open(&format!(
                        "{}/d/{}",
                        g.trim_end_matches('/'),
                        self.tab.dashboard()
                    ));
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
        } else {
            let lines = self.page_lines(body.width as usize);
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
        let mut s = vec![Span::styled(" INFRA ", self.p.head())];
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
        Line::from(s)
    }

    fn hints(&self) -> String {
        match self.tab {
            Tab::Jobs if self.jv.typing.is_some() => "type to search, Enter applies, Esc clears".into(),
            Tab::Jobs if self.jv.log.is_some() => {
                "Esc close log  J/K PgUp/PgDn scroll log  j/k move  o open url  q quit".into()
            }
            Tab::Jobs => {
                "Enter log  s source  f state  / search  h history  o open url  r refresh  1-4 tabs  q quit".into()
            }
            _ => "1-4/Tab pages  j/k PgUp/PgDn scroll  r refresh  o Grafana  q quit".into(),
        }
    }

    /// A Prometheus page as lines, or what is being waited for.
    pub fn page_lines(&self, w: usize) -> Vec<Line<'static>> {
        match &self.infra {
            None => vec![Line::styled("Reading Prometheus...", self.p.dim())],
            Some(i) => board::page(self.tab, i, self.p, jobs::now(), w, &self.hosts),
        }
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

/// Whether a changed path means a job started or ended (agentctl's stdout logs change all the
/// time and mean neither).
pub fn is_job_file(paths: &Paths, p: &std::path::Path) -> bool {
    p.starts_with(&paths.night)
        || p == paths.unity_runs
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

    fn app(tab: Tab) -> App {
        let (tx, _rx) = std::sync::mpsc::channel();
        let mut a = App::new(tab, tx);
        a.p = Palette { no_color: true };
        a.hosts = vec!["workstation".into()];
        a
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
    fn before_the_first_answer_it_says_it_is_reading() {
        let mut a = app(Tab::Machines);
        assert!(screen(&mut a, 80, 10).contains("Reading Prometheus..."));
        a.tab = Tab::Jobs;
        assert!(screen(&mut a, 80, 10).contains("Reading jobs..."));
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
        assert!(is_job_file(&a.paths, &a.paths.night.join("done/x.md")));
        assert!(is_job_file(&a.paths, &a.paths.unity_runs));
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
            hub_core::jobs::Source::Night,
            "task",
            hub_core::jobs::State::Done,
        );
        j.log = Some(LogRef::Night {
            slug: "task".into(),
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
