//! Infra's Pipelines inner tab: one row per workflow of each repo (`hub_core::pipelines`) on the
//! shared data table (`datatable`: `/` query, `f` state, `s`/`S` sort, `x` clear), as agent-web's
//! Pipelines section draws it. Enter opens the selected row's detail under the table: why it is in
//! its state, its purpose, crons, jobs and last runs, which `hub_core::pipelines::detail` builds.

use hub_core::pipelines::{Detail, Pipeline, Pipelines};
use hub_core::table::Row;
use ratatui::style::Style;
use ratatui::text::{Line, Span};

use crate::datatable::DataTable;
use crate::fit::{cell, wrap, Cell, Table};
use crate::fmt::{clock, dur, Palette};

/// The columns drawn, as the web's, each the `Pipeline::COLUMNS` key it shows; `file` and
/// `running` sort and filter without a column (the detail has the file).
const COLS: [(&str, &str); 12] = [
    ("STATE", "state"),
    ("REPO", "repo"),
    ("PIPELINE", "pipeline"),
    ("TRIGGER", "trigger"),
    ("NIGHTLY", "nightly"),
    ("SCHEDULE", "schedule"),
    ("NEXT", "next"),
    ("LAST RUN", "last"),
    ("PASS", "pass"),
    ("RUNS", "runs"),
    ("USUAL", "usual"),
    ("P90", "p90"),
];
/// The width of the detail's labels, as the longest one.
const LABEL: usize = 10;

#[derive(Default)]
pub struct PipelinesView {
    pub table: DataTable,
    /// The opened row's detail, built when Enter opens it and again on each re-read.
    pub open: Option<Detail>,
}

/// The row a selection stands for, so a re-read keeps the same pipeline selected.
pub type RowId = (String, String);

pub fn row_id(r: &Pipeline) -> RowId {
    (r.repo.clone(), r.file.clone())
}

impl PipelinesView {
    pub fn shown<'a>(&self, p: &'a Pipelines) -> Vec<&'a Pipeline> {
        self.table.view.apply(&p.rows)
    }

    pub fn selected<'a>(&self, p: &'a Pipelines) -> Option<&'a Pipeline> {
        self.shown(p).get(self.table.sel).copied()
    }

    /// After a re-read: the selection on the same pipeline, or the index kept in range.
    pub fn reselect(&mut self, p: &Pipelines, id: Option<RowId>) {
        let rows = self.shown(p);
        let at = id.and_then(|id| rows.iter().position(|r| row_id(r) == id));
        self.table.keep(at, rows.len());
    }

    /// The section: its head and summary, the chips, the table with the selection marked, then
    /// the opened row's detail. `sel` marks the selected row when the tab has the keys.
    pub fn lines(&self, p: Option<&Pipelines>, pal: Palette, w: usize) -> Vec<Line<'static>> {
        let mut out = vec![Line::styled("PIPELINES", pal.head())];
        let Some(p) = p else {
            out.push(Line::styled("Reading pipelines...", pal.dim()));
            return out;
        };
        out.push(crate::fit::clip_line(
            Line::styled(p.summary.clone(), pal.dim()),
            w,
        ));
        let mut chips = self.table.status(&p.rows, pal);
        chips.push(Span::styled(
            format!("    {} of {}", self.shown(p).len(), p.rows.len()),
            pal.dim(),
        ));
        out.push(crate::fit::clip_line(Line::from(chips), w));
        out.extend(DataTable::legend::<Pipeline>(pal, w));
        for e in &p.errors {
            out.push(crate::fit::clip_line(
                Line::styled(format!("unread: {e}"), pal.warn()),
                w,
            ));
        }
        out.extend(self.table_lines(p, pal, w));
        if let Some(d) = &self.open {
            out.push(Line::raw(""));
            out.extend(detail(d, pal, p.at, w));
        }
        out
    }

    fn table_lines(&self, p: &Pipelines, pal: Palette, w: usize) -> Vec<Line<'static>> {
        let rows = self.shown(p);
        if rows.is_empty() {
            return vec![Line::styled(
                if p.rows.is_empty() {
                    "no pipeline is known: state.json lists none"
                } else {
                    "no pipeline matches (/ query, f state, x clears)"
                },
                pal.dim(),
            )];
        }
        let cells: Vec<Vec<Cell>> = rows.iter().map(|r| row(r, pal, p.at)).collect();
        // The sort mark sits on the drawn column that shows the sort key, if one does.
        let mark = self.table.mark::<Pipeline>().and_then(|(i, m)| {
            let key = Pipeline::COLUMNS[i];
            COLS.iter().position(|c| c.1 == key).map(|at| (at, m))
        });
        let mut out = Table {
            header: COLS.iter().map(|c| c.0).collect(),
            rows: cells,
            // The pipeline, its state and when it next and last ran first; the counts last.
            keep: vec![2, 0, 6, 8, 7, 1, 5, 4, 3, 9, 10, 11],
            // No flex: `fit` pads only a last flex column, and the pipeline sits mid-row; its
            // cap clips it and `keep` drops columns from the end instead.
            flex: None,
            flexmin: 0,
            flexkeep: false,
            right: vec![8, 9, 10, 11],
            cap: vec![(1, 18), (2, 32), (3, 16), (5, 24)],
            mark,
        }
        .fit(w, pal.head());
        self.table.style(&mut out, pal);
        out
    }
}

