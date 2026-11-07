//! Home's Proposals table: `hub_core::proposals` on the shared data table (`datatable`: `/`
//! query, `f` state, `s`/`S` sort, `x` clear), with the selected record under it. `a` accepts
//! and `d` rejects, through the CLI that runs the verb.

use hub_core::proposals::Proposal;
use ratatui::text::{Line, Span};

use crate::datatable::DataTable;
use crate::fit::{clip_line, Cell, Table};
use crate::fmt::Palette;

/// `Proposal::COLUMNS` in capitals, in its order: the sort mark is placed by that index.
const HEADER: [&str; 5] = ["STREAM", "PROJECT", "PROPOSAL", "AGE", "VERB"];

#[derive(Default)]
pub struct ProposalsView {
    /// The query, state chip and sort, applied by `hub_core::table::View` as agent-web does.
    pub table: DataTable,
    pub sel: usize,
    pub top: usize,
    /// Home's section opened as the whole table.
    pub open: bool,
    /// The selected record's lines show under the table.
    pub detail: bool,
    /// What the last accept or reject answered.
    pub said: Option<Result<String, String>>,
}

impl ProposalsView {
    pub fn shown<'a>(&self, rows: &'a [Proposal]) -> Vec<&'a Proposal> {
        self.table.view.apply(rows)
    }

    pub fn selected<'a>(&self, rows: &'a [Proposal]) -> Option<&'a Proposal> {
        self.shown(rows).get(self.sel).copied()
    }

    /// The view on the left, how many it keeps on the right, and the last decision's answer.
    pub fn status(&self, rows: &[Proposal], p: Palette) -> Vec<Line<'static>> {
        let mut spans = self.table.status(rows, p);
        spans.push(Span::styled(
            format!("    {} of {}", self.shown(rows).len(), rows.len()),
            p.dim(),
        ));
        let mut out = vec![Line::from(spans)];
        match &self.said {
            Some(Ok(s)) => out.push(Line::styled(s.clone(), p.dim())),
            Some(Err(e)) => out.push(Line::styled(e.clone(), p.warn())),
            None => {}
        }
        out
    }

    /// A header line, then one line per shown row, the selected one marked.
    pub fn lines(&self, rows: &[Proposal], p: Palette, now: i64, w: usize) -> Vec<Line<'static>> {
        let shown = self.shown(rows);
        if shown.is_empty() {
            let why = if rows.is_empty() {
                "nothing proposed"
            } else {
                "no proposal matches (/ query, f state, x clears)"
            };
            return vec![Line::styled(why, p.dim())];
        }
        let cells: Vec<Vec<Cell>> = shown
            .iter()
            .map(|r| {
                vec![
                    r.stream.clone().into(),
                    r.project.clone().into(),
                    r.title.clone().into(),
                    crate::hometab::age(r.at(), now).into(),
                    r.verb.clone().into(),
                ]
            })
            .collect();
        let mut out = Table {
            header: HEADER.to_vec(),
            rows: cells,
            keep: vec![2, 3, 0, 1, 4],
            flex: Some(2),
            flexmin: 20,
            flexkeep: true,
            right: vec![3],
            cap: vec![(0, 18), (1, 18)],
            mark: self.table.mark::<Proposal>(),
        }
        .fit(w, p.head());
        if let Some(l) = out.get_mut(self.sel + 1) {
            l.style = p.sel();
        }
        out
    }

    /// The selected record: why, the evidence and exactly what an accept runs.
    pub fn record(&self, rows: &[Proposal], p: Palette, w: usize) -> Vec<Line<'static>> {
        let Some(r) = self.selected(rows) else {
            return vec![];
        };
        let field = |k: &str, v: &str| {
            clip_line(
                Line::from(vec![
                    Span::styled(format!("{k:<12}"), p.head()),
                    Span::raw(v.to_string()),
                ]),
                w,
            )
        };
        let mut out = vec![field("proposal", &r.title), field("why", &r.why)];
        if !r.evidence.is_empty() {
            out.push(field("evidence", &r.evidence));
        }
        out.push(field("accept runs", &r.does));
        if let Some(e) = &r.error {
            out.push(field("last failed", e));
        }
        out.push(field("expires", &r.expires));
        out
    }
}
