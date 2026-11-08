//! The Releases page's Builds section: the CI runs of the last 30 days from
//! `hub_core::builds::read`, on the shared data table (`datatable`), with the selected run's
//! failed-job log under it, read when the row is opened. `b` moves the keys between the channels
//! and this table.

use hub_core::builds::{self, Builds, Run, RunKey};
use hub_core::releases::Level;
use ratatui::text::{Line, Span};

use crate::datatable::DataTable;
use crate::fit::{cell, Cell, Table};
use crate::fmt::{clock, dur, Palette};
use crate::jobs::LogPane;

/// `Run::COLUMNS` in capitals, in its order, the sort mark placed by that index. `forge`, `event`
/// and `title` filter without a column: the log pane's heading says what they would.
const HEADER: [&str; 7] = [
    "STARTED", "STATE", "REPO", "WORKFLOW", "BRANCH", "TOOK", "OWNER",
];

#[derive(Default)]
pub struct BuildsView {
    /// The query, state chip and sort, applied by `hub_core::table::View` as agent-web does.
    pub table: DataTable,
    /// Whether the keys drive this table rather than the channels above it.
    pub focus: bool,
    /// The opened run's log, read in a worker. `Esc` closes it.
    pub log: Option<LogPane>,
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
            keep: vec![1, 2, 3, 0, 5, 6, 4],
            flex: Some(4),
            flexmin: 10,
            right: vec![5],
            cap: vec![(2, 24), (3, 28), (6, 16)],
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
            },
            rows,
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
    fn a_log_is_headed_with_the_run_and_its_owner() {
        let r = run(3, "binks", "red", "agent-3");
        assert_eq!(
            log_title(&r),
            "github.com binks Tests #3 agent-3/work owner agent-3"
        );
    }
}
