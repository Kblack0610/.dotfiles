//! The Projects tab: one table row per lab project with its open version's progress, built by
//! `hub_core::projects` (the same rows and words as agent-web's Projects tab), in flight first,
//! on the shared `DataTable`. j/k pick a project, Enter opens its card over its rows (tasktab.rs,
//! every row key works there), `a` opens every project's rows; in the rows Esc clears the view
//! first and then comes back here, as Backspace does at once. `P` steps the selected project's
//! priority (normal, focus, high, low; from `only` it clears it); app.rs runs the write. This file reads and writes
//! nothing.

use hub_core::deliverables::{Deliverable, Deliverables};
use hub_core::layout::PROJECT_PAGE;
use hub_core::page::{Page, System};
use hub_core::projects::{self, Card, Projects, Stats};
use hub_core::session_actions::Runner;
use hub_core::tasks::Feed;
use ratatui::crossterm::event::{KeyCode, KeyEvent};
use ratatui::text::{Line, Span};

use crate::datatable::{DataTable, Took};
use crate::fit::{cell, clip_line, wrap, Cell, Table};
use crate::fmt::Palette;
use crate::tasktab::TaskView;

/// One read of the cards' input that is not the board feed: `notes projects --stats --json`.
#[derive(Debug)]
pub struct Loaded {
    pub stats: Result<Vec<Stats>, String>,
}

pub fn load(runner: &dyn Runner) -> Loaded {
    Loaded {
        stats: projects::stats(runner),
    }
}

/// The list's columns, `Card`'s `Row::COLUMNS` in order, so the sort's mark lands on its header.
const HEADER: [&str; 19] = [
    "PROJECT", "PROFILE", "STAGE", "VERSION", "PRIO", "OPEN", "DOING", "HOT", "DONE", "7D", "PCT",
    "PACE/WK", "ETA", "RUN", "WAIT", "QUEUED", "HELD", "TODAY", "OLDEST",
];

#[derive(Debug)]
pub struct ProjView {
    /// The list's search, chip and sort, and its selected row.
    pub table: DataTable,
    /// The rows are open (tasktab), for one project or for every project.
    pub open: bool,
    /// A `hub tab projects <name>` that came before the cards: opened when they arrive.
    pub want: Option<String>,
    /// The opened project's inner tab (`layout::PROJECT_PAGE`), Left/Right switch it.
    pub inner: &'static str,
    /// Overview's Needs you lists each group's items (`F`), not only its head.
    pub needs: bool,
    /// Overview's selected system row, which Enter opens Build filtered to.
    pub sys: usize,
    /// The Deliverables table's search, chip and sort, and its selected row.
    pub dv: DataTable,
    /// The opened project's Build table: its own view, so the list's Deliverables keep theirs.
    pub bv: DataTable,
    /// The Deliverables table has the keys (`d`), not the project list.
    pub dfocus: bool,
}

impl Default for ProjView {
    fn default() -> ProjView {
        ProjView {
            table: DataTable::default(),
            open: false,
            want: None,
            inner: OVERVIEW,
            needs: false,
            sys: 0,
            dv: DataTable::default(),
            bv: DataTable::default(),
            dfocus: false,
        }
    }
}

impl ProjView {
    /// The cards the view keeps, in its order.
    pub fn shown<'a>(&self, cards: &'a [Card]) -> Vec<&'a Card> {
        self.table.view.apply(cards)
    }

    /// The selected row of `n`: a re-read can leave the selection past what the view now keeps.
    fn at(&self, n: usize) -> usize {
        self.table.sel.min(n.saturating_sub(1))
    }

    /// The selected project, when the view keeps one.
    pub fn selected<'a>(&self, cards: &'a [Card]) -> Option<&'a Card> {
        let shown = self.shown(cards);
        shown.get(self.at(shown.len())).copied()
    }

    /// Open one project's page on Overview, or with None every project's rows.
    pub fn open(&mut self, tv: &mut TaskView, c: Option<&Card>) {
        tv.project = c.map(|c| (c.profile.clone(), c.name.clone()));
        tv.table.clear();
        tv.said = None;
        self.open = true;
        self.inner = OVERVIEW;
        self.needs = false;
        self.sys = 0;
        self.bv = DataTable::default();
    }

    /// Back to the list, the selection on the row it was on.
    pub fn close(&mut self, tv: &mut TaskView) {
        self.open = false;
        tv.prompt = None;
        tv.said = None;
    }

    /// The rows are drawn and take the row keys: every project's, or a project's Rows inner tab.
    pub fn rows_shown(&self, tv: &TaskView) -> bool {
        tv.project.is_none() || self.inner == ROWS
    }

    /// The opened project's keys that are not the rows': Left/Right switch the inner tab, and on
    /// Overview j/k pick a system and Enter opens Build filtered to it, `F` lists each Needs you
    /// group's items; on Build the shared table keys, Enter opens Rows searched to the epic.
    /// False for a key it does not take.
    pub fn page_key(
        &mut self,
        tv: &mut TaskView,
        k: KeyEvent,
        pg: Option<&Page>,
        page: usize,
    ) -> bool {
        if let KeyCode::Left | KeyCode::Right = k.code {
            if self.bv.typing.is_none() {
                self.inner =
                    crate::innertabs::step_of(&PROJECT_PAGE, self.inner, k.code == KeyCode::Left);
                return true;
            }
        }
        let Some(pg) = pg else { return false };
        match self.inner {
            OVERVIEW => match k.code {
                KeyCode::Char('F') => self.needs = !self.needs,
                KeyCode::Char('j') | KeyCode::Down => {
                    self.sys = (self.sys + 1).min(pg.systems.len().saturating_sub(1))
                }
                KeyCode::Char('k') | KeyCode::Up => self.sys = self.sys.saturating_sub(1),
                // `no system` has no word to search by: Build opens on every epic.
                KeyCode::Enter => {
                    if let Some(s) = pg.systems.get(self.sys) {
                        self.bv.clear();
                        if !s.id.is_empty() {
                            self.bv.view.q = format!("sys:{}", s.id);
                        }
                        self.inner = BUILD;
                    }
                }
                _ => return false,
            },
            BUILD => {
                let rows = self.bv.view.apply(&pg.build.rows);
                if self.bv.key::<Deliverable>(k.code) != Took::No
                    || self.bv.moves(k, rows.len(), page)
                {
                    return true;
                }
                match k.code {
                    KeyCode::Enter => {
                        if let Some(r) = rows.get(self.bv.sel.min(rows.len().saturating_sub(1))) {
                            tv.table.clear();
                            tv.table.view.q = format!("tag:=of/{}", r.id);
                            self.inner = ROWS;
                        }
                    }
                    KeyCode::Esc if !self.bv.is_default() => self.bv.clear(),
                    _ => return false,
                }
            }
            _ => return false,
        }
        true
    }

    /// `hub tab projects <name>`: the project of that name, whatever the list's view keeps, else
    /// every project's rows searched for it. `<name>/<inner>` opens that inner tab.
    pub fn go(&mut self, tv: &mut TaskView, cards: &[Card], name: &str) {
        let (name, inner) = match name.rsplit_once('/') {
            Some((n, i)) if inner_id(i).is_some() => (n, inner_id(i)),
            _ => (name, None),
        };
        let named = |c: &Card| {
            c.name.eq_ignore_ascii_case(name)
                || format!("{}/{}", c.profile, c.name).eq_ignore_ascii_case(name)
        };
        match cards.iter().find(|c| named(c)) {
            Some(c) => {
                if let Some(i) = self.shown(cards).iter().position(|s| named(s)) {
                    self.table.sel = i;
                }
                self.open(tv, Some(c));
                if let Some(i) = inner {
                    self.inner = i;
                }
            }
            None => {
                self.open(tv, None);
                tv.table.view.q = name.to_string();
            }
        }
    }

    /// The deliverables the view keeps, in its order.
    pub fn dshown<'a>(&self, d: &'a Deliverables) -> Vec<&'a Deliverable> {
        self.dv.view.apply(&d.rows)
    }

    /// The Deliverables table's keys while it has them: the shared table keys and moves, Enter
    /// opens the selected epic's project on Build with the epic selected, Esc clears the view and
    /// then gives the keys back to the list, as `d` does at once.
    pub fn dkey(
        &mut self,
        tv: &mut TaskView,
        k: KeyEvent,
        cards: &[Card],
        d: &Deliverables,
        page: usize,
    ) -> bool {
        if self.dv.key::<Deliverable>(k.code) != Took::No
            || self.dv.moves(k, self.dshown(d).len(), page)
        {
            return true;
        }
        match k.code {
            KeyCode::Enter => {
                let shown = self.dshown(d);
                let want = shown.get(self.dv.sel.min(shown.len().saturating_sub(1)));
                if let Some(r) = want.filter(|r| cards.iter().any(|c| same(c, r))) {
                    // Build is the same rows scoped to the project, in the same default order,
                    // so the epic's place among its project's rows is its row there: selected by
                    // id, never a search that also matches gm-10 for gm-1.
                    let mine: Vec<Deliverable> = d
                        .rows
                        .iter()
                        .filter(|x| x.profile == r.profile && x.project == r.project)
                        .cloned()
                        .collect();
                    let (key, id) = (r.key(), r.id.clone());
                    self.dfocus = false;
                    self.go(tv, cards, &key);
                    self.inner = BUILD;
                    let at = self.bv.view.apply(&mine).iter().position(|x| x.id == id);
                    self.bv.sel = at.unwrap_or(0);
                }
            }
            KeyCode::Esc if !self.dv.is_default() => self.dv.clear(),
            KeyCode::Esc | KeyCode::Char('d') => self.dfocus = false,
            _ => return false,
        }
        true
    }

    /// The list's keys; false for one it does not take.
    pub fn key(&mut self, tv: &mut TaskView, k: KeyEvent, cards: &[Card], page: usize) -> bool {
        if self.table.key::<Card>(k.code) != Took::No
            || self.table.moves(k, self.shown(cards).len(), page)
        {
            return true;
        }
        match k.code {
            KeyCode::Enter => {
                if let Some(c) = self.selected(cards) {
                    self.open(tv, Some(c));
                }
            }
            KeyCode::Char('a') => self.open(tv, None),
            KeyCode::Char('d') => self.dfocus = true,
            KeyCode::Esc if !self.table.is_default() => self.table.clear(),
            _ => return false,
        }
        true
    }
}

