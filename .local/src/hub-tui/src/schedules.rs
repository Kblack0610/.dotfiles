//! The Schedules page: everything `hub_core::schedules::read` finds on the shared data table
//! (`datatable`: `/` query, `f` state, `s`/`S` sort, `x` clear), with the selected row's purpose,
//! insides, what reads its result and its runs in a pane under the list.

use hub_core::schedules::{Schedule, Schedules};
use ratatui::style::Style;
use ratatui::text::{Line, Span};

use crate::datatable::DataTable;
use crate::fit::{cell, wrap, Cell, Table};
use crate::fmt::{clock, Palette};

/// `Schedule::COLUMNS` in capitals, in its order, the sort mark placed by that index. `repo` and
/// `next` sort and filter without a column: the name says the one, the pane the other.
const HEADER: [&str; 7] = [
    "KIND", "NAME", "SCHEDULE", "LAST", "RESULT", "STREAK", "TRIAGE",
];
/// The width of the pane's labels, as the longest one.
const LABEL: usize = 14;
/// NAME and SCHEDULE at 80 columns, what leaves TRIAGE room, and at their widest: each takes half
/// of whatever a wider terminal adds.
const NAME_FIT: (usize, usize) = (22, 44);
const SCHEDULE_FIT: (usize, usize) = (12, 32);

#[derive(Default)]
pub struct SchedulesView {
    /// The query, state chip and sort, applied by `hub_core::table::View` as agent-web does.
    pub table: DataTable,
    pub sel: usize,
    pub top: usize,
    /// Whether the pane is open, and how far it is scrolled.
    pub open: bool,
    pub down: usize,
}

/// The row a selection stands for, so a refresh keeps the same schedule selected.
pub type RowId = (String, String);

pub fn row_id(r: &Schedule) -> RowId {
    (r.kind.clone(), r.name.clone())
}

