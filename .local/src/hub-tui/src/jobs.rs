//! The Jobs page: every job `hub_core::jobs::collect` finds (agentctl, timers, night shift,
//! Unity gates, CI, k8s), filtered and searched, with a log pane under the list.

use hub_core::jobs::{Job, Jobs, Source, State};
use ratatui::text::{Line, Span};

use crate::fit::{cell, Cell, Table};
use crate::fmt::{clock, dur, Palette};

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum StateFilter {
    #[default]
    All,
    Running,
    Queued,
    Done,
    Failed,
}

impl StateFilter {
    fn next(self) -> StateFilter {
        use StateFilter::*;
        match self {
            All => Running,
            Running => Queued,
            Queued => Done,
            Done => Failed,
            Failed => All,
        }
    }
    fn name(self) -> &'static str {
        use StateFilter::*;
        match self {
            All => "all states",
            Running => "running",
            Queued => "queued",
            Done => "done",
            Failed => "failed",
        }
    }
    fn keeps(self, j: &Job) -> bool {
        match self {
            StateFilter::All => true,
            StateFilter::Running => j.state == State::Running,
            StateFilter::Queued => j.state == State::Queued,
            StateFilter::Done => j.state == State::Done,
            StateFilter::Failed => j.ok == Some(false),
        }
    }
}

/// The log of one row, read in a worker. `back` counts lines up from the end: 0 follows the tail.
pub struct LogPane {
    pub title: String,
    pub text: Option<Result<String, String>>,
    pub back: usize,
    /// Which open this is, so a slow read for a row since closed is dropped.
    pub gen: u64,
}

#[derive(Default)]
pub struct JobsView {
    pub source: Option<Source>,
    pub state: StateFilter,
    pub search: String,
    /// The search being typed after `/`, applied on Enter.
    pub typing: Option<String>,
    pub sel: usize,
    pub top: usize,
    pub log: Option<LogPane>,
    /// Every run of this one job (h), none folded.
    pub history: Option<String>,
}

/// The row a selection stands for, so a refresh keeps the same job selected.
pub type RowId = (Source, String, Option<i64>);

pub fn row_id(j: &Job) -> RowId {
    (j.source, j.name.clone(), j.started.or(j.finished))
}

impl JobsView {
    pub fn cycle_source(&mut self) {
        self.source = match self.source {
            None => Some(Source::ALL[0]),
            Some(s) => Source::ALL
                .iter()
                .position(|x| *x == s)
                .and_then(|i| Source::ALL.get(i + 1))
                .copied(),
        };
        self.sel = 0;
    }
    pub fn cycle_state(&mut self) {
        self.state = self.state.next();
        self.sel = 0;
    }

