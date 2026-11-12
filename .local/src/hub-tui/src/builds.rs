//! The CI runs table: Infra's CI runs (every run of the last 30 days from
//! `hub_core::builds::read`) and Releases' Release runs (the same rows scoped by
//! `Scope::Release`), on the shared data table (`datatable`), with the selected run's detail
//! (header, jobs and their cost, from `hub_core::builds::detail`) and failed-job log under it,
//! both read when the row is opened. Each workflow's usual time is Infra's Pipelines
//! (`pipetab`); money is a cloud machine's POWER cell and Costs', not this table's. The
//! quarantine rides the same read and is drawn in Infra's Tests section (`quarantine`).

use hub_core::builds::{self, Builds, Run, RunKey, Scope};
use hub_core::quarantine;
use hub_core::releases::Level;
use hub_core::run_detail::RunDetail;
use ratatui::text::{Line, Span};

use crate::datatable::DataTable;
use crate::fit::{cell, Cell, Table};
use crate::fmt::{clock, dur, Palette};
use crate::jobs::LogPane;

/// `Run::COLUMNS` in capitals, in its order, the sort mark placed by that index. `forge`, `event`
/// and `title` filter without a column: the log pane's heading says what they would.
const HEADER: [&str; 10] = [
    "STARTED", "STATE", "REPO", "WORKFLOW", "BRANCH", "TOOK", "USUAL", "ETA", "OWNER", "RELEASE",
];

#[derive(Default)]
pub struct BuildsView {
    /// Which runs the table lists: every run (Infra's CI) or the ones tied to a release.
    pub scope: Scope,
    /// The query, state chip and sort, applied by `hub_core::table::View` as agent-web does.
    pub table: DataTable,
    /// The opened run's log, read in a worker. `Esc` closes it.
    pub log: Option<LogPane>,
    /// The opened run's detail, read in a worker beside the log, above it in the pane.
    pub detail: Option<DetailPane>,
}

use crate::releases::level;

impl BuildsView {
    pub fn of(scope: Scope) -> BuildsView {
        BuildsView {
            scope,
            ..Default::default()
        }
    }