impl SchedulesView {
    /// The rows the view keeps, in its sort or the reader's order.
    pub fn shown<'a>(&self, s: &'a Schedules) -> Vec<&'a Schedule> {
        self.table.view.apply(&s.rows)
    }

    /// Move the selection to the row with this id after a refresh, or keep the index in range.
    pub fn reselect(&mut self, s: &Schedules, id: Option<RowId>) {
        let rows = self.shown(s);
        if let Some(i) = id.and_then(|id| rows.iter().position(|r| row_id(r) == id)) {
            self.sel = i;
        }
        self.sel = self.sel.min(rows.len().saturating_sub(1));
    }

    /// The reader's summary, then the view and how many rows it keeps.
    pub fn status(&self, s: &Schedules, p: Palette) -> Vec<Line<'static>> {
        let mut spans = self.table.status(&s.rows, p);
        spans.push(Span::styled(
            format!("    {} of {}", self.shown(s).len(), s.rows.len()),
            p.dim(),
        ));
        let mut out = vec![Line::styled(s.summary.clone(), p.head()), Line::from(spans)];
        if !s.errors.is_empty() {
            out.push(Line::styled(
                format!("unread: {}", s.errors.join("; ")),
                p.warn(),
            ));
        }
        out
    }

    /// The table: a header line, then one line per shown row. `sel` marks the selected row.
    pub fn table(&self, s: &Schedules, p: Palette, w: usize, sel: bool) -> Vec<Line<'static>> {
        let rows = self.shown(s);
        if rows.is_empty() {
            return vec![Line::styled(
                if s.rows.is_empty() {
                    "nothing is scheduled"
                } else {
                    "no schedule matches (/ query, f state, x clears)"
                },
                p.dim(),
            )];
        }
        let spare = w.saturating_sub(80) / 2;
        let fit = |(least, most): (usize, usize)| (least + spare).min(most);
        let name = fit(NAME_FIT);
        let cells: Vec<Vec<Cell>> = rows.iter().map(|r| row(r, p, s.at, name)).collect();
        // The mark of a column with no header (`repo`, `next`) has nothing to sit on.
        let mark = self
            .table
            .mark::<Schedule>()
            .filter(|(i, _)| *i < HEADER.len());
        let mut out = Table {
            header: HEADER.to_vec(),
            rows: cells,
            keep: vec![1, 4, 5, 2, 3, 0],
            flex: Some(6),
            flexmin: 14,
            flexkeep: true,
            right: vec![3],
            cap: vec![(1, name), (2, fit(SCHEDULE_FIT)), (4, 8)],
            mark,
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

/// `name` in `w` columns. A CI name gives up its repo first: every workflow of one repo clipped
/// from the end would read the same.
fn short(name: &str, w: usize) -> String {
    match name.split_once(" / ") {
        Some((repo, job)) if name.len() > w && job.len() + 5 < w => {
            let keep: String = repo.chars().take(w - job.len() - 4).collect();
            format!("{keep}~ / {job}")
        }
        _ => name.to_string(),
    }
}

fn row(r: &Schedule, p: Palette, now: i64, name: usize) -> Vec<Cell> {
    let result = match r.ok {
        Some(false) => cell(r.result.clone(), p.bad()),
        _ if r.result.is_empty() => "-".into(),
        _ => r.result.clone().into(),
    };
    let streak = if r.streak < 0 {
        cell(r.streak_text(), p.bad())
    } else {
        r.streak_text().into()
    };
    vec![
        r.kind.clone().into(),
        // Amber says it has no purpose; the pane and the `no-purpose` chip say it in words.
        cell(
            short(&r.name, name),
            if r.purpose.is_empty() {
                p.warn()
            } else {
                Style::default()
            },
        ),
        r.schedule.clone().into(),
        // The day alone for an older run; the pane has its time.
        r.last
            .map_or("-".into(), |t| {
                clock(t, now).split(' ').next().unwrap_or("-").to_string()
            })
            .into(),
        result,
        streak,
        r.triage.clone().into(),
    ]
}

/// The pane: the row's status, then each part that has anything to say, wrapped to `w`.
pub fn detail(r: &Schedule, p: Palette, now: i64, w: usize) -> Vec<Line<'static>> {
    let mut out = vec![
        Line::styled(format!("> {}", r.name), p.head()),
        Line::styled(format!("  {}", r.status), p.dim()),
    ];
    if r.purpose.is_empty() {
        out.push(Line::styled(
            "  no purpose written: it says what it is, not why it runs",
            p.warn(),
        ));
    }
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
    part("Why it exists", &r.purpose);
    part("Inside", &r.inside);
    part("Before", &r.before);
    for a in &r.after {
        part("After", a);
    }
    for o in &r.open {
        part("Open triage", o);
    }
    for u in &r.runs {
        let at = u.at.map_or("-".into(), |t| clock(t, now));
        let failed = u.failed.join(", ");
        part("Run", format!("{at} {} {failed}", u.result).trim());
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use hub_core::schedules::Run;

    fn sample() -> Schedules {
        let blank = Schedule::default();
        let row = |kind: &str, name: &str, streak: i32, purpose: &str| {
            let mut r = blank.clone();
            r.kind = kind.into();
            r.name = name.into();
            r.schedule = "02:00 daily".into();
            r.streak = streak;
            r.ok = Some(streak > 0);
            r.result = if streak > 0 { "success" } else { "failure" }.into();
            r.purpose = purpose.into();
            r.triage = "-".into();
            r
        };
        Schedules {
            at: 1_794_002_400,
            summary: "2 scheduled, 1 red, 1 no purpose".into(),
            rows: vec![
                row("ci", "app / Tests", -3, "the one full run"),
                row("timer", "journal", 9, ""),
            ],
            errors: vec!["k8s: prometheus down".into()],
        }
    }

    fn text(l: &Line) -> String {
        l.spans.iter().map(|s| s.content.as_ref()).collect()
    }

    #[test]
    fn the_header_is_hub_cores_columns() {
        use hub_core::table::Row;
        let lower: Vec<String> = HEADER.iter().map(|h| h.to_lowercase()).collect();
        let all = Schedule::COLUMNS;
        assert_eq!(lower, all[..HEADER.len()]);
        assert_eq!(all[HEADER.len()..], ["repo", "next"]);
    }

    #[test]
    fn the_status_says_the_summary_the_view_and_what_was_not_read() {
        let st = SchedulesView::default().status(&sample(), Palette::default());
        assert_eq!(text(&st[0]), "2 scheduled, 1 red, 1 no purpose");
        assert!(text(&st[1]).ends_with("2 of 2"), "{:?}", text(&st[1]));
        assert_eq!(text(&st[2]), "unread: k8s: prometheus down");
    }

    #[test]
    fn the_table_fits_eighty_columns_and_keeps_the_exception_columns() {
        let mut s = sample();
        s.rows[0].name = "unity-core-playground / Perf round".into();
        s.rows[0].schedule = "02:20, 08:20, 14:20, 20:20 daily".into();
        s.rows[0].triage = "no fix ar-485".into();
        let t = SchedulesView::default().table(&s, Palette::default(), 80, false);
        let head = text(&t[0]);
        for col in ["NAME", "SCHEDULE", "LAST", "RESULT", "STREAK", "TRIAGE"] {
            assert!(head.contains(col), "{head}");
        }
        assert!(t.iter().all(|l| text(l).chars().count() <= 80));
        assert!(text(&t[1]).contains("~ / Perf round"), "{}", text(&t[1]));
        assert!(text(&t[1]).contains("no fix ar-485"), "{}", text(&t[1]));
        assert!(text(&t[1]).contains("red 3"), "{}", text(&t[1]));
    }

    #[test]
    fn a_short_name_gives_up_the_repo_and_keeps_the_workflow() {
        assert_eq!(short("app / Tests", 24), "app / Tests");
        assert_eq!(
            short("unity-core-playground / Multi", 24),
            "unity-core-play~ / Multi"
        );
        assert_eq!(short("repo / a workflow far too long for it", 24).len(), 37);
        assert_eq!(short("ns/job-with-a-long-enough-name", 24).len(), 30);
    }

    #[test]
    fn a_sort_on_a_column_with_no_header_still_draws() {
        let mut v = SchedulesView::default();
        v.table.view.sort = "next".into();
        let t = v.table(&sample(), Palette::default(), 80, false);
        assert_eq!(t.len(), 3);
    }

    #[test]
    fn a_reselect_follows_the_row_and_keeps_the_index_in_range() {
        let s = sample();
        let mut v = SchedulesView::default();
        v.reselect(&s, Some(("timer".into(), "journal".into())));
        assert_eq!(v.sel, 1);
        v.sel = 9;
        v.reselect(&s, Some(("ci".into(), "gone".into())));
        assert_eq!(v.sel, 1);
    }

    #[test]
    fn the_pane_wraps_its_parts_and_says_a_purpose_is_missing() {
        let s = sample();
        let mut r = s.rows[0].clone();
        r.status = "red since 11-01, next 02:00".into();
        r.purpose = "word ".repeat(40);
        r.after = vec!["Sentinel n (pages urgent)".into()];
        r.runs = vec![Run {
            at: Some(s.at),
            result: "failure".into(),
            ok: Some(false),
            failed: vec!["PlayMode 2".into()],
            url: String::new(),
        }];
        let lines: Vec<String> = detail(&r, Palette::default(), s.at, 60)
            .iter()
            .map(text)
            .collect();
        assert_eq!(lines[0], "> app / Tests");
        assert!(lines[1].contains("red since 11-01"));
        let why: Vec<&String> = lines.iter().filter(|l| l.contains("word")).collect();
        assert!(why.len() > 1 && why[0].contains("Why it exists"), "{why:?}");
        assert!(lines.iter().all(|l| l.chars().count() <= 60), "{lines:?}");
        assert!(lines.iter().any(|l| l.contains("failure PlayMode 2")));

        let none = detail(&s.rows[1], Palette::default(), s.at, 60);
        assert!(text(&none[2]).contains("no purpose written"));
    }
}