fn state_style(state: &str, p: Palette) -> Style {
    match state {
        "red" => p.bad(),
        "amber" => p.warn(),
        "off" => p.dim(),
        _ => Style::default(),
    }
}

fn row(r: &Pipeline, p: Palette, now: i64) -> Vec<Cell> {
    let or_dash = |s: &str| {
        if s.is_empty() {
            "-".to_string()
        } else {
            s.to_string()
        }
    };
    let secs = |v: Option<i64>| v.map_or("-".into(), |s| dur(s as f64));
    let pass = match r.pass {
        Some(n) if n < 70 => cell(format!("{n}%"), p.bad()),
        Some(n) if n < 90 => cell(format!("{n}%"), p.warn()),
        Some(n) => format!("{n}%").into(),
        None => "-".into(),
    };
    let last = match r.last {
        // The day alone for an older run, red when it failed; the detail has its time.
        Some(t) => cell(
            clock(t, now).split(' ').next().unwrap_or("-").to_string(),
            if r.last_result == "failure" {
                p.bad()
            } else {
                Style::default()
            },
        ),
        None => "-".into(),
    };
    vec![
        cell(r.state.clone(), state_style(&r.state, p)),
        r.project.clone().into(),
        r.pipeline.clone().into(),
        or_dash(&r.trigger).into(),
        or_dash(&r.nightly).into(),
        or_dash(&r.schedule).into(),
        r.next.map_or("-".into(), |t| clock(t, now)).into(),
        last,
        pass,
        r.runs.to_string().into(),
        secs(r.usual).into(),
        secs(r.p90).into(),
    ]
}

