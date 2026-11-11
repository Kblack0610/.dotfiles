//! The Releases page's Builds inner tab: the CI runs of the last 30 days from
//! `hub_core::builds::read`, on the shared data table (`datatable`), with the selected run's
//! detail (header, jobs and their cost, from `hub_core::builds::detail`) and failed-job log under
//! it, both read when the row is opened. `t` opens each workflow's usual run time and $ per run
//! in the same pane.

use hub_core::builds::{self, Builds, Run, RunKey, RunTime};
use hub_core::releases::Level;
use hub_core::run_detail::{RunCosts, RunDetail};
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
    /// The opened run's log, read in a worker. `Esc` closes it.
    pub log: Option<LogPane>,
    /// The opened run's detail, read in a worker beside the log, above it in the pane.
    pub detail: Option<DetailPane>,
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
        for l in &b.quarantine {
            out.push(Line::from(vec![
                Span::styled("Quarantine  ", p.head()),
                Span::styled(l.says(), level(l.level(), p)),
            ]));
        }
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

const TIMES_HEADER: [&str; 9] = [
    "REPO", "WORKFLOW", "RUNS", "USUAL", "P90", "LONGEST", "PASS", "RUNNING", "$/RUN",
];

/// The Run times pane: each workflow's usual time and $ per run over the window, `h` lines from
/// line `top`, then the idle and month lines from `costs`.
pub fn times(
    b: &Builds,
    costs: &RunCosts,
    p: Palette,
    w: usize,
    h: usize,
    top: usize,
) -> Vec<Line<'static>> {
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
    let mut table = Table {
        header: TIMES_HEADER.to_vec(),
        rows: b
            .times
            .iter()
            .enumerate()
            .map(|(i, t)| {
                let mut row = time_row(t);
                row.push(costs.times.get(i).map_or("-", String::as_str).into());
                row
            })
            .collect(),
        keep: vec![1, 3, 8, 4, 0, 7, 2, 6, 5],
        flex: Some(1),
        flexmin: 12,
        right: vec![2, 3, 4, 5, 6, 7],
        cap: vec![(0, 24)],
        ..Default::default()
    }
    .fit(w, p.head());
    let mut tail: Vec<Line<'static>> = costs
        .idle
        .iter()
        .map(|l| Line::styled(l.clone(), p.dim()))
        .collect();
    if let Some(m) = &costs.month {
        tail.push(Line::styled(
            m.clone(),
            if costs.month_off { p.warn() } else { p.dim() },
        ));
    }
    if let Some(e) = &costs.rates_error {
        tail.push(Line::styled(format!("no rates: {e}"), p.warn()));
    }
    let head = table.remove(0);
    if b.times.is_empty() {
        table.push(Line::styled("no finished runs in the ledger", p.dim()));
    }
    table.extend(quarantine(b, p, w));
    let body = h.saturating_sub(out.len() + 1 + tail.len());
    let top = top.min(table.len().saturating_sub(body));
    out.push(head);
    out.extend(table.into_iter().skip(top).take(body));
    out.extend(tail);
    out
}

const QUARANTINE_HEADER: [&str; 4] = ["OWNER ROW", "ENTRIES", "ENDS", "LEFT"];

/// The Quarantine section under the Run times rows: each repo's line, then its owner rows,
/// soonest end first, each coloured by how near its end is.
fn quarantine(b: &Builds, p: Palette, w: usize) -> Vec<Line<'static>> {
    if b.quarantine.is_empty() {
        return vec![];
    }
    let mut out = vec![Line::default(), Line::styled("Quarantine", p.head())];
    for l in &b.quarantine {
        out.push(Line::styled(l.says(), level(l.level(), p)));
        if l.rows().is_empty() {
            continue;
        }
        let rows = l
            .rows()
            .iter()
            .map(|r| {
                vec![
                    r.row.clone().into(),
                    r.entries.to_string().into(),
                    r.ends.clone().into(),
                    cell(r.left(), level(r.level(), p)),
                ]
            })
            .collect();
        out.extend(
            Table {
                header: QUARANTINE_HEADER.to_vec(),
                rows,
                keep: vec![0, 3, 1, 2],
                right: vec![1, 3],
                ..Default::default()
            }
            .fit(w, p.head()),
        );
    }
    out
}

