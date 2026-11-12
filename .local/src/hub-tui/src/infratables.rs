//! Infra's five tables (Machines: machines and pools; CI: runners, queued, finished), drawn from
//! the rows `hub_core` builds once for both surfaces (`hub_core::machines`, `hub_core::ci`) on the
//! shared data table. Each table keeps its own view; the tables of the inner tab shown take the
//! table keys (`/ f s S x`) one at a time, and `c` passes them to the next. agent-web draws the
//! same rows from the same summary.

use hub_core::ci::{Finished, Queued, Slot, Tally};
use hub_core::infra::Infra;
use hub_core::links::Link;
use hub_core::machines::{Machine, Pool};
use hub_core::table::Row;
use ratatui::crossterm::event::{KeyCode, KeyEvent};
use ratatui::style::Style;
use ratatui::text::{Line, Span};

use crate::datatable::{DataTable, Took};
use crate::fit::{cell, clip_line, Cell, Table};
use crate::fmt::{clock, dur, pct, Palette};

/// The tables in `hub_core::layout` section order; an index here is a table's view.
pub const TABLES: [&str; 5] = ["machines", "pools", "runners", "queued", "finished"];

/// Finished rows drawn before `+N more`, as on the web.
const FINISHED_ROWS: usize = 25;

/// The page section that marks the selected row's line, so the page keeps it in view; no
/// section for n/N.
pub const ROW: &str = "row";

/// Each table's view, and which one has the keys.
#[derive(Debug, Default)]
pub struct InfraTables {
    pub views: [DataTable; 5],
    pub at: usize,
    /// A key moved the selection, so the next draw scrolls it into view.
    pub follow: bool,
}

