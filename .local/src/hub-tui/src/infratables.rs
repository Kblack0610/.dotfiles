//! Infra's five tables (Machines: machines and pools; Runners: runners, queued, local), drawn from
//! the rows `hub_core` builds once for both surfaces (`hub_core::machines`, `hub_core::ci`) on the
//! shared data table. Each table keeps its own view; the tables of the inner tab shown take the
//! table keys (`/ f s S x`) one at a time, and `c` passes them to the next. agent-web draws the
//! same rows from the same summary.

use hub_core::ci::{LocalFail, Queued, Slot};
use hub_core::infra::Infra;
use hub_core::jobpods::Booked;
use hub_core::links::Link;
use hub_core::machines::{Machine, Pool};
use hub_core::table::Row;
use ratatui::crossterm::event::{KeyCode, KeyEvent};
use ratatui::style::Style;
use ratatui::text::{Line, Span};

use crate::datatable::{DataTable, Took};
use crate::fit::{cell, clip_line, Cell, Table};
use crate::fmt::{clock, dash, pct, Palette};
use hub_core::display::fmt::dur_secs;

/// The tables in `hub_core::layout` section order; an index here is a table's view.
pub const TABLES: [&str; 5] = ["machines", "pools", "runners", "queued", "local"];

/// Each table's view, and which one has the keys.
#[derive(Debug, Default)]
pub struct InfraTables {
    pub views: [DataTable; 5],
    pub at: usize,
    /// The Runners tab shows each job pod's row (`e`); folded, the machine rows say what runs.
    pub pods: bool,
    /// A key moved the selection, so the next draw scrolls it into view.
    pub follow: bool,
}

impl InfraTables {
    /// The tables an inner tab shows, as indexes into `TABLES`.
    pub fn on(inner: &str) -> &'static [usize] {
        match inner {
            "machines" => &[0, 1],
            "runners" => &[2, 3, 4],
            _ => &[],
        }
    }

    /// Its rows are picked with j/k and opened with Enter: Machines only; Runners' rows open
    /// nothing (a slot's run is on Runs).
    pub fn picks(inner: &str) -> bool {
        inner == "machines"
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
        if inner == "runners"
            && code == KeyCode::Char('e')
            && self.views.iter().all(|v| v.typing.is_none())
        {
            self.pods = !self.pods;
            return Took::View;
        }
        if inner == "runners" && !self.pods {
            // The pod table is folded: no table here takes a key, only `e`.
            return Took::No;
        }
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
                _ => v.cycle_shown(&r.ci.local),
            }
            t.sel = 0;
            return Took::View;
        }
        match i {
            0 => t.key::<Machine>(code),
            1 => t.key::<Pool>(code),
            2 => t.key::<Slot>(code),
            3 => t.key::<Queued>(code),
            _ => t.key::<LocalFail>(code),
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
            _ => v.apply(&infra.ci.local).len(),
        }
    }

    /// j/k, g/G and Home/End move the selection in the table with the keys; PgUp/PgDn and
    /// Ctrl-d/u stay the page's scroll.
    pub fn moves(&mut self, infra: Option<&Infra>, inner: &str, k: KeyEvent) -> bool {
        let (Some(infra), Some(i)) = (infra, self.focus(inner)) else {
            return false;
        };
        if !Self::picks(inner) {
            return false;
        }
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
        if !Self::picks(inner) {
            return None;
        }
        let t = &self.views[i];
        fn sel<R: Row>(t: &DataTable, rows: &[R]) -> Option<Link> {
            DataTable::opens(*t.view.apply(rows).get(t.sel)?)
        }
        match i {
            0 => sel(t, &infra.machines),
            1 => sel(t, &infra.pools),
            2 => sel(t, &infra.ci.rows),
            3 => sel(t, &infra.ci.queue),
            _ => sel(t, &infra.ci.local),
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
            picks: Self::picks(inner),
            more: Self::on(inner).len() > 1,
            p,
            w,
        };
        match i {
            0 => {
                let mut out = machines(&d, &infra.machines, now);
                out.extend(
                    infra
                        .ci
                        .glance
                        .pending_line()
                        .map(|l| Line::styled(l, p.warn())),
                );
                out
            }
            1 => pools(&d, &infra.pools),
            2 if self.pods => {
                let mut out = runners(&d, &infra.ci.rows);
                out.push(Line::styled("e folds the pod rows", p.dim()));
                out
            }
            2 => folded(&d, &infra.ci.rows),
            3 => queued(&d, &infra.ci.queue),
            _ => local(&d, &infra.ci.local, now),
        }
    }
}

