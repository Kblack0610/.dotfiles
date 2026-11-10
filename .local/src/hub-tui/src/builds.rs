//! The Releases page's Builds section: the CI runs of the last 30 days from
//! `hub_core::builds::read`, on the shared data table (`datatable`), with the selected run's
//! failed-job log under it, read when the row is opened. `b` moves the keys between the channels
//! and this table; `t` opens each workflow's usual run time in the same pane.

use hub_core::builds::{self, Builds, Run, RunKey, RunTime};
use hub_core::releases::Level;
use ratatui::text::{Line, Span};

use crate::datatable::DataTable;
use crate::fit::{cell, Cell, Table};
use crate::fmt::{clock, dur, Palette};
use crate::jobs::LogPane;

/// `Run::COLUMNS` in capitals, in its order, the sort mark placed by that index. `forge`, `event`
/// and `title` filter without a column: the log pane's heading says what they would.
const HEADER: [&str; 9] = [
    "STARTED", "STATE", "REPO", "WORKFLOW", "BRANCH", "TOOK", "USUAL", "ETA", "OWNER",
];

#[derive(Default)]
pub struct BuildsView {
    /// The query, state chip and sort, applied by `hub_core::table::View` as agent-web does.
    pub table: DataTable,
    /// Whether the keys drive this table rather than the channels above it.
    pub focus: bool,
    /// The opened run's log, read in a worker. `Esc` closes it.
    pub log: Option<LogPane>,
    /// The Run times table holds the pane, scrolled to this line. `t` toggles it, `Esc` closes it.
    pub times: Option<usize>,
}

use crate::releases::level;

impl BuildsView {
    /// The rows the view keeps, in its sort or the ledger's newest-first order, capped as the page is.
    pub fn shown<'a>(&self, b: &'a Builds) -> Vec<&'a Run> {
        builds::cap(self.table.view.apply(&b.rows)).0
    }

    /// Move the selection to the run with this key after a read, or keep the index in range.
    pub fn reselect(&mut self, b: &Builds, id: Option<RunKey>) {
        let rows = self.shown(b);
        let at = id.and_then(|id| rows.iter().position(|r| r.key() == id));
        self.table.keep(at, rows.len());
    }

    /// The section's heading with how the runs divide, the view and what stopped a read.
    pub fn status(&self, b: &Builds, p: Palette, now: i64) -> Vec<Line<'static>> {
        let mut head = vec![
            Span::styled("Builds  ", p.head()),
            Span::styled(b.summary(), level(b.counts.level(), p)),
        ];
        if b.stale(now) {
            head.push(Span::styled(
                format!("  ledger older than {}", dur(builds::STALE_SECS as f64)),
                p.warn(),
            ));
        }
        let all = self.table.view.apply(&b.rows).len();
        let mut spans = self.table.status(&b.rows, p);
        spans.push(Span::styled(
            format!("    {} of {}", self.shown(b).len(), b.rows.len()),
            p.dim(),
        ));
        if all > builds::LIST_ROWS {
            spans.push(Span::styled(
                format!(" ({} older: narrow with /)", all - builds::LIST_ROWS),
                p.dim(),
            ));
        }
        let mut out = vec![Line::from(head), Line::from(spans)];
        if !b.errors.is_empty() {
            out.push(Line::styled(
                format!("unread: {}", b.errors.join("; ")),
                p.warn(),
            ));
        }
        out
    }

    /// The table: a header line, then one line per shown run. `sel` marks the selected row.
    pub fn table(
        &self,
        b: &Builds,
        p: Palette,
        w: usize,
        sel: bool,
        now: i64,
    ) -> Vec<Line<'static>> {
        let rows = self.shown(b);
        if rows.is_empty() {
            return vec![Line::styled(
                if b.rows.is_empty() {
                    "no runs in the ledger"
                } else {
                    "no run matches (/ query, f state, x clears)"
                },
                p.dim(),
            )];
        }
        let mut out = Table {
            header: HEADER.to_vec(),
            rows: rows.iter().map(|r| run_row(r, p, now)).collect(),
            keep: vec![1, 2, 3, 0, 5, 7, 6, 8, 4],
            flex: Some(4),
            flexmin: 10,
            right: vec![5, 6, 7],
            cap: vec![(2, 24), (3, 28), (8, 16)],
            mark: self.table.mark::<Run>().filter(|(i, _)| *i < HEADER.len()),
            ..Default::default()
        }
        .fit(w, p.head());
        if sel {
            self.table.style(&mut out, p);
        }
        out
    }
}

