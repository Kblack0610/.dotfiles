//! Projects' Ladder inner tab (stages.md at a glance), built by `hub_core::stages` with the same
//! rows and words as agent-web's: the Gate, Filer and Kinds lines, Projects by stage (each staged
//! project against its next stage, failing first) and the Requirements of every stage. `t` moves
//! the keys between the two tables, which take the shared table keys; Enter on a project opens
//! its Stage page, Esc clears the view and then goes back to the list. This file reads nothing.

use hub_core::reading::NOT_READ;
use hub_core::stages::{Ladder, Project, Requirement, HUMAN};
use hub_core::vocab::Level;
use ratatui::crossterm::event::{KeyCode, KeyEvent};
use ratatui::style::Style;
use ratatui::text::{Line, Span};

use crate::datatable::{DataTable, Took};
use crate::fit::{cell, clip_line, Cell, Table};
use crate::fmt::Palette;
use crate::projtab::{wrapped, ProjView};
use crate::tasktab::TaskView;

/// How many rows of each table show at once; the rest scroll under the selection.
const ROWS: usize = 12;

const PHEADER: [&str; 7] = [
    "PROJECT", "TYPE", "STAGE", "NEXT", "MET", "FAILING", "FILED",
];
const RHEADER: [&str; 5] = ["STAGE", "APPLIES", "REQUIREMENT", "CHECK", "BY"];

/// The keys of the Ladder: `t` moves them between the tables, the shared table keys and moves
/// go to the one that has them, Enter opens a project's Stage page, Esc clears the view and then
/// goes back to the list. False for a key it does not take.
impl ProjView {
    pub fn lkey(
        &mut self,
        tv: &mut TaskView,
        k: KeyEvent,
        cards: &[hub_core::projects::Card],
        l: &Ladder,
        page: usize,
    ) -> bool {
        let took = if self.lreqs {
            let n = self.rv.view.apply(&l.requirements).len();
            self.rv.key::<Requirement>(k.code) != Took::No || self.rv.moves(k, n, page)
        } else {
            let n = self.lv.view.apply(&l.projects).len();
            self.lv.key::<Project>(k.code) != Took::No || self.lv.moves(k, n, page)
        };
        if took {
            return true;
        }
        let table = if self.lreqs {
            &mut self.rv
        } else {
            &mut self.lv
        };
        match k.code {
            KeyCode::Char('t') => self.lreqs = !self.lreqs,
            KeyCode::Enter if !self.lreqs => {
                let shown = self.lv.view.apply(&l.projects);
                if let Some(r) = shown.get(self.lv.sel.min(shown.len().saturating_sub(1))) {
                    let key = format!("{}/stage", r.key());
                    self.lfocus = false;
                    self.go(tv, cards, &key);
                }
            }
            KeyCode::Esc if !table.is_default() => table.clear(),
            KeyCode::Esc => self.lfocus = false,
            _ => return false,
        }
        true
    }
}

/// A line's style by its level: plain when ok, as agent-web draws it.
fn tone(l: Level, p: Palette) -> Style {
    match l {
        Level::Bad => p.bad(),
        Level::Warn => p.warn(),
        Level::Ok => Style::default(),
    }
}