    /// The rows the filters and the search keep, in the collector's order.
    pub fn shown<'a>(&self, jobs: &'a Jobs) -> Vec<&'a Job> {
        let q = self.search.to_lowercase();
        jobs.jobs
            .iter()
            .filter(|j| self.source.is_none_or(|s| j.source == s))
            .filter(|j| self.state.keeps(j))
            .filter(|j| {
                q.is_empty()
                    || [j.name.as_str(), &j.detail, &j.result, j.source.name()]
                        .iter()
                        .any(|f| f.to_lowercase().contains(&q))
            })
            .collect()
    }

    /// Move the selection to the row with this id after a refresh, or keep the index in range.
    pub fn reselect(&mut self, jobs: &Jobs, id: Option<RowId>) {
        let rows = self.shown(jobs);
        if let Some(i) = id.and_then(|id| rows.iter().position(|j| row_id(j) == id)) {
            self.sel = i;
        }
        self.sel = self.sel.min(rows.len().saturating_sub(1));
    }

    /// One status line: the filters on the left, what is going on on the right.
    pub fn status(&self, jobs: &Jobs, p: Palette) -> Vec<Line<'static>> {
        let count = |f: fn(&Job) -> bool| jobs.jobs.iter().filter(|j| f(j)).count();
        let mut spans = vec![Span::raw(format!(
            "{} | {}",
            self.source.map_or("all sources", |s| s.name()),
            self.state.name()
        ))];
        if let Some(t) = &self.typing {
            spans.push(Span::styled(format!(" | /{t}_"), p.head()));
        } else if !self.search.is_empty() {
            spans.push(Span::raw(format!(" | /{}", self.search)));
        }
        if let Some(h) = &self.history {
            spans.push(Span::styled(
                format!(" | history of {h} (h back)"),
                p.head(),
            ));
        }
        spans.push(Span::styled(
            format!(
                "    running {}  queued {}  failed {}  (last {})",
                count(|j| j.state == State::Running),
                count(|j| j.state == State::Queued),
                count(|j| j.ok == Some(false)),
                dur(jobs.window_secs as f64)
            ),
            p.dim(),
        ));
        let mut out = vec![Line::from(spans)];
        if !jobs.errors.is_empty() {
            out.push(Line::styled(
                format!("unread: {}", jobs.errors.join("; ")),
                p.warn(),
            ));
        }
        out
    }

    /// The table: a header line, then one line per shown row. `sel` marks the selected row.
    pub fn table(&self, jobs: &Jobs, p: Palette, w: usize, sel: bool) -> Vec<Line<'static>> {
        let now = jobs.at;
        let rows = self.shown(jobs);
        if rows.is_empty() {
            return vec![Line::styled(
                if jobs.jobs.is_empty() {
                    "no jobs in the window"
                } else {
                    "no job matches (s source, f state, / search, Esc clears)"
                },
                p.dim(),
            )];
        }
        let cells: Vec<Vec<Cell>> = rows.iter().map(|j| job_row(j, p, now)).collect();
        let mut out = Table {
            header: vec![
                "STATE", "SOURCE", "NAME", "STARTED", "DUR", "RESULT", "DETAIL",
            ],
            rows: cells,
            keep: vec![0, 2, 3, 4, 5, 1],
            flex: Some(6),
            flexmin: 10,
            right: vec![4],
            cap: vec![(2, 40), (5, 12)],
            ..Default::default()
        }
        .fit(w, p.head());
        if sel {
            if let Some(l) = out.get_mut(self.sel + 1) {
                l.style = p.sel();
            }
        }
        out
    }
}

fn job_row(j: &Job, p: Palette, now: i64) -> Vec<Cell> {
    let state = match j.state {
        State::Running => cell("run", p.good()),
        State::Queued => cell("queue", p.warn()),
        State::Done => "done".into(),
    };
    let name = if j.runs > 1 {
        format!("{} x{}", j.name, j.runs)
    } else {
        j.name.clone()
    };
    let took = match j.state {
        State::Queued => j
            .secs
            .map_or("-".into(), |s| format!("wait {}", dur(s as f64))),
        State::Running => j
            .started
            .map(|s| now - s)
            .or(j.secs)
            .map_or("-".into(), |s| dur(s as f64)),
        State::Done => j.secs.map_or("-".into(), |s| dur(s as f64)),
    };
    let result = match j.ok {
        Some(false) => cell(j.result.clone(), p.bad()),
        _ if j.result.is_empty() => "-".into(),
        _ => j.result.clone().into(),
    };
    vec![
        state,
        j.source.name().into(),
        name.into(),
        j.started.map_or("-".into(), |t| clock(t, now)).into(),
        took.into(),
        result,
        if j.detail.is_empty() {
            "-".into()
        } else {
            j.detail.clone().into()
        },
    ]
}

