//! The Projects tab: its inner tabs (`layout` Projects: the list, Board, Sprints, Deliverables, Coverage,
//! Ladder; Left/Right switch them, as agent-web's strip), the list one table row per lab project
//! with its open version's progress, built by `hub_core::projects` (the same rows and words as
//! agent-web's), in flight first, on the shared `DataTable`. j/k pick a project, Enter opens its
//! page (`layout::project_page`: its work tabs, then Departments with a chip per department, Rows being tasktab.rs),
//! `a` opens Board, `d` Deliverables (Coverage and the department tabs are coveragetab.rs,
//! Ladder laddertab.rs); in the rows Esc clears the view first and then comes back here, as
//! Backspace does at once. `P` steps the selected project's priority (normal, focus, high, low;
//! from `only` it clears it); app.rs runs the write. This file reads and writes nothing.

use hub_core::deliverables::{Deliverable, Deliverables};
use hub_core::departments::{self, Coverage};
use hub_core::home::Running;
use hub_core::layout::{self, Inner, Tab};
use hub_core::page::{NeedGroup, Page, System};
use hub_core::projects::{self, Card, Projects, Stats};
use hub_core::session_actions::Runner;
use hub_core::sprint_page::{self, SprintRow};
use hub_core::stages::Ladder;
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
const HEADER: [&str; 21] = [
    "PROJECT", "STATE", "PROFILE", "STAGE", "VERSION", "PRIO", "OPEN", "DOING", "HOT", "DONE",
    "7D", "PTS", "PTS7D", "WINDOW", "DUE", "PACE/WK", "RUN", "WAIT", "QUEUED", "SHIPPED", "OLDEST",
];

#[derive(Debug)]
pub struct ProjView {
    /// The list's search, chip and sort, and its selected row.
    pub table: DataTable,
    /// The rows are open (tasktab), for one project or for every project.
    pub open: bool,
    /// A `hub tab projects <name>` that came before the cards: opened when they arrive.
    pub want: Option<String>,
    /// The opened project's inner tab (`layout::project_page`), Left/Right switch it.
    pub inner: &'static str,
    /// The opened project's department chips (`Card::dept_tabs`): nine for a product, two for infra.
    pub tabs: Vec<&'static str>,
    /// The chip open on its Departments tab, `[` and `]` step it; "" before a project opens.
    pub dept: &'static str,
    /// Overview's Needs you lists each group's items (`F`), not only its head.
    pub needs: bool,
    /// Releases' Legacy fold lists its versions and apps (`F`), not only its count.
    pub legacy: bool,
    /// Overview's selected system row, which Enter opens Deliverables filtered to.
    pub sys: usize,
    /// The Deliverables table's search, chip and sort, and its selected row.
    pub dv: DataTable,
    /// The opened project's Deliverables: its own view, so the list's Deliverables keep theirs.
    pub bv: DataTable,
    /// The Deliverables inner tab is shown (`d`), not the project list.
    pub dfocus: bool,
    /// The Coverage inner tab is shown (coveragetab.rs), and its table's view.
    pub cfocus: bool,
    pub cv: DataTable,
    /// The Ladder inner tab is shown (laddertab.rs), its tables' views, and whether the
    /// Requirements table has the keys (`t`) rather than Projects by stage.
    pub lfocus: bool,
    pub lreqs: bool,
    /// The Sprints inner tab is shown (Left/Right only): every project's windows.
    pub sfocus: bool,
    pub lv: DataTable,
    pub rv: DataTable,
    /// The opened project's Sprint tab: which window j/k have selected (open, queued, then
    /// scored, `pickable`), and the window's page once Enter opened it.
    pub ssel: usize,
    pub sprint: Option<SprintOpen>,
}

/// One sprint's page as the tab holds it (`hub_core::sprint_page`): read in a worker, so it is
/// `None` until it lands.
#[derive(Debug, Default)]
pub struct SprintOpen {
    pub version: String,
    pub page: Option<Result<sprint_page::Page, String>>,
    pub busy: bool,
    /// The rows' search, chip and sort, and the selected row.
    pub rows: DataTable,
}

impl Default for ProjView {
    fn default() -> ProjView {
        ProjView {
            table: DataTable::default(),
            open: false,
            want: None,
            inner: OVERVIEW,
            tabs: vec![],
            dept: "",
            needs: false,
            legacy: false,
            sys: 0,
            dv: DataTable::default(),
            bv: DataTable::default(),
            dfocus: false,
            cfocus: false,
            cv: DataTable::default(),
            lfocus: false,
            lreqs: false,
            sfocus: false,
            lv: DataTable::default(),
            rv: DataTable::default(),
            ssel: 0,
            sprint: None,
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
        self.tabs = c.map(|c| c.dept_tabs.clone()).unwrap_or_default();
        self.dept = self.tabs.first().copied().unwrap_or("");
        self.needs = false;
        self.legacy = false;
        self.sys = 0;
        self.bv = DataTable::default();
        self.ssel = 0;
        self.sprint = None;
    }

    /// The opened project's inner tabs: the work, then Departments when it has a chip.
    pub fn page_tabs(&self) -> Vec<Inner> {
        layout::project_page(&self.tabs)
    }

    /// The department the opened page shows, when its inner tab is Departments.
    pub fn dept(&self) -> Option<&'static str> {
        if self.inner != layout::DEPT_TAB {
            return None;
        }
        self.tabs
            .iter()
            .copied()
            .find(|id| *id == self.dept)
            .or(self.tabs.first().copied())
    }

    /// `[` and `]` step the open department chip, wrapping at the ends.
    fn step_dept(&mut self, back: bool) {
        let to = crate::innertabs::step_of(
            &layout::project_depts(&self.tabs),
            self.dept().unwrap_or(""),
            back,
        );
        if !to.is_empty() {
            self.dept = to;
        }
    }

    /// Back to the list, the selection on the row it was on.
    pub fn close(&mut self, tv: &mut TaskView) {
        self.open = false;
        tv.prompt = None;
        tv.said = None;
    }