/// The Ladder: Projects by stage's head, its three lines and the doc, its table, then the
/// Requirements; and the line the selected row is on.
pub fn page(
    l: Option<&Ladder>,
    pv: &ProjView,
    p: Palette,
    w: usize,
) -> (Vec<Line<'static>>, Option<usize>) {
    let Some(l) = l else {
        return (
            vec![head(
                "Projects by stage",
                "  reading the nightly stage pass",
                p,
                w,
            )],
            None,
        );
    };
    let hint = if pv.lreqs {
        "  t projects"
    } else {
        "  Enter opens its Stage page, t requirements"
    };
    let mut out = vec![head(
        "Projects by stage",
        &format!(
            "  {}{hint}",
            count(pv.lv.view.apply(&l.projects).len(), l.projects.len())
        ),
        p,
        w,
    )];
    if l.failing > 0 {
        out[0].spans[0].style = p.bad();
    }
    for (lead, says, level) in [
        ("Gate   ", &l.gate_says, l.gate_level),
        ("Filer  ", &l.filer_says, l.filer_level),
        ("Kinds  ", &l.kinds_says, l.kinds_level),
        ("Doc    ", &hub_core::stages::DOC.to_string(), Level::Ok),
    ] {
        out.extend(wrapped(lead, says, tone(level, p), p, w));
    }
    let mut at = None;
    let rows: Vec<Vec<Cell>> = pv
        .lv
        .view
        .apply(&l.projects)
        .iter()
        .map(|r| prow(r, p))
        .collect();
    let none = if !l.projects_says.is_empty() {
        l.projects_says.clone()
    } else if l.projects.is_empty() {
        "No project is at dev or later.".into()
    } else {
        "No project matches.".into()
    };
    let t = Table {
        header: PHEADER.to_vec(),
        keep: vec![0, 5, 2, 4, 3, 6, 1],
        right: vec![4, 5, 6],
        cap: vec![(0, 28)],
        mark: pv.lv.mark::<Project>(),
        ..Default::default()
    };
    section(
        &mut out,
        &mut at,
        &pv.lv,
        pv.lv.status(&l.projects, p),
        rows,
        t,
        &none,
        !pv.lreqs,
        p,
        w,
    );
    out.push(Line::raw(""));
    out.push(head(
        "Requirements",
        &format!(
            "  {}",
            count(
                pv.rv.view.apply(&l.requirements).len(),
                l.requirements.len()
            )
        ),
        p,
        w,
    ));
    let rows: Vec<Vec<Cell>> = pv
        .rv
        .view
        .apply(&l.requirements)
        .iter()
        .map(|r| rrow(r, p))
        .collect();
    let none = if !l.requirements_says.is_empty() {
        l.requirements_says.clone()
    } else if l.requirements.is_empty() {
        "stages.md has no Requirements rows.".into()
    } else {
        "No requirement matches.".into()
    };
    let t = Table {
        header: RHEADER.to_vec(),
        keep: vec![0, 3, 1, 4],
        flex: Some(2),
        flexmin: 20,
        flexkeep: true,
        mark: pv.rv.mark::<Requirement>(),
        ..Default::default()
    };
    section(
        &mut out,
        &mut at,
        &pv.rv,
        pv.rv.status(&l.requirements, p),
        rows,
        t,
        &none,
        pv.lreqs,
        p,
        w,
    );
    out.push(Line::raw(""));
    (out, at)
}

/// `n` or `n of total`, the way every head counts what the view keeps.
fn count(n: usize, total: usize) -> String {
    if n == total {
        total.to_string()
    } else {
        format!("{n} of {total}")
    }
}

fn head(says: &str, hint: &str, p: Palette, w: usize) -> Line<'static> {
    clip_line(
        Line::from(vec![
            Span::styled(says.to_string(), p.head()),
            Span::styled(hint.to_string(), p.dim()),
        ]),
        w,
    )
}

/// One table under its chips: the rows the view keeps, `ROWS` at a time around the selection when
/// it has the keys, or why there are none.
#[allow(clippy::too_many_arguments)]
fn section(
    out: &mut Vec<Line<'static>>,
    at: &mut Option<usize>,
    dt: &DataTable,
    chips: Vec<Span<'static>>,
    rows: Vec<Vec<Cell>>,
    mut t: Table,
    none: &str,
    focus: bool,
    p: Palette,
    w: usize,
) {
    out.push(clip_line(Line::from(chips), w));
    if rows.is_empty() {
        out.push(Line::styled(none.to_string(), p.dim()));
        return;
    }
    let n = rows.len();
    let sel = dt.sel.min(n - 1);
    let top = if focus {
        (sel + 1).saturating_sub(ROWS)
    } else {
        0
    };
    t.rows = rows.into_iter().skip(top).take(ROWS).collect();
    let seen = t.rows.len();
    let mut lines = t.fit(w, p.head());
    if focus {
        if let Some(l) = lines.get_mut(sel - top + 1) {
            l.style = p.sel();
            *at = Some(out.len() + sel - top + 1);
        }
    }
    out.append(&mut lines);
    let (before, after) = (top, n - top - seen);
    if before + after > 0 {
        out.push(Line::styled(
            format!("  {before} above, {after} below"),
            p.dim(),
        ));
    }
}

fn dash(s: &str) -> String {
    if s.is_empty() {
        "-".into()
    } else {
        s.into()
    }
}

/// A project's cells, the same words as agent-web's row: a check that could not run says so in
/// red, never zero; a failing count is red, and the not-yet rows beside it are a TODO.
fn prow(r: &Project, p: Palette) -> Vec<Cell> {
    let failing = match (&r.error, r.fail, r.todo) {
        (Some(_), ..) => cell(NOT_READ, p.bad()),
        (None, f, 0) => cell(
            f.to_string(),
            if f > 0 { p.bad() } else { Style::default() },
        ),
        (None, f, t) => cell(
            format!("{f} {t} todo"),
            if f > 0 { p.bad() } else { Style::default() },
        ),
    };
    vec![
        r.name.clone().into(),
        dash(r.kind.as_deref().unwrap_or("")).into(),
        dash(&r.stage).into(),
        dash(&r.next).into(),
        dash(&r.met_says).into(),
        failing,
        r.filed_says.clone().into(),
    ]
}