/// How far the `t` pane scrolls: its Run times rows (or the line saying there are none) and the
/// Quarantine lines under them, counted from what `quarantine` draws.
pub fn times_rows(b: &Builds) -> usize {
    b.times.len().max(1) + quarantine(b, Palette { no_color: true }, 80).len()
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

    fn quarantined() -> Builds {
        use hub_core::quarantine::{Lane, Nightly, OwnerRow, Report};
        let row = |row: &str, entries, ends: &str, days_left| OwnerRow {
            row: row.into(),
            entries,
            ends: ends.into(),
            days_left,
        };
        Builds {
            quarantine: vec![Lane {
                repo: "Org/play".into(),
                report: Some(Report {
                    entries: 5,
                    rows: vec![
                        row("ucp-1", 2, "2026-11-10", -1),
                        row("ucp-2", 3, "2026-11-30", 19),
                    ],
                    ..Default::default()
                }),
                nightly: Some(Nightly {
                    created_at: Some("2026-11-11T08:00:00Z".into()),
                    known: 12,
                    now_passing: Some(3),
                    ..Default::default()
                }),
                ..Default::default()
            }],
            ..fixture()
        }
    }

    #[test]
    fn the_status_says_each_quarantine_and_its_nightlys_counts() {
        let p = Palette { no_color: true };
        let s: Vec<String> = BuildsView::default()
            .status(&quarantined(), p, 1400)
            .iter()
            .map(plain)
            .collect();
        assert_eq!(
            s[2],
            "Quarantine  play: 5 quarantined over 2 owner rows, 2 ended, next end 11-30 (19d); nightly 11-11: 12 known red, 3 now pass"
        );
        let none: Vec<String> = BuildsView::default()
            .status(&fixture(), p, 1400)
            .iter()
            .map(plain)
            .collect();
        assert!(!none.iter().any(|l| l.contains("Quarantine")), "{none:?}");
    }

    #[test]
    fn the_times_pane_lists_each_owner_row_under_run_times_and_scrolls_to_the_last() {
        let b = quarantined();
        let p = Palette { no_color: true };
        let all: Vec<String> = times(&b, &RunCosts::default(), p, 100, 100, 0)
            .iter()
            .map(plain)
            .collect();
        let at = all.iter().position(|l| l == "Quarantine").unwrap();
        assert!(all[at + 1].starts_with("play: 5 quarantined"), "{all:?}");
        assert!(all[at + 2].starts_with("OWNER ROW"), "{all:?}");
        assert!(
            all[at + 3].contains("ucp-1") && all[at + 3].ends_with("ended"),
            "{all:?}"
        );
        assert!(
            all[at + 4].contains("ucp-2") && all[at + 4].ends_with("19d"),
            "{all:?}"
        );
        assert_eq!(
            times_rows(&b),
            all.len() - 2,
            "the scroll bound is every line under the pinned heading and header"
        );
        let end: Vec<String> = times(&b, &RunCosts::default(), p, 100, 6, times_rows(&b) - 1)
            .iter()
            .map(plain)
            .collect();
        assert!(end.last().unwrap().contains("ucp-2"), "{end:?}");
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
        let out: Vec<String> = times(&b, &RunCosts::default(), p, 100, 10, 0)
            .iter()
            .map(plain)
            .collect();
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
        let end: Vec<String> = times(&b, &RunCosts::default(), p, 100, 10, 99)
            .iter()
            .map(plain)
            .collect();
        let last = end.last().unwrap();
        assert!(
            last.contains("wf29") && last.contains(" - "),
            "the scroll stops at the end, under 3 runs reads -: {end:?}"
        );
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
    fn the_run_times_pane_prices_each_workflow_and_flags_the_month() {
        let mut b = fixture();
        b.times = vec![RunTime {
            repo: "o/ucp".into(),
            workflow: "Tests".into(),
            runs: 3,
            ..Default::default()
        }];
        let costs = RunCosts {
            times: vec!["$0.20 (3 priced)".into()],
            idle: vec!["aws-burst-1: powered 2.0h today $3.71, jobs $1.00, idle $2.71".into()],
            month: Some("month to date: jobs priced $4.00, AWS actual $10.00, off by 60%".into()),
            month_off: true,
            ..Default::default()
        };
        let p = Palette { no_color: true };
        let out: Vec<String> = times(&b, &costs, p, 100, 20, 0).iter().map(plain).collect();
        assert!(out[1].contains("$/RUN"), "{out:?}");
        assert!(out[2].contains("$0.20 (3 priced)"), "{out:?}");
        assert!(out.iter().any(|l| l.contains("idle $2.71")), "{out:?}");
        assert!(out.last().unwrap().contains("off by 60%"), "{out:?}");
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