/// The opened row: its name and why it is in its state, then each part that has anything to say
/// and its last runs, wrapped to `w`.
pub fn detail(d: &Detail, p: Palette, now: i64, w: usize) -> Vec<Line<'static>> {
    let r = &d.row;
    let mut out = vec![
        crate::fit::clip_line(
            Line::styled(format!("> {} / {}", r.project, r.pipeline), p.head()),
            w,
        ),
        crate::fit::clip_line(
            Line::styled(
                format!("  {} - {}", r.state, r.why),
                state_style(&r.state, p),
            ),
            w,
        ),
    ];
    let width = w.saturating_sub(LABEL + 3).max(20);
    let mut part = |label: &str, text: &str| {
        let words: Vec<&str> = text.split_whitespace().collect();
        for (i, l) in wrap(&words, " ", width).into_iter().enumerate() {
            let name = if i == 0 { label } else { "" };
            out.push(Line::from(vec![
                Span::styled(format!("  {name:<LABEL$} "), p.dim()),
                Span::raw(l),
            ]));
        }
    };
    part("File", &r.file);
    part("Purpose", d.purpose.as_deref().unwrap_or(""));
    for c in &d.crons {
        part("Cron", c);
    }
    if let Some(runner) = &r.runner {
        part(
            "Night",
            &format!("{runner}: {}", d.night_title.as_deref().unwrap_or("")),
        );
    }
    part("Jobs", &d.jobs);
    for u in &d.runs {
        let took = u.took.map_or("-".into(), |s| dur(s as f64));
        let result = u.conclusion.as_deref().unwrap_or(&u.state);
        part(
            "Run",
            &format!(
                "{} #{} {} {result} {took} {}",
                clock(u.started, now),
                u.id,
                u.branch,
                u.event
            ),
        );
    }
    if d.runs.is_empty() {
        part("Run", "none in the ledger's window");
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn text(l: &Line) -> String {
        l.spans.iter().map(|s| s.content.as_ref()).collect()
    }

    fn pipe(state: &str, project: &str, name: &str, pass: Option<u32>) -> Pipeline {
        // A private field (the Schedules row) leaves only a default to build from.
        let mut r = Pipeline::default();
        r.state = state.into();
        r.why = format!("{name} is {state}");
        r.repo = format!("o/{project}");
        r.project = project.into();
        r.pipeline = name.into();
        r.file = format!(".github/workflows/{}.yml", name.to_lowercase());
        r.trigger = "dispatch, cron".into();
        r.nightly = "on".into();
        r.schedule = "02:00 daily".into();
        r.pass = pass;
        r.runs = 12;
        r.usual = Some(1500);
        r.p90 = Some(2400);
        r
    }

    fn sample() -> Pipelines {
        Pipelines {
            at: 1_800_000_000,
            summary: "2 pipelines in 2 repos, 1 red".into(),
            red: 1,
            rows: vec![
                pipe("red", "unity-core-playground", "Tests", Some(40)),
                pipe("ok", "binks", "CI", Some(100)),
            ],
            errors: vec![],
        }
    }

    #[test]
    fn each_drawn_column_is_a_hub_core_column() {
        for (_, key) in COLS {
            assert!(Pipeline::COLUMNS.contains(&key), "{key}");
        }
    }

    #[test]
    fn the_table_fits_eighty_and_keeps_state_pipeline_and_pass() {
        let l = PipelinesView::default().lines(Some(&sample()), Palette::default(), 80);
        let all: Vec<String> = l.iter().map(text).collect();
        assert_eq!(all[0], "PIPELINES");
        assert!(all.iter().all(|l| l.chars().count() <= 80), "{all:?}");
        let head = all.iter().find(|l| l.starts_with("STATE")).expect("header");
        for col in ["STATE", "PIPELINE", "NEXT", "PASS"] {
            assert!(head.contains(col), "{head}");
        }
        assert!(all.iter().any(|l| l.contains("red") && l.contains("40%")));
    }

    #[test]
    fn the_wide_table_draws_every_column() {
        let l = PipelinesView::default().lines(Some(&sample()), Palette::default(), 200);
        let head = l.iter().map(text).find(|l| l.starts_with("STATE")).unwrap();
        for (h, _) in COLS {
            assert!(head.contains(h), "{head}");
        }
    }

    #[test]
    fn a_chip_narrows_and_a_reselect_follows_the_row() {
        let p = sample();
        let mut v = PipelinesView::default();
        v.reselect(&p, Some(row_id(&p.rows[1])));
        assert_eq!(v.selected(&p).map(|r| r.pipeline.as_str()), Some("CI"));
        v.table.view.state = "red".into();
        assert_eq!(v.shown(&p).len(), 1);
        v.reselect(&p, Some(row_id(&p.rows[1])));
        assert_eq!(v.selected(&p).map(|r| r.pipeline.as_str()), Some("Tests"));
    }

    #[test]
    fn the_detail_says_why_its_file_and_its_runs() {
        let p = sample();
        let d = Detail {
            row: p.rows[0].clone(),
            purpose: Some("the one full run".into()),
            crons: vec!["0 2 * * * (02:00 daily)".into()],
            jobs: "EditMode, PlayMode".into(),
            night_title: None,
            runs: vec![],
        };
        let v = PipelinesView {
            open: Some(d),
            ..Default::default()
        };
        let all: Vec<String> = v
            .lines(Some(&p), Palette::default(), 80)
            .iter()
            .map(text)
            .collect();
        assert!(all.iter().any(|l| l == "> unity-core-playground / Tests"));
        assert!(all.iter().any(|l| l.contains("red - Tests is red")));
        assert!(all
            .iter()
            .any(|l| l.contains("File") && l.contains("tests.yml")));
        assert!(all
            .iter()
            .any(|l| l.contains("Cron") && l.contains("02:00 daily")));
        assert!(all.iter().any(|l| l.contains("none in the ledger")));
    }

    #[test]
    fn nothing_read_says_so() {
        let l = PipelinesView::default().lines(None, Palette::default(), 80);
        assert_eq!(text(&l[1]), "Reading pipelines...");
    }
}