/// The card a deliverable's project is.
fn same(c: &Card, r: &Deliverable) -> bool {
    c.profile == r.profile && c.name == r.project
}

/// The warning style when `b`, else none.
fn warn_if(b: bool, p: Palette) -> ratatui::style::Style {
    if b {
        p.warn()
    } else {
        ratatui::style::Style::default()
    }
}

const OVERVIEW: &str = "overview";
const ROWS: &str = "rows";
const BUILD: &str = "build";

/// The inner id `word` names, from `layout::PROJECT_PAGE`.
fn inner_id(word: &str) -> Option<&'static str> {
    PROJECT_PAGE.iter().find(|i| i.id == word).map(|i| i.id)
}

const BAR: usize = 20;

/// `[#######.............]`, the closed share of the open version by size.
fn bar(percent: Option<u32>, p: Palette) -> Vec<Span<'static>> {
    let (on, off) = crate::fmt::bar(percent, None, BAR);
    vec![
        Span::raw("["),
        Span::styled(on, p.good()),
        Span::styled(off, p.dim()),
        Span::raw("]"),
    ]
}

/// `text` word-wrapped to `w` under a `lead` label, continuation lines indented to match.
pub(crate) fn wrapped(
    lead: &str,
    text: &str,
    style: ratatui::style::Style,
    p: Palette,
    w: usize,
) -> Vec<Line<'static>> {
    // A line that fits keeps its own spacing: the epic lines' columns are two spaces apart.
    let lines = if w == 0 || lead.len() + text.len() <= w {
        vec![text.to_string()]
    } else {
        let words: Vec<&str> = text.split_whitespace().collect();
        wrap(&words, " ", w.saturating_sub(lead.len()).max(10))
    };
    lines
        .into_iter()
        .enumerate()
        .map(|(i, l)| {
            let head = if i == 0 {
                Span::styled(lead.to_string(), p.dim())
            } else {
                Span::raw(" ".repeat(lead.len()))
            };
            Line::from(vec![head, Span::styled(l, style)])
        })
        .collect()
}

/// The opened card's first line: name, profile, stage, priority.
fn head(c: &Card, p: Palette, w: usize) -> Line<'static> {
    let spans = vec![
        Span::styled(c.name.to_uppercase(), p.head()),
        Span::styled(format!("  {}, {}", c.profile, c.stage), p.dim()),
        Span::styled(
            if c.prio.is_empty() {
                String::new()
            } else {
                format!(", prio {}", c.prio)
            },
            if matches!(c.prio.as_str(), "focus" | "only") {
                p.head()
            } else {
                p.dim()
            },
        ),
    ];
    clip_line(Line::from(spans), w)
}

/// The bar and the open version's numbers, wrapped under the bar when they do not fit beside it.
fn bar_lines(c: &Card, p: Palette, w: usize) -> Vec<Line<'static>> {
    let mut b = vec![Span::raw("  ")];
    b.extend(bar(c.percent, p));
    let numbers = projects::summary(c);
    if w == 0 || BAR + 5 + numbers.len() <= w {
        b.push(Span::raw(format!("  {numbers}")));
        vec![Line::from(b)]
    } else {
        let mut out = vec![Line::from(b)];
        out.extend(wrapped("  ", &numbers, Default::default(), p, w));
        out
    }
}

/// A section's head: `TITLE  what it holds`, then its keys dim.
fn sec_head(title: &str, says: &str, keys: &str, p: Palette, w: usize) -> Line<'static> {
    clip_line(
        Line::from(vec![
            Span::styled(title.to_string(), p.head()),
            Span::styled(format!("  {says}"), p.dim()),
            Span::styled(keys.to_string(), p.dim()),
        ]),
        w,
    )
}

/// The systems table's columns, agent-web's `P_SYS_HEAD`.
const SYS_HEADER: [&str; 8] = [
    "SYSTEM",
    "DONE",
    "FEATURES",
    "STANDARD",
    "OPEN ROWS",
    "BEHIND",
    "CRITERIA",
    "CURRENT WAVE",
];