/// What the log pane is headed with: the run, its branch and the session working on it.
pub fn log_title(r: &Run) -> String {
    let owner = if r.owner.is_empty() { "-" } else { &r.owner };
    format!(
        "{} {} {} #{} {} owner {owner}",
        r.forge, r.repo, r.workflow, r.id, r.branch
    )
}

const TIMES_HEADER: [&str; 8] = [
    "REPO", "WORKFLOW", "RUNS", "USUAL", "P90", "LONGEST", "PASS", "RUNNING",
];

/// The Run times pane: each workflow's usual time over the window, `h` lines from line `top`.
pub fn times(b: &Builds, p: Palette, w: usize, h: usize, top: usize) -> Vec<Line<'static>> {
    let mut out = vec![Line::from(vec![
        Span::styled("Run times  ", p.head()),
        Span::styled(
            format!(
                "{} workflows, {} days, finished runs (cancelled left out); median under {} runs is -",
                b.times.len(),
                builds::KEEP_DAYS,
                builds::USUAL_MIN
            ),
            p.dim(),
        ),
    ])];
    if b.times.is_empty() {
        out.push(Line::styled("no finished runs in the ledger", p.dim()));
        return out;
    }
    let mut table = Table {
        header: TIMES_HEADER.to_vec(),
        rows: b.times.iter().map(time_row).collect(),
        keep: vec![1, 3, 4, 0, 7, 2, 6, 5],
        flex: Some(1),
        flexmin: 12,
        right: vec![2, 3, 4, 5, 6, 7],
        cap: vec![(0, 24)],
        ..Default::default()
    }
    .fit(w, p.head());
    let head = table.remove(0);
    let body = h.saturating_sub(out.len() + 1);
    let top = top.min(table.len().saturating_sub(body));
    out.push(head);
    out.extend(table.into_iter().skip(top).take(body));
    out
}

fn time_row(t: &RunTime) -> Vec<Cell> {
    let d = |s: Option<i64>| s.map_or("-".to_string(), |s| dur(s as f64));
    vec![
        t.short_repo().to_string().into(),
        t.workflow.clone().into(),
        t.runs.to_string().into(),
        d(t.usual.map(|u| u.median)).into(),
        d(t.usual.map(|u| u.p90)).into(),
        d((t.runs > 0).then_some(t.longest)).into(),
        if t.runs > 0 {
            format!("{}%", t.pass)
        } else {
            "-".into()
        }
        .into(),
        if t.running > 0 {
            t.running.to_string()
        } else {
            String::new()
        }
        .into(),
    ]
}

/// A running run's expected end as a clock, or once that has passed, how far past it is
/// (`+12m`): a clock in the past would read as on time.
pub fn eta(eta: Option<i64>, now: i64) -> String {
    match eta {
        Some(t) if t < now => format!("+{}", dur((now - t) as f64)),
        Some(t) => clock(t, now),
        None => "-".into(),
    }
}

fn run_row(r: &Run, p: Palette, now: i64) -> Vec<Cell> {
    let state = match r.level {
        Level::Ok => r.state.clone().into(),
        l => cell(r.state.clone(), level(l, p)),
    };
    let took = match (r.state.as_str(), r.took) {
        ("queued", Some(s)) => format!("wait {}", dur(s as f64)),
        (_, Some(s)) => dur(s as f64),
        _ => "-".into(),
    };
    vec![
        clock(r.started, now).into(),
        state,
        r.repo.clone().into(),
        r.workflow.clone().into(),
        r.branch.clone().into(),
        took.into(),
        r.usual
            .map_or("-".into(), |u| {
                format!("{}/{}", dur(u.median as f64), dur(u.p90 as f64))
            })
            .into(),
        eta(r.eta, now).into(),
        if r.owner.is_empty() {
            "-".into()
        } else {
            r.owner.clone().into()
        },
    ]
}

#[cfg(test)]
pub mod tests {
    use super::*;
    use crate::fit::plain;

    pub fn run(id: u64, repo: &str, state: &str, owner: &str) -> Run {
        Run {
            forge: "github.com".into(),
            repo: repo.into(),
            id,
            attempt: 1,
            workflow: "Tests".into(),
            branch: format!("{owner}/work"),
            state: state.into(),
            level: match state {
                "red" => Level::Bad,
                "queued" => Level::Warn,
                _ => Level::Ok,
            },
            started: 1000 + id as i64,
            took: Some(125),
            owner: owner.into(),
            url: format!("https://github.com/o/{repo}/actions/runs/{id}"),
            ..Default::default()
        }
    }

    pub fn fixture() -> Builds {
        let rows = vec![
            run(3, "binks", "red", "agent-3"),
            run(2, "binks", "green", ""),
            run(1, "dotfiles", "queued", "agent-9"),
        ];
        Builds {
            at: 1300,
            counts: builds::Counts {
                total: 3,
                running: 0,
                queued: 1,
                red: 1,
                recent_red: 1,
            },
            rows,
            times: vec![],
            errors: vec![],
        }
    }