    /// The scope's rows the query and chip keep, in its sort or the ledger's newest-first order.
    fn kept<'a>(&self, b: &'a Builds) -> Vec<&'a Run> {
        match self.scope {
            // Every run: the view over the read itself, no list of references to build first.
            Scope::All => self.table.view.apply(&b.rows),
            scope => {
                let rows = b.rows_in(scope);
                self.table.view.apply(&rows).into_iter().copied().collect()
            }
        }
    }

    /// The rows the view keeps, capped as the page is.
    pub fn shown<'a>(&self, b: &'a Builds) -> Vec<&'a Run> {
        builds::cap(self.kept(b)).0
    }

    /// The selected run, among the rows shown.
    pub fn selected<'a>(&self, b: &'a Builds) -> Option<&'a Run> {
        self.shown(b).get(self.table.sel).copied()
    }

    /// Move the selection to the run with this key after a read, or keep the index in range.
    pub fn reselect(&mut self, b: &Builds, id: Option<RunKey>) {
        let rows = self.shown(b);
        let at = id.and_then(|id| rows.iter().position(|r| r.key() == id));
        self.table.keep(at, rows.len());
    }

    /// The section's heading (`title`) with how the runs divide, the view and what stopped a
    /// read.
    pub fn status(&self, title: &str, b: &Builds, p: Palette, now: i64) -> Vec<Line<'static>> {
        let s = b.scoped(self.scope);
        let mut head = vec![
            Span::styled(format!("{title}  "), p.head()),
            Span::styled(s.summary(), level(s.counts.level(), p)),
        ];
        if b.stale(now) {
            head.push(Span::styled(
                format!("  ledger older than {}", dur(builds::STALE_SECS as f64)),
                p.warn(),
            ));
        }
        let (shown, more) = builds::cap(
            self.table
                .view
                .apply(&s.rows)
                .into_iter()
                .copied()
                .collect(),
        );
        let mut spans = self.table.status(&s.rows, p);
        spans.push(Span::styled(
            format!("    {} of {}", shown.len(), s.rows.len()),
            p.dim(),
        ));
        if more > 0 {
            spans.push(Span::styled(
                format!(" ({more} older: narrow with /)"),
                p.dim(),
            ));
        }
        let mut out = vec![Line::from(head), Line::from(spans)];
        if !s.errors.is_empty() {
            out.push(Line::styled(
                format!("unread: {}", s.errors.join("; ")),
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
        self.lines(b, self.shown(b), p, w, sel, now)
    }

    /// The first `n` shown runs as the table draws them, fitted to those rows only, and how
    /// many runs the view keeps: a section's preview of the table one key opens.
    pub fn preview(
        &self,
        b: &Builds,
        n: usize,
        p: Palette,
        w: usize,
        now: i64,
    ) -> (Vec<Line<'static>>, usize) {
        let mut rows = self.kept(b);
        let all = rows.len();
        rows.truncate(n);
        (self.lines(b, rows, p, w, false, now), all)
    }

    fn lines(
        &self,
        b: &Builds,
        rows: Vec<&Run>,
        p: Palette,
        w: usize,
        sel: bool,
        now: i64,
    ) -> Vec<Line<'static>> {
        if rows.is_empty() {
            return vec![Line::styled(
                if b.rows.is_empty() {
                    "no runs in the ledger"
                } else if !b.rows.iter().any(|r| self.scope.keeps(r)) {
                    "no run in the ledger is tied to a release"
                } else {
                    "no run matches (/ query, f state, x clears)"
                },
                p.dim(),
            )];
        }
        let mut out = Table {
            header: HEADER.to_vec(),
            rows: rows.iter().map(|r| run_row(r, p, now)).collect(),
            keep: vec![1, 2, 3, 0, 5, 7, 6, 9, 8, 4],
            flex: Some(4),
            flexmin: 10,
            right: vec![5, 6, 7],
            cap: vec![(2, 24), (3, 28), (8, 16), (9, 16)],
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

/// The opened run's detail. `top` is the first line drawn (`[` and `]` move it).
pub struct DetailPane {
    pub gen: u64,
    pub read: Option<Result<RunDetail, String>>,
    pub top: usize,
}

const JOB_HEADER: [&str; 6] = ["JOB", "CLASS", "WAIT", "TOOK", "RUNNER", "$"];

/// The opened run as the pane draws it: its title, header, then one line per job, every job
/// (none capped), with its steps under a job that failed or took longest.
pub fn detail_lines(d: &RunDetail, p: Palette, w: usize) -> Vec<Line<'static>> {
    let mut out = vec![Line::styled(d.title.clone(), p.head())];
    // The header breaks between its parts rather than run past the pane.
    let mut line = String::new();
    for part in d.header.split(" | ") {
        if !line.is_empty() && 2 + line.len() + 3 + part.len() > w {
            out.push(Line::styled(format!("  {line}"), p.dim()));
            line.clear();
        }
        if !line.is_empty() {
            line.push_str(" | ");
        }
        line.push_str(part);
    }
    out.push(Line::styled(format!("  {line}"), p.dim()));
    if let Some(e) = &d.rates_error {
        out.push(Line::styled(format!("  no rates: {e}"), p.warn()));
    }
    if d.coverage != "complete" {
        out.push(Line::styled(format!("  {}", d.coverage_text), p.warn()));
    }
    if d.jobs.is_empty() {
        return out;
    }
    let longest = d.jobs.iter().filter_map(|j| j.took).max();
    let rows: Vec<Vec<Cell>> = d
        .jobs
        .iter()
        .map(|j| {
            let name = match j.conclusion.as_str() {
                "" | "success" | "skipped" => j.name.clone().into(),
                _ => cell(j.name.clone(), p.bad()),
            };
            vec![
                name,
                j.class.clone().into(),
                j.wait_text.clone().into(),
                j.took_text.clone().into(),
                j.runner.clone().into(),
                j.price.text.clone().into(),
            ]
        })
        .collect();
    // The runner sits before the price, as the mock has it, so it takes what the others leave.
    let w = w.saturating_sub(2);
    let widest = |j: usize, cap: usize| {
        rows.iter()
            .map(|r: &Vec<Cell>| crate::fit::len(&r[j].text))
            .chain([JOB_HEADER[j].len()])
            .max()
            .unwrap_or(0)
            .min(cap)
    };
    let others: usize = [(0, 18), (1, 16), (2, 6), (3, 6), (5, 32)]
        .iter()
        .map(|&(j, cap)| widest(j, cap) + 2)
        .sum();
    let table = Table {
        header: JOB_HEADER.to_vec(),
        rows,
        keep: vec![0, 5, 3, 2, 1, 4],
        right: vec![2, 3],
        cap: vec![
            (0, 18),
            (1, 16),
            (2, 6),
            (3, 6),
            (5, 32),
            (4, w.saturating_sub(others).clamp(8, 28)),
        ],
        ..Default::default()
    }
    .fit(w, p.head());
    let mut it = table.into_iter();
    if let Some(h) = it.next() {
        out.push(indent(h));
    }
    for (j, line) in d.jobs.iter().zip(it) {
        out.push(indent(line));
        let failed = !matches!(j.conclusion.as_str(), "" | "success" | "skipped");
        if !j.steps_text.is_empty() && (failed || (j.took.is_some() && j.took == longest)) {
            out.push(Line::styled(
                format!("    > steps: {}", j.steps_text),
                p.dim(),
            ));
        }
    }
    if d.attempts.len() > 1 {
        let a: Vec<String> = d.attempts.iter().map(u32::to_string).collect();
        out.push(Line::styled(
            format!("  attempts {}", a.join(", ")),
            p.dim(),
        ));
    }
    out
}

fn indent(mut l: Line<'static>) -> Line<'static> {
    l.spans.insert(0, Span::raw("  "));
    l
}

/// The detail pane's lines from `top`, at most `h`: reading, the read's error, or the detail.
pub fn detail_pane(d: &mut DetailPane, p: Palette, w: usize, h: usize) -> Vec<Line<'static>> {
    let all = match &d.read {
        None => vec![Line::styled("reading jobs...", p.dim())],
        Some(Err(e)) => vec![Line::styled(e.clone(), p.warn())],
        Some(Ok(r)) => detail_lines(r, p, w),
    };
    d.top = d.top.min(all.len().saturating_sub(h));
    all.into_iter().skip(d.top).take(h).collect()
}

/// What Infra's CI Tests section says: the suites are read by agent-web alone.
pub fn tests_note(p: Palette, w: usize) -> Vec<Line<'static>> {
    let text = "The suites of each repo's newest declared test-workflow run (testWorkflows in the project map) are on agent-web, Infra, Tests. The TUI does not read them.";
    let words: Vec<&str> = text.split_whitespace().collect();
    let mut out = vec![Line::styled("TESTS", p.head())];
    out.extend(
        crate::fit::wrap(&words, " ", w.max(20))
            .into_iter()
            .map(|l| crate::fit::clip_line(Line::styled(l, p.dim()), w)),
    );
    out
}

const QUARANTINE_HEADER: [&str; 6] = ["TEST", "REPO", "ROW", "ENDS", "LEFT", "NIGHTLY"];

/// The Quarantine part of Infra's CI Tests section: each repo's line and its nightly, how the
/// held tests divide by their end, then the first `rows` of them, soonest end first, as agent-web's
/// Quarantine table lists them.
pub fn quarantine(b: &Builds, p: Palette, w: usize, rows: usize) -> Vec<Line<'static>> {
    let mut out = vec![];
    if let Some(e) = &b.quarantine_error {
        out.push(crate::fit::clip_line(
            Line::styled(format!("unread: {e}"), p.warn()),
            w,
        ));
    }
    if b.quarantine.is_empty() {
        return out;
    }
    out.insert(0, Line::styled("QUARANTINE", p.head()));
    for l in &b.quarantine {
        let mut line = vec![Span::styled(l.says(), level(l.level(), p))];
        if let Some(u) = l.url() {
            line.push(Span::styled(format!("  {u}"), p.dim()));
        }
        out.push(crate::fit::clip_line(Line::from(line), w));
    }
    let all = quarantine::entries(&b.quarantine);
    if all.is_empty() {
        return out;
    }
    let count = |c: &str| all.iter().filter(|e| e.chip() == c).count();
    out.push(Line::styled(
        format!(
            "{} tests: {} ended, {} ending, {} held",
            all.len(),
            count("ended"),
            count("ending"),
            count("held")
        ),
        p.dim(),
    ));
    let cells = all
        .iter()
        .take(rows)
        .map(|e| {
            let nightly = match e.nightly.as_str() {
                "now passing" => cell(&e.nightly, p.good()),
                n => cell(n, p.dim()),
            };
            vec![
                e.test.clone().into(),
                e.repo.clone().into(),
                e.row.clone().into(),
                e.ends.clone().into(),
                cell(&e.left, level(e.level, p)),
                nightly,
            ]
        })
        .collect();
    out.extend(
        Table {
            header: QUARANTINE_HEADER.to_vec(),
            rows: cells,
            keep: vec![0, 4, 2, 5, 1, 3],
            right: vec![4],
            cap: vec![(0, 60)],
            ..Default::default()
        }
        .fit(w, p.head()),
    );
    if all.len() > rows {
        out.push(Line::styled(
            format!("  {} more on agent-web, Infra, Tests", all.len() - rows),
            p.dim(),
        ));
    }
    out
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
        r.release
            .as_ref()
            .map_or("-".into(), |x| x.tag.clone())
            .into(),
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
            errors: vec![],
            ..Default::default()
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
    fn a_preview_draws_only_its_rows_and_counts_every_run_the_view_keeps() {
        let mut b = fixture();
        b.rows[0].release = Some(hub_core::release_graph::RunRelease {
            project: "binks".into(),
            tag: "v1.2.0".into(),
        });
        let p = Palette { no_color: true };
        let (out, all) = BuildsView::default().preview(&b, 2, p, 100, 1300);
        assert_eq!((out.len(), all), (3, 3), "a header and 2 of 3 runs");
        // The release scope keeps the one tied run: a preview of it, and its table.
        let rel = BuildsView::of(Scope::Release);
        let (out, all) = rel.preview(&b, 2, p, 100, 1300);
        assert_eq!((out.len(), all), (2, 1));
        assert_eq!(rel.shown(&b).len(), 1);
        assert!(plain(&out[1]).contains("v1.2.0"));
        // A ledger with no run tied to a release says so, not that the ledger is empty.
        b.rows[0].release = None;
        let (out, all) = rel.preview(&b, 2, p, 100, 1300);
        assert_eq!(all, 0);
        assert_eq!(plain(&out[0]), "no run in the ledger is tied to a release");
    }

    #[test]
    fn the_status_says_how_runs_divide_and_when_the_ledger_is_late() {
        let b = fixture();
        let v = BuildsView::default();
        let p = Palette { no_color: true };
        let s: Vec<String> = v.status("Runs", &b, p, 1400).iter().map(plain).collect();
        assert!(
            s[0].contains("3 runs in 30 days: 0 running, 1 queued, 1 red"),
            "{s:?}"
        );
        assert!(!s[0].contains("older than"));
        let late: Vec<String> = v
            .status("Runs", &b, p, 1300 + builds::STALE_SECS + 1)
            .iter()
            .map(plain)
            .collect();
        assert!(late[0].contains("ledger older than 30m"), "{late:?}");
    }

    fn quarantined() -> Builds {
        use hub_core::quarantine::{Held, Lane, Nightly, OwnerRow, Report};
        let row = |row: &str, entries, ends: &str, days_left| OwnerRow {
            row: row.into(),
            entries,
            ends: ends.into(),
            days_left,
        };
        let held = |test: &str, row: &str, ends: &str, days_left| Held {
            test: test.into(),
            row: row.into(),
            ends: ends.into(),
            days_left,
            ..Default::default()
        };
        Builds {
            quarantine: vec![Lane {
                repo: "Org/play".into(),
                report: Some(Report {
                    entries: 3,
                    rows: vec![
                        row("ucp-1", 1, "2026-11-10", -1),
                        row("ucp-2", 2, "2026-11-30", 19),
                    ],
                    tests: vec![
                        held("A.gone", "ucp-1", "2026-11-10", -1),
                        held("B.t1", "ucp-2", "2026-11-30", 19),
                        held("B.t2", "ucp-2", "2026-11-30", 19),
                    ],
                }),
                nightly: Some(Nightly {
                    created_at: Some("2026-11-11T08:00:00Z".into()),
                    known: 12,
                    now_passing: Some(1),
                    now_passing_tests: vec!["B.t2".into()],
                    url: Some("https://github.com/Org/play/actions/runs/7".into()),
                    ..Default::default()
                }),
                ..Default::default()
            }],
            ..fixture()
        }
    }

    #[test]
    fn the_tests_section_lists_each_quarantined_test_under_its_repos_line() {
        let p = Palette { no_color: true };
        let all: Vec<String> = quarantine(&quarantined(), p, 200, 2)
            .iter()
            .map(plain)
            .collect();
        assert_eq!(all[0], "QUARANTINE", "{all:?}");
        assert!(
            all[1].starts_with("play: 3 quarantined over 2 owner rows")
                && all[1].ends_with("https://github.com/Org/play/actions/runs/7"),
            "{all:?}"
        );
        assert_eq!(all[2], "3 tests: 1 ended, 0 ending, 2 held", "{all:?}");
        assert!(all[3].starts_with("TEST"), "{all:?}");
        assert!(
            all[4].contains("A.gone") && all[4].contains("ended") && all[4].contains("failing"),
            "the ended test is first: {all:?}"
        );
        assert!(all[5].contains("B.t1") && all[5].contains("19d"), "{all:?}");
        assert_eq!(all[6], "  1 more on agent-web, Infra, Tests", "{all:?}");
        assert!(quarantine(&fixture(), p, 140, 2).is_empty());
        let bad = Builds {
            quarantine_error: Some("quarantine.json: expected value".into()),
            ..fixture()
        };
        let out: Vec<String> = quarantine(&bad, p, 140, 2).iter().map(plain).collect();
        assert_eq!(out, ["unread: quarantine.json: expected value"]);
    }

    #[test]
    fn the_runs_carry_no_quarantine_line() {
        let b = quarantined();
        let p = Palette { no_color: true };
        let s: Vec<String> = BuildsView::default()
            .status("Runs", &b, p, 1400)
            .iter()
            .map(plain)
            .collect();
        assert!(!s.iter().any(|l| l.contains("quarantined")), "{s:?}");
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

    fn job(i: usize, runner: &str, price: &str, took: i64) -> hub_core::run_detail::JobRow {
        hub_core::run_detail::JobRow {
            name: format!("shard {i}"),
            conclusion: "success".into(),
            class: "aws/on-demand".into(),
            took: Some(took),
            wait_text: "21m".into(),
            took_text: hub_core::run_detail::took_text(Some(took)),
            runner: runner.into(),
            price: hub_core::run_detail::Price {
                text: price.into(),
                ..Default::default()
            },
            steps_text: "checkout 2s, PlayMode 43m10".into(),
            ..Default::default()
        }
    }

    fn opened(jobs: Vec<hub_core::run_detail::JobRow>) -> RunDetail {
        RunDetail {
            title: "#42871773354 Tests (affected)  red  46m  $0.20".into(),
            header:
                "end to end 46m | before first job 2m | runner time 1h42 | tested a1b2c3 | complete"
                    .into(),
            coverage: "complete".into(),
            jobs,
            ..Default::default()
        }
    }

    #[test]
    fn an_opened_run_fits_80_columns_with_its_price_and_the_longest_jobs_steps() {
        let d = opened(vec![
            job(1, "cachyos-x8664-main-pool-1", "0.00 owned", 2590),
            job(
                2,
                "aws-burst-1-unity-pool-3",
                "0.20 (1/5 of $1.855/h)",
                1965,
            ),
        ]);
        let p = Palette { no_color: true };
        let out: Vec<String> = detail_lines(&d, p, 80).iter().map(plain).collect();
        assert!(out.iter().all(|l| l.chars().count() <= 80), "{out:#?}");
        assert!(out[1].contains("before first job 2m"), "{out:?}");
        let head = out
            .iter()
            .position(|l| l.trim_start().starts_with("JOB"))
            .unwrap();
        assert!(out[head].contains('$'), "{out:?}");
        let aws = out.iter().find(|l| l.contains("shard 2")).unwrap();
        assert!(
            aws.contains("32m45") && aws.contains("0.20 (1/5 of $1.855/h)"),
            "{aws}"
        );
        assert_eq!(
            out[head + 2].trim(),
            "> steps: checkout 2s, PlayMode 43m10",
            "{out:?}"
        );
        assert_eq!(
            out.iter().filter(|l| l.contains("> steps")).count(),
            1,
            "{out:?}"
        );
    }

    #[test]
    fn every_one_of_130_jobs_draws_and_a_partial_read_says_so() {
        let mut d = opened(
            (0..130)
                .map(|i| job(i, "hp-victus-light-1", "no rate", 60))
                .collect(),
        );
        d.coverage = "partial".into();
        d.coverage_text = "partial: 130 jobs so far".into();
        let p = Palette { no_color: true };
        let out: Vec<String> = detail_lines(&d, p, 80).iter().map(plain).collect();
        assert_eq!(out.iter().filter(|l| l.contains("no rate")).count(), 130);
        assert!(
            out.iter().any(|l| l.contains("partial: 130 jobs so far")),
            "{out:?}"
        );
        let mut pane = DetailPane {
            gen: 1,
            read: Some(Ok(d)),
            top: 999,
        };
        let shown = detail_pane(&mut pane, p, 80, 10);
        assert_eq!(shown.len(), 10);
        assert!(plain(&shown[9]).contains("shard 129") || plain(&shown[9]).contains("> steps"));
    }

    #[test]
    fn a_run_tied_to_a_release_names_its_tag() {
        let mut r = run(3, "binks", "green", "agent-3");
        r.release = Some(hub_core::release_graph::RunRelease {
            project: "binks".into(),
            tag: "v1.2.0".into(),
        });
        let p = Palette { no_color: true };
        let row: Vec<String> = run_row(&r, p, 0).iter().map(|c| c.text.clone()).collect();
        assert_eq!(row[9], "v1.2.0");
        assert_eq!(run_row(&run(4, "binks", "green", ""), p, 0)[9].text, "-");
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