/// One row per CI machine and nothing under it: its units (allocatable cores), the units every
/// pod there takes and their share, its real CPU, what is free in the limit that binds, memory
/// taken, and the jobs running there by kind. The per-pod rows are `runners`, folded until `e`.
/// Drawn with no view and no keys: the Machines tab's table is the one to sort and open.
pub fn ci_machines(infra: &Infra, p: Palette, w: usize) -> Vec<Line<'static>> {
    let t = DataTable::default();
    let d = Draw {
        t: &t,
        keys: false,
        picks: false,
        more: false,
        p,
        w,
    };
    let mut rows: Vec<Machine> = infra
        .machines
        .iter()
        .filter(|m| m.carries_ci())
        .cloned()
        .collect();
    rows.sort_by(|a, b| {
        let share = |m: &Machine| m.booked.map_or(0.0, |b| b.share());
        share(b)
            .total_cmp(&share(a))
            .then_with(|| a.host.cmp(&b.host))
    });
    ci_machine_rows(&d, &rows)
}

const CI_MACHINE_HEAD: [&str; 9] = [
    "MACHINE", "STATE", "UNITS", "TAKEN", "REAL", "FREE", "MEM", "JOBS", "RUNNING",
];

fn ci_machine_rows(d: &Draw, rows: &[Machine]) -> Vec<Line<'static>> {
    let p = d.p;
    d.table(
        "CI MACHINES".into(),
        rows,
        "no CI machine reports",
        None,
        |m| {
            let state = match m.state.as_str() {
                "up" => Style::default(),
                hub_core::reading::NO_DATA => p.dim(),
                _ => p.warn(),
            };
            let b = m.booked.filter(Booked::on_ci);
            let full = b.is_some_and(|b| b.share() >= 1.0);
            let or_dash =
                |f: fn(&hub_core::jobpods::Booked) -> String| b.as_ref().map_or("-".into(), f);
            vec![
                m.host.clone().into(),
                cell(&m.state, state),
                b.map_or("-".into(), |b| format!("{:.0}", b.cpu_alloc))
                    .into(),
                or_dash(|b| b.taken_cell()).into(),
                pct(m.cpu).into(),
                match full {
                    true => cell(or_dash(|b| b.free_cell()), p.warn()),
                    false => or_dash(|b| b.free_cell()).into(),
                },
                or_dash(|b| b.mem_cell()).into(),
                m.busy.to_string().into(),
                dash(m.running.join(", ")).into(),
            ]
        },
        Table {
            header: CI_MACHINE_HEAD.to_vec(),
            keep: vec![0, 3, 5, 8, 4, 2, 7, 6, 1],
            right: vec![2, 3, 4, 5, 6, 7],
            cap: vec![(8, 80)],
            flex: Some(8),
            flexmin: 14,
            ..Default::default()
        },
    )
}

/// A pool page's machines, a blank line, and its waiting jobs (`pooltab`), drawn with the tab's
/// own cells: hub-core's order, no view, no keys.
pub fn page_tables(
    rows: &[Machine],
    waiting: &[Queued],
    p: Palette,
    now: i64,
    w: usize,
) -> Vec<Line<'static>> {
    let t = DataTable::default();
    let d = Draw {
        t: &t,
        keys: false,
        picks: false,
        more: false,
        p,
        w,
    };
    let mut out = machines(&d, rows, now);
    out.push(Line::raw(""));
    out.extend(queued(&d, waiting));
    out
}