    fn lines(v: &BuildsView, b: &Builds) -> Vec<String> {
        v.table(b, Palette { no_color: true }, 100, false, 1300)
            .iter()
            .map(plain)
            .collect()
    }

    #[test]
    fn a_row_shows_state_repo_workflow_took_and_the_owning_session() {
        let out = lines(&BuildsView::default(), &fixture());
        assert!(out[0].starts_with("STARTED"), "{out:?}");
        let red = out.iter().find(|r| r.contains("red")).unwrap();
        assert!(
            red.contains("binks") && red.contains("Tests") && red.contains("2m"),
            "{red}"
        );
        assert!(red.contains("agent-3"), "{red}");
        let green = out.iter().find(|r| r.contains("green")).unwrap();
        assert!(
            green.trim_end().ends_with('-'),
            "no owner reads a dash: {green}"
        );
        assert!(out.iter().any(|r| r.contains("wait 2m")), "{out:?}");
    }

    #[test]
    fn the_status_says_how_runs_divide_and_when_the_ledger_is_late() {
        let b = fixture();
        let v = BuildsView::default();
        let p = Palette { no_color: true };
        let s: Vec<String> = v.status(&b, p, 1400).iter().map(plain).collect();
        assert!(
            s[0].contains("3 runs in 30 days: 0 running, 1 queued, 1 red"),
            "{s:?}"
        );
        assert!(!s[0].contains("older than"));
        let late: Vec<String> = v
            .status(&b, p, 1300 + builds::STALE_SECS + 1)
            .iter()
            .map(plain)
            .collect();
        assert!(late[0].contains("ledger older than 30m"), "{late:?}");
    }

    #[test]
    fn a_query_narrows_to_the_owners_runs() {
        let b = fixture();
        let mut v = BuildsView::default();
        v.table.view.q = "owner:agent-3".into();
        assert_eq!(v.shown(&b).len(), 1);
        v.table.view.q = "repo:nothing".into();
        let out = lines(&v, &b);
        assert!(out[0].contains("no run matches"), "{out:?}");
    }

    #[test]
    fn a_row_shows_its_usual_time_and_a_running_one_its_eta() {
        let mut b = fixture();
        b.rows[0].usual = Some(builds::Usual {
            median: 2640,
            p90: 4740,
        });
        b.rows[0].state = "running".into();
        b.rows[0].eta = Some(1300 + 3600);
        let out = lines(&BuildsView::default(), &b);
        assert!(
            out[0].contains("USUAL") && out[0].contains("ETA"),
            "{out:?}"
        );
        let row = out.iter().find(|r| r.contains("running")).unwrap();
        assert!(row.contains("44m/1h19m"), "{row}");
        assert!(row.contains(&clock(4900, 1300)), "{row}");
        assert_eq!(eta(Some(1000), 1720), "+12m", "a passed ETA says how late");
        assert_eq!(eta(None, 1720), "-");
    }

    #[test]
    fn the_run_times_pane_lists_each_workflow_and_scrolls() {
        let mut b = fixture();
        b.times = (0..30)
            .map(|i| RunTime {
                repo: "o/ucp".into(),
                workflow: format!("wf{i}"),
                runs: 100 - i,
                usual: (i < 29).then_some(builds::Usual {
                    median: 2640,
                    p90: 4740,
                }),
                longest: 29880,
                pass: 69,
                ..Default::default()
            })
            .collect();
        let p = Palette { no_color: true };
        let out: Vec<String> = times(&b, p, 100, 10, 0).iter().map(plain).collect();
        assert_eq!(out.len(), 10, "{out:?}");
        assert!(out[0].contains("30 workflows"), "{out:?}");
        assert!(out[1].starts_with("REPO"), "{out:?}");
        assert!(
            out[2].contains("wf0")
                && out[2].contains("44m")
                && out[2].contains("8h18m")
                && out[2].contains("69%"),
            "{out:?}"
        );
        let end: Vec<String> = times(&b, p, 100, 10, 99).iter().map(plain).collect();
        let last = end.last().unwrap();
        assert!(
            last.contains("wf29") && last.contains(" - "),
            "the scroll stops at the end, under 3 runs reads -: {end:?}"
        );
    }

    #[test]
    fn a_log_is_headed_with_the_run_and_its_owner() {
        let r = run(3, "binks", "red", "agent-3");
        assert_eq!(
            log_title(&r),
            "github.com binks Tests #3 agent-3/work owner agent-3"
        );
    }
}