    /// The tab's own inner tab shown, the list's `layout` id; None on an opened project's page.
    pub fn top(&self, tv: &TaskView) -> Option<&'static str> {
        match (self.open, tv.project.is_some()) {
            (true, true) => None,
            (true, false) => Some(ALL),
            _ if self.sfocus => Some(SPRINTS),
            _ if self.dfocus => Some(DELIVERABLES),
            _ if self.cfocus => Some(COVERAGE),
            _ if self.lfocus => Some(LADDER),
            _ => Some(LIST),
        }
    }

    /// Show the tab's inner tab `id`: Board opens every project's rows, searched afresh.
    pub fn set_top(&mut self, tv: &mut TaskView, id: &str) {
        self.sfocus = id == SPRINTS;
        self.dfocus = id == DELIVERABLES;
        self.cfocus = id == COVERAGE;
        self.lfocus = id == LADDER;
        if id != ALL {
            self.close(tv);
        } else if self.top(tv) != Some(ALL) {
            self.open(tv, None);
        }
    }

    /// Deliverables shows: its own inner tab, or an opened project's (dashboards rule 10: it
    /// reads only then).
    pub fn deliverables_shown(&self, tv: &TaskView) -> bool {
        self.top(tv) == Some(DELIVERABLES) || (self.top(tv).is_none() && self.inner == DELIVERABLES)
    }

    /// Coverage shows: its own inner tab, or an opened product's department or Overview (its
    /// department needs), which one read serves (dashboards rules 8 and 10).
    pub fn coverage_shown(&self, tv: &TaskView) -> bool {
        self.top(tv) == Some(COVERAGE)
            || (self.top(tv).is_none()
                && (self.dept().is_some() || (self.inner == OVERVIEW && !self.tabs.is_empty())))
    }

    /// The Ladder shows, so it reads (dashboards rule 10).
    pub fn ladder_shown(&self, tv: &TaskView) -> bool {
        self.top(tv) == Some(LADDER)
    }

    /// Left/Right on the tab's own inner tabs; false on an opened project's page, whose are its.
    pub fn step_top(&mut self, tv: &mut TaskView, back: bool) -> bool {
        let Some(on) = self.top(tv) else {
            return false;
        };
        self.set_top(tv, crate::innertabs::step(projects_tab(), on, back));
        true
    }

    /// The rows are drawn and take the row keys: every project's, or a project's Rows inner tab.
    pub fn rows_shown(&self, tv: &TaskView) -> bool {
        tv.project.is_none() || self.inner == ROWS
    }

    /// The opened project's keys that are not the rows': Left/Right switch the inner tab, and on
    /// Overview j/k pick a system and Enter opens Deliverables filtered to it, `F` lists each
    /// Needs you group's items; on Deliverables the shared table keys, Enter opens Rows searched
    /// to the epic; on Releases `F` lists the Legacy fold. False for a key it does not take.
    pub fn page_key(
        &mut self,
        tv: &mut TaskView,
        k: KeyEvent,
        pg: Option<&Page>,
        feed: Option<&Feed>,
        page: usize,
    ) -> bool {
        if let KeyCode::Left | KeyCode::Right = k.code {
            if self.bv.typing.is_none()
                && self.sprint.as_ref().is_none_or(|s| s.rows.typing.is_none())
            {
                self.inner = crate::innertabs::step_of(
                    &self.page_tabs(),
                    self.inner,
                    k.code == KeyCode::Left,
                );
                return true;
            }
        }
        if let (layout::DEPT_TAB, KeyCode::Char(c @ ('[' | ']'))) = (self.inner, k.code) {
            self.step_dept(c == '[');
            return true;
        }
        let Some(pg) = pg else { return false };
        match self.inner {
            OVERVIEW => match k.code {
                KeyCode::Char('F') => self.needs = !self.needs,
                KeyCode::Char('j') | KeyCode::Down => {
                    self.sys = (self.sys + 1).min(pg.systems.len().saturating_sub(1))
                }
                KeyCode::Char('k') | KeyCode::Up => self.sys = self.sys.saturating_sub(1),
                // `no system` has no word to search by: Deliverables opens on every epic.
                KeyCode::Enter => {
                    if let Some(s) = pg.systems.get(self.sys) {
                        self.bv.clear();
                        if !s.id.is_empty() {
                            self.bv.view.q = format!("sys:{}", s.id);
                        }
                        self.inner = DELIVERABLES;
                    }
                }
                _ => return false,
            },
            DELIVERABLES => {
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
            "releases" => match k.code {
                KeyCode::Char('F') => self.legacy = !self.legacy,
                _ => return false,
            },
            SPRINT => return self.sprint_key(tv, k, pg, feed, page),
            _ => return false,
        }
        true
    }

    /// The Sprint tab's keys. On the list: j/k pick a window, Enter opens its page. On a page:
    /// the shared table keys and moves over its rows, `[` and `]` the previous and next
    /// version, Esc clears the view and then closes the page.
    fn sprint_key(
        &mut self,
        tv: &TaskView,
        k: KeyEvent,
        pg: &Page,
        feed: Option<&Feed>,
        page: usize,
    ) -> bool {
        if let Some(so) = self.sprint.as_mut() {
            let n = match &so.page {
                Some(Ok(p)) => so.rows.view.apply(&p.rows).len(),
                _ => 0,
            };
            // The rows hide an empty state chip, so `f` steps over the chips the page has.
            if let (KeyCode::Char('f'), None, Some(Ok(p))) = (k.code, &so.rows.typing, &so.page) {
                so.rows.view.cycle_shown(&p.rows);
                return true;
            }
            if so.rows.key::<SprintRow>(k.code) != Took::No || so.rows.moves(k, n, page) {
                return true;
            }
            let near = |p: &sprint_page::Page, back: bool| {
                let l = if back { &p.prev } else { &p.next };
                l.as_ref().and_then(version_of)
            };
            match (k.code, &so.page) {
                (KeyCode::Char(c @ ('[' | ']')), Some(Ok(p))) => {
                    if let Some(v) = near(p, c == '[') {
                        self.sprint = Some(SprintOpen {
                            version: v,
                            ..Default::default()
                        });
                    }
                }
                (KeyCode::Esc, _) if !so.rows.is_default() => so.rows.clear(),
                (KeyCode::Esc, _) => self.sprint = None,
                _ => return false,
            }
            return true;
        }
        let versions = pickable(tv.project.as_ref(), pg, feed);
        match k.code {
            KeyCode::Char('j') | KeyCode::Down => {
                self.ssel = (self.ssel + 1).min(versions.len().saturating_sub(1))
            }
            KeyCode::Char('k') | KeyCode::Up => self.ssel = self.ssel.saturating_sub(1),
            KeyCode::Enter => match versions.get(self.ssel.min(versions.len().saturating_sub(1))) {
                Some(v) => {
                    self.sprint = Some(SprintOpen {
                        version: v.clone(),
                        ..Default::default()
                    })
                }
                None => return false,
            },
            _ => return false,
        }
        true
    }

    /// `hub tab projects <name>`: the project of that name, whatever the list's view keeps, else
    /// every project's rows searched for it. `<name>/<inner>` opens that inner tab. A bare inner
    /// id or section (`all`, `board`, `deliverables`) is the tab's inner tab, never a project:
    /// one of that name opens as `<profile>/<name>`, as on agent-web.
    pub fn go(&mut self, tv: &mut TaskView, cards: &[Card], name: &str) {
        if let Some(id) = crate::innertabs::named(projects_tab(), name) {
            self.set_top(tv, id);
            return;
        }
        // `all <search>` (links::Link::tab_args for a row): Board searched to it, as the web's
        // `#projects/all?q=<search>`.
        if let Some((first, q)) = name.split_once(char::is_whitespace) {
            if crate::innertabs::named(projects_tab(), first) == Some(ALL) {
                self.set_top(tv, ALL);
                tv.table.view.q = q.trim().to_string();
                return;
            }
        }
        // `<profile>/<project>/sprint/<version>` (`links::Kind::Sprint`'s `tab_args`): that
        // project's Sprint tab with the window's page open.
        let (name, sprint) = match name.rsplit_once("/sprint/") {
            Some((n, v)) if sprint_page::safe_version(v) => (n, Some(v)),
            _ => (name, None),
        };
        let is_card = |name: &str, c: &Card| {
            c.name.eq_ignore_ascii_case(name)
                || format!("{}/{}", c.profile, c.name).eq_ignore_ascii_case(name)
        };
        // A project named like an inner tab (`bnb/ops`) is the project, not a chip of `bnb`.
        let (name, target) = if cards.iter().any(|c| is_card(name, c)) {
            (name, None)
        } else {
            split_target(name)
        };
        let named = |c: &Card| is_card(name, c);
        match cards.iter().find(|c| named(c)) {
            Some(c) => {
                if let Some(i) = self.shown(cards).iter().position(|s| named(s)) {
                    self.table.sel = i;
                }
                self.open(tv, Some(c));
                // A department the card lacks opens its first chip.
                if let Some((i, chip)) =
                    target.filter(|t| self.page_tabs().iter().any(|p| p.id == t.0))
                {
                    self.inner = i;
                    if let Some(d) = chip.filter(|d| self.tabs.contains(d)) {
                        self.dept = d;
                    }
                }
                if let Some(v) = sprint {
                    self.inner = SPRINT;
                    self.sprint = Some(SprintOpen {
                        version: v.to_string(),
                        ..Default::default()
                    });
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
    /// opens the selected epic's project on Deliverables with the epic selected, Esc clears the view and
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
                    // Deliverables is the same rows scoped to the project, in the same default order,
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
                    self.inner = DELIVERABLES;
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

const LIST: &str = "list";
const ALL: &str = "all";
const SPRINTS: &str = "sprints";
const SPRINT: &str = "sprint";
const DELIVERABLES: &str = "deliverables";
const LADDER: &str = "ladder";
const COVERAGE: &str = "coverage";

/// Projects in `layout`, whose `inner` is the list, Board, Sprints, Deliverables, Coverage and Ladder.
fn projects_tab() -> &'static Tab {
    layout::resolve("projects").expect("layout has Projects")
}

/// The strip over the tab's inner tabs, each with its total once read: Board the feed's
/// `totals.agent` (`tasks::Totals`, the agent board the tiers line under it names and
/// agent-web's strip shows; its closed rows are the table's done chip), and Deliverables its epics as of its last read: it
/// reads only while it shows, so its count waits for the first visit and then stays at that
/// read until the next. Coverage counts the products with a red cell and Ladder its failing
/// projects, as agent-web's do.
pub fn top_strip(
    feed: Option<&Feed>,
    dl: Option<&Result<Deliverables, String>>,
    cov: Option<&Coverage>,
    ladder: Option<&Ladder>,
    on: &str,
    p: Palette,
    w: usize,
) -> Line<'static> {
    let total = |i: &layout::Inner| match i.id {
        ALL => feed.and_then(|f| f.totals).map(|t| t.agent),
        SPRINTS => feed.map(|f| {
            f.sprint_rows(None, chrono::Local::now().naive_local())
                .len()
        }),
        DELIVERABLES => dl.and_then(|d| d.as_ref().ok()).map(|d| d.rows.len()),
        COVERAGE => cov.map(Coverage::failing),
        LADDER => ladder.map(|l| l.failing),
        _ => None,
    };
    crate::innertabs::strip_totals(projects_tab().inner, on, total, p, w)
}

const OVERVIEW: &str = "overview";
const ROWS: &str = "rows";

/// A `hub tab projects` word split into the project and the inner tab it names, with the chip on
/// Departments (`layout::project_target`): `<name>/<inner>`, `<name>/departments/<dept>`, or an
/// old department id such as `<name>/legal`. A tail that names no inner tab stays in the name.
fn split_target(word: &str) -> (&str, Option<(&'static str, Option<&'static str>)>) {
    let chip = word.rsplit_once('/').and_then(|(rest, c)| {
        let (n, t) = rest.rsplit_once('/')?;
        t.eq_ignore_ascii_case(layout::DEPT_TAB).then_some((n, c))
    });
    if let Some((n, _)) = chip {
        if let Some((i, d)) = layout::project_target(&word[n.len() + 1..]) {
            return (n, Some((i.id, d)));
        }
    }
    match word.rsplit_once('/') {
        Some((n, i)) => {
            layout::project_target(i).map_or((word, None), |(i, d)| (n, Some((i.id, d))))
        }
        None => (word, None),
    }
}

const BAR: usize = 20;

/// `[#######.............]`, the release window's delivered share of its committed rows.
fn bar(share: u32, p: Palette) -> Vec<Span<'static>> {
    let (on, off) = crate::fmt::bar(Some(share), None, BAR);
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

/// A project state's hue (`projects::state_level`), grey for `parked`.
fn state_style(c: &Card, p: Palette) -> ratatui::style::Style {
    projects::state_level(c.state).map_or_else(|| p.dim(), |l| crate::releases::level(l, p))
}

/// The opened card's first line, a breadcrumb: `Projects > name`, its state in its hue (none
/// while the queue is unread), then profile, stage, priority.
fn head(c: &Card, p: Palette, w: usize) -> Line<'static> {
    let spans = vec![
        Span::styled("Projects > ", p.dim()),
        Span::styled(c.name.clone(), p.head()),
        Span::styled(
            if c.state.is_empty() {
                String::new()
            } else {
                format!("  {}", c.state)
            },
            state_style(c, p),
        ),
        Span::styled(format!("  {}, {}", c.profile, c.stage), p.dim()),
        Span::styled(
            if c.prio.is_empty() {
                String::new()
            } else {
                format!(", prio {}", c.prio)
            },
            if c.prio == "focus" { p.head() } else { p.dim() },
        ),
    ];
    clip_line(Line::from(spans), w)
}

/// The window's bar and the open version's numbers, wrapped under the bar when they do not fit
/// beside it. With no window there is no bar, only the words, which say `no window`.
fn bar_lines(c: &Card, p: Palette, w: usize) -> Vec<Line<'static>> {
    let numbers = projects::summary(c);
    let Some(share) = projects::window_share(c) else {
        return wrapped("  ", &numbers, Default::default(), p, w);
    };
    let mut b = vec![Span::raw("  ")];
    b.extend(bar(share, p));
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
pub(crate) fn sec_head(title: &str, says: &str, keys: &str, p: Palette, w: usize) -> Line<'static> {
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

/// Overview's Needs you groups: the work's (the page's), then each department's
/// (`Product::need_groups`), so what is critical anywhere is on the page's first tab.
fn need_groups(pg: &Page, prod: Option<&departments::Product>) -> Vec<NeedGroup> {
    let mut out = pg.need_groups.clone();
    out.extend(prod.map(|pr| pr.need_groups()).unwrap_or_default());
    out
}

/// The inner tab a Needs you group acts on, as ` (Title)`: Stage, or its department.
fn need_to(kind: &str) -> String {
    let id = kind.strip_prefix("dept:").unwrap_or(kind);
    match layout::project_target(id) {
        Some((i, None)) if kind == "stage" => format!("  ({})", i.title),
        Some((i, Some(d))) if kind != id => format!(
            "  ({} > {})",
            i.title,
            layout::PROJECT_DEPTS
                .iter()
                .find(|x| x.id == d)
                .map_or(d, |x| x.title)
        ),
        _ => String::new(),
    }
}

/// Why Overview lacks the department needs a typed page should have: Coverage not read yet,
/// or read without this product. None when they are there or the page has no departments.
fn dept_note(pv: &ProjView, cov: Option<&Coverage>, key: &str) -> Option<String> {
    if pv.tabs.is_empty() || cov.is_some_and(|c| c.product(key).is_some()) {
        return None;
    }
    Some(match cov {
        None => "departments: reading...".into(),
        Some(c) if c.says.is_empty() => format!("departments not read: {key} is not in Coverage"),
        Some(c) => format!("departments not read: {}", c.says.join(" ")),
    })
}

/// Overview: what needs the human (each group's head, its items with `F`, and why the
/// departments' are missing), what is in flight, and one table row per system, the selected one
/// marked; and the line it is on.
fn overview(
    c: &Card,
    pg: &Page,
    prod: Option<&departments::Product>,
    dept_note: Option<&str>,
    pv: &ProjView,
    p: Palette,
    w: usize,
) -> (Vec<Line<'static>>, Option<usize>) {
    let groups = need_groups(pg, prod);
    let n: usize = groups.iter().map(|g| g.items.len()).sum();
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
    for g in &groups {
        let to = need_to(&g.kind);
        out.extend(wrapped("  ", &format!("{}{to}", g.says), p.warn(), p, w));
        if pv.needs {
            for i in &g.items {
                out.extend(wrapped("      ", i, Default::default(), p, w));
            }
        }
    }
    if let Some(s) = dept_note {
        out.extend(wrapped("  ", s, p.dim(), p, w));
    }
    out.push(Line::raw(""));
    out.push(sec_head("IN FLIGHT", &projects::counts(c), "", p, w));
    if !c.running.is_empty() {
        // Home's Running table scoped to the project, so a phase reads the same in both.
        let rows: Vec<&Running> = c.running.iter().collect();
        let t = crate::hometab::running_table(&rows, p, hub_core::jobs::now(), None, true);
        out.extend(t.fit_wrapped(w, p.dim()).0);
    }
    out.push(Line::raw(""));
    out.push(sec_head(
        "SYSTEMS",
        &pg.systems_says,
        "  j/k pick, Enter opens Deliverables filtered to it",
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

/// Releases (`hub_core::project_releases`): the versions on the line newest first, the apps with
/// a line as Releases > Apps words them, then the Legacy fold, its items listed with `F`.
fn releases(pg: &Page, pv: &ProjView, p: Palette, w: usize) -> Vec<Line<'static>> {
    use hub_core::project_releases::{AppLine, Version};
    let t = &pg.release_tab;
    let ver = |v: &Version| -> Vec<Cell> {
        vec![
            v.version.clone().into(),
            cell(v.status.clone(), crate::releases::alert(v.level, p)),
            cell(v.line_text.clone(), p.dim()),
            v.progress_text.clone().into(),
            cell(v.cut_text.clone(), p.dim()),
        ]
    };
    let app = |a: &AppLine| -> Vec<Cell> {
        vec![
            a.app.clone().into(),
            cell(a.status_text.clone(), crate::releases::alert(a.level, p)),
            a.live_text.clone().into(),
            cell(a.released_text.clone(), p.dim()),
            cell(a.line_text.clone(), p.dim()),
        ]
    };
    let vers = |vs: &[Version]| {
        Table {
            header: vec!["VERSION", "STATUS", "LINE", "ROWS", "CUT"],
            rows: vs.iter().map(ver).collect(),
            keep: vec![0, 1, 3, 2, 4],
            flex: Some(4),
            ..Default::default()
        }
        .fit(w, p.head())
    };
    let apps = |as_: &[AppLine]| {
        Table {
            header: vec!["APP", "STATUS", "DEPLOYED", "RELEASED", "LINE"],
            rows: as_.iter().map(app).collect(),
            keep: vec![0, 1, 2, 3, 4],
            flex: Some(2),
            ..Default::default()
        }
        .fit(w, p.head())
    };
    let mut out = vec![sec_head(
        "VERSIONS",
        &t.versions.len().to_string(),
        "  hub tab releases versions/<project>/<v> opens one",
        p,
        w,
    )];
    for e in &t.errors {
        out.extend(wrapped("  ", e, p.bad(), p, w));
    }
    out.extend(wrapped("  ", &t.line_text, p.dim(), p, w));
    for e in &t.elsewhere {
        out.extend(wrapped("  ", &e.text, Default::default(), p, w));
    }
    if !t.versions.is_empty() {
        out.extend(vers(&t.versions));
    }
    out.push(Line::raw(""));
    out.push(sec_head("APPS", &t.apps.len().to_string(), "", p, w));
    if t.apps.is_empty() {
        out.push(Line::styled("  No app on a release line.", p.dim()));
    } else {
        out.extend(apps(&t.apps));
    }
    let n = t.legacy_versions.len() + t.legacy_apps.len();
    if n == 0 {
        return out;
    }
    let keys = if pv.legacy {
        "  F folds them"
    } else {
        "  F lists them"
    };
    out.push(Line::raw(""));
    out.push(sec_head("LEGACY", &t.legacy_says, keys, p, w));
    if pv.legacy {
        if !t.legacy_versions.is_empty() {
            out.extend(vers(&t.legacy_versions));
        }
        if !t.legacy_apps.is_empty() {
            out.extend(apps(&t.legacy_apps));
        }
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
    if let Some(h) = &c.status.headline {
        out.extend(wrapped("  ", h.full(), p.dim(), p, w));
    }
    // The labelled lines as a key table: the label padded to the widest, the value wrapped under itself.
    let key = c
        .status
        .rows
        .iter()
        .map(|f| f.label.text().len())
        .max()
        .unwrap_or(0);
    for f in &c.status.rows {
        let lead = format!("  {:<key$}  ", f.label.text());
        out.extend(wrapped(&lead, f.value.full(), p.dim(), p, w));
    }
    out
}

/// The version a sprint link names (`<profile>/<project>/<version>`).
fn version_of(l: &hub_core::links::Link) -> Option<String> {
    let hub_core::links::Link::To(_, id) = l else {
        return None;
    };
    id.rsplit('/').next().map(str::to_string)
}

/// A project's open and its queued windows, from the board feed.
fn windows(
    feed: Option<&Feed>,
    project: Option<&(String, String)>,
) -> (
    Vec<hub_core::tasks::SprintRow>,
    Vec<hub_core::tasks::SprintRow>,
) {
    match (feed, project) {
        (Some(f), Some((profile, name))) => f
            .sprint_rows(Some((profile, name)), chrono::Local::now().naive_local())
            .into_iter()
            .partition(|r| !r.queued),
        _ => (vec![], vec![]),
    }
}

/// The versions j/k pick on a project's Sprint tab, in the order it draws them: the open
/// window, the queued ones, then the scored past, newest first.
fn pickable(project: Option<&(String, String)>, pg: &Page, feed: Option<&Feed>) -> Vec<String> {
    let (open, queued) = windows(feed, project);
    let mut out: Vec<String> = open.into_iter().chain(queued).map(|r| r.version).collect();
    for s in &pg.sprint_past {
        if !out.contains(&s.version) {
            out.push(s.version.clone());
        }
    }
    out
}

/// A sprint field's text, a dash where it is unset.
fn opt_dash(o: &Option<String>) -> String {
    o.clone().unwrap_or_else(|| "-".into())
}

/// The Sprint inner tab of an opened project (`hub_core::tasks::SprintRow`, `hub_core::project_sprints`):
/// its open window, the ones queued behind it, then its scored past, newest first; j/k pick one
/// and Enter opens its page. The windows come from the board feed, the past from the page
/// (`notes projects --sprints`).
fn sprint(
    c: &Card,
    pg: &Page,
    feed: Option<&Feed>,
    pv: &ProjView,
    p: Palette,
    w: usize,
) -> (Vec<Line<'static>>, Option<usize>) {
    if let Some(so) = &pv.sprint {
        return sprint_open(so, p, w);
    }
    let project = (c.profile.clone(), c.name.clone());
    let (open, queued) = windows(feed, Some(&project));
    let picked = pickable(Some(&project), pg, feed);
    let picked = picked.get(pv.ssel.min(picked.len().saturating_sub(1)));
    let mut at = None;
    // Style the picked window's line in a drawn table (its header, then one line per window).
    let mut pick = |lines: &mut Vec<Line<'static>>, from: usize, versions: Vec<&str>| {
        if let Some(i) = versions.iter().position(|v| Some(&v.to_string()) == picked) {
            if let Some(l) = lines.get_mut(from + 1 + i) {
                l.style = p.sel();
                at = Some(from + 1 + i);
            }
        }
    };
    let none = |what: &str| Line::styled(format!("  {what}"), p.dim());
    let mut out = vec![sec_head(
        "SPRINT",
        &open.len().to_string(),
        "  j/k pick a window, Enter opens its rows",
        p,
        w,
    )];
    match (feed, open.is_empty()) {
        (None, _) => out.push(none("reading the board...")),
        (_, true) => out.push(none("No window is open.")),
        _ => {
            let from = out.len();
            out.extend(crate::tasktab::sprint_lines(&open, p, w));
            pick(
                &mut out,
                from,
                open.iter().map(|r| r.version.as_str()).collect(),
            );
        }
    }
    out.push(sec_head("QUEUED", &queued.len().to_string(), "", p, w));
    if queued.is_empty() {
        out.push(none("No window is queued."));
    } else {
        let from = out.len();
        out.extend(crate::tasktab::sprint_lines(&queued, p, w));
        pick(
            &mut out,
            from,
            queued.iter().map(|r| r.version.as_str()).collect(),
        );
    }
    out.push(sec_head(
        "PAST",
        &pg.sprint_past.len().to_string(),
        "  newest first; each is sprints/<version>.md in the lab directory",
        p,
        w,
    ));
    if pg.sprint_past.is_empty() {
        out.push(none("No window has been cut with a score yet."));
        return (out, at);
    }
    let dash = opt_dash;
    let cells = pg
        .sprint_past
        .iter()
        .map(|s| {
            vec![
                s.version.clone().into(),
                dash(&s.opened).into(),
                dash(&s.cut).into(),
                s.committed.to_string().into(),
                s.delivered.to_string().into(),
                s.carried.to_string().into(),
                s.dropped.to_string().into(),
                s.interrupted.to_string().into(),
                cell(
                    dash(&s.timing),
                    warn_if(s.timing.as_deref().is_some_and(|t| t != "on time"), p),
                ),
            ]
        })
        .collect();
    let from = out.len();
    out.extend(
        Table {
            header: vec![
                "VERSION",
                "OPENED",
                "CUT",
                "COMMITTED",
                "DELIVERED",
                "CARRIED",
                "DROPPED",
                "INTERRUPTED",
                "TIMING",
            ],
            rows: cells,
            keep: vec![0, 4, 8, 3, 5, 6, 7, 2, 1],
            right: vec![3, 4, 5, 6, 7],
            ..Default::default()
        }
        .fit(w, p.head()),
    );
    pick(
        &mut out,
        from,
        pg.sprint_past.iter().map(|s| s.version.as_str()).collect(),
    );
    (out, at)
}

/// How many of a sprint's rows show at once; the rest scroll under the selection.
const SPRINT_ROWS: usize = 15;

/// One sprint's page: its dates and counts, the By area table, then every row with its outcome
/// on the shared table (the same words as agent-web's page).
fn sprint_open(so: &SprintOpen, p: Palette, w: usize) -> (Vec<Line<'static>>, Option<usize>) {
    let mut out = vec![sec_head(
        &format!("SPRINT {}", so.version),
        "",
        "  [ ] previous and next, / f s S x the table, Esc back",
        p,
        w,
    )];
    let pg = match &so.page {
        None => {
            out.push(Line::styled("  reading the sprint...", p.dim()));
            return (out, None);
        }
        Some(Err(e)) => {
            out.extend(wrapped("  ", e, p.warn(), p, w));
            return (out, None);
        }
        Some(Ok(pg)) => pg,
    };
    for l in &pg.head {
        out.extend(wrapped("  ", l, Default::default(), p, w));
    }
    for e in &pg.errors {
        out.extend(wrapped("  ", e, p.warn(), p, w));
    }
    out.push(Line::raw(""));
    out.push(sec_head("BY AREA", &pg.by_area.len().to_string(), "", p, w));
    let heads = sprint_page::area_heads(&pg.state);
    out.extend(
        Table {
            header: heads.iter().map(|(_, h)| *h).collect(),
            rows: pg
                .by_area
                .iter()
                .map(|a| {
                    vec![
                        a.group.clone().into(),
                        a.rows.to_string().into(),
                        a.delivered.to_string().into(),
                        a.pending.to_string().into(),
                        a.dropped.to_string().into(),
                        a.pts.clone().into(),
                    ]
                })
                .collect(),
            keep: vec![0, 2, 1, 3, 4, 5],
            right: vec![1, 2, 3, 4, 5],
            ..Default::default()
        }
        .fit(w, p.head()),
    );
    out.push(Line::raw(""));
    out.push(sec_head("ROWS", &pg.rows.len().to_string(), "", p, w));
    out.push(clip_line(Line::from(so.rows.status(&pg.rows, p)), w));
    let shown = so.rows.view.apply(&pg.rows);
    if shown.is_empty() {
        out.push(Line::styled("  No row matches.", p.dim()));
        return (out, None);
    }
    let sel = so.rows.sel.min(shown.len() - 1);
    let top = (sel + 1).saturating_sub(SPRINT_ROWS);
    let seen: Vec<&&SprintRow> = shown.iter().skip(top).take(SPRINT_ROWS).collect();
    let dash = opt_dash;
    let mut t = Table {
        header: vec![
            "ID", "TYPE", "SCOPE", "GROUP", "TITLE", "PTS", "OUTCOME", "STATE", "INT",
        ],
        rows: seen
            .iter()
            .map(|r| {
                vec![
                    dash(&r.id).into(),
                    dash(&r.kind).into(),
                    dash(&r.scope).into(),
                    r.group.clone().into(),
                    r.name.clone().into(),
                    r.pts.to_string().into(),
                    cell(r.outcome.clone(), warn_if(r.outcome == "dropped", p)),
                    r.state.clone().into(),
                    (if r.interrupt { "yes" } else { "-" }).into(),
                ]
            })
            .collect(),
        keep: vec![4, 6, 5, 3, 0, 1, 2, 7, 8],
        flex: Some(4),
        flexmin: 12,
        flexkeep: true,
        right: vec![5],
        mark: so.rows.mark::<SprintRow>(),
        ..Default::default()
    }
    .fit(w, p.head());
    let at = out.len() + sel - top + 1;
    if let Some(l) = t.get_mut(sel - top + 1) {
        l.style = p.sel();
    }
    out.append(&mut t);
    let (before, after) = (top, shown.len() - top - seen.len());
    if before + after > 0 {
        out.push(Line::styled(
            format!("  {before} above, {after} below"),
            p.dim(),
        ));
    }
    (out, Some(at))
}

/// Projects' Sprints inner tab: every project's open and queued windows (LEFT reads `queued`
/// for the next one), then each project's last scored window from its card (`last_window`).
fn sprints(pr: &Projects, feed: Option<&Feed>, p: Palette, w: usize) -> Vec<Line<'static>> {
    let none = |what: &str| Line::styled(format!("  {what}"), p.dim());
    let Some(f) = feed else {
        return vec![none("reading the board...")];
    };
    let rows = f.sprint_rows(None, chrono::Local::now().naive_local());
    let mut out = vec![sec_head("SPRINTS", &rows.len().to_string(), "", p, w)];
    if rows.is_empty() {
        out.push(none("No window is open or queued."));
    } else {
        out.extend(crate::tasktab::sprint_lines(&rows, p, w));
    }
    let last = hub_core::project_sprints::last_scores(&pr.cards);
    out.push(sec_head("LAST SCORE", &last.len().to_string(), "", p, w));
    if last.is_empty() {
        out.push(none("No project has a scored window."));
    }
    for l in &last {
        out.extend(wrapped(
            &format!("  {:<14} {:<8} ", l.project, l.version),
            &l.line,
            p.dim(),
            p,
            w,
        ));
    }
    out
}

/// The number beside an inner tab: Needs you's items on Overview, failing checks on Stage, a
/// department chip's needs that are not ok, and on Departments those of every chip (`tabs`).
fn inner_count(
    pg: Option<&Page>,
    prod: Option<&departments::Product>,
    tabs: &[&str],
    id: &str,
) -> usize {
    if id == layout::DEPT_TAB {
        return tabs.iter().map(|t| inner_count(pg, prod, &[], t)).sum();
    }
    if let Some(d) = prod.and_then(|pr| pr.dept(id)) {
        return d.open_needs();
    }
    let Some(pg) = pg else { return 0 };
    match id {
        OVERVIEW => pg.overview_needs(prod),
        "stage" => pg.gate.as_ref().map_or(0, |g| g.fail as usize),
        _ => 0,
    }
}

/// The opened project, as agent-web's project page: a breadcrumb head (the card, its goal, the
/// Flow line, releases, checks, alerts and the next stage), the inner tab strip
/// (`layout::project_page`, with the department chips under it on Departments), then the inner tab
/// shown; Rows draws nothing here, the app puts the rows under it. Task lines are never drawn:
/// they are Rows. `page` and `cov` are None while they are read. Returns the line the selection
/// is on, for the app to keep in view.
pub fn open_lines(
    c: &Card,
    page: Option<&Page>,
    cov: Option<&Coverage>,
    feed: Option<&Feed>,
    pv: &ProjView,
    p: Palette,
    w: usize,
) -> (Vec<Line<'static>>, Option<usize>) {
    let key = format!("{}/{}", c.profile, c.name);
    let prod = cov.and_then(|cv| cv.product(&key));
    let mut out = vec![head(c, p, w)];
    out.extend(bar_lines(c, p, w));
    let (goal, style) = if c.goal.is_empty() {
        ("no goal set", p.dim())
    } else {
        (c.goal.as_str(), Default::default())
    };
    out.extend(wrapped("  goal     ", goal, style, p, w));
    for v in &c.versions {
        let words = projects::version_words(v);
        out.extend(wrapped("  epics    ", &words, Default::default(), p, w));
    }
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
        if let Some(b) = &pg.checks {
            out.extend(wrapped(
                "  checks   ",
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
    out.extend(crate::innertabs::strip_flow(
        &pv.page_tabs(),
        pv.inner,
        |i| inner_count(page, prod, &pv.tabs, i.id),
        crate::innertabs::HINT,
        p,
        w,
    ));
    if let Some(d) = pv.dept() {
        out.extend(crate::innertabs::strip_flow(
            &layout::project_depts(&pv.tabs),
            d,
            |i| inner_count(page, prod, &pv.tabs, i.id),
            "  [ ] switch",
            p,
            w,
        ));
    }
    out.push(Line::raw(""));
    if pv.inner == ROWS {
        return (out, None);
    }
    if let Some(id) = pv.dept() {
        out.extend(crate::coveragetab::dept(cov, &key, id, p, w));
        return (out, None);
    }
    let Some(pg) = page else {
        out.push(Line::styled("  reading the page...", p.dim()));
        return (out, None);
    };
    let top = out.len();
    let (body, at) = match pv.inner {
        OVERVIEW => overview(c, pg, prod, dept_note(pv, cov, &key).as_deref(), pv, p, w),
        DELIVERABLES => deliverables(
            Some(Ok(&pg.build)),
            &pv.bv,
            true,
            "  Enter opens the epic's rows",
            p,
            w,
        ),
        SPRINT => sprint(c, pg, feed, pv, p, w),
        "releases" => (releases(pg, pv, p, w), None),
        "stage" => (stage(pg, p, w), None),
        _ => (activity(c, pg, p, w), None),
    };
    out.extend(body);
    (out, at.map(|a| a + top))
}

/// One line of the list: `Card`'s columns, a blank word as `-`.
fn row(c: &Card, p: Palette) -> Vec<Cell> {
    let dash = |s: &str| if s.is_empty() { "-" } else { s }.to_string();
    let lit = |n: usize, on| {
        let style = if n > 0 { on } else { p.dim() };
        cell(n.to_string(), style)
    };
    vec![
        c.name.clone().into(),
        cell(dash(c.state), state_style(c, p)),
        c.profile.clone().into(),
        dash(&c.stage).into(),
        dash(c.version.as_deref().unwrap_or_default()).into(),
        cell(
            dash(&c.prio),
            if c.prio == "focus" { p.head() } else { p.dim() },
        ),
        c.progress.open.to_string().into(),
        c.doing.to_string().into(),
        lit(c.hot, p.warn()),
        c.progress.done.to_string().into(),
        c.progress.closed_7d.to_string().into(),
        c.progress.done_weight.to_string().into(),
        c.progress.closed_weight_7d.to_string().into(),
        projects::window_cell(c).into(),
        projects::due_cell(c).into(),
        format!("{:.1}", c.pace()).into(),
        lit(c.running.len(), p.good()),
        lit(c.waiting, p.warn()),
        c.queued.to_string().into(),
        lit(c.today.shipped, p.good()),
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

/// The strip, then the list or Deliverables, and the line the selected row is on (the app keeps
/// it in view).
#[allow(clippy::too_many_arguments)]
pub fn page(
    pr: &Projects,
    feed: Option<&Feed>,
    dl: Option<&Result<Deliverables, String>>,
    cov: Option<&Coverage>,
    ladder: Option<&Ladder>,
    pv: &ProjView,
    p: Palette,
    w: usize,
) -> (Vec<Line<'static>>, Option<usize>) {
    let on = if pv.sfocus {
        SPRINTS
    } else if pv.dfocus {
        DELIVERABLES
    } else if pv.cfocus {
        COVERAGE
    } else if pv.lfocus {
        LADDER
    } else {
        LIST
    };
    let mut out = vec![top_strip(feed, dl, cov, ladder, on, p, w), Line::raw("")];
    let (mut body, at) = if pv.sfocus {
        (sprints(pr, feed, p, w), None)
    } else if pv.lfocus {
        crate::laddertab::page(ladder, pv, p, w)
    } else if pv.cfocus {
        crate::coveragetab::page(cov, pv, p, w)
    } else if pv.dfocus {
        let dl = dl.map(|r| r.as_ref().map_err(String::as_str));
        let hint = "  Enter opens the epic's project, Esc back";
        deliverables(dl, &pv.dv, true, hint, p, w)
    } else {
        list(pr, pv, p, w)
    };
    let at = at.map(|a| a + out.len());
    out.append(&mut body);
    (out, at)
}

/// The project list, the strip's first inner tab.
fn list(pr: &Projects, pv: &ProjView, p: Palette, w: usize) -> (Vec<Line<'static>>, Option<usize>) {
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
                    "  {count} projects, {flying} in flight; window is delivered of committed rows, due is days to its due day"
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
                0, 1, 13, 16, 17, 18, 8, 20, 6, 3, 15, 19, 7, 9, 11, 12, 10, 14, 4, 5, 2,
            ],
            right: (6..HEADER.len()).collect(),
            mark: pv.table.mark::<Card>(),
            ..Default::default()
        }
        .fit_wrapped(w, p.head());
        if let Some(&start) = starts.get(pv.at(shown.len())) {
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
                filed_weight_28d: 0,
                last_closed: Some("2026-11-04".into()),
            },
            state: if done > 0 {
                projects::ON_TRACK
            } else {
                projects::NO_WINDOW
            },
            // A window committing what the version holds, due in 7 days; `demo` has none.
            window: (done > 0).then(|| projects::Window {
                due: Some("2026-11-12".into()),
                committed: done + open,
                delivered: done,
                open,
                days_left: Some(7),
                ..Default::default()
            }),
            status: projects::Status::of(
                "landed the cards",
                &serde_json::from_str(r#"{"done":"the arena (#9).","needs":"nothing."}"#).unwrap(),
            ),
            status_date: "2026-11-05".into(),
            ..Default::default()
        };
        Projects {
            cards: vec![card("garden", 3, 1), card("demo", 0, 2)],
            unlinked: vec!["dotfiles: fix the hook".into()],
            errors: vec![],
            board_open: Some(4),
            board_backlog: Some(9),
        }
    }

    fn a_page() -> Page {
        Page {
            project: "garden".into(),
            releases: None,
            release_tab: Default::default(),
            sprint_past: vec![],
            alerts: None,
            checks: None,
            check_groups: vec![],
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
            need_count: 1,
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
        open_lines(c, pg, None, None, pv, Palette { no_color: true }, 200)
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
        assert_eq!(l[0], "Projects > garden  on track  personal, alpha");
        assert_eq!(l[2], "  goal     the human can see where each project is");
        assert!(l[3].starts_with("  flow     ideas 3 | briefs 1"), "{l:?}");
        assert!(l[4].starts_with("  next     beta  4 of 12 met"), "{l:?}");
        assert_eq!(l[5], "  project-stage-check --systems: exited 2");
        // An untyped project has no department tabs, so its strip has no break.
        assert_eq!(
            l[7],
            "[Overview 1] Sprint  Rows  Deliverables  Releases  Stage  Activity   <- -> switch"
        );
        let body = l[9..].join("\n");
        assert!(
            body.starts_with("NEEDS YOU  1  F lists them\n  1 epic landed with no live proof\n"),
            "{body}"
        );
        // Nor does it wait on departments it does not have.
        assert!(!body.contains("departments"), "{body}");
        assert!(
            !body.contains("Saves (4 of 4"),
            "F lists the items:\n{body}"
        );
        assert!(body.contains("SYSTEMS  2 systems, 1 open epics"), "{body}");
        // IN FLIGHT carries the agent board and backlog counts once the feed joined them in.
        assert!(!body.contains("Backlog"), "no feed, no tiers:\n{body}");
        let mut tiered = pr.cards[0].clone();
        tiered.agent_tiers = Some(hub_core::tasks::Tiers {
            sprint: hub_core::tasks::Sprint {
                open: 12,
                committed: 71,
            },
            board: 75,
            backlog: 12,
            epics: 2,
            epic_backlog: 5,
        });
        let t = draw(&tiered, Some(&pg), &pv).join("\n");
        assert!(
            t.contains("IN FLIGHT  0 running, 0 waiting, 0 queued; 0 rows #requested, 0 in the inbox; Sprint 12/71 | Today 75 | Backlog 12 | Epics 2 | Epic backlog 5"),
            "{t}"
        );
        // In flight is Home's Running table scoped to the project: the phase as `Phases::shown`
        // words it, the next phase its own column, and no PROJECT column or sentence.
        let mut busy = pr.cards[0].clone();
        busy.running = vec![hub_core::home::Running {
            slug: "s1".into(),
            title: "wire the bar".into(),
            project: busy.name.clone(),
            phases: Some(hub_core::boards::Phases {
                done: 1,
                total: 3,
                next: Some("web".into()),
                eta: None,
                eta_epoch: None,
                overdue: None,
            }),
            ..Default::default()
        }];
        let flight = draw(&busy, Some(&pg), &pv).join("\n");
        assert!(
            flight.contains("wire the bar") && flight.contains("PHASE"),
            "{flight}"
        );
        assert!(
            flight
                .lines()
                .any(|l| l.contains("1/3") && l.contains("web")),
            "{flight}"
        );
        assert!(
            !flight.contains("PROJECT") && !flight.contains("phase 2 of"),
            "{flight}"
        );
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
        watched.checks = Some(hub_core::releases::Badge {
            says: "Partial outage: api".into(),
            level: hub_core::releases::Level::Bad,
        });
        let lines = draw(&pr.cards[0], Some(&watched), &pv);
        let at = |want: &str| lines.iter().position(|l| l.starts_with(want));
        assert!(
            lines
                .iter()
                .any(|l| l == "  checks   Partial outage: api (R opens)"),
            "the checks line leads to the app's page under Releases: {lines:?}"
        );
        assert!(at("  checks").unwrap() < at("  alerts").unwrap());
        assert_eq!(
            draw(&pr.cards[0], None, &pv).last().unwrap(),
            "  reading the page..."
        );
        let mut c = pr.cards[0].clone();
        c.goal.clear();
        assert_eq!(draw(&c, None, &pv)[2], "  goal     no goal set");
        c.versions = vec![projects::VersionEpics {
            version: "v0.3.0".into(),
            epics: 2,
            done_weight: 5,
            total_weight: 20,
        }];
        let l = draw(&c, None, &pv);
        assert_eq!(l[3], "  epics    v0.3.0: 2 open epics, 5 of 20 points done");
        assert!(l[1].ends_with("; no target"), "{l:?}");
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
        let build = at(DELIVERABLES);
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
            "AGENT NOTE  model-written, 2026-11-05\n  landed the cards\n  Done       the arena (#9).\n  Needs you  nothing.",
        ] {
            assert!(act.contains(s), "{s} in {act}");
        }
    }

    #[test]
    fn left_right_step_the_inner_tabs_and_enter_walks_overview_to_deliverables_to_rows() {
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
        assert!(pv.page_key(&mut tv, k(KeyCode::Right), Some(&pg), None, 10));
        assert_eq!(pv.inner, SPRINT, "Sprint follows Overview");
        assert!(pv.page_key(&mut tv, k(KeyCode::Right), Some(&pg), None, 10));
        assert!(pv.rows_shown(&tv));
        assert!(pv.page_key(&mut tv, k(KeyCode::Left), Some(&pg), None, 10));
        assert!(pv.page_key(&mut tv, k(KeyCode::Left), Some(&pg), None, 10));
        assert!(pv.page_key(&mut tv, k(KeyCode::Left), Some(&pg), None, 10));
        assert_eq!(
            pv.inner, "activity",
            "Left from the first wraps to the last"
        );
        pv.inner = OVERVIEW;

        // j picks the second system; Enter opens Deliverables filtered to it.
        assert!(pv.page_key(&mut tv, k(KeyCode::Char('j')), Some(&pg), None, 10));
        assert!(pv.page_key(&mut tv, k(KeyCode::Char('j')), Some(&pg), None, 10));
        assert_eq!(pv.sys, 1, "j stops at the last system");
        let (_, sel) = open_lines(
            &pr.cards[0],
            Some(&pg),
            None,
            None,
            &pv,
            Palette { no_color: true },
            200,
        );
        let l = draw(&pr.cards[0], Some(&pg), &pv);
        assert!(l[sel.unwrap()].starts_with("ci "), "{l:?}");
        assert!(pv.page_key(&mut tv, k(KeyCode::Enter), Some(&pg), None, 10));
        assert_eq!((pv.inner, pv.bv.view.q.as_str()), (DELIVERABLES, "sys:ci"));
        assert!(
            pv.dv.is_default(),
            "the list's Deliverables keep their own view"
        );
        let s = draw(&pr.cards[0], Some(&pg), &pv).join("\n");
        assert!(s.contains("Pipelines") && !s.contains("Menus"), "{s}");

        // Esc clears Deliverables' filter; Enter on an epic opens Rows searched to it.
        assert!(pv.page_key(&mut tv, k(KeyCode::Esc), Some(&pg), None, 10));
        assert!(pv.bv.is_default());
        assert!(
            !pv.page_key(&mut tv, k(KeyCode::Esc), Some(&pg), None, 10),
            "then Esc goes back"
        );
        assert!(pv.page_key(&mut tv, k(KeyCode::Enter), Some(&pg), None, 10));
        assert_eq!((pv.inner, tv.table.view.q.as_str()), (ROWS, "tag:=of/gm-1"));

        // F lists Needs you's items on Overview; with no page read the keys wait.
        pv.inner = OVERVIEW;
        assert!(pv.page_key(&mut tv, k(KeyCode::Char('F')), Some(&pg), None, 10));
        assert!(pv.needs);
        assert!(!pv.page_key(&mut tv, k(KeyCode::Char('F')), None, None, 10));
        pv.open(&mut tv, Some(&pr.cards[1]));
        assert_eq!((pv.inner, pv.needs, pv.sys), (OVERVIEW, false, 0));
        pv.go(&mut tv, &pr.cards, "garden/stage");
        assert_eq!(pv.inner, "stage");
    }

    #[test]
    fn releases_draws_the_line_first_and_f_lists_the_legacy_fold() {
        use hub_core::project_releases::{AppLine, Version};
        let pr = fixture();
        let mut pg = a_page();
        let v = |n: &str, line: &str| Version {
            version: n.into(),
            status: "released".into(),
            line_text: line.into(),
            ..Default::default()
        };
        let a = |n: &str, line: &str| AppLine {
            app: n.into(),
            status_text: "live".into(),
            line_text: line.into(),
            ..Default::default()
        };
        pg.release_tab.versions = vec![
            v("v0.6.0", "on the line"),
            v("v0.5.9", "cut outside the release flow"),
        ];
        pg.release_tab.apps = vec![a("garden-web", "from v0.5.0")];
        pg.release_tab.legacy_versions = vec![v("v0.1.0", "before the line")];
        pg.release_tab.legacy_apps = vec![a("garden-old", "no line")];
        pg.release_tab.legacy_says = "1 versions, 1 apps".into();
        pg.release_tab.line_text = "line from v0.5.0".into();
        let (mut pv, mut tv) = (ProjView::default(), TaskView::default());
        pv.open(&mut tv, Some(&pr.cards[0]));
        pv.go(&mut tv, &pr.cards, "garden/releases");
        assert_eq!(pv.inner, "releases");
        let s = draw(&pr.cards[0], Some(&pg), &pv).join("\n");
        let at = |t: &str| s.find(t).unwrap_or_else(|| panic!("{t} in {s}"));
        assert!(at("v0.6.0") < at("v0.5.9") && at("v0.5.9") < at("APPS"));
        assert!(s.contains("cut outside the release flow") && s.contains("line from v0.5.0"));
        assert!(at("APPS") < at("garden-web") && at("garden-web") < at("LEGACY"));
        assert!(s.contains("F lists them"), "{s}");
        assert!(
            !s.contains("v0.1.0") && !s.contains("garden-old"),
            "the fold is shut: {s}"
        );

        let k = |c| KeyEvent::from(c);
        assert!(pv.page_key(&mut tv, k(KeyCode::Char('F')), Some(&pg), None, 10));
        let s = draw(&pr.cards[0], Some(&pg), &pv).join("\n");
        assert!(s.contains("v0.1.0") && s.contains("garden-old") && s.contains("F folds them"));
        pv.open(&mut tv, Some(&pr.cards[0]));
        assert!(!pv.legacy, "a project opens with its fold shut");

        // Nothing legacy: no fold at all.
        pg.release_tab.legacy_versions.clear();
        pg.release_tab.legacy_apps.clear();
        pv.go(&mut tv, &pr.cards, "garden/releases");
        let s = draw(&pr.cards[0], Some(&pg), &pv).join("\n");
        assert!(!s.contains("LEGACY"), "{s}");
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
        let (l, at) = page(
            &pr,
            None,
            None,
            None,
            None,
            &pv,
            Palette { no_color: true },
            200,
        );
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
        let (l, _) = page(
            &pr,
            None,
            None,
            None,
            None,
            &pv,
            Palette { no_color: true },
            200,
        );
        let s: Vec<String> = l.iter().map(plain).collect();
        assert!(s.iter().any(|l| l.starts_with("PROJECT v")), "{s:?}");
        pv.key(&mut tv, key('f'), &pr.cards, 10);
        assert_eq!(pv.shown(&pr.cards).len(), 0, "none is in flight");
        let (l, at) = page(
            &pr,
            None,
            None,
            None,
            None,
            &pv,
            Palette { no_color: true },
            200,
        );
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
        let pv = ProjView {
            table: DataTable {
                sel: 1,
                ..Default::default()
            },
            ..Default::default()
        };
        let (l, at) = page(
            &pr,
            None,
            None,
            None,
            None,
            &pv,
            Palette { no_color: true },
            200,
        );
        let s: Vec<String> = l.iter().map(plain).collect();
        // The strip is on top, nothing counted before its read; the list follows it.
        assert_eq!(
            s[0],
            "[Projects] Board  Sprints  Deliverables  Coverage  Ladder   <- -> switch"
        );
        let s = s[2..].to_vec();
        assert!(
            s[0].starts_with("PROJECTS  2 projects, 1 in flight"),
            "{s:?}"
        );
        assert_eq!(s[1], "all 2  in flight 1  waiting 1");
        assert_eq!(s[3].split_whitespace().collect::<Vec<_>>(), HEADER.to_vec());
        assert_eq!(
            s[4].split_whitespace().collect::<Vec<_>>(),
            [
                "garden", "on", "track", "personal", "alpha", "v0.0.1", "focus", "1", "0", "0",
                "3", "2", "3", "2", "3/4", "7d", "1.0", "0", "1", "0", "0", "-"
            ]
        );
        assert_eq!(
            s[at.unwrap() - 2].split_whitespace().collect::<Vec<_>>(),
            [
                "demo", "no", "window", "personal", "alpha", "-", "-", "2", "0", "0", "0", "2",
                "0", "2", "no", "window", "-", "1.0", "0", "0", "0", "0", "-"
            ]
        );
        let tail = s.join("\n");
        assert!(
            tail.contains("NOT ON A CARD  1 active queue items"),
            "{tail}"
        );
        assert!(tail.ends_with("  dotfiles: fix the hook"), "{tail}");

        let narrow = page(
            &pr,
            None,
            None,
            None,
            None,
            &pv,
            Palette { no_color: true },
            40,
        )
        .0;
        assert!(narrow.iter().all(|l| plain(l).len() <= 40));
        let head = narrow.iter().map(plain).find(|l| l.starts_with("PROJECT "));
        let head = head.expect("the header stays");
        assert!(head.contains("WINDOW"), "{head}");
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
    fn deliverables_is_its_own_inner_tab_with_the_webs_words() {
        let pr = fixture();
        let d = delivs();
        let pv = ProjView {
            dfocus: true,
            ..Default::default()
        };
        let (l, at) = page(
            &pr,
            None,
            Some(&d),
            None,
            None,
            &pv,
            Palette { no_color: true },
            120,
        );
        let s = lines(&l);
        assert_eq!(
            s[0], " Projects  Board  Sprints [Deliverables 2] Coverage  Ladder   <- -> switch",
            "{s:?}"
        );
        let s = s[2..].to_vec();
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
        assert!(
            !s.iter().any(|l| l.starts_with("PROJECTS ")),
            "the list is its own inner tab: {s:?}"
        );
        assert_eq!(at, Some(5), "the table's first row, under the strip");
    }

    #[test]
    fn a_failed_read_says_so_and_a_missing_one_says_reading() {
        let pr = fixture();
        let pv = ProjView {
            dfocus: true,
            ..Default::default()
        };
        let p = Palette { no_color: true };
        let s = lines(&page(&pr, None, None, None, None, &pv, p, 120).0);
        assert_eq!(s[2], "Deliverables  reading fleet-bench epics");
        let bad: Result<Deliverables, String> = Err("fleet-bench epics: exit 2".into());
        let s = lines(&page(&pr, None, Some(&bad), None, None, &pv, p, 120).0);
        assert_eq!(s[2], "Deliverables");
        assert_eq!(s[3], "fleet-bench epics: exit 2");
        assert!(
            !s.iter()
                .any(|l| l.starts_with("PROJECT ") && l.contains("EPIC")),
            "{s:?}"
        );
        let none = Ok(Deliverables::default());
        let s = lines(&page(&pr, None, Some(&none), None, None, &pv, p, 120).0);
        assert!(s.iter().any(|l| l == "No open feature epics."), "{s:?}");
    }

    #[test]
    fn d_gives_the_table_the_keys_and_enter_opens_the_epics_project_on_deliverables() {
        let pr = fixture();
        let d = delivs();
        let mut tv = TaskView::default();
        let mut pv = ProjView::default();
        let key = |c| KeyEvent::from(c);
        assert!(pv.key(&mut tv, key(KeyCode::Char('d')), &pr.cards, 20));
        assert!(pv.dfocus);
        let (l, at) = page(
            &pr,
            None,
            Some(&d),
            None,
            None,
            &pv,
            Palette { no_color: true },
            120,
        );
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
        // Enter: the project opens on Deliverables with the epic selected by id; g-10, which a search
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
        assert_eq!(
            (pv.inner, pv.bv.view.q.as_str(), pv.bv.sel),
            (DELIVERABLES, "", 0)
        );
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
            (DELIVERABLES, 1),
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
        let mut pv = ProjView {
            dfocus: true,
            ..Default::default()
        };
        let s = lines(&page(&pr, None, Some(&d), None, None, &pv, p, 120).0);
        assert!(
            s.iter().any(|l| l.contains("epic 00")) && !s.iter().any(|l| l.contains("epic 20"))
        );
        assert!(s.iter().any(|l| l.contains("0 above, 18 below")), "{s:?}");
        pv.dv.sel = 25;
        let (l, at) = page(&pr, None, Some(&d), None, None, &pv, p, 120);
        let s = lines(&l);
        assert!(s[at.unwrap()].contains("epic 25"), "{:?}", s[at.unwrap()]);
        assert!(!s.iter().any(|l| l.contains("epic 00")));
    }

    #[test]
    fn a_game_shows_nine_department_tabs_infra_two_and_an_untyped_project_none_at_80_columns() {
        let p = Palette { no_color: true };
        let mut pr = fixture();
        pr.cards[0].dept_tabs = layout::dept_tabs(Some("game"));
        pr.cards[1].dept_tabs = layout::dept_tabs(Some("infra"));
        let (mut pv, mut tv) = (ProjView::default(), TaskView::default());
        pv.open(&mut tv, Some(&pr.cards[0]));
        assert_eq!(pv.tabs.len(), 9);
        let (l, _) = open_lines(&pr.cards[0], None, None, None, &pv, p, 80);
        let t = lines(&l);
        assert!(t.iter().all(|s| crate::fit::len(s) <= 80), "{t:#?}");
        let s = t.iter().position(|s| s.starts_with("[Overview]")).unwrap();
        // Eight tabs fit one line; Departments is the last, and its nine chips sit on their own
        // strip beneath it, which is not drawn until Departments is open.
        assert_eq!(
            t[s],
            "[Overview] Sprint  Rows  Deliverables  Releases  Stage  Activity  Departments "
        );
        let titles = layout::project_page(&pv.tabs);
        assert_eq!(titles.len(), 8);
        assert_eq!(layout::project_depts(&pv.tabs).len(), 9);
        assert!(!t.iter().any(|s| s.contains("Engineering")), "{t:#?}");

        // Right walks to the work first; a department shows "reading" until Coverage arrives,
        // then its parts.
        assert!(pv.page_key(&mut tv, KeyEvent::from(KeyCode::Right), None, None, 10));
        assert_eq!((pv.inner, pv.dept()), (SPRINT, None));
        assert!(pv.page_key(&mut tv, KeyEvent::from(KeyCode::Right), None, None, 10));
        assert_eq!((pv.inner, pv.dept()), (ROWS, None));
        // An old `garden/legal` link and the new `garden/departments/legal` both land on the
        // Legal chip of the Departments tab.
        pv.go(&mut tv, &pr.cards, "garden/departments/design");
        assert_eq!((pv.inner, pv.dept()), (layout::DEPT_TAB, Some("design")));
        pv.go(&mut tv, &pr.cards, "garden/legal");
        assert_eq!((pv.inner, pv.dept()), (layout::DEPT_TAB, Some("legal")));
        let t = lines(&open_lines(&pr.cards[0], None, None, None, &pv, p, 80).0);
        assert!(t.iter().all(|s| crate::fit::len(s) <= 80), "{t:#?}");
        let s = t
            .iter()
            .position(|s| s.contains("[Departments]"))
            .unwrap_or_else(|| panic!("{t:#?}"));
        assert!(t[s].contains("[Departments]"), "{t:#?}");
        let chips = t[s + 1..].join("");
        assert!(
            [
                "Product",
                "Engineering",
                "Ops",
                "Design",
                "Analytics",
                "Marketing",
                "Legal",
                "Support",
                "Money"
            ]
            .iter()
            .all(|c| chips.contains(c)),
            "{t:#?}"
        );
        assert!(chips.contains("[Legal]"), "{t:#?}");
        // `]` steps to the next chip, `[` back; neither leaves Departments.
        assert!(pv.page_key(&mut tv, KeyEvent::from(KeyCode::Char(']')), None, None, 10));
        assert_eq!((pv.inner, pv.dept()), (layout::DEPT_TAB, Some("support")));
        assert!(pv.page_key(&mut tv, KeyEvent::from(KeyCode::Char('[')), None, None, 10));
        assert_eq!(pv.dept(), Some("legal"));
        let t = lines(&open_lines(&pr.cards[0], None, None, None, &pv, p, 80).0);
        assert!(
            t.contains(&"  reading the departments...".to_string()),
            "{t:#?}"
        );
        let c = crate::coveragetab::tests::coverage();
        let t = lines(&open_lines(&pr.cards[0], None, Some(&c), None, &pv, p, 80).0);
        assert!(
            t.iter().any(|s| s == "LEGAL  red  required from beta"),
            "{t:#?}"
        );
        assert!(t.iter().any(|s| s.starts_with("CHECKLIST")), "{t:#?}");
        // Overview lists each department's needs after the work's, naming the tab that acts.
        pv.inner = OVERVIEW;
        let pg = Page::default();
        let t = lines(&open_lines(&pr.cards[0], Some(&pg), Some(&c), None, &pv, p, 80).0);
        assert!(
            t.iter()
                .any(|s| s.starts_with("  Legal: ") && s.ends_with("(Departments > Legal)")),
            "{t:#?}"
        );
        assert!(!t.iter().any(|s| s.contains("departments")), "{t:#?}");
        // A typed Overview reads Coverage, and until it arrives says so instead of a clean list.
        assert!(pv.coverage_shown(&tv));
        let t = lines(&open_lines(&pr.cards[0], Some(&pg), None, None, &pv, p, 80).0);
        assert!(
            t.iter().any(|s| s.starts_with("NEEDS YOU  nothing")),
            "{t:#?}"
        );
        assert!(
            t.contains(&"  departments: reading...".to_string()),
            "{t:#?}"
        );
        // A Coverage read without this product says why, too.
        let none = Coverage {
            says: vec!["catalog not read".into()],
            ..Default::default()
        };
        let t = lines(&open_lines(&pr.cards[0], Some(&pg), Some(&none), None, &pv, p, 80).0);
        assert!(
            t.contains(&"  departments not read: catalog not read".to_string()),
            "{t:#?}"
        );
        // Negative control: Rows does not read Coverage.
        pv.inner = ROWS;
        assert!(!pv.coverage_shown(&tv));

        // An infra project: only engineering and ops; a department word it lacks opens the first chip, as the web does.
        let (mut pv, mut tv) = (ProjView::default(), TaskView::default());
        pv.open(&mut tv, Some(&pr.cards[1]));
        assert_eq!(pv.tabs, ["engineering", "ops"]);
        let t = lines(&open_lines(&pr.cards[1], None, None, None, &pv, p, 80).0);
        let s = t.iter().position(|s| s.starts_with("[Overview]")).unwrap();
        assert_eq!(
            t[s..s + 2],
            [
                "[Overview] Sprint  Rows  Deliverables  Releases  Stage  Activity  Departments ",
                "  <- -> switch"
            ]
        );
        assert_eq!(pv.page_tabs().len(), 8);
        assert_eq!(layout::project_depts(&pv.tabs).len(), 2);
        pv.go(&mut tv, &pr.cards, "demo/legal");
        assert_eq!(
            (pv.inner, pv.dept()),
            (layout::DEPT_TAB, Some("engineering"))
        );

        // A project named like a chip is the project: `bnb/ops` is not chip `ops` of `bnb`.
        let mut ops = pr.cards[1].clone();
        (ops.profile, ops.name) = ("bnb".into(), "ops".into());
        let cards = [pr.cards[0].clone(), ops];
        pv.go(&mut tv, &cards, "bnb/ops");
        assert!(
            pv.open && tv.table.view.q.is_empty(),
            "bnb/ops opens the project, not a search"
        );
        pv.go(&mut tv, &pr.cards, "demo/build");

        // The retired `build` opens Deliverables, as an old `#projects/<p>/build` link does.
        pv.go(&mut tv, &pr.cards, "demo/build");
        assert_eq!(pv.inner, DELIVERABLES);
        let t = lines(&open_lines(&pr.cards[1], None, None, None, &pv, p, 80).0);
        assert!(t.iter().any(|s| s.contains("[Deliverables]")), "{t:#?}");
    }

    /// A feed with `garden`'s open window and the next one queued behind it, and `demo`'s own
    /// window.
    fn windowed() -> Feed {
        use hub_core::tasks::SprintLine;
        let line = |project: &str, version: &str, queued: bool| SprintLine {
            profile: "personal".into(),
            project: project.into(),
            version: version.into(),
            done: 1,
            committed: 2,
            opened: "2026-01-01".into(),
            locked: Some("2026-01-01T09:30".into()),
            cut: Some("2026-01-01T14:00".into()),
            build: "held".into(),
            queued,
            ..Default::default()
        };
        Feed {
            sprints: vec![
                line("garden", "v0.3.0", false),
                line("garden", "v0.4.0", true),
                line("demo", "v1.0.0", false),
            ],
            ..Default::default()
        }
    }

    #[test]
    fn the_sprints_tab_lists_every_open_and_queued_window_then_each_projects_last_score() {
        let mut pr = fixture();
        pr.cards[0].last_window = Some(projects::LastWindow {
            version: "v0.2.0".into(),
            line: "delivered 3 of 4".into(),
        });
        let pv = ProjView {
            sfocus: true,
            ..Default::default()
        };
        assert_eq!(pv.top(&TaskView::default()), Some(SPRINTS));
        let p = Palette { no_color: true };
        let f = windowed();
        let t = lines(&page(&pr, Some(&f), None, None, None, &pv, p, 100).0).join("\n");
        for want in [
            "Sprints 3",
            "SPRINTS  3",
            "v0.3.0",
            "v0.4.0",
            "v1.0.0",
            "queued",
            "01-01 09:30",
            "FINISH (7d rate)",
            "LAST SCORE  1",
            "garden",
            "v0.2.0",
            "delivered 3 of 4",
        ] {
            assert!(t.contains(want), "{want:?} in:\n{t}");
        }
        let t = lines(&page(&pr, None, None, None, None, &pv, p, 100).0).join("\n");
        assert!(t.contains("reading the board"), "{t}");
    }

    fn past_pg() -> Page {
        use hub_core::project_sprints::Past;
        let mut pg = a_page();
        pg.sprint_past = vec![
            Past {
                version: "v0.2.0".into(),
                committed: 5,
                delivered: 4,
                carried: 1,
                timing: Some("1d late".into()),
                line: "delivered 4 of 5".into(),
                ..Default::default()
            },
            Past {
                version: "v0.1.0".into(),
                committed: 3,
                delivered: 3,
                ..Default::default()
            },
        ];
        pg
    }

    #[test]
    fn a_projects_sprint_tab_has_its_open_window_the_queued_one_and_the_scored_past() {
        let pr = fixture();
        let pg = past_pg();
        let pv = ProjView {
            inner: SPRINT,
            ..Default::default()
        };
        let p = Palette { no_color: true };
        let f = windowed();
        let t = lines(&open_lines(&pr.cards[0], Some(&pg), None, Some(&f), &pv, p, 120).0);
        let at = |w: &str| {
            t.iter()
                .position(|l| l.starts_with(w))
                .unwrap_or_else(|| panic!("{w:?} in {t:#?}"))
        };
        let (open, queued, past) = (at("SPRINT  1"), at("QUEUED  1"), at("PAST  2"));
        assert!(open < queued && queued < past, "{t:#?}");
        assert!(
            t[open..queued].iter().any(|l| l.contains("v0.3.0"))
                && !t[open..queued].iter().any(|l| l.contains("v0.4.0")),
            "the open window is not the queued one:\n{t:#?}"
        );
        assert!(
            t[queued..past]
                .iter()
                .any(|l| l.contains("v0.4.0") && l.contains("queued")),
            "{t:#?}"
        );
        let past_rows = &t[past..];
        let (a, b) = (
            past_rows.iter().position(|l| l.contains("v0.2.0")),
            past_rows.iter().position(|l| l.contains("v0.1.0")),
        );
        assert!(a < b && a.is_some(), "newest first:\n{t:#?}");
        assert!(
            !t.iter().any(|l| l.contains("v1.0.0") || l.contains("db-1")),
            "another project's window, or a folded task:\n{t:#?}"
        );
        let t = lines(&open_lines(&pr.cards[0], Some(&pg), None, None, &pv, p, 120).0);
        assert!(t.iter().any(|l| l.contains("reading the board")), "{t:#?}");
    }

    fn built_sprint() -> sprint_page::Page {
        let json = r#"{"version":"v0.2.0","state":"closed","opened":"2026-01-01","committed":2,
            "delivered":1,"open":1,"dropped":0,"interrupted":0,
            "rows":[{"id":"g-1","type":"fix","area":"ci","title":"red main","pts":3,"state":"done","outcome":"delivered","interrupt":false},
                    {"id":"g-2","type":"feat","area":"gameplay","title":"dash","pts":5,"state":"open","outcome":"carried","interrupt":false}]}"#;
        let areas = hub_core::areas::Areas::parse("ci  Tests, CI and benches\ngameplay  Engine\n");
        sprint_page::build(json, &areas, "personal", "garden", vec!["v0.3.0".into()]).unwrap()
    }

    /// j/k pick a window across the open, queued and scored ones, Enter opens the picked one's
    /// page, which says its rows and its By area table; Esc clears the table's view and then
    /// closes the page.
    #[test]
    fn enter_on_a_window_opens_its_page_with_the_rollup_and_every_row() {
        let pr = fixture();
        let pg = past_pg();
        let f = windowed();
        let (mut pv, mut tv) = (ProjView::default(), TaskView::default());
        pv.open(&mut tv, Some(&pr.cards[0]));
        tv.project = Some(("personal".into(), "garden".into()));
        pv.inner = SPRINT;
        let k = |c| KeyEvent::from(c);
        for _ in 0..3 {
            assert!(pv.page_key(&mut tv, k(KeyCode::Char('j')), Some(&pg), Some(&f), 10));
        }
        assert_eq!(pv.ssel, 3, "open, queued, v0.2.0, v0.1.0");
        assert!(pv.page_key(&mut tv, k(KeyCode::Char('j')), Some(&pg), Some(&f), 10));
        assert_eq!(pv.ssel, 3, "j stops at the last window");
        assert!(pv.page_key(&mut tv, k(KeyCode::Char('k')), Some(&pg), Some(&f), 10));
        assert!(pv.page_key(&mut tv, k(KeyCode::Enter), Some(&pg), Some(&f), 10));
        let so = pv.sprint.as_mut().unwrap();
        assert_eq!(so.version, "v0.2.0");
        let p = Palette { no_color: true };
        let t =
            lines(&open_lines(&pr.cards[0], Some(&pg), None, Some(&f), &pv, p, 120).0).join("\n");
        assert!(t.contains("reading the sprint"), "{t}");
        pv.sprint.as_mut().unwrap().page = Some(Ok(built_sprint()));
        let t =
            lines(&open_lines(&pr.cards[0], Some(&pg), None, Some(&f), &pv, p, 120).0).join("\n");
        for want in [
            "SPRINT v0.2.0",
            "BY AREA  2",
            "Tests, CI and benches",
            "Engine",
            "CARRIED",
            "ROWS  2",
            "red main",
            "carried",
        ] {
            assert!(t.contains(want), "{want:?} in:\n{t}");
        }
        assert!(pv.page_key(&mut tv, k(KeyCode::Char('f')), Some(&pg), Some(&f), 10));
        assert!(pv.sprint.is_some(), "a chip does not close the page");
        assert!(pv.page_key(&mut tv, k(KeyCode::Esc), Some(&pg), Some(&f), 10));
        assert!(pv.sprint.is_some(), "Esc clears the view first");
        assert!(pv.page_key(&mut tv, k(KeyCode::Esc), Some(&pg), Some(&f), 10));
        assert!(pv.sprint.is_none());
    }

    #[test]
    fn a_sprint_link_opens_that_projects_sprint_page() {
        let pr = fixture();
        let (mut pv, mut tv) = (ProjView::default(), TaskView::default());
        pv.go(&mut tv, &pr.cards, "personal/garden/sprint/v0.2.0");
        assert_eq!(pv.inner, SPRINT);
        assert_eq!(
            pv.sprint.as_ref().map(|s| s.version.as_str()),
            Some("v0.2.0")
        );
        assert_eq!(tv.project.as_ref().map(|(_, n)| n.as_str()), Some("garden"));
    }
}