/// What one table is drawn with.
struct Draw<'a> {
    t: &'a DataTable,
    /// It has the table keys.
    keys: bool,
    /// Its selected row is marked (`InfraTables::picks`).
    picks: bool,
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
        out.extend(DataTable::legend::<R>(p, self.w));
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
        if self.keys && self.picks {
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

fn num(v: Option<f64>) -> Cell {
    v.map_or("-".into(), |x| format!("{x:.0}").into())
}

/// `Machine::COLUMNS` in capitals.
const MACHINE_HEAD: [&str; 12] = [
    "MACHINE", "STATE", "BOOKED", "CPU", "6H", "LOAD", "MEM", "TEMP", "DISK", "RUNNING", "NEXT",
    "UP",
];

/// What its job pods book of its CPU and memory, as a bar of the fuller share and the counts:
/// `[#...] 5.1/32 4.0G/92G`, `-` on no CI node, then its runners down. Amber once a resource
/// is fully booked or a runner is down.
fn booked(m: &Machine, p: crate::fmt::Palette) -> Cell {
    const WIDTH: usize = 4;
    let share = m.booked.map_or(0.0, |b| b.share());
    let text = match m.booked {
        Some(_) => {
            let (on, off) = crate::fmt::bar(Some((share * 100.0).round() as u32), None, WIDTH);
            format!("[{on}{off}] {}", m.booked_cell())
        }
        None => m.booked_cell(),
    };
    match (m.off, share >= 1.0) {
        (0, false) => text.into(),
        (0, true) => cell(text, p.warn()),
        (n, _) => cell(format!("{text} +{n} off"), p.warn()),
    }
}

/// One row per machine. Narrowing keeps the machine, what it takes, what it runs and cpu longest.
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
                hub_core::reading::NO_DATA => p.dim(),
                _ => p.warn(),
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
                Some(t) if t >= hub_core::host_now::HOT_C => cell(format!("{t:.0}C"), p.warn()),
                Some(t) => format!("{t:.0}C").into(),
            };
            vec![
                m.host.clone().into(),
                cell(&m.state, state),
                booked(m, p),
                pct(m.cpu).into(),
                pct(m.cpu6h).into(),
                load,
                pct(m.mem).into(),
                temp,
                pct(m.disk).into(),
                dash(m.running.join(", ")).into(),
                m.next
                    .as_ref()
                    .map_or("-".into(), |n| n.line(|s| dur_secs(s as f64)).into()),
                m.boot.map_or("-".into(), |b| clock(b as i64, now).into()),
            ]
        },
        Table {
            header: MACHINE_HEAD.to_vec(),
            keep: vec![0, 2, 9, 3, 1, 5, 10, 4, 6, 7, 8, 11],
            right: vec![2, 3, 4, 5, 6, 7, 8],
            cap: vec![(9, 56), (10, 44)],
            flex: Some(9),
            flexmin: 14,
            flexkeep: true,
            ..Default::default()
        },
    )
}

const POOL_HEAD: [&str; 10] = [
    "KIND", "RUNNING", "WAITING", "OLDEST", "DONE 1H", "DONE 5H", "DONE 24H", "USUAL", "PASS",
    "MACHINES",
];

/// One row per job kind, the longest queue first: its jobs running, waiting, how long one usually
/// runs and the machines that take it (`Pool::machines_cell`).
fn pools(d: &Draw, rows: &[Pool]) -> Vec<Line<'static>> {
    let p = d.p;
    let shown = |r: &Pool, col: &str| r.val(col).shown().unwrap_or_default();
    d.table(
        "JOB KINDS".into(),
        rows,
        "no job kind reports",
        None,
        |r| {
            vec![
                r.pool.clone().into(),
                num(r.running),
                match r.waiting {
                    Some(x) if x > 0.0 => cell(format!("{x:.0}"), p.warn()),
                    v => num(v),
                },
                r.oldest.map_or("-".into(), |s| dur_secs(s).into()),
                num(r.done_1h),
                num(r.done_5h),
                num(r.done),
                r.usual.map_or("-".into(), |s| dur_secs(s).into()),
                cell(pct(r.pass), p.pass(r.pass)),
                dash(shown(r, "machines")).into(),
            ]
        },
        Table {
            header: POOL_HEAD.to_vec(),
            keep: vec![0, 2, 1, 3, 8, 9, 6, 7, 4, 5],
            right: vec![1, 2, 3, 4, 5, 6, 7, 8],
            cap: vec![(9, 100)],
            ..Default::default()
        },
    )
}

/// The runners table folded: how many job rows it holds and what shows them.
fn folded(d: &Draw, rows: &[Slot]) -> Vec<Line<'static>> {
    let text = if rows.is_empty() {
        "no runner is running a job".to_string()
    } else {
        format!("{} jobs running, one per pod: e shows each", rows.len())
    };
    vec![clip_line(
        Line::from(vec![
            Span::styled("RUNNERS", d.p.head()),
            Span::raw("  "),
            Span::styled(text, d.p.dim()),
        ]),
        d.w,
    )]
}

const SLOT_HEAD: [&str; 8] = [
    "HOST", "SLOT", "STATE", "POOL", "RAN", "USUAL", "JOB", "REF",
];