impl InfraTables {
    /// The tables an inner tab shows, as indexes into `TABLES`.
    pub fn on(inner: &str) -> &'static [usize] {
        match inner {
            "machines" => &[0, 1],
            "ci" => &[2, 3, 4],
            _ => &[],
        }
    }

    /// The table with the keys on this inner tab: the one last given them, else its first.
    pub fn focus(&self, inner: &str) -> Option<usize> {
        let on = Self::on(inner);
        on.contains(&self.at)
            .then_some(self.at)
            .or(on.first().copied())
    }

    /// The keys pass to the inner tab's next table, wrapping.
    pub fn cycle(&mut self, inner: &str) {
        let on = Self::on(inner);
        if let Some(i) = self
            .focus(inner)
            .and_then(|f| on.iter().position(|x| *x == f))
        {
            self.at = on[(i + 1) % on.len()];
        }
    }

    /// The view of table `name`, for a link or alias that opens it under a chip.
    pub fn view(&mut self, name: &str) -> Option<&mut DataTable> {
        let i = TABLES.iter().position(|t| *t == name)?;
        self.at = i;
        Some(&mut self.views[i])
    }

    /// A table key for the inner tab's table with the keys; `f` steps over the chips these rows
    /// show, so it needs them. Esc with nothing to clear is not the table's, so the page can
    /// take it.
    pub fn key(&mut self, infra: Option<&Infra>, inner: &str, code: KeyCode) -> Took {
        let Some(i) = self.focus(inner) else {
            return Took::No;
        };
        self.at = i;
        let t = &mut self.views[i];
        if code == KeyCode::Esc && t.typing.is_none() {
            if t.is_default() {
                return Took::No;
            }
            t.clear();
            return Took::View;
        }
        if !DataTable::owns(code) && t.typing.is_none() {
            return Took::No;
        }
        if code == KeyCode::Char('f') && t.typing.is_none() {
            let Some(r) = infra else {
                return Took::No;
            };
            let v = &mut t.view;
            match i {
                0 => v.cycle_shown(&r.machines),
                1 => v.cycle_shown(&r.pools),
                2 => v.cycle_shown(&r.ci.rows),
                3 => v.cycle_shown(&r.ci.queue),
                _ => v.cycle_shown(&r.ci.finished),
            }
            t.sel = 0;
            return Took::View;
        }
        match i {
            0 => t.key::<Machine>(code),
            1 => t.key::<Pool>(code),
            2 => t.key::<Slot>(code),
            3 => t.key::<Queued>(code),
            _ => t.key::<Finished>(code),
        }
    }

    /// The rows the table with the keys shows, at most its cap: what j/k step through.
    fn shown_len(&self, infra: &Infra, i: usize) -> usize {
        let v = &self.views[i].view;
        match i {
            0 => v.apply(&infra.machines).len(),
            1 => v.apply(&infra.pools).len(),
            2 => v.apply(&infra.ci.rows).len(),
            3 => v.apply(&infra.ci.queue).len(),
            _ => v.apply(&infra.ci.finished).len().min(FINISHED_ROWS),
        }
    }

    /// j/k, g/G and Home/End move the selection in the table with the keys; PgUp/PgDn and
    /// Ctrl-d/u stay the page's scroll.
    pub fn moves(&mut self, infra: Option<&Infra>, inner: &str, k: KeyEvent) -> bool {
        let (Some(infra), Some(i)) = (infra, self.focus(inner)) else {
            return false;
        };
        if !matches!(
            k.code,
            KeyCode::Char('j' | 'k' | 'g' | 'G')
                | KeyCode::Up
                | KeyCode::Down
                | KeyCode::Home
                | KeyCode::End
        ) {
            return false;
        }
        let n = self.shown_len(infra, i);
        self.at = i;
        let moved = self.views[i].moves(k, n, 1);
        self.follow |= moved;
        moved
    }

    /// What Enter opens: the selected row's record in the table with the keys (`Row::link`).
    pub fn opens(&self, infra: Option<&Infra>, inner: &str) -> Option<Link> {
        let (infra, i) = (infra?, self.focus(inner)?);
        let t = &self.views[i];
        fn sel<R: Row>(t: &DataTable, rows: &[R]) -> Option<Link> {
            DataTable::opens(*t.view.apply(rows).get(t.sel)?)
        }
        match i {
            0 => sel(t, &infra.machines),
            1 => sel(t, &infra.pools),
            2 => sel(t, &infra.ci.rows),
            3 => sel(t, &infra.ci.queue),
            _ => sel(t, &infra.ci.finished),
        }
    }

    /// Table `name` drawn from `infra`, its head carrying its chips and, when it has the keys,
    /// what they are.
    pub fn draw(
        &self,
        infra: &Infra,
        name: &str,
        inner: &str,
        p: Palette,
        now: i64,
        w: usize,
    ) -> Vec<Line<'static>> {
        let Some(i) = TABLES.iter().position(|t| *t == name) else {
            return vec![];
        };
        let d = Draw {
            t: &self.views[i],
            keys: self.focus(inner) == Some(i),
            more: Self::on(inner).len() > 1,
            p,
            w,
        };
        match i {
            0 => machines(&d, &infra.machines, now),
            1 => pools(&d, &infra.pools),
            2 => runners(&d, &infra.ci.rows),
            3 => queued(&d, &infra.ci.queue),
            _ => finished(&d, &infra.ci.finished, &infra.ci.done),
        }
    }
}

/// What one table is drawn with.
struct Draw<'a> {
    t: &'a DataTable,
    /// It has the table keys.
    keys: bool,
    /// Another table on the inner tab can take them (`c`).
    more: bool,
    p: Palette,
    w: usize,
}

impl Draw<'_> {
    /// The head line (title, chips, query, sort, keys), then the table, or a line saying why
    /// there is none. `cap` rows at most, the rest a `+N more` line.
    fn table<R: Row>(
        &self,
        title: String,
        rows: &[R],
        empty: &'static str,
        cap: Option<usize>,
        cells: impl Fn(&R) -> Vec<Cell>,
        shape: Table,
    ) -> Vec<Line<'static>> {
        let p = self.p;
        if rows.is_empty() && self.t.is_default() {
            return vec![clip_line(
                Line::from(vec![
                    Span::styled(title, p.head()),
                    Span::raw("  "),
                    Span::styled(empty, p.dim()),
                ]),
                self.w,
            )];
        }
        let mut head = vec![Span::styled(title, p.head()), Span::raw("  ")];
        head.extend(self.t.status(rows, p));
        if self.keys {
            let c = if self.more { ", c next table" } else { "" };
            head.push(Span::styled(format!("   [/ f s S x{c}]"), p.dim()));
        }
        let mut out = vec![clip_line(Line::from(head), self.w)];
        let shown = self.t.view.apply(rows);
        if shown.is_empty() {
            out.push(Line::styled(
                "no row matches (/ query, f state, x clears)",
                p.dim(),
            ));
            return out;
        }
        let n = cap.unwrap_or(shown.len()).min(shown.len());
        let mut lines = Table {
            rows: shown[..n].iter().map(|r| cells(r)).collect(),
            mark: self.t.mark::<R>(),
            ..shape
        }
        .fit(self.w, p.head());
        // The table with the keys marks its selected row, which Enter opens.
        if self.keys {
            if let Some(l) = lines.get_mut(self.t.sel.min(n.saturating_sub(1)) + 1) {
                l.style = p.sel();
            }
        }
        out.extend(lines);
        if shown.len() > n {
            out.push(Line::styled(
                format!("+{} more: / or f narrows", shown.len() - n),
                p.dim(),
            ));
        }
        out
    }
}