/// One system's cells, the same words as agent-web's systems row.
fn sys_row(s: &System, p: Palette) -> Vec<Cell> {
    let n = |v: usize| {
        if v == 0 {
            "-".to_string()
        } else {
            v.to_string()
        }
    };
    let wave = s.wave.as_ref().map_or("-".to_string(), |v| {
        let mut t = v.title.clone();
        if let Some(pc) = v.percent {
            t += &format!(" {pc}%");
        }
        if v.more > 0 {
            t += &format!(" +{}", v.more);
        }
        t
    });
    vec![
        if s.id.is_empty() {
            "no system".to_string()
        } else {
            s.id.clone()
        }
        .into(),
        s.percent
            .map_or("-".to_string(), |pc| format!("{pc}%"))
            .into(),
        if s.features == 0 {
            "-".to_string()
        } else {
            format!("{} of {}", s.features_done, s.features)
        }
        .into(),
        n(s.standing).into(),
        n(s.open_rows as usize).into(),
        cell(n(s.behind), warn_if(s.behind > 0, p)),
        match (s.criteria_met, s.criteria_total) {
            (Some(m), Some(t)) => format!("{m} of {t}"),
            _ => "-".to_string(),
        }
        .into(),
        wave.into(),
    ]
}

/// Overview: what needs the human (each group's head, its items with `F`), what is in flight,
/// and one table row per system, the selected one marked; and the line it is on.
fn overview(
    c: &Card,
    pg: &Page,
    pv: &ProjView,
    p: Palette,
    w: usize,
) -> (Vec<Line<'static>>, Option<usize>) {
    let n: usize = pg.need_groups.iter().map(|g| g.items.len()).sum();
    let keys = match (n, pv.needs) {
        (0, _) => "",
        (_, false) => "  F lists them",
        (_, true) => "  F folds them",
    };
    let says = if n == 0 {
        "nothing".to_string()
    } else {
        n.to_string()
    };
    let mut out = vec![sec_head("NEEDS YOU", &says, keys, p, w)];
    for g in &pg.need_groups {
        let to = if g.kind == "stage" { "  (Stage)" } else { "" };
        out.extend(wrapped("  ", &format!("{}{to}", g.says), p.warn(), p, w));
        if pv.needs {
            for i in &g.items {
                out.extend(wrapped("      ", i, Default::default(), p, w));
            }
        }
    }
    out.push(Line::raw(""));
    out.push(sec_head("IN FLIGHT", &projects::counts(c), "", p, w));
    for r in &c.running {
        let mut t = r.title.clone();
        if let Some(ph) = &r.phases {
            t += &format!(" (phase {} of {}", ph.done + 1, ph.total);
            if let Some(n) = &ph.next {
                t += &format!(": {n}");
            }
            t += ")";
        }
        out.extend(wrapped("  running  ", &t, p.good(), p, w));
    }
    out.push(Line::raw(""));
    out.push(sec_head(
        "SYSTEMS",
        &pg.systems_says,
        "  j/k pick, Enter opens Build filtered to it",
        p,
        w,
    ));
    if pg.systems.is_empty() {
        out.push(Line::styled("  No systems.", p.dim()));
        return (out, None);
    }
    let sel = pv.sys.min(pg.systems.len() - 1);
    let mut t = Table {
        header: SYS_HEADER.to_vec(),
        rows: pg.systems.iter().map(|s| sys_row(s, p)).collect(),
        keep: vec![0, 1, 4, 5, 7, 2, 6, 3],
        right: vec![1, 2, 3, 4, 5, 6],
        cap: vec![(7, 40)],
        ..Default::default()
    }
    .fit(w, p.head());
    let at = out.len() + sel + 1;
    if let Some(l) = t.get_mut(sel + 1) {
        l.style = p.sel();
    }
    out.append(&mut t);
    (out, Some(at))
}

/// Stage: the next stage's checks not met, failing first, then a human's, then the rest.
fn stage(pg: &Page, p: Palette, w: usize) -> Vec<Line<'static>> {
    let mut out = vec![sec_head("NEXT STAGE", &pg.next_says, "", p, w)];
    let rank = |r: &str| match r {
        "FAIL" => 0,
        "HUMAN" => 1,
        _ => 2,
    };
    let mut rows: Vec<_> = pg.next_rows.iter().collect();
    rows.sort_by_key(|r| rank(&r.result));
    for r in rows {
        out.extend(wrapped(
            &format!("  {:<6} ", r.result),
            &format!("{} ({})", r.requirement, r.stage),
            warn_if(r.result == "FAIL", p),
            p,
            w,
        ));
    }
    out
}

/// Activity: the shipped versions, the dev timeline and the agent's status note.
fn activity(c: &Card, pg: &Page, p: Palette, w: usize) -> Vec<Line<'static>> {
    let mut out = vec![sec_head("SHIPPED", &pg.shipped_says, "", p, w)];
    for s in &pg.shipped {
        out.extend(wrapped("  ", s, Default::default(), p, w));
    }
    if let Some(t) = &pg.timeline {
        out.push(Line::raw(""));
        out.push(sec_head("TIMELINE", &t.says, "", p, w));
        for n in &t.notes {
            out.extend(wrapped("  ", n, p.dim(), p, w));
        }
        for l in &t.lines {
            out.push(clip_line(
                Line::styled(format!("  {}", l.line), crate::releases::alert(l.level, p)),
                w,
            ));
        }
        let shown = t.lines.len();
        out.extend(crate::fmt::older(shown + t.older, shown, p));
    }
    out.push(Line::raw(""));
    out.push(sec_head("AGENT NOTE", &projects::note_says(c), "", p, w));
    if !c.status.is_empty() {
        out.extend(wrapped("  ", &c.status, p.dim(), p, w));
    }
    out
}

/// The number beside an inner tab: Needs you's items on Overview, failing checks on Stage.
fn inner_count(pg: Option<&Page>, id: &str) -> usize {
    let Some(pg) = pg else { return 0 };
    match id {
        OVERVIEW => pg.need_groups.iter().map(|g| g.items.len()).sum(),
        "stage" => pg.gate.as_ref().map_or(0, |g| g.fail as usize),
        _ => 0,
    }
}

/// The opened project, as agent-web's project page: a header (the card, its goal, the Flow
/// line, releases, alerts and the next stage), the inner tab strip (`layout::PROJECT_PAGE`), then
/// the inner tab shown; Rows draws nothing here, the app puts the rows under it. Task lines are
/// never drawn: they are Rows. `page` is None while it is read. Returns the line the selection
/// is on, for the app to keep in view.
pub fn open_lines(
    c: &Card,
    page: Option<&Page>,
    pv: &ProjView,
    p: Palette,
    w: usize,
) -> (Vec<Line<'static>>, Option<usize>) {
    let mut out = vec![head(c, p, w)];
    out.extend(bar_lines(c, p, w));
    let (goal, style) = if c.goal.is_empty() {
        ("no goal set", p.dim())
    } else {
        (c.goal.as_str(), Default::default())
    };
    out.extend(wrapped("  goal     ", goal, style, p, w));
    if let Some(pg) = page {
        if let Some(f) = &pg.flow_line {
            out.extend(wrapped("  flow     ", f, Default::default(), p, w));
        }
        if let Some(b) = &pg.releases {
            out.extend(wrapped(
                "  releases ",
                &format!("{} (R opens)", b.says),
                crate::releases::alert(b.level, p),
                p,
                w,
            ));
        }
        if let Some(b) = &pg.alerts {
            out.extend(wrapped(
                "  alerts   ",
                &format!("{} (A opens)", b.says),
                crate::releases::alert(b.level, p),
                p,
                w,
            ));
        }
        let failing = pg.gate.as_ref().is_some_and(|g| g.fail > 0);
        out.extend(wrapped(
            "  next     ",
            &pg.next_says,
            warn_if(failing, p),
            p,
            w,
        ));
        for e in &pg.errors {
            out.extend(wrapped("  ", e, p.warn(), p, w));
        }
    }
    out.push(Line::raw(""));
    out.push(crate::innertabs::strip_of(
        &PROJECT_PAGE,
        pv.inner,
        |i| inner_count(page, i.id),
        p,
        w,
    ));
    out.push(Line::raw(""));
    if pv.inner == ROWS {
        return (out, None);
    }
    let Some(pg) = page else {
        out.push(Line::styled("  reading the page...", p.dim()));
        return (out, None);
    };
    let top = out.len();
    let (body, at) = match pv.inner {
        OVERVIEW => overview(c, pg, pv, p, w),
        BUILD => deliverables(
            Some(Ok(&pg.build)),
            &pv.bv,
            true,
            "  Enter opens the epic's rows",
            p,
            w,
        ),
        "stage" => (stage(pg, p, w), None),
        _ => (activity(c, pg, p, w), None),
    };
    out.extend(body);
    (out, at.map(|a| a + top))
}