/// A requirement's cells: its check kind as the doc's word, a human one amber, a not-yet one dim.
fn rrow(r: &Requirement, p: Palette) -> Vec<Cell> {
    let style = match r.says {
        HUMAN => p.warn(),
        hub_core::stages::NOT_YET => p.dim(),
        _ => Style::default(),
    };
    vec![
        r.stage.clone().into(),
        r.applies.join(" ").into(),
        r.requirement.clone().into(),
        cell(r.says, style),
        dash(&r.skills.join(" ")).into(),
    ]
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ladder() -> Ladder {
        let p = |name: &str, fail: u32, error: Option<&str>, state: &'static str| Project {
            name: name.into(),
            profile: "bnb".into(),
            stage: "dev".into(),
            next: "alpha".into(),
            fail,
            todo: 2,
            error: error.map(Into::into),
            state,
            met_says: "3/5".into(),
            filed_says: "2/1".into(),
            ..Default::default()
        };
        Ladder {
            projects: vec![
                p("busy", 2, None, "failing"),
                p("odd", 0, Some("no stage"), "not read"),
            ],
            requirements: vec![Requirement {
                stage: "prod".into(),
                applies: vec!["game".into(), "store".into()],
                requirement: "Store page signed off, with every listing field, screenshot, rating and price filled in".into(),
                check: "human".into(),
                says: HUMAN,
                ..Default::default()
            }],
            gate_says: "report only until 2026-11-19 (in 6 days)".into(),
            gate_level: Level::Warn,
            filer_says: "nightly, last 04:30 today: 2 filed".into(),
            kinds_says: "on fix feat; off legal".into(),
            failing: 2,
            ..Default::default()
        }
    }

    fn text(l: &[Line]) -> Vec<String> {
        l.iter()
            .map(|l| l.spans.iter().map(|s| s.content.as_ref()).collect())
            .collect()
    }

    #[test]
    fn the_ladder_says_its_lines_then_both_tables_at_80_columns() {
        let p = Palette::default();
        let (l, at) = page(Some(&ladder()), &ProjView::default(), p, 80);
        let t = text(&l);
        assert!(t.iter().all(|s| crate::fit::len(s) <= 80), "{t:#?}");
        assert!(t[0].starts_with("Projects by stage  2"));
        assert_eq!(
            l[0].spans[0].style,
            p.bad(),
            "a failing project reddens the head"
        );
        assert!(t
            .iter()
            .any(|s| s.starts_with("Gate   report only until 2026-11-19")));
        assert!(t
            .iter()
            .any(|s| s.starts_with("Kinds  on fix feat; off legal")));
        assert!(t
            .iter()
            .any(|s| s.starts_with("Doc    ~/.local/src/docs/stages.md")));
        let busy = t.iter().find(|s| s.starts_with("busy")).expect("busy row");
        assert!(busy.contains("2 2 todo"), "{busy}");
        let odd = t.iter().find(|s| s.starts_with("odd")).expect("odd row");
        assert!(
            odd.contains(NOT_READ),
            "a check that could not run says so: {odd}"
        );
        assert!(t.iter().any(|s| s.starts_with("Requirements  1")));
        assert!(t
            .iter()
            .any(|s| s.contains("Store page signed off") && s.contains("human")));
        assert!(
            t.iter()
                .any(|s| s.starts_with("STAGE") && s.contains("CHECK")),
            "a long requirement clips; its stage and check stay: {t:#?}"
        );
        let at = at.expect("the projects table has the keys first");
        assert!(
            t[at].starts_with("busy"),
            "the cursor is on the first project: {}",
            t[at]
        );
        // NEGATIVE CONTROL: nothing failing, a plain head.
        let calm = Ladder {
            failing: 0,
            ..ladder()
        };
        let (l, _) = page(Some(&calm), &ProjView::default(), p, 80);
        assert_eq!(l[0].spans[0].style, p.head());
    }

    #[test]
    fn t_moves_the_keys_and_enter_opens_the_projects_stage_page() {
        let mut pv = ProjView {
            lfocus: true,
            ..Default::default()
        };
        let mut tv = TaskView::default();
        let l = ladder();
        let cards = [hub_core::projects::Card {
            profile: "bnb".into(),
            name: "busy".into(),
            ..Default::default()
        }];
        assert!(pv.lkey(&mut tv, KeyEvent::from(KeyCode::Char('t')), &cards, &l, 10));
        assert!(pv.lreqs);
        assert!(
            !pv.lkey(&mut tv, KeyEvent::from(KeyCode::Enter), &cards, &l, 10),
            "Enter on a requirement opens nothing"
        );
        assert!(pv.lkey(&mut tv, KeyEvent::from(KeyCode::Char('t')), &cards, &l, 10));
        assert!(pv.lkey(&mut tv, KeyEvent::from(KeyCode::Enter), &cards, &l, 10));
        assert!(!pv.lfocus, "Enter leaves the Ladder for the project");
        assert_eq!(tv.project, Some(("bnb".into(), "busy".into())));
        assert_eq!(pv.inner, "stage");
    }
}