fn or_dash(s: String) -> Cell {
    if s.is_empty() {
        "-".into()
    } else {
        s.into()
    }
}

fn num(v: Option<f64>) -> Cell {
    v.map_or("-".into(), |x| format!("{x:.0}").into())
}

/// `Machine::COLUMNS` in capitals.
const MACHINE_HEAD: [&str; 15] = [
    "MACHINE", "WHERE", "STATE", "BUSY", "CPU", "6H", "LOAD", "MEM", "TEMP", "DISK", "POOLS",
    "RUNNING", "GOVERNOR", "POWER", "UP",
];

/// One row per machine. Narrowing keeps the machine, busy, cpu and pools longest.
fn machines(d: &Draw, rows: &[Machine], now: i64) -> Vec<Line<'static>> {
    let p = d.p;
    d.table(
        "MACHINES".into(),
        rows,
        "no machine reports",
        None,
        |m| {
            let state = match m.state.as_str() {
                "up" => Style::default(),
                "no reading" => p.dim(),
                _ => p.warn(),
            };
            let busy = match m.off {
                0 => m.busy_cell().into(),
                n => cell(format!("{} +{n} off", m.busy_cell()), p.warn()),
            };
            let load = match (m.load, m.cores) {
                (None, _) => "-".into(),
                (Some(l), c) => {
                    let s = format!("{l:.1}/{}", c.map_or("?".into(), |c| format!("{c:.0}")));
                    if c.is_some_and(|c| l > c * 1.5) {
                        cell(s, p.warn())
                    } else {
                        s.into()
                    }
                }
            };
            let temp = match m.temp {
                None => "-".into(),
                Some(t) if t > 85.0 => cell(format!("{t:.0}C"), p.warn()),
                Some(t) => format!("{t:.0}C").into(),
            };
            let power = m.power.as_ref().map_or("-".into(), |w| {
                let mut s = w.state.clone();
                match w.max {
                    Some(max) => s += &format!(" {:.1}/{max:.0}h", w.hours),
                    None => s += &format!(" {:.1}h", w.hours),
                }
                if !w.hold.is_empty() {
                    s += &format!(" held {}", w.hold);
                }
                s
            });
            vec![
                m.host.clone().into(),
                m.place.clone().into(),
                cell(&m.state, state),
                busy,
                pct(m.cpu).into(),
                pct(m.cpu6h).into(),
                load,
                pct(m.mem).into(),
                temp,
                pct(m.disk).into(),
                or_dash(m.pools.join("  ")),
                or_dash(m.running.join(", ")),
                m.governor.as_ref().map_or("-".into(), |g| g.says().into()),
                power.into(),
                m.boot.map_or("-".into(), |b| clock(b as i64, now).into()),
            ]
        },
        Table {
            header: MACHINE_HEAD.to_vec(),
            keep: vec![0, 3, 4, 10, 2, 6, 11, 1, 5, 7, 8, 12, 13, 9, 14],
            right: vec![3, 4, 5, 6, 7, 8, 9],
            cap: vec![(10, 36), (11, 40), (13, 28)],
            ..Default::default()
        },
    )
}

const POOL_HEAD: [&str; 9] = [
    "POOL", "SLOTS", "BUSY", "WITHHELD", "WAITING", "OLDEST", "DONE 24H", "PASS", "MACHINES",
];