/// One line of the list: `Card`'s columns, a blank word as `-`.
fn row(c: &Card, p: Palette) -> Vec<Cell> {
    let dash = |s: &str| if s.is_empty() { "-" } else { s }.to_string();
    let or_dash = |n: Option<u32>, unit: &str| n.map_or("-".to_string(), |n| format!("{n}{unit}"));
    let lit = |n: usize, on| {
        let style = if n > 0 { on } else { p.dim() };
        cell(n.to_string(), style)
    };
    vec![
        c.name.clone().into(),
        c.profile.clone().into(),
        dash(&c.stage).into(),
        dash(c.version.as_deref().unwrap_or_default()).into(),
        cell(
            dash(&c.prio),
            if matches!(c.prio.as_str(), "focus" | "only") {
                p.head()
            } else {
                p.dim()
            },
        ),
        c.progress.open.to_string().into(),
        c.doing.to_string().into(),
        lit(c.hot, p.warn()),
        c.progress.done.to_string().into(),
        c.progress.closed_7d.to_string().into(),
        or_dash(c.percent, "%").into(),
        format!("{:.1}", c.pace()).into(),
        or_dash(c.eta_days, "d").into(),
        lit(c.running.len(), p.good()),
        lit(c.waiting, p.warn()),
        c.queued.to_string().into(),
        c.held.to_string().into(),
        lit(c.done_today, p.good()),
        projects::wait_word(c.oldest_ready_min).into(),
    ]
}

/// How many deliverables show at once; the rest scroll under the selection once `d` has the keys.
const DELIVERABLE_ROWS: usize = 12;

const DHEADER: [&str; 6] = ["PROJECT", "EPIC", "SYS", "DONE", "ETA", "TRACK"];

/// The Deliverables section: its head, the chips, the table, the coverage line, a blank line;
/// and the line the selected row is on when `d` has the keys. A failed read says so, never an
/// empty table.
fn deliverables(
    dl: Option<Result<&Deliverables, &str>>,
    dv: &DataTable,
    focus: bool,
    hint: &str,
    p: Palette,
    w: usize,
) -> (Vec<Line<'static>>, Option<usize>) {
    let head = |says: &str, hint: &str| {
        clip_line(
            Line::from(vec![
                Span::styled(says.to_string(), p.head()),
                Span::styled(hint.to_string(), p.dim()),
            ]),
            w,
        )
    };
    let mut out = vec![];
    let mut at = None;
    match dl {
        None => out.push(head("Deliverables", "  reading fleet-bench epics")),
        Some(Err(e)) => {
            out.push(head("Deliverables", ""));
            out.extend(wrapped("", e, p.warn(), p, w));
        }
        Some(Ok(d)) => {
            out.push(head(&d.says, hint));
            out.push(clip_line(Line::from(dv.status(&d.rows, p)), w));
            let shown = dv.view.apply(&d.rows);
            if shown.is_empty() {
                let none = if d.rows.is_empty() {
                    "No open feature epics."
                } else {
                    "No deliverable matches."
                };
                out.push(Line::styled(none, p.dim()));
            } else {
                let sel = dv.sel.min(shown.len() - 1);
                let top = if focus {
                    (sel + 1).saturating_sub(DELIVERABLE_ROWS)
                } else {
                    0
                };
                let seen: Vec<&&Deliverable> =
                    shown.iter().skip(top).take(DELIVERABLE_ROWS).collect();
                let mut t = Table {
                    header: DHEADER.to_vec(),
                    rows: seen.iter().map(|r| drow(r, p)).collect(),
                    keep: vec![1, 0, 5, 3, 4, 2],
                    right: vec![3, 4],
                    cap: vec![(0, 16), (1, 44)],
                    mark: dv.mark::<Deliverable>(),
                    ..Default::default()
                }
                .fit(w, p.head());
                if focus {
                    if let Some(l) = t.get_mut(sel - top + 1) {
                        l.style = p.sel();
                        at = Some(out.len() + sel - top + 1);
                    }
                }
                out.append(&mut t);
                let (before, after) = (top, shown.len() - top - seen.len());
                if before + after > 0 {
                    out.push(Line::styled(
                        format!("  {before} above, {after} below"),
                        p.dim(),
                    ));
                }
            }
            out.push(clip_line(
                Line::styled(format!("{}; {}", d.coverage_says, d.legend), p.dim()),
                w,
            ));
        }
    }
    out.push(Line::raw(""));
    (out, at)
}

/// One deliverable's cells, the same words as agent-web's row.
fn drow(r: &Deliverable, p: Palette) -> Vec<Cell> {
    let dash = |s: &str| {
        if s.is_empty() {
            "-".to_string()
        } else {
            s.to_string()
        }
    };
    vec![
        r.project.clone().into(),
        r.title.clone().into(),
        dash(&r.system).into(),
        r.done_says.clone().into(),
        dash(&r.eta_day).into(),
        cell(dash(&r.track), warn_if(r.track == "behind", p)),
    ]
}

/// The list, and the line the selected row is on (the app keeps it in view); the Deliverables
/// section comes first.
pub fn page(
    pr: &Projects,
    feed: Option<&Feed>,
    dl: Option<&Result<Deliverables, String>>,
    pv: &ProjView,
    p: Palette,
    w: usize,
) -> (Vec<Line<'static>>, Option<usize>) {
    let hint = if pv.dfocus {
        "  Enter opens the epic's project, Esc back"
    } else {
        "  d browses them"
    };
    let dl = dl.map(|r| r.as_ref().map_err(String::as_str));
    let (mut out, dat) = deliverables(dl, &pv.dv, pv.dfocus, hint, p, w);
    let (mut list, at) = list(pr, feed, pv, p, w);
    let at = if pv.dfocus {
        dat
    } else {
        at.map(|a| a + out.len())
    };
    out.append(&mut list);
    (out, at)
}