/// Log text as plain lines: escape sequences and other control characters go, tabs become
/// spaces, so a CI log cannot move the cursor or recolour the board.
pub fn clean(text: &str) -> Vec<String> {
    text.lines()
        .map(|l| {
            let mut out = String::with_capacity(l.len());
            let mut it = l.chars().peekable();
            while let Some(c) = it.next() {
                match c {
                    '\x1b' => {
                        if it.peek() == Some(&'[') {
                            it.next();
                            for d in it.by_ref() {
                                if d.is_ascii_alphabetic() {
                                    break;
                                }
                            }
                        }
                    }
                    '\t' => out.push_str("    "),
                    c if c.is_control() => {}
                    c => out.push(c),
                }
            }
            out
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::fit::plain;

    fn job(src: Source, name: &str, state: State, ok: Option<bool>) -> Job {
        let mut j = Job::new(src, name, state);
        j.ok = ok;
        j.started = Some(1000);
        j.secs = Some(90);
        j.result = match ok {
            Some(true) => "success".into(),
            Some(false) => "failure".into(),
            None => String::new(),
        };
        j.detail = "feat/x".into();
        j
    }

    fn fixture() -> Jobs {
        let mut dream = job(Source::Agentctl, "dream", State::Done, Some(true));
        dream.runs = 3;
        Jobs {
            at: 1300,
            window_secs: 86400,
            jobs: vec![
                job(Source::Ci, "playground / gate", State::Running, None),
                job(Source::Ci, "platform / e2e", State::Queued, None),
                dream,
                job(Source::Unity, "editmode", State::Done, Some(false)),
            ],
            errors: vec!["k8s: prometheus down".into()],
        }
    }

    fn lines(v: &JobsView, j: &Jobs) -> Vec<String> {
        v.table(j, Palette { no_color: true }, 120, false)
            .iter()
            .map(plain)
            .collect()
    }

    #[test]
    fn a_row_shows_state_source_name_runs_duration_and_result() {
        let j = fixture();
        let out = lines(&JobsView::default(), &j);
        assert!(out[0].starts_with("STATE"));
        let sq = |s: &String| s.split_whitespace().collect::<Vec<_>>().join(" ");
        let rows: Vec<String> = out.iter().map(sq).collect();
        // Running counts from its start to the collection time, not the collector's secs.
        assert!(
            rows.iter()
                .any(|r| r.starts_with("run ci playground / gate") && r.contains(" 5m ")),
            "{rows:?}"
        );
        assert!(rows
            .iter()
            .any(|r| r.contains("queue ci platform / e2e") && r.contains("wait 1m")));
        assert!(rows
            .iter()
            .any(|r| r.contains("agentctl dream x3") && r.contains("1m success")));
    }

    #[test]
    fn filters_and_search_narrow_the_rows() {
        let j = fixture();
        let mut v = JobsView::default();
        v.cycle_state(); // running
        assert_eq!(v.shown(&j).len(), 1);
        v.state = StateFilter::Failed;
        assert_eq!(v.shown(&j)[0].name, "editmode");
        v.state = StateFilter::All;
        v.cycle_source(); // agentctl
        assert_eq!(v.shown(&j).len(), 1);
        v.source = None;
        v.search = "E2E".into();
        assert_eq!(v.shown(&j)[0].name, "platform / e2e");
        v.search = "nothing-like-it".into();
        assert!(lines(&v, &j)[0].contains("no job matches"));
    }

    #[test]
    fn a_failed_run_is_red_and_the_selection_is_reversed() {
        let j = fixture();
        let p = Palette::default();
        let v = JobsView {
            sel: 1,
            ..Default::default()
        };
        let out = v.table(&j, p, 120, true);
        assert_eq!(out[2].style, p.sel());
        let fail = out
            .iter()
            .flat_map(|l| &l.spans)
            .find(|s| s.content == "failure")
            .unwrap();
        assert_eq!(fail.style, p.bad());
    }

    #[test]
    fn a_refresh_keeps_the_same_job_selected() {
        let mut j = fixture();
        let mut v = JobsView {
            sel: 2,
            ..Default::default()
        };
        let id = Some(row_id(v.shown(&j)[v.sel]));
        j.jobs
            .insert(0, job(Source::Night, "new-task", State::Running, None));
        v.reselect(&j, id);
        assert_eq!(v.shown(&j)[v.sel].name, "dream");
    }

    #[test]
    fn source_errors_are_said_not_hidden() {
        let j = fixture();
        let st: Vec<String> = JobsView::default()
            .status(&j, Palette::default())
            .iter()
            .map(plain)
            .collect();
        assert!(st[0].contains("running 1  queued 1  failed 1"));
        assert_eq!(st[1], "unread: k8s: prometheus down");
    }

    #[test]
    fn log_text_loses_escapes_and_control_characters() {
        assert_eq!(clean("\x1b[31mred\x1b[0m\tx\r"), vec!["red    x"]);
    }
}