/// One row per runner pool, the longest queue first.
fn pools(d: &Draw, rows: &[Pool]) -> Vec<Line<'static>> {
    let p = d.p;
    let warn = |v: Option<f64>| match v {
        Some(x) if x > 0.0 => cell(format!("{x:.0}"), p.warn()),
        v => num(v),
    };
    d.table(
        "POOLS".into(),
        rows,
        "no pool reports",
        None,
        |r| {
            vec![
                r.pool.clone().into(),
                num(r.slots),
                num(r.busy),
                warn(r.withheld),
                warn(r.waiting),
                r.oldest.map_or("-".into(), |s| dur(s).into()),
                num(r.done),
                cell(pct(r.pass), p.pass(r.pass)),
                or_dash(r.machines.join(", ")),
            ]
        },
        Table {
            header: POOL_HEAD.to_vec(),
            keep: vec![0, 4, 5, 2, 1, 7, 6, 3, 8],
            flex: Some(8),
            flexmin: 10,
            right: vec![1, 2, 3, 4, 5, 6, 7],
            ..Default::default()
        },
    )
}

const SLOT_HEAD: [&str; 8] = [
    "HOST", "SLOT", "STATE", "POOL", "RAN", "USUAL", "JOB", "REF",
];

/// Every CI slot with the job it runs and how long against its usual; a late job is amber.
fn runners(d: &Draw, rows: &[Slot]) -> Vec<Line<'static>> {
    let p = d.p;
    let secs = |v: Option<i64>| v.map_or("-".to_string(), |s| dur(s as f64));
    d.table(
        "RUNNERS".into(),
        rows,
        "no runner reports",
        None,
        |r| {
            let state = match r.state.as_str() {
                "busy" => Style::default(),
                "withheld" => p.warn(),
                "off" => p.bad(),
                _ => p.dim(),
            };
            let busy = r.state == "busy";
            vec![
                r.host.clone().into(),
                r.slot.clone().into(),
                cell(&r.state, state),
                or_dash(r.pool.clone()),
                if r.late {
                    cell(format!("{}!", secs(r.ran)), p.warn())
                } else {
                    secs(r.ran).into()
                },
                secs(r.usual).into(),
                or_dash(if busy { r.job.clone() } else { r.note.clone() }),
                or_dash(if busy { r.reference() } else { String::new() }),
            ]
        },
        Table {
            header: SLOT_HEAD.to_vec(),
            keep: vec![0, 2, 4, 6, 7, 1, 3, 5],
            right: vec![4, 5],
            cap: vec![(6, 40), (7, 40)],
            ..Default::default()
        },
    )
}

const QUEUED_HEAD: [&str; 7] = ["JOB", "POOL", "REF", "N", "WAIT", "NEEDS", "CAN RUN ON"];

/// The waiting jobs, what each needs and who can take it; one nobody can take is red.
fn queued(d: &Draw, rows: &[Queued]) -> Vec<Line<'static>> {
    let p = d.p;
    d.table(
        "QUEUED".into(),
        rows,
        "nothing queued",
        None,
        |q| {
            let s = if q.stuck { p.bad() } else { Style::default() };
            let can = if !q.can.is_empty() {
                q.can
                    .iter()
                    .map(|f| format!("{} ({})", f.host, f.state))
                    .collect::<Vec<_>>()
                    .join(", ")
            } else if q.needs.is_empty() {
                "-".into()
            } else {
                "nobody".into()
            };
            vec![
                cell(&q.job, s),
                or_dash(q.pool.clone()),
                or_dash(q.reference()),
                q.n.to_string().into(),
                dur(q.wait as f64).into(),
                or_dash(q.needs.join(", ")),
                cell(can, s),
            ]
        },
        Table {
            header: QUEUED_HEAD.to_vec(),
            keep: vec![0, 4, 6, 2, 1, 3, 5],
            flex: Some(6),
            flexmin: 14,
            right: vec![3, 4],
            cap: vec![(0, 44)],
            ..Default::default()
        },
    )
}

const FINISHED_HEAD: [&str; 7] = [
    "REPO",
    "WORKFLOW",
    "MAIN",
    "BRANCHES",
    "RUNS",
    "FAILED",
    "CANCELLED",
];