/// The project list under the Deliverables section.
fn list(
    pr: &Projects,
    feed: Option<&Feed>,
    pv: &ProjView,
    p: Palette,
    w: usize,
) -> (Vec<Line<'static>>, Option<usize>) {
    let shown = pv.shown(&pr.cards);
    let total = pr.cards.len();
    let count = if shown.len() == total {
        total.to_string()
    } else {
        format!("{} of {total}", shown.len())
    };
    let flying = pv
        .table
        .view
        .states(&pr.cards)
        .iter()
        .find(|c| c.name == "in flight")
        .map_or(0, |c| c.n);
    let mut out = vec![clip_line(
        Line::from(vec![
            Span::styled("PROJECTS", p.head()),
            Span::styled(
                format!(
                    "  {count} projects, {flying} in flight; progress is the open version's rows by size (#size/s 1, m 3, l 8)"
                ),
                p.dim(),
            ),
        ]),
        w,
    )];
    for e in &pr.errors {
        out.extend(wrapped("", e, p.warn(), p, w));
    }
    out.push(clip_line(Line::from(pv.table.status(&pr.cards, p)), w));
    let rows = feed.map_or("reading notes board".to_string(), |f| {
        format!("{} open rows", f.open_rows(None).len())
    });
    out.push(clip_line(
        Line::from(vec![
            Span::styled("ALL ROWS", p.head()),
            Span::styled(format!("  {rows}; a opens them"), p.dim()),
        ]),
        w,
    ));
    out.push(Line::raw(""));
    let mut at = None;
    if shown.is_empty() {
        let none = if total > 0 {
            "No project matches."
        } else {
            "No projects."
        };
        out.push(Line::styled(none, p.dim()));
    } else {
        let (mut t, starts) = Table {
            header: HEADER.to_vec(),
            rows: shown.iter().map(|c| row(c, p)).collect(),
            keep: vec![
                0, 10, 13, 14, 15, 7, 18, 5, 2, 12, 16, 17, 6, 8, 9, 11, 3, 4, 1,
            ],
            right: (5..HEADER.len()).collect(),
            mark: pv.table.mark::<Card>(),
            ..Default::default()
        }
        .fit_wrapped(w, p.head());
        // The Deliverables table has the keys: the list keeps no highlight.
        if let (false, Some(&start)) = (pv.dfocus, starts.get(pv.at(shown.len()))) {
            t[start].style = p.sel();
            at = Some(out.len() + start);
        }
        out.append(&mut t);
    }
    if !pr.unlinked.is_empty() {
        out.push(Line::raw(""));
        out.push(clip_line(
            Line::from(vec![
                Span::styled("NOT ON A CARD", p.head()),
                Span::styled(
                    format!(
                        "  {} active queue items no project claims (no board origin, and their repo is not one lab project's)",
                        pr.unlinked.len()
                    ),
                    p.dim(),
                ),
            ]),
            w,
        ));
        for u in &pr.unlinked {
            out.extend(wrapped("  ", u, p.dim(), p, w));
        }
    }
    (out, at)
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    use crate::fit::plain;
    use hub_core::projects::Progress;

    pub fn fixture() -> Projects {
        let card = |name: &str, done: u32, open: u32| Card {
            profile: "personal".into(),
            name: name.into(),
            stage: "alpha".into(),
            version: Some("v0.0.1".into()),
            goal: "the human can see where each project is".into(),
            progress: Progress {
                open,
                done,
                open_weight: open,
                done_weight: done,
                closed_7d: 2,
                closed_28d: 4,
                closed_weight_7d: 2,
                closed_weight_28d: 4,
            },
            percent: projects::percent(&Progress {
                open_weight: open,
                done_weight: done,
                ..Default::default()
            }),
            eta_days: Some(open * 7),
            status: "landed the cards".into(),
            status_date: "2026-11-05".into(),
            ..Default::default()
        };
        Projects {
            cards: vec![card("garden", 3, 1), card("demo", 0, 2)],
            unlinked: vec!["dotfiles: fix the hook".into()],
            errors: vec![],
        }
    }

    fn a_page() -> Page {
        Page {
            project: "garden".into(),
            releases: None,
            alerts: None,
            flow_line: Some(
                "ideas 3 | briefs 1 | plans 1 | epics 2 | rows 5 | landed 1 | verified 0".into(),
            ),
            systems: vec![
                hub_core::page::System {
                    id: "ui".into(),
                    head: "ui  25%  1 feature, 0 done  criteria 5 of 7".into(),
                    percent: Some(25),
                    epics: vec![hub_core::page::EpicLine {
                        id: "gm-1".into(),
                        line: "Menus  25%  [rows]  brief yes  plan 1 of 3  rows 2 of 4  behind"
                            .into(),
                        behind: true,
                    }],
                    closed: "+1 closed, 1 verified".into(),
                    wave: None,
                    ..Default::default()
                },
                hub_core::page::System {
                    id: "ci".into(),
                    head: "ci  criteria 1 of 2".into(),
                    ..Default::default()
                },
            ],
            systems_says: "2 systems, 1 open epics (2 rows with no epic)".into(),
            next_says: "beta  4 of 12 met, 1 failing, 1 human, 6 not checkable yet".into(),
            gate: None,
            next_rows: vec![hub_core::page::Requirement {
                stage: "beta".into(),
                result: "FAIL".into(),
                requirement: "a soak test".into(),
            }],
            shipped_says: "none yet".into(),
            shipped: vec![],
            need_groups: vec![hub_core::page::NeedGroup {
                kind: "verify".into(),
                says: "1 epic landed with no live proof".into(),
                items: vec!["Saves (4 of 4 rows landed)".into()],
            }],
            timeline: Some(hub_core::timeline::Timeline {
                says: "7d: 1 commit (1 red on CI)".into(),
                lines: vec![hub_core::timeline::Line {
                    line: "14:02  commit  fix(web): keep the cart (#12)  CI red".into(),
                    level: hub_core::releases::Level::Bad,
                    url: String::new(),
                }],
                older: 3,
                notes: vec!["PRs: the origin is not GitHub".into()],
            }),
            errors: vec!["project-stage-check --systems: exited 2".into()],
            build: Default::default(),
        }
    }

    fn draw(c: &Card, pg: Option<&Page>, pv: &ProjView) -> Vec<String> {
        open_lines(c, pg, pv, Palette { no_color: true }, 200)
            .0
            .iter()
            .map(plain)
            .collect()
    }

    #[test]
    fn the_opened_card_is_a_header_an_inner_strip_and_overview_with_needs_you_first() {
        let pr = fixture();
        let mut pg = a_page();
        pg.build.rows = vec![deliverable("garden", "gm-1", "Menus", "ui", "behind")];
        let pv = ProjView::default();
        let l = draw(&pr.cards[0], Some(&pg), &pv);
        assert_eq!(l[0], "GARDEN  personal, alpha");
        assert_eq!(l[2], "  goal     the human can see where each project is");
        assert!(l[3].starts_with("  flow     ideas 3 | briefs 1"), "{l:?}");
        assert!(l[4].starts_with("  next     beta  4 of 12 met"), "{l:?}");
        assert_eq!(l[5], "  project-stage-check --systems: exited 2");
        assert_eq!(
            l[7],
            "[Overview 1] Rows  Build  Stage  Activity   <- -> switch"
        );
        let body = l[9..].join("\n");
        assert!(
            body.starts_with("NEEDS YOU  1  F lists them\n  1 epic landed with no live proof\n"),
            "{body}"
        );
        assert!(
            !body.contains("Saves (4 of 4"),
            "F lists the items:\n{body}"
        );
        assert!(body.contains("SYSTEMS  2 systems, 1 open epics"), "{body}");
        assert!(
            !body.contains("Menus"),
            "no epic or task lines on Overview:\n{body}"
        );
        let open = draw(
            &pr.cards[0],
            Some(&pg),
            &ProjView {
                needs: true,
                ..Default::default()
            },
        );
        assert!(
            open.iter().any(|l| l == "      Saves (4 of 4 rows landed)"),
            "{open:?}"
        );

        let mut watched = a_page();
        watched.alerts = Some(hub_core::releases::Badge {
            says: "2 watches, 1 firing".into(),
            level: hub_core::releases::Level::Bad,
        });
        assert!(
            draw(&pr.cards[0], Some(&watched), &pv)
                .iter()
                .any(|l| l == "  alerts   2 watches, 1 firing (A opens)"),
            "the count line leads to Alerts"
        );
        assert_eq!(
            draw(&pr.cards[0], None, &pv).last().unwrap(),
            "  reading the page..."
        );
        let mut c = pr.cards[0].clone();
        c.goal.clear();
        assert_eq!(draw(&c, None, &pv)[2], "  goal     no goal set");
    }

    #[test]
    fn each_inner_tab_draws_its_own_part_and_rows_leaves_the_body_to_the_rows() {
        let pr = fixture();
        let mut pg = a_page();
        pg.build.rows = vec![deliverable("garden", "gm-1", "Menus", "ui", "behind")];
        let at = |inner| {
            draw(
                &pr.cards[0],
                Some(&pg),
                &ProjView {
                    inner,
                    ..Default::default()
                },
            )
            .join("\n")
        };
        let rows = at(ROWS);
        assert!(rows.ends_with("<- -> switch\n"), "{rows}");
        let build = at(BUILD);
        assert!(
            build.contains("Menus") && !build.contains("NEEDS YOU"),
            "{build}"
        );
        let stage = at("stage");
        assert!(
            stage.contains("NEXT STAGE  beta") && stage.contains("  FAIL   a soak test (beta)"),
            "{stage}"
        );
        let act = at("activity");
        for s in [
            "SHIPPED  none yet",
            "TIMELINE  7d: 1 commit (1 red on CI)\n  PRs: the origin is not GitHub\n  14:02  commit  fix(web): keep the cart (#12)  CI red\n  +3 older",
            "AGENT NOTE  model-written, 2026-11-05\n  landed the cards",
        ] {
            assert!(act.contains(s), "{s} in {act}");
        }
    }

    #[test]
    fn left_right_step_the_inner_tabs_and_enter_walks_overview_to_build_to_rows() {
        let pr = fixture();
        let mut pg = a_page();
        pg.build.rows = vec![
            deliverable("garden", "gm-1", "Menus", "ui", "behind"),
            deliverable("garden", "gm-2", "Pipelines", "ci", ""),
        ];
        let (mut pv, mut tv) = (ProjView::default(), TaskView::default());
        pv.open(&mut tv, Some(&pr.cards[0]));
        assert_eq!(pv.inner, OVERVIEW);
        assert!(
            !pv.rows_shown(&tv),
            "the rows are an inner tab of an opened project"
        );
        let k = |c| KeyEvent::from(c);
        assert!(pv.page_key(&mut tv, k(KeyCode::Right), Some(&pg), 10));
        assert!(pv.rows_shown(&tv));
        assert!(pv.page_key(&mut tv, k(KeyCode::Left), Some(&pg), 10));
        assert!(pv.page_key(&mut tv, k(KeyCode::Left), Some(&pg), 10));
        assert_eq!(
            pv.inner, "activity",
            "Left from the first wraps to the last"
        );
        pv.inner = OVERVIEW;

        // j picks the second system; Enter opens Build filtered to it.
        assert!(pv.page_key(&mut tv, k(KeyCode::Char('j')), Some(&pg), 10));
        assert!(pv.page_key(&mut tv, k(KeyCode::Char('j')), Some(&pg), 10));
        assert_eq!(pv.sys, 1, "j stops at the last system");
        let (_, sel) = open_lines(
            &pr.cards[0],
            Some(&pg),
            &pv,
            Palette { no_color: true },
            200,
        );
        let l = draw(&pr.cards[0], Some(&pg), &pv);
        assert!(l[sel.unwrap()].starts_with("ci "), "{l:?}");
        assert!(pv.page_key(&mut tv, k(KeyCode::Enter), Some(&pg), 10));
        assert_eq!((pv.inner, pv.bv.view.q.as_str()), (BUILD, "sys:ci"));
        assert!(
            pv.dv.is_default(),
            "the list's Deliverables keep their own view"
        );
        let s = draw(&pr.cards[0], Some(&pg), &pv).join("\n");
        assert!(s.contains("Pipelines") && !s.contains("Menus"), "{s}");

        // Esc clears Build's filter; Enter on an epic opens Rows searched to it.
        assert!(pv.page_key(&mut tv, k(KeyCode::Esc), Some(&pg), 10));
        assert!(pv.bv.is_default());
        assert!(
            !pv.page_key(&mut tv, k(KeyCode::Esc), Some(&pg), 10),
            "then Esc goes back"
        );
        assert!(pv.page_key(&mut tv, k(KeyCode::Enter), Some(&pg), 10));
        assert_eq!((pv.inner, tv.table.view.q.as_str()), (ROWS, "tag:=of/gm-1"));

        // F lists Needs you's items on Overview; with no page read the keys wait.
        pv.inner = OVERVIEW;
        assert!(pv.page_key(&mut tv, k(KeyCode::Char('F')), Some(&pg), 10));
        assert!(pv.needs);
        assert!(!pv.page_key(&mut tv, k(KeyCode::Char('F')), None, 10));
        pv.open(&mut tv, Some(&pr.cards[1]));
        assert_eq!((pv.inner, pv.needs, pv.sys), (OVERVIEW, false, 0));
        pv.go(&mut tv, &pr.cards, "garden/stage");
        assert_eq!(pv.inner, "stage");
    }

    fn key(c: char) -> KeyEvent {
        KeyEvent::from(KeyCode::Char(c))
    }

    fn enter() -> KeyEvent {
        KeyEvent::from(KeyCode::Enter)
    }

    #[test]
    fn enter_opens_the_selected_project_a_opens_every_row_and_a_name_opens_its_project() {
        let pr = fixture();
        let (mut pv, mut tv) = (ProjView::default(), TaskView::default());
        for _ in 0..3 {
            assert!(pv.key(&mut tv, key('j'), &pr.cards, 10));
        }
        assert_eq!(pv.table.sel, 1, "j stops at the last row");
        pv.key(&mut tv, enter(), &pr.cards, 10);
        assert!(pv.open);
        assert_eq!(tv.project, Some(("personal".into(), "demo".into())));
        pv.close(&mut tv);
        assert!(!pv.open);
        assert_eq!(pv.table.sel, 1, "back on the row it opened");
        pv.key(&mut tv, key('a'), &pr.cards, 10);
        assert!(pv.open && tv.project.is_none());
        assert_eq!(pv.table.sel, 1, "All leaves the selection where it was");
        assert!(!pv.key(&mut tv, key('z'), &pr.cards, 10));

        pv.go(&mut tv, &pr.cards, "personal/Garden");
        assert_eq!(
            (pv.table.sel, tv.project.clone()),
            (0, Some(("personal".into(), "garden".into())))
        );
        pv.go(&mut tv, &pr.cards, "menu");
        assert_eq!(
            (tv.project.clone(), tv.table.view.q.as_str()),
            (None, "menu")
        );
    }

    #[test]
    fn the_header_is_cards_columns_in_order() {
        use hub_core::table::Row as _;
        assert_eq!(HEADER.len(), Card::COLUMNS.len());
        for (h, c) in HEADER.iter().zip(Card::COLUMNS) {
            assert!(h.to_lowercase().starts_with(c), "{h} is not {c}");
        }
    }

    #[test]
    fn a_re_read_that_shrinks_the_view_leaves_the_last_row_selected() {
        let pr = fixture();
        let (mut pv, mut tv) = (
            ProjView {
                table: DataTable {
                    sel: 5,
                    ..Default::default()
                },
                ..Default::default()
            },
            TaskView::default(),
        );
        assert_eq!(pv.selected(&pr.cards).unwrap().name, "demo");
        let (l, at) = page(&pr, None, None, &pv, Palette { no_color: true }, 200);
        assert!(plain(&l[at.unwrap()]).starts_with("demo"));
        pv.key(&mut tv, key('k'), &pr.cards, 10);
        assert_eq!(pv.table.sel, 0, "k moves from the row on screen");
    }

    #[test]
    fn the_shared_keys_narrow_the_list_and_enter_opens_the_row_on_screen() {
        let pr = fixture();
        let (mut pv, mut tv) = (ProjView::default(), TaskView::default());
        pv.key(&mut tv, key('j'), &pr.cards, 10);
        for c in "/demo".chars() {
            assert!(pv.key(&mut tv, key(c), &pr.cards, 10), "{c} is typed");
        }
        assert!(pv.table.typing.is_some());
        assert_eq!(pv.shown(&pr.cards).len(), 2, "nothing applies until Enter");
        pv.key(&mut tv, enter(), &pr.cards, 10);
        assert!(!pv.open, "Enter ends the search, it opens nothing");
        assert_eq!(
            pv.table.sel, 0,
            "the view changed, so the selection is back on top"
        );
        assert_eq!(pv.shown(&pr.cards).len(), 1);
        pv.key(&mut tv, enter(), &pr.cards, 10);
        assert_eq!(tv.project, Some(("personal".into(), "demo".into())));
        pv.close(&mut tv);

        // A project the view hides still opens by name, and Back keeps the selection.
        pv.go(&mut tv, &pr.cards, "garden");
        assert_eq!(pv.table.sel, 0);
        pv.close(&mut tv);

        assert!(pv.key(&mut tv, KeyEvent::from(KeyCode::Esc), &pr.cards, 10));
        assert!(pv.table.is_default(), "Esc clears the view");
        assert!(!pv.key(&mut tv, KeyEvent::from(KeyCode::Esc), &pr.cards, 10));

        pv.key(&mut tv, key('s'), &pr.cards, 10);
        assert_eq!(pv.table.view.sort, "project");
        let (l, _) = page(&pr, None, None, &pv, Palette { no_color: true }, 200);
        let s: Vec<String> = l.iter().map(plain).collect();
        assert!(s.iter().any(|l| l.starts_with("PROJECT v")), "{s:?}");
        pv.key(&mut tv, key('f'), &pr.cards, 10);
        assert_eq!(pv.shown(&pr.cards).len(), 0, "none is in flight");
        let (l, at) = page(&pr, None, None, &pv, Palette { no_color: true }, 200);
        let s = l.iter().map(plain).collect::<Vec<_>>().join("\n");
        assert!(s.contains("0 of 2 projects"), "{s}");
        assert!(s.contains("No project matches."), "{s}");
        assert_eq!(at, None);
    }

    #[test]
    fn the_list_is_one_row_a_project_and_names_what_no_card_claims() {
        let mut pr = fixture();
        pr.cards[0].prio = "focus".into();
        pr.cards[0].waiting = 1;
        pr.cards[1].version = None;
        pr.cards[1].eta_days = None;
        let pv = ProjView {
            table: DataTable {
                sel: 1,
                ..Default::default()
            },
            ..Default::default()
        };
        let (l, at) = page(&pr, None, None, &pv, Palette { no_color: true }, 200);
        let s: Vec<String> = l.iter().map(plain).collect();
        // The Deliverables section is on top and still reading; the list follows it.
        assert_eq!(s[0], "Deliverables  reading fleet-bench epics");
        let s = s[2..].to_vec();
        assert!(
            s[0].starts_with("PROJECTS  2 projects, 1 in flight"),
            "{s:?}"
        );
        assert_eq!(s[1], "all 2  in flight 1  waiting 1");
        assert!(s[2].starts_with("ALL ROWS  reading notes board"), "{s:?}");
        assert_eq!(s[4].split_whitespace().collect::<Vec<_>>(), HEADER.to_vec());
        assert_eq!(
            s[5].split_whitespace().collect::<Vec<_>>(),
            [
                "garden", "personal", "alpha", "v0.0.1", "focus", "1", "0", "0", "3", "2", "75%",
                "1.0", "7d", "0", "1", "0", "0", "0", "-"
            ]
        );
        assert_eq!(
            s[at.unwrap() - 2].split_whitespace().collect::<Vec<_>>(),
            [
                "demo", "personal", "alpha", "-", "-", "2", "0", "0", "0", "2", "0%", "1.0", "-",
                "0", "0", "0", "0", "0", "-"
            ]
        );
        let tail = s.join("\n");
        assert!(
            tail.contains("NOT ON A CARD  1 active queue items"),
            "{tail}"
        );
        assert!(tail.ends_with("  dotfiles: fix the hook"), "{tail}");

        let narrow = page(&pr, None, None, &pv, Palette { no_color: true }, 40).0;
        assert!(narrow.iter().all(|l| plain(l).len() <= 40));
        let head = narrow.iter().map(plain).find(|l| l.starts_with("PROJECT "));
        let head = head.expect("the header stays");
        assert!(head.contains("PCT"), "{head}");
    }

    fn deliverable(project: &str, id: &str, title: &str, system: &str, track: &str) -> Deliverable {
        Deliverable {
            project: project.into(),
            profile: "personal".into(),
            id: id.into(),
            title: title.into(),
            system: system.into(),
            done: 8,
            total: 19,
            percent: Some(60),
            done_says: "60% 8/19".into(),
            eta: Some(1),
            eta_day: "11-13".into(),
            track: track.into(),
        }
    }

    fn delivs() -> Result<Deliverables, String> {
        Ok(Deliverables {
            rows: vec![
                deliverable("garden", "g-1", "school days", "gameplay", "behind"),
                deliverable("demo", "d-1", "Lobby", "netcode", "on track"),
            ],
            says: "Deliverables (2 open, 0 ready to verify, 1 on track, 1 behind)".into(),
            coverage_says: "Coverage: 4 linked / 9 open rows (44%)".into(),
            legend: hub_core::deliverables::LEGEND,
            ..Default::default()
        })
    }

    fn lines(l: &[Line<'static>]) -> Vec<String> {
        l.iter().map(plain).collect()
    }

    #[test]
    fn deliverables_sit_above_the_list_with_the_webs_words() {
        let pr = fixture();
        let d = delivs();
        let (l, at) = page(
            &pr,
            None,
            Some(&d),
            &ProjView::default(),
            Palette { no_color: true },
            120,
        );
        let s = lines(&l);
        assert!(
            s[0].starts_with("Deliverables (2 open, 0 ready to verify, 1 on track, 1 behind)"),
            "{s:?}"
        );
        assert_eq!(s[1], "all 2  behind 1  on track 1  verify 0");
        assert_eq!(
            s[2].split_whitespace().collect::<Vec<_>>(),
            ["PROJECT", "EPIC", "SYS", "DONE", "ETA", "TRACK"]
        );
        // worst first, the web's cell words: percent, then done/all
        assert_eq!(
            s[3].split_whitespace().collect::<Vec<_>>(),
            ["garden", "school", "days", "gameplay", "60%", "8/19", "11-13", "behind"]
        );
        assert!(
            s[5].starts_with("Coverage: 4 linked / 9 open rows (44%); percent is"),
            "{s:?}"
        );
        let list = s.iter().position(|l| l.starts_with("PROJECTS ")).unwrap();
        assert!(list > 5, "the list is under the section: {s:?}");
        // the list's own row is the highlighted one until `d` moves the keys
        assert!(at.unwrap() > list);
    }

    #[test]
    fn a_failed_read_says_so_and_a_missing_one_says_reading() {
        let pr = fixture();
        let pv = ProjView::default();
        let p = Palette { no_color: true };
        let bad: Result<Deliverables, String> = Err("fleet-bench epics: exit 2".into());
        let s = lines(&page(&pr, None, Some(&bad), &pv, p, 120).0);
        assert_eq!(s[0], "Deliverables");
        assert_eq!(s[1], "fleet-bench epics: exit 2");
        assert!(
            !s.iter()
                .any(|l| l.starts_with("PROJECT ") && l.contains("EPIC")),
            "{s:?}"
        );
        let none = Ok(Deliverables::default());
        let s = lines(&page(&pr, None, Some(&none), &pv, p, 120).0);
        assert!(s.iter().any(|l| l == "No open feature epics."), "{s:?}");
    }

    #[test]
    fn d_gives_the_table_the_keys_and_enter_opens_the_epics_project_on_build() {
        let pr = fixture();
        let d = delivs();
        let mut tv = TaskView::default();
        let mut pv = ProjView::default();
        let key = |c| KeyEvent::from(c);
        assert!(pv.key(&mut tv, key(KeyCode::Char('d')), &pr.cards, 20));
        assert!(pv.dfocus);
        let (l, at) = page(&pr, None, Some(&d), &pv, Palette { no_color: true }, 120);
        let s = lines(&l);
        assert_eq!(s[at.unwrap()].split_whitespace().next(), Some("garden"));
        // j moves in the table, not the project list
        assert!(pv.dkey(
            &mut tv,
            key(KeyCode::Char('j')),
            &pr.cards,
            d.as_ref().unwrap(),
            20
        ));
        assert_eq!((pv.dv.sel, pv.table.sel), (1, 0));
        // the shared keys work: f steps the chip
        assert!(pv.dkey(
            &mut tv,
            key(KeyCode::Char('f')),
            &pr.cards,
            d.as_ref().unwrap(),
            20
        ));
        assert_eq!(pv.dv.view.state, "behind");
        assert!(pv.dkey(
            &mut tv,
            key(KeyCode::Char('x')),
            &pr.cards,
            d.as_ref().unwrap(),
            20
        ));
        pv.dv.sel = 0;
        // Enter: the project opens on Build with the epic selected by id; g-10, which a search
        // for g-1 also matches, stays a row of its own
        assert!(pv.dkey(
            &mut tv,
            key(KeyCode::Enter),
            &pr.cards,
            d.as_ref().unwrap(),
            20
        ));
        assert!(pv.open && !pv.dfocus);
        assert_eq!(tv.project, Some(("personal".into(), "garden".into())));
        assert_eq!((pv.inner, pv.bv.view.q.as_str(), pv.bv.sel), (BUILD, "", 0));
        let mut d10 = d.clone().unwrap();
        let g10 = deliverable("garden", "g-10", "after g-1", "gameplay", "behind");
        d10.rows.insert(0, g10);
        pv.close(&mut tv);
        pv.dfocus = true;
        pv.dv.sel = 0;
        assert!(pv.dkey(&mut tv, key(KeyCode::Char('f')), &pr.cards, &d10, 20));
        assert!(pv.dkey(&mut tv, key(KeyCode::Char('j')), &pr.cards, &d10, 20));
        assert_eq!(pv.dshown(&d10)[pv.dv.sel].id, "g-1");
        assert!(pv.dkey(&mut tv, key(KeyCode::Enter), &pr.cards, &d10, 20));
        assert_eq!(
            (pv.inner, pv.bv.sel),
            (BUILD, 1),
            "g-1 is garden's second row"
        );
        pv.dv.clear();
        // Esc from the table: clear the view first, then back to the list
        pv.close(&mut tv);
        pv.dfocus = true;
        pv.dv.view.q = "zzz".into();
        assert!(pv.dkey(
            &mut tv,
            key(KeyCode::Esc),
            &pr.cards,
            d.as_ref().unwrap(),
            20
        ));
        assert!(pv.dfocus && pv.dv.is_default());
        assert!(pv.dkey(
            &mut tv,
            key(KeyCode::Esc),
            &pr.cards,
            d.as_ref().unwrap(),
            20
        ));
        assert!(!pv.dfocus);
    }

    #[test]
    fn an_epic_whose_project_has_no_card_opens_nothing() {
        let pr = fixture();
        let d: Result<Deliverables, String> = Ok(Deliverables {
            rows: vec![deliverable("ghost", "x-1", "Lost", "ui", "behind")],
            ..Default::default()
        });
        let mut tv = TaskView::default();
        let mut pv = ProjView {
            dfocus: true,
            ..Default::default()
        };
        pv.dkey(
            &mut tv,
            KeyEvent::from(KeyCode::Enter),
            &pr.cards,
            d.as_ref().unwrap(),
            20,
        );
        assert!(!pv.open);
    }

    #[test]
    fn a_long_table_shows_a_window_that_follows_the_selection() {
        let pr = fixture();
        let rows: Vec<Deliverable> = (0..30)
            .map(|i| {
                deliverable(
                    "garden",
                    &format!("g-{i}"),
                    &format!("epic {i:02}"),
                    "ui",
                    "on track",
                )
            })
            .collect();
        let d = Ok(Deliverables {
            rows,
            says: "Deliverables (30 open)".into(),
            ..Default::default()
        });
        let p = Palette { no_color: true };
        let mut pv = ProjView::default();
        let s = lines(&page(&pr, None, Some(&d), &pv, p, 120).0);
        assert!(
            s.iter().any(|l| l.contains("epic 00")) && !s.iter().any(|l| l.contains("epic 20"))
        );
        assert!(s.iter().any(|l| l.contains("0 above, 18 below")), "{s:?}");
        pv.dfocus = true;
        pv.dv.sel = 25;
        let (l, at) = page(&pr, None, Some(&d), &pv, p, 120);
        let s = lines(&l);
        assert!(s[at.unwrap()].contains("epic 25"), "{:?}", s[at.unwrap()]);
        assert!(!s.iter().any(|l| l.contains("epic 00")));
    }
}