/// Every CI runner with a job, how long it has run against its usual; a late job is amber.
fn runners(d: &Draw, rows: &[Slot]) -> Vec<Line<'static>> {
    let p = d.p;
    let secs = |v: Option<i64>| v.map_or("-".to_string(), |s| dur_secs(s as f64));
    d.table(
        "RUNNERS".into(),
        rows,
        "no runner is running a job",
        None,
        |r| {
            vec![
                r.host.clone().into(),
                r.slot.clone().into(),
                cell(&r.state, Style::default()),
                dash(&r.pool).into(),
                if r.late {
                    cell(format!("{}!", secs(r.ran)), p.warn())
                } else {
                    secs(r.ran).into()
                },
                secs(r.usual).into(),
                dash(&r.job).into(),
                dash(r.reference()).into(),
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

const QUEUED_HEAD: [&str; 8] = [
    "JOB",
    "POOL",
    "REF",
    "N",
    "WAIT",
    "NEEDS",
    "CAN RUN ON",
    "STARTS",
];

/// The waiting jobs, what each needs, who can take it and about when it starts there
/// (`Queued::starts`, `-` with no usual time); one nobody can take is red.
fn queued(d: &Draw, rows: &[Queued]) -> Vec<Line<'static>> {
    let p = d.p;
    d.table(
        "WAITING".into(),
        rows,
        "nothing waiting",
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
            } else if q.hosted() {
                "GitHub".into()
            } else {
                "nobody".into()
            };
            vec![
                cell(&q.job, s),
                dash(&q.pool).into(),
                dash(q.reference()).into(),
                q.n.to_string().into(),
                dur_secs(q.wait as f64).into(),
                dash(q.needs.join(", ")).into(),
                cell(can, s),
                match q.starts {
                    None => "-".into(),
                    Some(0) => format!("now {}", q.at).into(),
                    Some(t) => format!("in {} {}", dur_secs(t as f64), q.at).into(),
                },
            ]
        },
        Table {
            header: QUEUED_HEAD.to_vec(),
            keep: vec![0, 4, 7, 6, 2, 1, 3, 5],
            flex: Some(6),
            flexmin: 14,
            right: vec![3, 4],
            cap: vec![(0, 44)],
            ..Default::default()
        },
    )
}

const LOCAL_HEAD: [&str; 6] = ["LAST", "REPO", "BRANCH", "PLATFORM", "RESULT", "FAILED"];

/// The local Unity gate runs that failed in the last day, one row per branch and platform, the
/// newest first (`hub_core::ci::local`). A red CI run is Runs' red chip, not a row here.
fn local(d: &Draw, rows: &[LocalFail], now: i64) -> Vec<Line<'static>> {
    let p = d.p;
    d.table(
        "LOCAL UNITY".to_string(),
        rows,
        "no local Unity gate failed in 24h",
        None,
        |f| {
            vec![
                clock(f.last, now).into(),
                cell(f.repo.clone(), p.dim()),
                f.branch.clone().into(),
                f.platform.clone().into(),
                cell(f.result.clone(), p.bad()),
                f.n.to_string().into(),
            ]
        },
        Table {
            header: LOCAL_HEAD.to_vec(),
            keep: vec![2, 5, 0, 3, 4, 1],
            right: vec![5],
            cap: vec![(1, 28), (2, 40)],
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
        for h in ["MACHINE", "BOOKED", "RUNNING", "NEXT", "UP"] {
            assert!(m.contains(h), "{h}: {m}");
        }
        for host in i.machines.iter().map(|m| m.host.as_str()) {
            assert!(m.contains(host), "{host}: {m}");
        }
        let p = text(&t, &i, "pools", "machines", 200);
        assert!(
            p.starts_with("JOB KINDS  all ") && !p.contains("[/ f"),
            "{p}"
        );
        assert!(p.contains("WAITING") && p.contains("unity"), "{p}");
        // The runners tab folds its pod rows into one line until `e` opens them.
        let folded = text(&t, &i, "runners", "runners", 200);
        assert!(
            folded.starts_with("RUNNERS  3 jobs running, one per pod: e shows each"),
            "{folded}"
        );
        let open = InfraTables {
            pods: true,
            ..Default::default()
        };
        let r = text(&open, &i, "runners", "runners", 200);
        assert!(r.starts_with("RUNNERS  all ") && r.contains("[/ f"), "{r}");
        let f = text(&t, &i, "local", "runners", 200);
        assert!(
            f.starts_with("LOCAL UNITY  all ") && f.contains("PLATFORM") && f.contains("android"),
            "{f}"
        );
    }

    #[test]
    fn e_opens_and_folds_the_pod_rows_on_the_runners_tab_only() {
        let (mut t, i) = (InfraTables::default(), infra());
        assert!(!t.pods);
        assert_eq!(t.key(Some(&i), "machines", KeyCode::Char('e')), Took::No);
        assert!(!t.pods, "the machines tab has no pod rows to open");
        assert_eq!(t.key(Some(&i), "runners", KeyCode::Char('e')), Took::View);
        assert!(t.pods);
        let r = text(&t, &i, "runners", "runners", 200);
        assert!(r.starts_with("RUNNERS  all "), "{r}");
        assert_eq!(t.key(Some(&i), "runners", KeyCode::Char('e')), Took::View);
        assert!(!t.pods);
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
        // On Runners the keys are its own tables'; Esc clears a view, then is the page's.
        assert_eq!(t.focus("runners"), Some(2));
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