/// The last day of runs per workflow, a red on main first, the first `FINISHED_ROWS` drawn.
fn finished(d: &Draw, rows: &[Finished], done: &Tally) -> Vec<Line<'static>> {
    let p = d.p;
    let title = if done.runs == 0 {
        "FINISHED 24H".to_string()
    } else {
        format!(
            "FINISHED 24H  {} runs, {} pass, {} failed, {} cancelled",
            done.runs,
            pct(done.pass()),
            done.bad,
            done.can
        )
    };
    d.table(
        title,
        rows,
        "no finished-run series yet (runner exporter)",
        Some(FINISHED_ROWS),
        |f| {
            let (main, branch) = (f.main.pass(), f.branch.pass());
            vec![
                f.repo.clone().into(),
                f.workflow.clone().into(),
                cell(pct(main), p.pass(main)),
                cell(pct(branch), p.dim()),
                f.all.runs.to_string().into(),
                if f.all.bad > 0 {
                    cell(f.all.bad.to_string(), p.bad())
                } else {
                    "0".into()
                },
                f.all.can.to_string().into(),
            ]
        },
        Table {
            header: FINISHED_HEAD.to_vec(),
            keep: vec![1, 2, 5, 0, 4, 3, 6],
            right: vec![2, 3, 4, 5, 6],
            cap: vec![(0, 28), (1, 36)],
            ..Default::default()
        },
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::fit::plain;

    fn text(t: &InfraTables, i: &Infra, name: &str, inner: &str, w: usize) -> String {
        t.draw(i, name, inner, Palette { no_color: true }, 0, w)
            .iter()
            .map(plain)
            .collect::<Vec<_>>()
            .join("\n")
    }

    fn infra() -> Infra {
        crate::board::tests::built(&crate::board::tests::fixture())
    }

    #[test]
    fn every_table_draws_its_rows_under_its_chips_from_the_shared_rows() {
        let (t, i) = (InfraTables::default(), infra());
        let m = text(&t, &i, "machines", "machines", 200);
        assert!(m.starts_with("MACHINES  all "), "{m}");
        assert!(
            m.contains("[/ f s S x, c next table]"),
            "the first table has the keys: {m}"
        );
        for h in ["MACHINE", "BUSY", "POOLS", "GOVERNOR"] {
            assert!(m.contains(h), "{h}: {m}");
        }
        for host in i.machines.iter().map(|m| m.host.as_str()) {
            assert!(m.contains(host), "{host}: {m}");
        }
        let p = text(&t, &i, "pools", "machines", 200);
        assert!(p.starts_with("POOLS  all ") && !p.contains("[/ f"), "{p}");
        assert!(p.contains("WAITING") && p.contains("unity"), "{p}");
        let r = text(&t, &i, "runners", "ci", 200);
        assert!(r.starts_with("RUNNERS  all ") && r.contains("[/ f"), "{r}");
        let f = text(&t, &i, "finished", "ci", 200);
        assert!(
            f.starts_with("FINISHED 24H  171 runs")
                && f.contains("  all 6")
                && f.contains("WORKFLOW"),
            "{f}"
        );
    }

    #[test]
    fn the_keys_go_to_the_inner_tabs_table_in_turn_and_change_only_its_view() {
        let (mut t, i) = (InfraTables::default(), infra());
        assert_eq!(t.key(Some(&i), "machines", KeyCode::Char('f')), Took::View);
        assert_eq!(t.views[0].view.state, "busy");
        assert!(t.views[1].view.is_default());
        let m = text(&t, &i, "machines", "machines", 200);
        let busy = i.machines.iter().filter(|m| m.busy > 0).count();
        assert_eq!(
            m.lines().count(),
            2 + busy,
            "the head, the header and the busy machines: {m}"
        );
        t.cycle("machines");
        assert_eq!(t.focus("machines"), Some(1));
        t.cycle("machines");
        assert_eq!(t.focus("machines"), Some(0), "c wraps");
        // On CI the keys are its own tables'; Esc clears a view, then is the page's.
        assert_eq!(t.focus("ci"), Some(2));
        assert_eq!(t.key(Some(&i), "machines", KeyCode::Esc), Took::View);
        assert!(t.views[0].view.is_default());
        assert_eq!(t.key(Some(&i), "machines", KeyCode::Esc), Took::No);
        assert_eq!(t.key(Some(&i), "jobs", KeyCode::Char('f')), Took::No);
    }

    #[test]
    fn an_alias_opens_machines_under_its_chip() {
        let mut t = InfraTables::default();
        t.view("machines").unwrap().view.state = "cloud".into();
        assert_eq!(t.focus("machines"), Some(0));
        let i = infra();
        let m = text(&t, &i, "machines", "machines", 200);
        for h in i.machines.iter().filter(|m| m.place != "cloud") {
            assert!(!m.contains(&format!("\n{} ", h.host)), "{}: {m}", h.host);
        }
    }
}
