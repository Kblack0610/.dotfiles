//! The Costs tab: `hub_core::costs::board`, the same view agent-web draws. `b`/`B` step the cut,
//! `w` the window, `/` types the query (the shared table's grammar), `s` sorts by the cut's next
//! column, `S` flips it, `x` clears; `o` opens the Grafana trends. Burn has one row per source
//! (each account's week, 5h window and day). Under it Consumers has one row per LLM
//! consumer (a runner with a priority, or a gateway key no runner names): `K` opens or folds it,
//! and it starts open when amber or red. Under them the token folds
//! (tokens.rs): `u` opens where the tokens go, `U` its window, `l` what Langfuse sees. The
//! Sections block is folded to its headline: `e` opens it, `t` steps its sort column and `T`
//! flips it. Spend charts the fleet's last 30 days and ranks the picked day's sessions: `,` and `.`
//! pick the day, `v` opens a session's own days, `y` opens the year, month and day rows.
//! The sections sit in inner tabs (`hub_core::layout`, Spend, Limits, Models, Budget); Spend opens
//! first, on the 24h fleet figure and the totals, with burn per session per day last. Left/Right switch
//! them, and a key for a section on another one switches to it. Budget is the one cash view
//! (`hub_core::budget`); every other figure here is list price.

use hub_core::burn::{self, Account, Burn};
use hub_core::costs::{self, Board, Costs};
use hub_core::display::fmt::usd_est;
use hub_core::fleet_cost::FleetCost;
use hub_core::gateway::Consumers;
use hub_core::layout;
use hub_core::pace_conf;
use hub_core::sections::{self, Block};
use hub_core::spend_history::{self, Bar, DayView, History};
use hub_core::table::Val;
use ratatui::crossterm::event::KeyCode;
use ratatui::style::Style;
use ratatui::text::{Line, Span};

use crate::fit::{cell, clip_line, wrap, Cell, Table};
use crate::fmt::{clock, Palette};
use crate::innertabs;
use crate::tokens::{self, TokensView};

pub struct CostsView {
    pub by: &'static str,
    pub window: &'static str,
    pub q: String,
    /// One of the cut's columns, or empty for its own order (the costliest first).
    pub sort: String,
    pub asc: bool,
    pub typing: Option<String>,
    /// The Sections block is open (it starts as its headline).
    pub sections_open: bool,
    /// The History section's year/month/day rows are open (the chart and the day's sessions
    /// always show).
    pub history_open: bool,
    /// The chart day picked, as days back from the newest (`,` and `.` step it); only once `snap`.
    pub day_back: usize,
    /// A chart day is picked; false is the live last 24h (the default when `fleet-cost.json` has
    /// session rows).
    pub snap: bool,
    /// The spend table's cut, an index of `spend_history::GROUPS` (`g` steps it).
    pub group: usize,
    /// The group opened in the table (`V`), empty when none.
    pub open_grp: String,
    /// The row highlighted in the table, 1-based: a group while they show, else a session, which
    /// opens its own days (`v` steps it, 0 highlights none).
    pub sess_at: usize,
    /// Rows the table last drew, so `v` wraps at the last one, and the names of its groups.
    pub sess_n: std::cell::Cell<usize>,
    pub grp_names: std::cell::RefCell<Vec<String>>,
    /// The board last read had a live day, so the first `,` steps from it to the newest chart day.
    pub live_seen: std::cell::Cell<bool>,
    /// One of the Sections columns, or empty for fleet-bench's order (the most gate hours first).
    pub ssort: String,
    pub sasc: bool,
    /// The tokens fold (`u`) and its window (`U`).
    pub tokens: TokensView,
    /// The Langfuse fold (`l`); None while it follows its amber state.
    pub langfuse: Option<bool>,
    /// The Consumers fold (`K`); None while it follows its amber state.
    pub consumers: Option<bool>,
    /// The inner tab shown (a `layout::Inner` id of Costs).
    pub inner: &'static str,
}

/// Costs' layout entry: its sections and inner tabs.
fn tab() -> &'static layout::Tab {
    layout::resolve("costs").expect("costs is a tab")
}

/// The inner tab a word names strictly: an inner id, or a section id for the one holding it.
fn inner_named(word: &str) -> Option<&'static str> {
    innertabs::named(tab(), word)
}

impl Default for CostsView {
    fn default() -> CostsView {
        CostsView {
            by: costs::DEFAULT_CUT,
            window: costs::DEFAULT_WINDOW,
            q: String::new(),
            sort: String::new(),
            asc: false,
            typing: None,
            sections_open: true,
            history_open: true,
            day_back: 0,
            snap: false,
            group: 0,
            open_grp: String::new(),
            sess_at: 0,
            sess_n: std::cell::Cell::new(0),
            grp_names: std::cell::RefCell::new(vec![]),
            live_seen: std::cell::Cell::new(false),
            ssort: String::new(),
            sasc: false,
            tokens: TokensView::default(),
            langfuse: None,
            consumers: None,
            inner: layout::inner_tab(tab(), None).map_or("", |i| i.id),
        }
    }
}

fn step<T: Copy + PartialEq>(list: &[T], at: T, back: bool) -> T {
    let i = list.iter().position(|x| *x == at).unwrap_or(0);
    let n = list.len();
    list[if back { (i + n - 1) % n } else { (i + 1) % n }]
}

/// A column's header, the same words agent-web's costs.js prints.
pub fn header(col: &str) -> &'static str {
    match col {
        "session" => "SESSION",
        "tool" => "TOOL",
        "skill" => "SKILL",
        "kind" => "KIND",
        "project" => "PROJECT",
        "harness" => "HARNESS",
        "model" => "MODEL",
        "runner" => "RUNNER",
        "sessions" => "SESS",
        "calls" => "CALLS",
        "tokens" => "TOKENS",
        "cost" => "COST",
        "share" => "OF TABLE",
        "landed" => "LANDED",
        "redo" => "REDO",
        "reverts" => "REV",
        "per_pr" => "$/PR",
        "src" => "SRC",
        _ => "",
    }
}

/// The section a key acts on, which `key` brings up and the page seeks to: the table's keys the
/// table, which sits under Spend's other sections, and `t`/`T` the Sections block.
pub fn key_section(code: KeyCode) -> Option<&'static str> {
    match code {
        KeyCode::Char('/' | 'b' | 'B' | 'w' | 's' | 'S') => Some("table"),
        KeyCode::Char('t' | 'T') => Some("sections"),
        _ => None,
    }
}

impl CostsView {
    pub fn is_default(&self) -> bool {
        self.typing.is_none()
            && self.q.is_empty()
            && self.sort.is_empty()
            && !self.asc
            && self.ssort.is_empty()
            && !self.sasc
            && self.day_back == 0
            && !self.snap
            && self.group == 0
            && self.open_grp.is_empty()
            && self.sess_at == 0
    }

    /// `hub --tab costs --q '<words>'`: a cut or window name sets it, `key=value` sets `by`, `w`
    /// or `q`, a section's name opens its fold (the page scrolls there), and any other word joins
    /// the query.
    pub fn open(&mut self, arg: &str) {
        let mut q = vec![];
        for word in arg.split(['&', ' ']).filter(|w| !w.is_empty()) {
            let (k, v) = word.split_once('=').unwrap_or(("", word));
            let named = if k.is_empty() { inner_named(v) } else { None };
            if let Some(id) = named {
                self.inner = id;
            }
            match k {
                "by" => self.by = costs::cut(v),
                "w" => self.window = costs::window(v).0,
                "q" => q.push(v.to_string()),
                "ssort" => self.ssort = v.to_string(),
                "sdir" => self.sasc = v == "asc",
                "back" => {
                    self.day_back = v.parse().unwrap_or(0);
                    self.snap = true;
                }
                "g" => {
                    self.group = spend_history::GROUPS
                        .iter()
                        .position(|g| *g == v)
                        .unwrap_or(0)
                }
                _ if word == "sections" => self.sections_open = true,
                _ if word == "spend" => self.history_open = true,
                _ if word == "tokens" => self.tokens.open = Some(true),
                _ if word == "langfuse" => self.langfuse = Some(true),
                _ if word == "consumers" => self.consumers = Some(true),
                _ if named.is_some() => {}
                _ if costs::CUTS.contains(&v) => self.by = costs::cut(v),
                _ if costs::WINDOWS.iter().any(|w| w.0 == v) => self.window = costs::window(v).0,
                _ => q.push(word.to_string()),
            }
        }
        if !q.is_empty() {
            self.q = q.join(" ");
        }
    }

    /// Show the inner tab holding `sec`; true when that was a switch, so the key that asked for
    /// its section opens it rather than folds it.
    fn reveal(&mut self, sec: &str) -> bool {
        let id = inner_named(sec).unwrap_or(self.inner);
        let switched = id != self.inner;
        self.inner = id;
        switched
    }

    /// One key; false leaves it to the page (digits, `r`, `o`, scrolling).
    pub fn key(&mut self, code: KeyCode) -> bool {
        if let Some(t) = self.typing.as_mut() {
            match code {
                KeyCode::Enter => self.q = self.typing.take().unwrap_or_default(),
                KeyCode::Esc => self.typing = None,
                KeyCode::Backspace => {
                    t.pop();
                }
                KeyCode::Char(c) => t.push(c),
                _ => {}
            }
            return true;
        }
        if let Some(sec) = key_section(code) {
            self.reveal(sec);
        }
        match code {
            KeyCode::Left | KeyCode::Right => {
                self.inner = innertabs::step(tab(), self.inner, code == KeyCode::Left);
            }
            KeyCode::Char('/') => self.typing = Some(self.q.clone()),
            KeyCode::Char(c @ ('b' | 'B')) => {
                self.by = step(&costs::CUTS, self.by, c == 'B');
                // Another cut has other columns, so the sort goes back to the cut's own.
                self.sort.clear();
            }
            KeyCode::Char('w') => {
                let names: Vec<&'static str> = costs::WINDOWS.iter().map(|w| w.0).collect();
                self.window = step(&names, self.window, false);
            }
            KeyCode::Char('s') => {
                let mut cols = vec![""];
                cols.extend(costs::columns(self.by));
                self.sort = step(&cols, self.sort.as_str(), false).to_string();
            }
            KeyCode::Char('S') => self.asc = !self.asc,
            KeyCode::Char('e') => {
                let moved = self.reveal("sections");
                self.sections_open = moved || !self.sections_open;
            }
            KeyCode::Char('t') => {
                let mut cols = vec![""];
                cols.extend(<sections::Section as hub_core::table::Row>::COLUMNS);
                self.ssort = step(&cols, self.ssort.as_str(), false).to_string();
                // A new column starts descending, as a header click does on the web.
                self.sasc = false;
            }
            KeyCode::Char('T') => self.sasc = !self.sasc,
            KeyCode::Char('x') => {
                let (by, window, open) = (self.by, self.window, self.sections_open);
                let (history_open, inner) = (self.history_open, self.inner);
                let (tokens, langfuse) = (std::mem::take(&mut self.tokens), self.langfuse);
                *self = CostsView {
                    by,
                    window,
                    sections_open: open,
                    history_open,
                    inner,
                    tokens,
                    langfuse,
                    ..CostsView::default()
                };
            }
            KeyCode::Esc if !self.is_default() => {
                self.key(KeyCode::Char('x'));
            }
            _ => return false,
        }
        true
    }

    /// The folds' keys: `K` folds or opens Consumers (None when there is no Consumers data), `u` where the tokens go, `U`
    /// switches its window, `i` opens its next tool's rows, `l` opens or folds what Langfuse sees. None leaves the key to `key`;
    /// Some carries the section to scroll to (a fold that opened), or None for one that shut.
    pub fn fold(
        &mut self,
        code: KeyCode,
        t: Option<&hub_core::tokens::Tokens>,
        consumers: Option<&str>,
    ) -> Option<Option<&'static str>> {
        if self.typing.is_some() {
            return None;
        }
        // The spend table: the picked day, its cut, the group opened and the row highlighted.
        match code {
            KeyCode::Char(',') => {
                self.reveal("sessions");
                if self.snap || !self.live_seen.get() {
                    self.day_back = (self.day_back + 1).min(spend_history::CHART_DAYS - 1);
                } else {
                    // from the live day to the newest chart day
                    self.snap = true;
                    self.day_back = 0;
                }
                self.sess_at = 0;
                return Some(Some("sessions"));
            }
            KeyCode::Char('.') => {
                self.reveal("sessions");
                if self.day_back == 0 {
                    // from the newest chart day back to the live one
                    self.snap = false;
                } else {
                    self.day_back -= 1;
                }
                self.sess_at = 0;
                return Some(Some("sessions"));
            }
            // `g` still scrolls to the top on the other inner tabs.
            KeyCode::Char('g') if self.inner == "spend" => {
                self.group = (self.group + 1) % spend_history::GROUPS.len();
                self.open_grp.clear();
                self.sess_at = 0;
                return Some(Some("sessions"));
            }
            KeyCode::Char('V') => {
                if self.reveal("sessions") {
                    return Some(Some("sessions"));
                }
                // The total row (nothing highlighted) closes the open group; a group row opens it.
                let name = self
                    .sess_at
                    .checked_sub(1)
                    .and_then(|i| self.grp_names.borrow().get(i).cloned());
                self.open_grp = name.unwrap_or_default();
                self.sess_at = 0;
                return Some(Some("sessions"));
            }
            KeyCode::Char('v') => {
                // A switch only shows the table: its row count is unknown until Spend draws.
                if self.reveal("sessions") {
                    return Some(Some("sessions"));
                }
                self.sess_at = (self.sess_at + 1) % (self.sess_n.get() + 1);
                return Some(Some("sessions"));
            }
            _ => {}
        }
        // A fold key for a section on another inner tab switches there and opens the fold.
        if code == KeyCode::Char('y') {
            let moved = self.reveal("spend");
            self.history_open = moved || !self.history_open;
            return Some(self.history_open.then_some("spend"));
        }
        if code == KeyCode::Char('K') {
            consumers?;
            let moved = self.reveal("consumers");
            let open = moved || !consumers_open(self.consumers);
            self.consumers = Some(open);
            return Some(open.then_some("consumers"));
        }
        let t = t?;
        match code {
            KeyCode::Char('u') => {
                let moved = self.reveal("tokens");
                let open = moved || !self.tokens.is_open(Some(t));
                self.tokens.open = Some(open);
                Some(open.then_some("tokens"))
            }
            KeyCode::Char('U') => {
                self.reveal("tokens");
                self.tokens.day = !self.tokens.day;
                Some(None)
            }
            KeyCode::Char('i') => {
                let moved = self.reveal("tokens");
                self.tokens.open = Some(true);
                self.tokens.part = self.tokens.next_part(self.tokens.split(t));
                Some(moved.then_some("tokens"))
            }
            KeyCode::Char('l') => {
                let moved = self.reveal("langfuse");
                let open = moved || !tokens::langfuse_open(self.langfuse);
                self.langfuse = Some(open);
                Some(open.then_some("langfuse"))
            }
            _ => None,
        }
    }

    /// Whether a live last-24h day with session rows exists: the one `day_view` shows by default.
    fn has_live(c: &Costs) -> bool {
        c.live.as_ref().is_some_and(|d| !d.sessions.is_empty())
    }

    /// The chart day `,` and `.` picked: `day_back` days before the newest. Empty is the live last
    /// 24h while there is one and no day is picked (`day_view` reads empty that way).
    fn picked<'a>(&self, c: &'a Costs) -> &'a str {
        if Self::has_live(c) && !self.snap {
            return "";
        }
        let chart = &c.history.chart;
        chart
            .len()
            .checked_sub(1 + self.day_back)
            .and_then(|i| chart.get(i))
            .map_or("", |b| b.key.as_str())
    }

    pub fn board(&self, c: &Costs) -> Board {
        let dir = if self.asc { "asc" } else { "desc" };
        let sdir = if self.sasc { "asc" } else { "desc" };
        self.live_seen.set(Self::has_live(c));
        let day = self.picked(c);
        let group = spend_history::GROUPS[self.group % spend_history::GROUPS.len()];
        // The highlighted session is the `sess_at`th row of the day's own table; while the groups
        // show, `sess_at` highlights a group instead, so no session is opened.
        let sid = self.sess_at.checked_sub(1).and_then(|i| {
            let pick = spend_history::Pick {
                day,
                group,
                in_group: &self.open_grp,
                ..Default::default()
            };
            spend_history::day_view(&c.spend_days, c.live.as_ref(), &pick)
                .rows
                .get(i)
                .map(|r| r.sid.clone())
        });
        let pick = spend_history::Pick {
            day,
            sid: sid.as_deref().unwrap_or(""),
            group,
            in_group: &self.open_grp,
            ..Default::default()
        };
        costs::board(
            c,
            self.by,
            self.window,
            &self.q,
            &self.sort,
            dir,
            hub_core::table::Keys {
                sort: &self.ssort,
                dir: sdir,
                ..Default::default()
            },
            &pick,
        )
    }

    /// The page, and where each of its sections starts (layout.rs's Costs sections, for `seek`):
    /// the strip first, then the sections of the inner tab shown.
    pub fn lines(
        &self,
        c: &Costs,
        p: Palette,
        now: i64,
        w: usize,
    ) -> (Vec<Line<'static>>, Vec<(&'static str, usize)>) {
        let b = self.board(c);
        let mut out = vec![innertabs::strip(tab(), self.inner, &b.amber, p, w)];
        let mut at: Vec<(&'static str, usize)> = vec![];
        let shown = layout::inner_tab(tab(), Some(self.inner)).map_or(&[][..], |i| i.sections);
        for sec in shown {
            at.push((*sec, out.len()));
            match *sec {
                "burn" => out.extend(burn(&b.burn, p, w)),
                "allowance" => out.extend(allowance(&b.pace, &b.burn, p, w)),
                "pace" => out.extend(pace_config(&b.pace, p, w)),
                "consumers" => {
                    let open = consumers_open(self.consumers);
                    out.extend(consumers(&b.consumers, open, p, w))
                }
                "sessions" => {
                    out.extend(day_table(&b.day, &b.fleet_cost, self.sess_at, p, w));
                    // `v` steps the groups while they show, else the sessions.
                    let rows = if b.day.table.is_some() {
                        b.day.rows.len().min(SESS_ROWS)
                    } else {
                        b.day.groups.len()
                    };
                    self.sess_n.set(rows);
                    *self.grp_names.borrow_mut() =
                        b.day.groups.iter().map(|g| g.name.clone()).collect();
                }
                "spend" => {
                    out.extend(history(&b.history, self.history_open, p, w));
                    if b.history.why.is_none() {
                        out.extend(spend_chart(&b.history.chart, self.picked(c), p, w));
                        out.extend(history_rows(&b.history, self.history_open, p, w));
                    }
                }
                "totals" => self.totals(&b, p, now, w, &mut out),
                "table" => self.table_section(&b, p, w, &mut out),
                "tokens" => out.extend(tokens::tokens(b.tokens.as_ref(), &self.tokens, p, now, w)),
                "langfuse" => {
                    out.extend(tokens::langfuse(b.tokens.as_ref(), self.langfuse, p, w));
                    if b.tokens.is_some() {
                        out.push(Line::raw(""));
                    }
                }
                "sections" => out.extend(sections(&b.sections, self.sections_open, p, w)),
                "budget" => out.extend(budget(&b.budget, p, now, w)),
                _ => {}
            }
        }
        (out, at)
    }

    /// The 24h fleet figure, the window tiles and what each source says: Spend's head.
    fn totals(&self, b: &Board, p: Palette, now: i64, w: usize, out: &mut Vec<Line<'static>>) {
        out.push(clip_line(fleet_head(&b.fleet_cost, p, now), w));
        out.push(clip_line(Line::from(tiles(b, p)), w));
        out.push(clip_line(Line::from(direct(b, p)), w));
        out.push(clip_line(Line::from(sources(b, p)), w));
        for e in &b.errors {
            out.push(clip_line(Line::styled(e.clone(), p.warn()), w));
        }
        if let Some(note) = b.unpriced {
            out.push(clip_line(Line::styled(note, p.warn()), w));
        }
        out.push(Line::raw(""));
    }

    /// The window and cut bars over the table.
    fn switches(&self, b: &Board, p: Palette, w: usize, out: &mut Vec<Line<'static>>) {
        let bar = |name: &str, all: &[&'static str], on: &str, key: &str| {
            let mut s = vec![Span::styled(format!("{name}: "), p.dim())];
            for x in all {
                s.push(if *x == on {
                    Span::styled(format!("[{x}]"), p.head())
                } else {
                    Span::raw(format!(" {x} "))
                });
            }
            s.push(Span::styled(format!("  {key}"), p.dim()));
            clip_line(Line::from(s), w)
        };
        out.push(bar("window", &b.windows, &b.window, "w"));
        out.push(bar("by", b.cuts, &b.by, "b/B"));
    }

    /// The query line, the rows and the notes under them.
    fn table_section(&self, b: &Board, p: Palette, w: usize, out: &mut Vec<Line<'static>>) {
        self.switches(b, p, w, out);
        let mut st = vec![];
        if let Some(t) = &self.typing {
            st.push(Span::styled(format!("/{t}_"), p.head()));
        } else if !self.q.is_empty() {
            st.push(Span::raw(format!("/{}", self.q)));
        }
        st.push(Span::styled(
            format!(
                "{}{} of {}, {}",
                if st.is_empty() { "" } else { "    " },
                b.table.shown,
                b.table.total,
                hub_core::display::fmt::usd_opt(b.unpriced.is_none().then_some(b.shown_usd))
            ),
            p.dim(),
        ));
        out.push(clip_line(Line::from(st), w));
        if b.rows.is_empty() {
            let why = if b.table.total > 0 {
                "nothing matches the query (x clears)"
            } else {
                "nothing spent in this window"
            };
            out.push(Line::styled(why, p.dim()));
        } else {
            out.extend(table(b, p, w));
        }
        out.push(clip_line(
            Line::styled(format!("rows: {}", b.source), p.dim()),
            w,
        ));
        if matches!(b.by.as_str(), "model" | "harness") {
            let d = b.eval_days.map_or(String::new(), |d| format!(" over {d}d"));
            out.push(clip_line(
                Line::styled(
                    format!(
                        "LANDED, REDO, REV and $/PR are fleet-bench models{d}, per family (opus), queue items only"
                    ),
                    p.dim(),
                ),
                w,
            ));
        }
        out.push(Line::styled("trends: o opens Grafana", p.dim()));
    }
}

/// Consumers starts open like every section (dashboards rule 4); the reader's `K` wins after that.
fn consumers_open(set: Option<bool>) -> bool {
    set.unwrap_or(true)
}

/// Cells of the usage bar, brackets apart.
const BAR_CELLS: usize = 10;

/// The Allowance section: the burn allowance in force, what it lets through, and its schedule.
/// Read-only here: a window is set and ended in agent-web or with `pace-conf`.
fn allowance(v: &pace_conf::View, b: &Burn, p: Palette, w: usize) -> Vec<Line<'static>> {
    let dim = |s: &str| Span::styled(s.to_string(), p.dim());
    let Some(a) = &v.allowance else {
        let why = v.error.clone().unwrap_or_else(|| "no pace config".into());
        return vec![
            clip_line(
                Line::from(vec![dim("ALLOWANCE  "), Span::styled(why, p.bad())]),
                w,
            ),
            Line::raw(""),
        ];
    };
    let rate = |n: Option<f64>| n.map_or("-".to_string(), |n| format!("{n:.2}"));
    let style = match b.level {
        "bad" => p.bad(),
        "warn" => p.warn(),
        _ => p.good(),
    };
    let mut out = vec![clip_line(
        Line::from(vec![
            dim("ALLOWANCE  "),
            Span::raw(format!(
                "{}% ({}), default {}%",
                a.in_force, a.source, a.default
            )),
        ]),
        w,
    )];
    let spare = a
        .spare
        .map_or(String::new(), |n| format!(", {n} spare sessions"));
    out.push(clip_line(
        Line::from(vec![
            dim("LETS THROUGH  "),
            Span::styled(format!("{}/h now", rate(a.burn)), style),
            Span::raw(format!(
                " against {}/h sustainable and {}/h allowed{spare}",
                rate(a.sustain),
                rate(a.allowed)
            )),
        ]),
        w,
    ));
    let lag = a.as_of.map_or(
        format!("{} from claude-acct", hub_core::reading::NO_DATA),
        |t| {
            format!(
                "claude-acct wrote the figures {}; a change shows there on its next run",
                clock(t, b.at)
            )
        },
    );
    for l in wrap(&[format!("{lag}."), a.note.to_string()], " ", w) {
        out.push(clip_line(Line::styled(l, p.dim()), w));
    }
    let rows = a
        .rows
        .iter()
        .map(|r| {
            let state = match r.state {
                "In force" => p.good(),
                _ => p.dim(),
            };
            vec![
                format!("{}%", r.value).into(),
                r.from.clone().into(),
                r.until.clone().into(),
                r.by.clone().into(),
                cell(r.state, state),
            ]
        })
        .collect();
    out.extend(
        Table {
            header: vec!["ALLOWANCE", "FROM", "UNTIL", "BY", "STATE"],
            rows,
            keep: vec![0, 4, 1, 2, 3],
            right: vec![0],
            ..Default::default()
        }
        .fit(w, p.head()),
    );
    out.push(clip_line(
        Line::styled(
            "Set or end a window in agent-web (Costs, Limits) or with `pace-conf`.",
            p.dim(),
        ),
        w,
    ));
    out.push(Line::raw(""));
    out
}

/// The Pace config section: every pace.conf key, its value and where it came from.
fn pace_config(v: &pace_conf::View, p: Palette, w: usize) -> Vec<Line<'static>> {
    if v.keys.is_empty() {
        let why = v.error.clone().unwrap_or_else(|| "no pace config".into());
        return vec![
            clip_line(
                Line::from(vec![
                    Span::styled("PACE CONFIG  ".to_string(), p.dim()),
                    Span::styled(why, p.bad()),
                ]),
                w,
            ),
            Line::raw(""),
        ];
    }
    let rows = v
        .keys
        .iter()
        .map(|k| {
            let source = if k.source == "default" {
                p.dim()
            } else {
                Style::new()
            };
            vec![
                cell(k.key.clone(), p.head()),
                k.value.clone().into(),
                cell(k.source.clone(), source),
                k.default.clone().into(),
                if k.editable { "yes" } else { "" }.to_string().into(),
            ]
        })
        .collect();
    let mut out = vec![clip_line(
        Line::styled(format!("PACE CONFIG  {} keys", v.keys.len()), p.dim()),
        w,
    )];
    out.extend(
        Table {
            header: vec!["KEY", "VALUE", "SOURCE", "DEFAULT", "SETTABLE"],
            rows,
            keep: vec![0, 1, 2, 3, 4],
            right: vec![1, 3],
            ..Default::default()
        }
        .fit(w, p.head()),
    );
    out.push(Line::raw(""));
    out
}

/// The Burn section, first on the tab: the headline coloured by `level`, the drip and its hold
/// badge, when each account is back on pace, and one row per source claude-acct reads. The keys
/// under a pool are Consumers rows, so Burn only points there.
fn burn(b: &Burn, p: Palette, w: usize) -> Vec<Line<'static>> {
    let dim = |s: &str| Span::styled(s.to_string(), p.dim());
    if b.accounts.is_empty() {
        return vec![clip_line(
            Line::from(vec![
                dim("BURN  "),
                Span::raw(format!("{} from claude-acct", hub_core::reading::NO_DATA)),
            ]),
            w,
        )];
    }
    let style = match b.level {
        "bad" => p.bad(),
        "warn" => p.warn(),
        _ => p.good(),
    };
    let time = |t: i64| crate::fmt::clock(t, b.at);
    let mut drip = vec![dim("DRIP  "), Span::raw(b.drip_line.clone())];
    if b.drip.held.is_some() {
        drip.push(Span::styled(
            format!("   dispatch held -> {}", burn::hold_badge()),
            p.warn(),
        ));
    }
    // The headline wraps between its clauses, never inside one, so a narrow pane keeps all of it.
    let parts: Vec<&str> = b.head.split(", ").collect();
    let mut out: Vec<Line<'static>> = crate::fit::wrap(&parts, ", ", w.saturating_sub(6))
        .into_iter()
        .enumerate()
        .map(|(i, l)| {
            let lead = if i == 0 {
                dim("BURN  ")
            } else {
                Span::raw("      ")
            };
            clip_line(Line::from(vec![lead, Span::styled(l, style)]), w)
        })
        .collect();
    out.extend([
        clip_line(Line::from(drip), w),
        clip_line(
            Line::from(vec![dim("BACK ON PACE  "), Span::raw(b.pace_text(&time))]),
            w,
        ),
    ]);
    // A source with no figures has a line of its own, so its words do not widen the columns.
    let note = |a: &&Account| {
        let (text, style) = match a.state {
            "unreadable" => ("usage unreadable", p.bad()),
            "stale" => (burn::STALE_NOTE, p.bad()),
            "idle" => (burn::IDLE_NOTE, p.dim()),
            _ => return None,
        };
        Some(clip_line(
            Line::from(vec![
                Span::styled(a.name.clone(), p.head()),
                Span::raw("  "),
                Span::styled(text.to_string(), style),
            ]),
            w,
        ))
    };
    let has_figures = |a: &&&Account| a.state == "ok";
    let name = |a: &Account| cell(a.name.clone(), p.head());
    let pc = |v: Option<f64>| v.map_or("-".to_string(), |v| format!("{}%", v.floor()));
    // Fill is the share used, the tick the share of the week gone; a dollar budget has no week.
    let usage = |a: &Account| {
        let gone = a.gone.filter(|_| !a.unpaced).map(|g| g as u32);
        let (on, off) = crate::fmt::bar(a.used.map(|u| u as u32), gone, BAR_CELLS);
        Cell::from(format!("[{on}{off}]"))
    };
    let room = |a: &Account| match &a.room {
        Some(r) => cell(r.text.clone(), if r.ok { p.good() } else { p.bad() }),
        None => cell("-", p.dim()),
    };
    let top: Vec<&Account> = b.accounts.iter().filter(|a| !a.nested).collect();
    let rows = top
        .iter()
        .filter(has_figures)
        .map(|a| {
            let rate = |v: Option<f64>| v.map_or("-".into(), |v| format!("{v:.2}"));
            // A dollar budget has no pace line, so its pace cells say nothing.
            let paced = |s: String| if a.unpaced { "-".into() } else { s };
            vec![
                name(a),
                a.kind.clone().into(),
                a.live.to_string().into(),
                usage(a),
                a.used_text.clone().into(),
                pc(a.gone).into(),
                pc(a.reserve).into(),
                room(a),
                cell(
                    paced(rate(Some(a.burn))),
                    if !a.unpaced && a.is_over() {
                        p.warn()
                    } else {
                        Style::new()
                    },
                ),
                paced(rate(a.sustain)).into(),
                paced(a.on_pace(a.burn_at, b.at, &time)).into(),
                paced(a.on_pace(a.idle_at, b.at, &time)).into(),
                a.run_out.map_or("-".into(), time).into(),
                a.resets.map_or("-".into(), time).into(),
                pc(a.five_hour).into(),
                a.five_hour_resets.map_or("-".into(), time).into(),
                hub_core::display::fmt::usd_opt(a.cost_24h).into(),
            ]
        })
        .collect::<Vec<_>>();
    let mut rows = rows;
    if let Some(f) = &b.total {
        let dash = || Cell::from("-");
        let over = if f.over { p.warn() } else { Style::new() };
        rows.push(vec![
            cell("TOTAL", p.head()),
            dash(),
            f.live.to_string().into(),
            Cell::from(""),
            dash(),
            dash(),
            dash(),
            dash(),
            cell(format!("{:.2}", f.burn), over),
            format!("{:.2}", f.sustain).into(),
            dash(),
            dash(),
            f.run_out.map_or("-".into(), time).into(),
            dash(),
            dash(),
            dash(),
            hub_core::display::fmt::usd_opt(f.cost_24h).into(),
        ]);
    }
    out.extend(
        Table {
            header: vec![
                "SOURCE",
                "KIND",
                "LIVE",
                "BAR",
                "USED",
                "GONE",
                "RESERVE",
                "ROOM",
                "BURN/H",
                "KEEPS/H",
                "AT BURN",
                "IF IDLE",
                "RUNS OUT",
                "RESETS",
                "5H",
                "5H RESETS",
                "$24H",
            ],
            rows,
            // The 5h window and the day's dollars drop first at a narrow width, $24H before them.
            keep: vec![0, 7, 4, 1, 8, 9, 2, 14, 10, 11, 3, 5, 6, 12, 13, 15, 16],
            right: vec![2, 4, 5, 6, 8, 9, 14, 16],
            ..Default::default()
        }
        .fit(w, p.head()),
    );
    out.extend(top.iter().filter_map(note));
    if let Some(k) = &b.keys {
        let head = if k.level == "ok" { p.dim() } else { p.warn() };
        out.push(clip_line(
            Line::from(vec![
                dim("KEYS  "),
                Span::styled(k.head.clone(), head),
                dim("   rows in Consumers (K)"),
            ]),
            w,
        ));
    }
    let terms: Vec<String> = b.legend.iter().map(|(t, d)| format!("{t}: {d}.")).collect();
    for l in crate::fit::wrap(&terms, " ", w) {
        out.push(clip_line(Line::styled(l, p.dim()), w));
    }
    out.push(Line::raw(""));
    out
}

/// The Consumers section: its headline always, and when open one row per LLM consumer under
/// `gateway::build`'s order (a MISMATCH first), then each pool's budget, the gateway's aliases and
/// fallbacks, and what each column means.
fn consumers(c: &Consumers, open: bool, p: Palette, w: usize) -> Vec<Line<'static>> {
    let mark = if open { "-" } else { "+" };
    let level = match c.level {
        "bad" => p.bad(),
        "warn" => p.warn(),
        _ => Style::new(),
    };
    // The headline wraps between its clauses, never inside one, so a narrow pane keeps all of it.
    let parts: Vec<&str> = c.head.split(" | ").collect();
    let title = format!("{mark} CONSUMERS  ");
    let mut out: Vec<Line<'static>> = wrap(&parts, " | ", w.saturating_sub(title.len()))
        .into_iter()
        .enumerate()
        .map(|(i, l)| {
            let lead = if i == 0 {
                Span::styled(title.clone(), p.head())
            } else {
                Span::raw(" ".repeat(title.len()))
            };
            clip_line(Line::from(vec![lead, Span::styled(l, level)]), w)
        })
        .collect();
    if !open {
        if let Some(l) = out.last_mut() {
            l.spans.push(Span::styled("   K opens", p.dim()));
            *l = clip_line(l.clone(), w);
        }
        out.push(Line::raw(""));
        return out;
    }
    for e in c.stale.iter().chain(&c.errors) {
        out.push(clip_line(Line::styled(e.clone(), p.warn()), w));
    }
    let rows = c
        .rows
        .iter()
        .map(|r| {
            let style = match r.level {
                "bad" => p.bad(),
                _ => Style::new(),
            };
            c.columns
                .iter()
                .map(|k| {
                    let s = if *k == "consumer" && r.level != "bad" {
                        p.head()
                    } else {
                        style
                    };
                    cell(r.show(k).to_string(), s)
                })
                .collect()
        })
        .collect::<Vec<Vec<Cell>>>();
    let at = |k: &str| c.columns.iter().position(|x| *x == k);
    // The consumer and its status never drop; how it routes goes first on a narrow screen.
    let keep = [
        "consumer", "status", "priority", "spent", "budget", "runs_on", "fallback",
    ]
    .iter()
    .filter_map(|k| at(k))
    .collect();
    let cap = [
        ("consumer", 24),
        ("runs_on", 32),
        ("budget", 26),
        ("fallback", 24),
    ]
    .iter()
    .filter_map(|(k, n)| at(k).map(|i| (i, *n)))
    .collect();
    out.extend(
        Table {
            header: c.headers.clone(),
            rows,
            keep,
            cap,
            ..Default::default()
        }
        .fit(w, p.head()),
    );
    for l in &c.pools {
        out.push(clip_line(Line::styled(l.clone(), p.dim()), w));
    }
    // The routes and the legend wrap between words: either is longer than a narrow pane.
    let terms: String = c
        .legend
        .iter()
        .map(|(t, d)| format!("{t}: {d}. "))
        .collect();
    for text in [c.routes.as_str(), terms.as_str()] {
        let words: Vec<&str> = text.split_whitespace().collect();
        for l in wrap(&words, " ", w) {
            out.push(clip_line(Line::styled(l, p.dim()), w));
        }
    }
    out.push(Line::raw(""));
    out
}

/// The Sections block: its headline always, and when open All PRs on top of one row per section
/// under the sort, then the note on what the figures cannot say.
fn sections(b: &Block, open: bool, p: Palette, w: usize) -> Vec<Line<'static>> {
    let Some(t) = &b.table else {
        return vec![];
    };
    let mark = if open { "-" } else { "+" };
    let mut out = vec![clip_line(
        Line::from(vec![
            Span::styled(format!("{mark} SECTIONS  "), p.head()),
            Span::raw(b.head.clone()),
            Span::styled(if open { "" } else { "   e opens" }, p.dim()),
        ]),
        w,
    )];
    if !open {
        out.push(Line::raw(""));
        return out;
    }
    let shown = b.rows.len().min(hub_core::layout::FOLD_ROWS);
    let row = |cells: &Vec<String>, style: Style| -> Vec<Cell> {
        cells.iter().map(|c| cell(c.clone(), style)).collect()
    };
    let mut rows = vec![row(&b.all, p.head())];
    rows.extend(b.rows[..shown].iter().map(|r| row(r, Style::new())));
    let at = |k: &str| b.columns.iter().position(|c| *c == k);
    // The section and the gate minutes never drop; the claimed-session figures go first.
    let order = [
        "section",
        "gate_min_per_pr",
        "first_try",
        "prs",
        "reds_per_pr",
        "gate_h",
        "green_lost",
        "cost_per_pr",
        "work_min_per_pr",
        "tokens_per_pr",
    ];
    let marked = t.columns.iter().find(|c| c.sort.is_some());
    // The sorted column is never the one a narrow screen drops, so the mark always shows.
    let mut keep: Vec<usize> = order.iter().filter_map(|k| at(k)).collect();
    if let Some(i) = marked.and_then(|c| at(c.key)).filter(|i| *i != 0) {
        keep.retain(|k| *k != i);
        keep.insert(1.min(keep.len()), i);
    }
    out.extend(
        Table {
            header: b.headers.clone(),
            rows,
            keep,
            right: (1..b.columns.len()).collect(),
            cap: vec![(0, 40)],
            mark: marked.and_then(|c| {
                at(c.key).map(|i| {
                    (
                        i,
                        if c.sort == Some(hub_core::table::Dir::Asc) {
                            " ^"
                        } else {
                            " v"
                        },
                    )
                })
            }),
            ..Default::default()
        }
        .fit(w, p.head()),
    );
    if let Some(more) = crate::fmt::older(b.rows.len(), shown, p) {
        out.push(more);
    }
    for n in &b.notes {
        out.push(clip_line(Line::styled(n.clone(), p.dim()), w));
    }
    out.push(Line::raw(""));
    out
}

/// The History section: its headline always, and when open the year, month and day rows that
/// `hub_core::spend_history` built, then what the figures are.
fn history(h: &History, open: bool, p: Palette, w: usize) -> Vec<Line<'static>> {
    let mark = if open { "-" } else { "+" };
    let title = Span::styled(format!("{mark} SPEND  "), p.head());
    if let Some(why) = &h.why {
        return vec![
            clip_line(
                Line::from(vec![title, Span::styled(why.clone(), p.dim())]),
                w,
            ),
            Line::raw(""),
        ];
    }
    // the month and the day halves of the headline on their own lines, so the warning and the key fit 80 columns
    let (month, day) = (&h.month, &h.last_day);
    let mut head = vec![title];
    if h.stale {
        head.push(Span::styled("STALE: no snapshot for yesterday  ", p.warn()));
    }
    head.push(Span::raw(month.to_string()));
    if !open {
        head.push(Span::styled("   y: by period", p.dim()));
    }
    let mut out = vec![clip_line(Line::from(head), w)];
    if !day.is_empty() {
        out.push(clip_line(Line::raw(format!("  {day}")), w));
    }
    out
}

/// The year, month and day rows under the chart (`y` opens them), and the section's notes.
fn history_rows(h: &History, open: bool, p: Palette, w: usize) -> Vec<Line<'static>> {
    let mut out = vec![];
    if h.why.is_some() || !open {
        return out;
    }
    let rows = h
        .rows
        .iter()
        .map(|r| {
            [
                &r.period,
                &r.total,
                &r.days.to_string(),
                &r.per_day,
                &r.per_session,
                &r.vs_prev,
                &r.est,
            ]
            .iter()
            .map(|c| cell(c.to_string(), Style::new()))
            .collect()
        })
        .collect();
    out.extend(
        Table {
            header: vec![
                "period",
                "total",
                "days",
                "$/day",
                "$/session",
                "vs prev",
                "est.",
            ],
            rows,
            keep: vec![0, 1, 3, 4, 5, 6, 2],
            right: (1..7).collect(),
            ..Default::default()
        }
        .fit(w, p.head()),
    );
    if h.older > 0 {
        out.push(Line::styled(format!("+{} older days", h.older), p.dim()));
    }
    if h.missing > 0 {
        out.push(clip_line(
            Line::styled(
                format!(
                    "{} days in the range have no figure and are not counted",
                    h.missing
                ),
                p.warn(),
            ),
            w,
        ));
    }
    let note: Vec<&str> = h.note.split(' ').collect();
    for l in wrap(&note, " ", w) {
        out.push(clip_line(Line::styled(l, p.dim()), w));
    }
    out.push(Line::raw(""));
    out
}

/// Session rows the day's table draws in 80 columns; the web table has the rest under its query.
const SESS_ROWS: usize = 12;
/// Rows of the day chart, each worth an eighth of a row per block step.
const CHART_ROWS: usize = 6;

/// The `CHART_DAYS` bars, one column each with a space between, tallest at full height; the
/// billed part of a bar in the normal colour, the estimated part dim, a day with no figure as a
/// gap mark, and the picked day `sel` highlighted with its figure under the axis.
fn spend_chart(bars: &[Bar], sel: &str, p: Palette, w: usize) -> Vec<Line<'static>> {
    if bars.iter().all(|b| b.usd.is_none()) {
        return vec![];
    }
    let max = bars
        .iter()
        .filter_map(|b| b.usd)
        .fold(0.0, f64::max)
        .max(0.01);
    let step = if w >= 2 * bars.len() + 9 { 2 } else { 1 };
    let mut out = vec![clip_line(
        Line::from(vec![
            Span::styled("  $/DAY, LAST 30 DAYS  ", p.head()),
            Span::styled(", and . pick a day   v opens a session", p.dim()),
        ]),
        w,
    )];
    const BLOCKS: [char; 9] = [
        ' ', '\u{2581}', '\u{2582}', '\u{2583}', '\u{2584}', '\u{2585}', '\u{2586}', '\u{2587}',
        '\u{2588}',
    ];
    for row in (0..CHART_ROWS).rev() {
        let axis = if row == CHART_ROWS - 1 {
            format!("{:>7} ", usd_est(max))
        } else {
            " ".repeat(8)
        };
        let mut spans = vec![Span::styled(axis, p.dim())];
        for b in bars {
            let units = |v: f64| v / max * CHART_ROWS as f64;
            let total = units(b.usd.unwrap_or(0.0));
            let mut fill = ((total - row as f64).clamp(0.0, 1.0) * 8.0).round() as usize;
            // A priced day too small to round to a block still shows, never as a gap or $0.
            if row == 0 && fill == 0 && b.usd.is_some_and(|u| u > 0.0) {
                fill = 1;
            }
            let ch = if b.usd.is_none() && row == 0 {
                '.'
            } else {
                BLOCKS[fill]
            };
            let style = if b.key == sel {
                p.sel()
            } else if units(b.measured) >= row as f64 + 0.5 {
                Style::new()
            } else {
                p.dim()
            };
            spans.push(Span::styled(ch.to_string(), style));
            if step == 2 {
                spans.push(Span::raw(" "));
            }
        }
        out.push(clip_line(Line::from(spans), w));
    }
    let first = bars.first().map_or("", |b| b.label.as_str());
    let last = bars.last().map_or("", |b| b.label.as_str());
    let span = step * bars.len();
    out.push(clip_line(
        Line::styled(
            format!(
                "{}{first}{}{last}",
                " ".repeat(8),
                " ".repeat(span.saturating_sub(first.len() + last.len() + 1))
            ),
            p.dim(),
        ),
        w,
    ));
    if let Some(b) = bars.iter().find(|b| b.key == sel) {
        out.push(clip_line(Line::raw(format!("  {}", b.tip)), w));
    }
    out
}

/// A share as a whole percent; one that rounds to 0 but is not 0 reads "<1%", so a priced row never looks free.
fn pct_text(v: f64) -> String {
    if v > 0.0 && v <= 0.5 {
        "<1%".into()
    } else {
        format!("{v:.0}%")
    }
}

/// A row of the group table: the day's total, a group, or the opened group.
fn tot_cells(t: &spend_history::Tot, style: Style) -> Vec<Cell> {
    vec![
        cell(t.name.clone(), style),
        cell(t.sessions.to_string(), style),
        cell(usd_est(t.cost), style),
        cell(pct_text(t.share), style),
        cell(usd_est(t.per_session), style),
        cell(pct_text(t.est), style),
    ]
}

/// The spend table of the day shown (the live last 24h until a chart day is picked): the day's
/// total row on top, then its groups, or its sessions under the opened group's row. `at`
/// highlights a row. The coverage words and the foot are the fleet figure's (`f`).
fn day_table(d: &DayView, f: &FleetCost, at: usize, p: Palette, w: usize) -> Vec<Line<'static>> {
    let mut out = vec![];
    if let Some(why) = &d.why {
        out.push(clip_line(
            Line::styled(format!("  SPEND TABLE  {why}"), p.dim()),
            w,
        ));
        out.push(Line::raw(""));
        return out;
    }
    out.push(clip_line(
        Line::from(vec![
            Span::styled("  SPEND TABLE  ", p.head()),
            Span::raw(d.head.clone()),
        ]),
        w,
    ));
    let cuts: Vec<Span> = d
        .cuts
        .iter()
        .flat_map(|c| {
            let style = if *c == d.group { p.sel() } else { p.dim() };
            [Span::styled(c.to_string(), style), Span::raw(" ")]
        })
        .collect();
    let mut keys = vec![Span::styled("  group ", p.dim())];
    keys.extend(cuts);
    keys.push(Span::styled(
        " g cuts, , . day, v row, V opens a group",
        p.dim(),
    ));
    out.push(clip_line(Line::from(keys), w));
    let tot_head = vec!["name", "sess", "cost", "of day", "$/sess", "est."];
    let tot_table = |rows: Vec<Vec<Cell>>| {
        Table {
            header: tot_head.clone(),
            rows,
            keep: vec![0, 2, 3, 1, 4, 5],
            right: vec![1, 2, 3, 4, 5],
            ..Default::default()
        }
        .fit(w, p.head())
    };
    let total = d.total.as_ref().map(|t| tot_cells(t, Style::new()));
    if d.table.is_none() {
        let mut rows: Vec<Vec<Cell>> = total.into_iter().collect();
        rows.extend(
            d.groups
                .iter()
                .enumerate()
                .map(|(i, g)| tot_cells(g, if i + 1 == at { p.sel() } else { Style::new() })),
        );
        out.extend(tot_table(rows));
    } else {
        // the total row stays on top of the sessions, with the opened group's row under it
        let mut rows: Vec<Vec<Cell>> = total.into_iter().collect();
        rows.extend(d.open.iter().map(|o| tot_cells(o, p.sel())));
        out.extend(tot_table(rows));
        let rows = d
            .rows
            .iter()
            .take(SESS_ROWS)
            .enumerate()
            .map(|(i, r)| {
                let style = if i + 1 == at { p.sel() } else { Style::new() };
                let opt = |s: &Option<String>| s.clone().unwrap_or_default();
                vec![
                    cell(r.session.clone(), style),
                    cell(r.who.clone(), style),
                    cell(opt(&r.project), style),
                    cell(opt(&r.harness), style),
                    cell(usd_est(r.cost), style),
                    cell(pct_text(r.share), style),
                    cell(pct_text(r.est), style),
                    cell(r.days.to_string(), style),
                ]
            })
            .collect();
        out.extend(
            Table {
                header: vec![
                    "session", "who", "project", "harness", "cost", "of day", "est.", "days",
                ],
                rows,
                keep: vec![0, 4, 5, 1, 2, 3, 6, 7],
                right: vec![4, 5, 6, 7],
                ..Default::default()
            }
            .fit(w, p.head()),
        );
        let past = d.rows.len().saturating_sub(SESS_ROWS) + d.more;
        if past > 0 {
            out.push(Line::styled(
                format!("+{past} more sessions; the web table (#costs/spend) shows up to 50"),
                p.dim(),
            ));
        }
    }
    if !d.outside.is_empty() {
        out.push(clip_line(
            Line::styled(format!("  {}", d.outside), p.dim()),
            w,
        ));
    }
    if f.why.is_none() {
        if d.live {
            out.push(clip_line(Line::styled(f.coverage.clone(), p.dim()), w));
            for u in &f.unpriced {
                let words: Vec<&str> = u.split(' ').collect();
                for l in wrap(&words, " ", w.saturating_sub(2)) {
                    out.push(clip_line(Line::styled(format!("  {l}"), p.warn()), w));
                }
            }
        }
        let foot: Vec<&str> = f.foot.split(' ').collect();
        for l in wrap(&foot, " ", w) {
            out.push(clip_line(Line::styled(l, p.dim()), w));
        }
    }
    if let Some(s) = &d.series {
        let max = s
            .bars
            .iter()
            .filter_map(|b| b.usd)
            .fold(0.0, f64::max)
            .max(0.01);
        let line: String = s
            .bars
            .iter()
            .map(|b| match b.usd {
                None => '.',
                Some(v) => [
                    '\u{2581}', '\u{2582}', '\u{2583}', '\u{2584}', '\u{2585}', '\u{2586}',
                    '\u{2587}', '\u{2588}',
                ][((v / max) * 7.0).round() as usize],
            })
            .collect();
        out.push(clip_line(
            Line::from(vec![
                Span::styled(format!("  {}  ", s.session), p.head()),
                Span::raw(line),
                Span::styled(format!("  {} in 30 days", s.total), p.dim()),
            ]),
            w,
        ));
    }
    out.push(Line::raw(""));
    out
}

/// The whole fleet's 24h figure, the first line of Spend's totals: `hub_core::fleet_cost`'s
/// total, its measured and estimated parts and its age, or why there is none.
fn fleet_head(f: &FleetCost, p: Palette, now: i64) -> Line<'static> {
    let title = Span::styled("FLEET 24H ", p.head());
    if let Some(why) = &f.why {
        return Line::from(vec![title, Span::styled(why.clone(), p.warn())]);
    }
    let as_of = f.as_of.map_or("-".into(), |t| clock(t, now));
    let (age, style) = if f.stale {
        (format!("STALE, as of {as_of}"), p.warn())
    } else {
        (format!("as of {as_of}"), p.dim())
    };
    Line::from(vec![
        title,
        Span::raw(format!("{}  ", f.usd)),
        Span::styled(
            format!("API cash {}  sub burn {}  ", f.cash, f.burn),
            p.dim(),
        ),
        Span::styled(age, style),
    ])
}

/// This month's cash by bill: `hub_core::budget` builds every row and word, this draws them.
fn budget(b: &hub_core::budget::Budget, p: Palette, now: i64, w: usize) -> Vec<Line<'static>> {
    let title = Span::styled("BUDGET  ", p.head());
    if let Some(why) = &b.why {
        return vec![
            clip_line(
                Line::from(vec![title, Span::styled(why.clone(), p.warn())]),
                w,
            ),
            Line::raw(""),
        ];
    }
    let as_of = b.as_of.map_or("-".into(), |t| clock(t, now));
    // STALE leads, so a narrow screen clips the month, never the warning.
    let mut head = vec![title];
    if b.stale {
        head.push(Span::styled(format!("STALE, as of {as_of}  "), p.warn()));
    }
    head.push(Span::styled(format!("{}  ", b.month), p.dim()));
    head.push(Span::raw(format!(
        "{} so far  {} by month end  ",
        b.spent, b.projected
    )));
    head.push(Span::styled(format!("caps {}", b.caps), p.dim()));
    if !b.stale {
        head.push(Span::styled(format!("  as of {as_of}"), p.dim()));
    }
    let mut out = vec![clip_line(Line::from(head), w)];
    if !b.partial.is_empty() {
        out.push(clip_line(
            Line::styled(
                format!("partial, not counted: {}", b.partial.join(", ")),
                p.warn(),
            ),
            w,
        ));
    }
    if !b.needs.is_empty() {
        out.push(clip_line(
            Line::styled(format!("NEEDS LOOK {}", b.needs.len()), p.warn()),
            w,
        ));
        for n in &b.needs {
            let words: Vec<&str> = n.split(' ').collect();
            for l in wrap(&words, " ", w.saturating_sub(2)) {
                out.push(clip_line(Line::styled(format!("  {l}"), p.warn()), w));
            }
        }
    }
    // Each group's heading row (its name and our cash in it), then its bills.
    let mut rows = vec![];
    for g in &b.groups {
        rows.push(vec![
            cell(g.name.to_uppercase(), p.head()),
            Cell::from(""),
            Cell::from(""),
            cell(g.spent.clone(), p.head()),
            cell(g.month.clone(), p.head()),
            Cell::from(""),
        ]);
        for x in &g.bills {
            let s = if x.status == "ok" {
                Style::new()
            } else {
                p.warn()
            };
            rows.push(vec![
                cell(format!("  {}", x.name), s),
                cell(x.kind.clone(), p.dim()),
                x.cap.clone().into(),
                cell(x.spent.clone(), s),
                x.month.clone().into(),
                cell(x.note.clone(), p.dim()),
            ]);
        }
    }
    out.extend(
        Table {
            header: vec!["BILL", "KIND", "CAP", "SO FAR", "MONTH EST", "NOTE"],
            rows,
            keep: vec![0, 3, 4, 2, 5, 1],
            flex: Some(5),
            flexmin: 12,
            right: vec![2, 3, 4],
            ..Table::default()
        }
        .fit(w, p.head()),
    );
    let project: Vec<String> = b
        .by_project
        .iter()
        .map(|c| format!("{} {}", c.name, c.usd))
        .collect();
    for (head, items) in [
        ("BY PROJECT  ", project),
        ("BY LANE     ", b.by_lane.clone()),
    ] {
        for (i, l) in wrap(&items, "  ", w.saturating_sub(head.len()))
            .into_iter()
            .enumerate()
        {
            let lead = if i == 0 {
                head.to_string()
            } else {
                " ".repeat(head.len())
            };
            out.push(clip_line(
                Line::from(vec![Span::styled(lead, p.head()), Span::raw(l)]),
                w,
            ));
        }
    }
    let foot: Vec<&str> = b.foot.split(' ').collect();
    for l in wrap(&foot, " ", w) {
        out.push(clip_line(Line::styled(l, p.dim()), w));
    }
    out.push(Line::raw(""));
    out
}

/// The 7d and 30d spend from their nightly days.
fn tiles(b: &Board, p: Palette) -> Vec<Span<'static>> {
    let mut s = vec![];
    for t in &b.totals {
        let label = format!("{} ", t.window.to_uppercase());
        let style = if t.window == b.window {
            p.head()
        } else {
            p.dim()
        };
        s.push(Span::styled(label, style));
        if t.days == 0 {
            s.push(Span::styled(
                format!("- no nightly day in {}  ", t.window),
                p.warn(),
            ));
            continue;
        }
        s.push(Span::raw(format!(
            "{} ",
            hub_core::display::fmt::usd_opt(Some(t.usd))
        )));
        let through = t.through.get(5..).unwrap_or(&t.through);
        s.push(Span::styled(
            format!("({}d to {through})  ", t.days),
            p.dim(),
        ));
    }
    s.push(Span::styled(b.totals_note, p.dim()));
    s
}

/// Direct Lazer use with what it cannot see beside it, so a low figure never reads as all of it.
fn direct(b: &Board, p: Palette) -> Vec<Span<'static>> {
    let d = &b.direct;
    let mut s = vec![
        Span::styled("DIRECT ", p.dim()),
        Span::raw(hub_core::display::fmt::usd_opt(Some(d.usd))),
    ];
    if d.unpriced > 0 {
        s.push(Span::styled(format!(" +{} unpriced", d.unpriced), p.warn()));
    }
    s.push(Span::styled(format!("  {}", d.note), p.dim()));
    s
}

fn sources(b: &Board, p: Palette) -> Vec<Span<'static>> {
    let mut s = vec![Span::styled("as of: ", p.dim())];
    for (i, src) in b.sources.iter().enumerate() {
        let when = src.as_of.map_or(hub_core::reading::NO_DATA.into(), |t| {
            crate::fmt::clock(t, b.at)
        });
        let text = format!("{}{} {when}", if i == 0 { "" } else { "  " }, src.name);
        s.push(if src.stale {
            Span::styled(text, p.warn())
        } else {
            Span::styled(text, p.dim())
        });
    }
    s
}

fn text(v: Val) -> String {
    match v {
        Val::Text(t) => t,
        Val::Num(n) => format!("{n}"),
        Val::None => "-".into(),
    }
}

/// One cell as both surfaces print it.
pub fn show(l: &costs::Line, col: &str) -> String {
    use hub_core::table::Row;
    match col {
        "cost" => hub_core::display::fmt::usd_opt(Some(l.cost)),
        "per_pr" => hub_core::display::fmt::usd_opt(l.per_pr),
        "tokens" => hub_core::display::fmt::tokens(l.tokens),
        "share" => format!("{:.0}%", l.share * 100.0),
        "landed" => l.landed.map_or("-".into(), |x| format!("{x:.2}")),
        "session" => l
            .session
            .as_deref()
            .map_or("-".into(), |s| s.chars().take(8).collect()),
        c => text(l.val(c)),
    }
}

fn table(b: &Board, p: Palette, w: usize) -> Vec<Line<'static>> {
    let cols = b.columns;
    let shown = b.rows.len().min(hub_core::layout::FOLD_ROWS);
    let rows: Vec<Vec<Cell>> = b.rows[..shown]
        .iter()
        .map(|l| {
            cols.iter()
                .map(|c| {
                    let t = if b.unpriced.is_some() && matches!(*c, "cost" | "share") {
                        "-".to_string()
                    } else {
                        show(l, c)
                    };
                    if *c == "src" && t == "mixed" {
                        cell(t, p.warn())
                    } else {
                        t.into()
                    }
                })
                .collect()
        })
        .collect();
    let at = |k: &str| cols.iter().position(|c| *c == k);
    let num = [
        "sessions", "calls", "tokens", "cost", "share", "landed", "redo", "reverts", "per_pr",
    ];
    // The key column and its cost never drop; the evaluation goes before the share.
    let order = [
        "session", "tool", "skill", "kind", "project", "harness", "model", "runner", "cost",
        "landed", "per_pr", "sessions", "calls", "share", "tokens", "redo", "reverts", "src",
    ];
    let mut keep: Vec<usize> = vec![0];
    keep.extend(order.iter().filter_map(|k| at(k)).filter(|i| *i != 0));
    let mark = cols.iter().position(|c| *c == b.table.sort).map(|i| {
        (
            i,
            if b.table.dir == hub_core::table::Dir::Asc {
                " ^"
            } else {
                " v"
            },
        )
    });
    let mut out = Table {
        header: cols.iter().map(|c| header(c)).collect(),
        rows,
        keep,
        flex: None,
        flexmin: 0,
        flexkeep: false,
        right: num.iter().filter_map(|k| at(k)).collect(),
        cap: [
            ("model", 22),
            ("project", 20),
            ("runner", 22),
            ("tool", 28),
            ("skill", 28),
        ]
        .iter()
        .filter_map(|(k, n)| at(k).map(|i| (i, *n)))
        .collect(),
        mark,
    }
    .fit(w, p.head());
    if let Some(more) = crate::fmt::older(b.rows.len(), shown, p) {
        out.push(more);
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use hub_core::costs::Eval;

    fn costs() -> Costs {
        let s = |id: &str, h: &str, m: &str, usd: f64| hub_core::spend_history::Sess {
            sid: id.into(),
            usd,
            project: Some("dotfiles".into()),
            harness: Some(h.into()),
            origin: Some("interactive".into()),
            models: [(m.to_string(), usd)].into(),
            ..Default::default()
        };
        // at is 1970-01-12: the 7d cut reads the day before.
        let day = hub_core::spend_history::Day {
            date: "1970-01-11".into(),
            usd: 15.5,
            sessions: vec![
                s("aaaaaaaa1", "claude", "claude-opus-5-5", 12.5),
                s("bbbbbbbb2", "codex", "gpt-5.6-sol", 3.0),
            ]
            .into(),
            ..Default::default()
        };
        Costs {
            at: 1_000_000,
            spend_days: vec![day],
            evals: vec![Eval {
                model: "opus".into(),
                harness: "claude".into(),
                done: 4,
                landed: 3,
                priced: 3,
                cost_usd: 9.0,
                source: "list".into(),
                ..Eval::default()
            }],
            ..Costs::default()
        }
    }

    fn series(account: &str, name: &str, v: f64) -> hub_core::prom::Series {
        hub_core::prom::Series {
            labels: [
                ("__name__".to_string(), format!("claude_account_{name}")),
                ("account".to_string(), account.to_string()),
            ]
            .into(),
            value: Some(v),
            points: vec![],
        }
    }

    /// 2026-11-06's numbers: three accounts, 39 live, 3.3x over what the weeks carry.
    fn burning() -> Costs {
        let mut all = vec![];
        for (n, live, used, gone, burn, sustain) in [
            ("main", 13.0, 33.0, 12.0, 1.51, 0.45),
            ("alt", 9.0, 55.0, 25.0, 1.04, 0.36),
            ("bnb", 17.0, 7.0, 1.0, 1.97, 0.56),
        ] {
            for (k, v) in [
                ("live_sessions", live),
                ("week_used_percent", used),
                ("week_gone_percent", gone),
                ("burn_points_per_hour", burn),
                ("sustain_points_per_hour", sustain),
                (
                    "on_pace_idle_timestamp_seconds",
                    1_000_000.0 + 36.0 * 3600.0,
                ),
                ("resets_timestamp_seconds", 1_000_000.0 + 80.0 * 3600.0),
            ] {
                all.push(series(n, k, v));
            }
        }
        for (k, v) in [
            ("five_hour_percent", 61.4),
            (
                "five_hour_resets_timestamp_seconds",
                1_000_000.0 + 2.0 * 3600.0,
            ),
            ("cost_24h_usd", 12.5),
        ] {
            all.push(series("main", k, v));
        }
        let mut age = series("", "textfile_age_seconds", 120.0);
        age.labels.remove("account");
        all.push(age);
        // claude-acct's fleet sum of the three accounts
        for (k, v) in [
            ("live_sessions", 39.0),
            ("burn_points_per_hour", 4.52),
            ("sustain_points_per_hour", 1.37),
            ("session_rate_points_per_hour", 0.116),
        ] {
            all.push(hub_core::prom::Series {
                labels: [("__name__".to_string(), format!("claude_fleet_{k}"))].into(),
                value: Some(v),
                points: vec![],
            });
        }
        let drip = hub_core::burn::Drip {
            hour: 15,
            day: 349,
            held: Some("fleet-assess says HOLD".into()),
        };
        Costs {
            burn: burn::build(&all, drip, 1_000_000),
            fleet_cost: fleet_block(),
            ..costs()
        }
    }

    fn fleet_block() -> FleetCost {
        FleetCost {
            usd: "about $849".into(),
            cash: "$310".into(),
            burn: "$538".into(),
            as_of: Some(1_000_000),
            coverage: "71% of tokens estimated: 280 of 458 sessions have no cost telemetry".into(),
            unpriced: vec![
                "claude-sonnet-4-6: 32M tokens in 3 sessions not in the total, no billed sessions"
                    .into(),
            ],
            foot: hub_core::fleet_cost::FOOT,
            ..FleetCost::default()
        }
    }

    /// A view with one inner tab shown.
    #[test]
    fn v_from_another_inner_tab_only_switches_until_spend_has_drawn_its_rows() {
        let mut v = on("limits");
        assert_eq!(
            v.fold(KeyCode::Char('v'), None, None),
            Some(Some("sessions"))
        );
        assert_eq!(
            (v.inner, v.sess_at),
            ("spend", 0),
            "the switch opens no session"
        );
        v.sess_n.set(3);
        v.fold(KeyCode::Char('v'), None, None);
        assert_eq!(v.sess_at, 1, "on Spend, v steps to the first session");
        assert_eq!(key_section(KeyCode::Char('w')), Some("table"));
        assert_eq!(key_section(KeyCode::Char('T')), Some("sections"));
        assert_eq!(key_section(KeyCode::Left), None);
    }

    fn on(inner: &'static str) -> CostsView {
        CostsView {
            inner,
            ..CostsView::default()
        }
    }

    fn screen_of(c: &Costs, v: &CostsView, w: usize) -> String {
        v.lines(c, Palette::default(), 1_000_000, w)
            .0
            .iter()
            .map(crate::fit::plain)
            .collect::<Vec<_>>()
            .join("\n")
    }

    #[test]
    fn a_spend_tile_names_its_nightly_days_and_a_window_with_none_says_so_never_zero() {
        let s = screen_of(&costs(), &CostsView::default(), 200);
        assert!(s.contains("7D $15.50 (1d to 01-11)"), "{s}");
        let none = Costs {
            spend_days: vec![],
            ..costs()
        };
        let s = screen_of(&none, &CostsView::default(), 200);
        assert!(s.contains("7D - no nightly day in 7d"), "{s}");
        assert!(!s.contains("7D $0.00"), "{s}");
    }

    #[test]
    fn a_priced_share_that_rounds_to_nothing_reads_under_one_percent() {
        assert_eq!(
            [pct_text(0.0), pct_text(0.2), pct_text(0.5), pct_text(0.6)],
            ["0%", "<1%", "<1%", "1%"]
        );
    }

    #[test]
    fn the_spend_table_opens_on_the_live_day_by_who_and_g_v_and_the_day_keys_drive_it() {
        use hub_core::spend_history::{build, Day, Sess};
        let sess = |sid: &str, usd: f64, origin: &str, project: &str| Sess {
            sid: sid.into(),
            usd,
            measured: usd,
            origin: Some(origin.into()),
            project: Some(project.into()),
            title: Some(format!("title {sid}")),
            ..Sess::default()
        };
        let snap = Day {
            date: "2026-11-09".into(),
            usd: 10.0,
            sessions: vec![sess("old", 10.0, "queue", "dotfiles")].into(),
            ..Day::default()
        };
        let live = Day {
            date: "24h".into(),
            usd: 100.0,
            sessions: vec![
                sess("a", 60.0, "queue", "dotfiles"),
                sess("b", 30.0, "shepherd", "dotfiles"),
                sess("c", 10.0, "queue", "bnb"),
            ]
            .into(),
            ..Day::default()
        };
        let c = Costs {
            live: Some(live),
            history: build(std::slice::from_ref(&snap), "2026-11-10"),
            spend_days: vec![snap],
            ..burning()
        };
        let mut v = on("spend");
        let page = |v: &CostsView| screen_of(&c, v, 80);
        let rows_after = |s: &str, head: &str| -> Vec<String> {
            s.lines()
                .skip_while(|l| !l.contains(head))
                .skip(3)
                .take(3)
                .map(|l| l.split_whitespace().next().unwrap_or("").to_string())
                .collect()
        };
        let s = page(&v);
        assert!(
            s.contains("SPEND TABLE  last 24h: 3 sessions"),
            "the live last 24h is the default: {s}"
        );
        assert!(s.lines().all(|l| l.chars().count() <= 80), "{s}");
        assert_eq!(
            rows_after(&s, "SPEND TABLE"),
            ["total", "queue", "shepherd"],
            "the total row leads, groups ranked by cost: {s}"
        );
        // g cuts by project (the cut steps on each press).
        v.fold(KeyCode::Char('g'), None, None);
        let s = page(&v);
        assert_eq!(
            rows_after(&s, "SPEND TABLE"),
            ["total", "dotfiles", "bnb"],
            "{s}"
        );
        // v highlights a group row and V opens it: its sessions under the group's own total.
        v.fold(KeyCode::Char('v'), None, None);
        v.fold(KeyCode::Char('V'), None, None);
        let s = page(&v);
        assert!(
            s.contains("title a") && s.contains("title b") && !s.contains("title c"),
            "the opened group lists its sessions only: {s}"
        );
        // V with nothing highlighted is the total row: back to the groups.
        v.fold(KeyCode::Char('V'), None, None);
        let s = page(&v);
        assert!(!s.contains("title a"), "{s}");
        // the sessions cut keeps the total row above the sessions
        v.group = 4;
        let s = page(&v);
        let at = |n: &str| s.find(n).unwrap_or_else(|| panic!("{n} missing\n{s}"));
        assert!(at("total") < at("title a"), "{s}");
        v.group = 1;
        // on another inner tab `g` is left to the page (scroll to the top)
        let mut other = on("limits");
        assert_eq!(other.fold(KeyCode::Char('g'), None, None), None);
        assert_eq!(other.inner, "limits");
        // , leaves the live day for the newest snapshot, and . returns.
        v.fold(KeyCode::Char(','), None, None);
        let s = page(&v);
        assert!(s.contains("SPEND TABLE  2026-11-09: 1 sessions"), "{s}");
        v.fold(KeyCode::Char('.'), None, None);
        let s = page(&v);
        assert!(s.contains("SPEND TABLE  last 24h: 3 sessions"), "{s}");
    }

    #[test]
    fn the_strip_is_the_first_line_spend_opens_on_the_fleet_figure_and_the_spend_table_and_arrows_switch(
    ) {
        let mut v = CostsView::default();
        let spend = screen_of(&burning(), &v, 80);
        let lines: Vec<&str> = spend.lines().collect();
        assert!(
            lines[0].starts_with("[Spend] Limits 1  Models") && lines[0].contains("<- -> switch"),
            "the strip is the first line, Spend first: {spend}"
        );
        let at = |head: &str| lines.iter().position(|l| l.trim_start().starts_with(head));
        let (fleet, table) = (at("FLEET 24H").unwrap(), at("SPEND TABLE").unwrap());
        assert!(
            fleet == 1 && fleet < table,
            "the fleet figure heads Spend, the one spend table next: {spend}"
        );
        assert!(spend.contains("window:") && !spend.contains("WHERE THE TOKENS GO"));
        assert!(v.key(KeyCode::Right));
        assert_eq!(v.inner, "limits");
        let limits = screen_of(&burning(), &v, 80);
        assert!(
            !limits.contains("FLEET 24H") && !limits.contains("SPEND TABLE"),
            "no fleet figure on Limits: {limits}"
        );
        assert!(limits.contains("BURN"));
        v.key(KeyCode::Right);
        v.key(KeyCode::Right);
        v.key(KeyCode::Right);
        assert_eq!(v.inner, "spend", "Right wraps past the last");
        v.key(KeyCode::Left);
        assert_eq!(v.inner, "budget", "Left wraps before the first");
        // Esc clears the view, not the inner tab shown.
        v.q = "x".into();
        v.key(KeyCode::Esc);
        assert_eq!(v.inner, "budget");
    }

    fn with_budget(age: i64) -> Costs {
        let f: hub_core::budget::File = serde_json::from_value(serde_json::json!({
            "schema": 2, "month": "2026-11", "as_of_epoch": 1_000_000 - age, "day": 11, "days": 30,
            "total": {"spent": 838.3, "projected": 1303.52, "caps": 1445.0},
            "needs": [],
            "by_project": [{"name": "unity-core-playground", "usd": 334.31}, {"name": "agent-runtime", "usd": 200.91},
                           {"name": "dotfiles", "usd": 118.82}, {"name": "notes-cockpit", "usd": 93.08},
                           {"name": "unattributed", "usd": 91.18}],
            "by_lane": [{"name": "queue", "usd": 175.02}, {"name": "interactive", "usd": 171.06}],
            "lines": [
                {"name": "max4", "kind": "subscription", "cap": 200.0, "spent": 200.0, "projected": 200.0,
                 "list_usd": 1125.54, "status": "ok", "note": ""},
                {"name": "lazer", "kind": "litellm", "paid_by": "lazer", "cap": 50.0, "spent": 228.12,
                 "projected": 228.12, "status": "over", "note": "past its $50 cap"},
                {"name": "do", "kind": "digitalocean", "lane": "infra", "spent": 77.71, "projected": 224.0, "status": "ok", "note": ""},
                {"name": "aws", "kind": "aws", "lane": "ci", "cap": 600.0, "spent": 112.95, "projected": 379.86,
                 "status": "ok", "note": "AWS's own forecast"}
            ]
        }))
        .unwrap();
        Costs {
            at: 1_000_000,
            budget: hub_core::budget::build(&f, 1_000_000),
            ..Costs::default()
        }
    }

    #[test]
    fn budget_leads_with_the_month_then_what_needs_a_look_then_the_bills_within_80_columns() {
        let c = with_budget(600);
        let screen = screen_of(&c, &on("budget"), 80);
        for l in screen.lines() {
            assert!(crate::fit::len(l) <= 80, "{l:?} is wider than 80");
        }
        let lines: Vec<&str> = screen.lines().collect();
        assert!(
            lines[0].contains("Budget 1"),
            "the strip counts it: {screen}"
        );
        let at = |head: &str| {
            lines
                .iter()
                .position(|l| l.starts_with(head))
                .unwrap_or(usize::MAX)
        };
        let (head, needs, bills) = (at("BUDGET"), at("NEEDS LOOK 1"), at("BILL "));
        assert!(
            head < needs && needs < bills && bills < lines.len(),
            "{screen}"
        );
        assert!(
            lines[head].contains("$838 so far") && lines[head].contains("~$1,304 by month end"),
            "{screen}"
        );
        assert!(
            lines[needs + 1].contains("lazer over its $50 cap ($228)"),
            "{screen}"
        );
        assert!(
            lines[bills + 1].starts_with("AGENTS"),
            "the agents group leads: {screen}"
        );
        assert!(
            lines[bills + 2].starts_with("  lazer"),
            "off ok leads its group: {screen}"
        );
        let (ci, infra) = (at("CI "), at("INFRA "));
        assert!(
            bills < ci && ci < at("  aws") && at("  aws") < infra && infra < at("  do"),
            "{screen}"
        );
        assert!(
            screen.contains("BY PROJECT  unity-core-playground $334"),
            "{screen}"
        );
        assert!(screen.contains("unattributed $91"), "{screen}");
        assert!(
            !screen.contains("FLEET 24H"),
            "the fleet figure is on Spend, not Budget"
        );
        // negative control: three hours old says STALE and needs a look for it
        let stale = screen_of(&with_budget(3 * 3600), &on("budget"), 80);
        assert!(
            stale.contains("STALE, as of") && stale.contains("NEEDS LOOK 2"),
            "{stale}"
        );
    }

    #[test]
    fn a_section_starts_open_and_its_key_folds_it_and_the_fold_stays() {
        let mut v = on("models");
        let open = sections_screen(&v, 80);
        assert!(open.lines().any(|l| l.starts_with("- SECTIONS")), "{open}");
        assert!(open.contains("All PRs"), "open shows the table: {open}");
        v.key(KeyCode::Char('e'));
        let shut = sections_screen(&v, 80);
        assert!(shut.lines().any(|l| l.starts_with("+ SECTIONS")), "{shut}");
        assert!(
            !shut.lines().any(|l| l.starts_with("- SECTIONS")),
            "negative control"
        );
        v.key(KeyCode::Char('x'));
        assert!(!v.sections_open, "a reset keeps the reader's fold");
        assert!(sections_screen(&v, 80).contains("+ SECTIONS"));
    }

    #[test]
    fn an_amber_section_puts_its_count_on_its_inner_tab() {
        let mut c = burning();
        c.burn.level = "warn";
        let v = on("spend");
        let strip = screen_of(&c, &v, 80)
            .lines()
            .find(|l| l.contains("<- -> switch"))
            .unwrap()
            .to_string();
        assert!(
            strip.contains("Limits 1") && !strip.contains("Spend 1"),
            "{strip}"
        );
        c.burn.level = "ok";
        let strip = screen_of(&c, &v, 80);
        assert!(!strip.contains("Limits 1"), "no count at zero");
    }

    #[test]
    fn a_link_a_key_or_a_section_word_opens_the_inner_tab_holding_it() {
        let mut v = CostsView::default();
        v.open("models");
        assert_eq!(v.inner, "models");
        v.open("burn");
        assert_eq!(v.inner, "limits");
        v.open("table");
        assert_eq!(v.inner, "spend");
        assert!(v.q.is_empty(), "an inner tab's name is no query");
        // an unknown word stays a query and leaves the tab
        v.open("nonsense");
        assert_eq!((v.inner, v.q.as_str()), ("spend", "nonsense"));
        // a table key brings the table up; a fold key for another tab's section switches there
        let mut v = CostsView::default();
        v.key(KeyCode::Char('b'));
        assert_eq!(v.inner, "spend");
        assert_eq!(
            v.fold(KeyCode::Char('y'), None, None),
            Some(None),
            "on its own tab, y folds the open history"
        );
        let mut v = on("limits");
        assert_eq!(v.fold(KeyCode::Char('y'), None, None), Some(Some("spend")));
        assert!(
            v.history_open && v.inner == "spend",
            "a switch opens the fold"
        );
        v.inner = "limits";
        assert_eq!(v.fold(KeyCode::Char('y'), None, None), Some(Some("spend")));
        assert!(v.history_open, "it was open, and the switch keeps it open");
        v.key(KeyCode::Char('e'));
        assert!(v.sections_open && v.inner == "models");
    }

    #[test]
    fn history_is_a_headline_until_y_opens_its_rows_within_80_columns() {
        use hub_core::spend_history::{build, Day};
        let day = |d: &str, usd: f64| Day {
            date: d.into(),
            usd,
            estimated: usd / 4.0,
            ..Day::default()
        };
        let c = Costs {
            history: build(
                &[
                    day("2026-10-30", 1102.0),
                    day("2026-10-31", 1102.0),
                    day("2026-11-01", 1579.0),
                ],
                "2026-11-02",
            ),
            ..burning()
        };
        let page = |v: &CostsView| {
            v.lines(&c, Palette::default(), 1_000_000, 80)
                .0
                .iter()
                .map(crate::fit::plain)
                .collect::<Vec<_>>()
                .join("\n")
        };
        let mut v = on("spend");
        assert!(page(&v).contains("- SPEND  "), "it starts open");
        assert_eq!(v.fold(KeyCode::Char('y'), None, None), Some(None));
        let shut = page(&v);
        assert!(
            shut.contains(
                "+ SPEND  Nov $1,579/day vs Oct $1,102/day (+43%)   y: by period\n  11-01 $1,579"
            ),
            "{shut}"
        );
        assert!(shut.lines().all(|l| l.chars().count() <= 80), "{shut}");
        assert!(!shut.contains("vs prev"), "folded: {shut}");
        assert_eq!(v.fold(KeyCode::Char('y'), None, None), Some(Some("spend")));
        let open = page(&v);
        assert!(open.lines().all(|l| l.chars().count() <= 80), "{open}");
        assert!(open.contains("- SPEND  "), "{open}");
        assert!(
            open.contains("vs prev") && open.contains("$/session"),
            "{open}"
        );
        let row = |p: &str| {
            open.lines()
                .find(|l| l.trim_start().starts_with(p))
                .unwrap()
                .split_whitespace()
                .collect::<Vec<_>>()
        };
        assert_eq!(
            row("2026-11 "),
            ["2026-11", "$1,579", "1", "$1,579", "-", "+43%", "25%"]
        );
        assert_eq!(
            row("2026 "),
            ["2026", "$3,783", "3", "$1,261", "-", "-", "25%"]
        );
        assert_eq!(
            row("10-31"),
            ["10-31", "$1,102", "1", "$1,102", "-", "+0%", "25%"]
        );
    }

    #[test]
    fn spend_charts_the_days_and_ranks_the_picked_days_sessions_by_session_within_80_columns() {
        use hub_core::spend_history::{build, Day, Sess};
        let sess = |sid: &str, usd: f64, title: &str| Sess {
            sid: sid.into(),
            usd,
            measured: usd,
            origin: Some("runner".into()),
            title: Some(title.into()),
            ..Sess::default()
        };
        let days = vec![
            Day {
                date: "2026-11-07".into(),
                usd: 30.0,
                sessions: vec![sess("a", 20.0, "dream"), sess("b", 10.0, "shepherd")].into(),
                ..Day::default()
            },
            // 11-08 has no snapshot: a gap, not a $0 bar.
            Day {
                date: "2026-11-09".into(),
                usd: 100.0,
                estimated: 40.0,
                sessions: vec![sess("b", 5.0, "shepherd"), sess("c", 90.0, "big run")].into(),
                ..Day::default()
            },
        ];
        let c = Costs {
            history: build(&days, "2026-11-10"),
            spend_days: days,
            ..burning()
        };
        let page = |v: &CostsView| {
            v.lines(&c, Palette::default(), 1_000_000, 80)
                .0
                .iter()
                .map(crate::fit::plain)
                .collect::<Vec<_>>()
                .join("\n")
        };
        let mut v = on("spend");
        v.group = 4;
        let s = page(&v);
        assert!(s.lines().all(|l| l.chars().count() <= 80), "{s}");
        assert!(s.contains("$/DAY, LAST 30 DAYS"), "{s}");
        let base = s
            .lines()
            .rev()
            .find(|l| l.starts_with("        ") && l.contains('.'))
            .unwrap();
        assert!(
            base.trim_end().ends_with(". \u{2588}"),
            "11-08 is a gap beside 11-09: {base:?}"
        );
        assert!(
            s.contains("2026-11-09: $100 ($60 billed, $40 estimated), 2 sessions"),
            "{s}"
        );
        let ranked: Vec<&str> = s
            .lines()
            .filter(|l| l.starts_with("big run") || l.starts_with("shepherd"))
            .collect();
        assert!(
            ranked[0].starts_with("big run")
                && ranked[0].contains("$90")
                && ranked[0].contains("90%"),
            "{s}"
        );
        assert_eq!(
            v.fold(KeyCode::Char(','), None, None),
            Some(Some("sessions"))
        );
        let s = page(&v);
        assert!(s.contains("2026-11-08: no figure"), "{s}");
        assert!(
            s.contains("SPEND TABLE  2026-11-08: no session rows"),
            "the picked day stays picked, and says it has no rows: {s}"
        );
        v.fold(KeyCode::Char(','), None, None);
        let s = page(&v);
        assert!(s.contains("SPEND TABLE  2026-11-07: 2 sessions"), "{s}");
        v.fold(KeyCode::Char('v'), None, None);
        v.fold(KeyCode::Char('v'), None, None);
        let s = page(&v);
        let line = s.lines().find(|l| l.contains("in 30 days")).expect(&s);
        assert!(
            line.trim_start().starts_with("shepherd") && line.contains("$15 in 30 days"),
            "both days the session ran: {line}"
        );
    }

    #[test]
    fn the_fleet_figure_leads_spend_and_burn_leads_limits_all_in_80_columns() {
        let page = |v: CostsView| {
            v.lines(&burning(), Palette::default(), 1_000_000, 80)
                .0
                .iter()
                .map(crate::fit::plain)
                .collect::<Vec<_>>()
                .join("\n")
        };
        let (spend, limits) = (page(CostsView::default()), page(on("limits")));
        assert!(
            spend.starts_with("[Spend] Limits 1  Models")
                && spend
                    .lines()
                    .nth(1)
                    .unwrap()
                    .starts_with("FLEET 24H about $849  API cash $310  sub burn $538  as of "),
            "{spend}"
        );
        assert!(
            limits.lines().nth(1).unwrap().starts_with("BURN"),
            "{limits}"
        );
        let s = format!("{spend}\n{limits}");
        assert!(s.lines().all(|l| l.chars().count() <= 80), "{s}");
        let burn = s.lines().find(|l| l.starts_with("BURN")).unwrap();
        assert!(
            burn.starts_with("BURN  4.5 pts/h vs 1.4 sustainable, 3.3x, 39 live"),
            "{s}"
        );
        assert!(s.contains("DRIP  15 started in 1h, 349 in 24h"), "{s}");
        assert!(s.contains("dispatch held -> 4 Sessions"), "{s}");
        assert!(
            s.contains("BACK ON PACE  at this burn: not before the reset; if idle: all by"),
            "{s}"
        );
        assert!(
            s.contains("bnb") && s.contains("1.97") && s.contains("after reset"),
            "{s}"
        );
        assert!(
            !limits.contains("window:") && !limits.contains("7D "),
            "the spend tiles are on Spend, not Limits"
        );
        // a narrow pane wraps the headline between clauses instead of cutting its last one
        let narrow = on("limits")
            .lines(&burning(), Palette::default(), 1_000_000, 50)
            .0
            .iter()
            .map(crate::fit::plain)
            .collect::<Vec<_>>()
            .join("\n");
        assert!(
            narrow.contains("3.3x, 39 live\n      carries ~11\n"),
            "{narrow}"
        );
        // every term on the section is defined under it, wrapped to the width
        for t in ["pts/h: ", "GONE: ", "AT BURN: ", "IF IDLE: ", "$24H: "] {
            assert!(s.contains(t), "{t} undefined: {s}");
        }
        // and every term the legend defines, bar the headline's unit, is a column the table prints
        let wide = on("limits")
            .lines(&burning(), Palette::default(), 1_000_000, 400)
            .0
            .iter()
            .map(crate::fit::plain)
            .find(|l| l.trim_start().starts_with("SOURCE"))
            .unwrap();
        for (t, _) in burn::LEGEND.iter().filter(|(t, _)| *t != "pts/h") {
            assert!(wide.contains(t), "{t} is not a column: {wide}");
        }
    }

    #[test]
    fn a_burn_row_carries_the_five_hour_window_and_the_days_dollars() {
        let at = |w| {
            on("limits")
                .lines(&burning(), Palette::default(), 1_000_000, w)
                .0
                .iter()
                .map(crate::fit::plain)
                .collect::<Vec<_>>()
        };
        let wide = at(200);
        let head = wide.iter().find(|l| l.starts_with("SOURCE")).unwrap();
        for col in ["5H", "5H RESETS", "$24H"] {
            assert!(head.contains(col), "{col} missing from {head}");
        }
        let main = wide.iter().find(|l| l.starts_with("main")).unwrap();
        let five = crate::fmt::clock(1_000_000 + 2 * 3600, 1_000_000);
        assert!(
            main.contains("61%") && main.contains(&five) && main.contains("$12.50"),
            "{main}"
        );
        let bnb = wide.iter().find(|l| l.starts_with("bnb")).unwrap();
        assert!(!bnb.contains('$'), "no figure is no dollars: {bnb}");
        // Narrow, $24H is the first to go and the 5h window stays.
        let narrow = at(100);
        let head = narrow.iter().find(|l| l.starts_with("SOURCE")).unwrap();
        assert!(!head.contains("$24H") && head.contains("5H"), "{head}");
    }

    #[test]
    fn the_token_folds_sit_under_burn_and_a_link_opens_them_where_the_page_says() {
        let mut c = burning();
        c.tokens = Some(Default::default());
        let mut v = CostsView::default();
        v.open("tokens");
        assert_eq!((v.tokens.open, v.q.as_str()), (Some(true), ""));
        assert_eq!(
            v.inner, "models",
            "a section's name opens the inner tab holding it"
        );
        v.open("langfuse");
        v.open("burn");
        assert_eq!(
            (v.langfuse, v.q.as_str()),
            (Some(true), ""),
            "a section is no query"
        );
        // Each inner tab's sections: together every Costs section has its anchor, in the
        // layout's order.
        let mut names: Vec<&str> = vec![];
        let mut pages = std::collections::HashMap::new();
        for i in layout::resolve("costs").unwrap().inner {
            v.inner = i.id;
            let (l, at) = v.lines(&c, Palette::default(), 1_000_000, 100);
            let l: Vec<String> = l.iter().map(crate::fit::plain).collect();
            names.extend(at.iter().map(|a| a.0));
            for (sec, n) in &at {
                pages.insert(*sec, l.get(*n).cloned().unwrap_or_default());
            }
        }
        assert_eq!(
            names,
            hub_core::layout::resolve("costs").unwrap().sections,
            "every Costs section has its anchor, in the layout's order"
        );
        assert!(pages["burn"].starts_with("BURN"), "{pages:#?}");
        assert!(
            pages["tokens"].starts_with("- WHERE THE TOKENS GO"),
            "{pages:#?}"
        );
        assert!(
            pages["langfuse"].starts_with("- WHAT LANGFUSE SEES"),
            "{pages:#?}"
        );
        assert!(pages["totals"].starts_with("FLEET 24H"), "{pages:#?}");
        assert!(
            pages["sessions"].trim_start().starts_with("SPEND TABLE"),
            "{pages:#?}"
        );
        assert!(pages["table"].starts_with("window:"), "{pages:#?}");
        assert!(pages["budget"].starts_with("BUDGET"), "{pages:#?}");
    }

    fn with_sections() -> Costs {
        let out = r#"{"days":7,"all":{"prs":598,"gated":460,"with_session":339,"first_try":0.515,"reds_per_pr":0.976,"gate_min_per_pr":144.7,"gate_h":1109,"green_lost":116,"cost_per_pr":7.33,"tokens_per_pr":14030412,"work_min_per_pr":34.4},
          "sections":[
            {"section":"Assets/Playground/Tests","prs":417,"gated":399,"with_session":209,"first_try":0.484,"reds_per_pr":1.065,"gate_min_per_pr":155.6,"gate_h":1035,"green_lost":107,"cost_per_pr":6.96,"tokens_per_pr":13026570,"work_min_per_pr":36.2},
            {"section":"docs","prs":472,"gated":369,"with_session":272,"first_try":0.45,"reds_per_pr":1.127,"gate_min_per_pr":162.9,"gate_h":1002,"green_lost":103,"cost_per_pr":7.69,"tokens_per_pr":14771869,"work_min_per_pr":35.7}]}"#;
        Costs {
            sections: hub_core::sections::parse(out).unwrap(),
            ..costs()
        }
    }

    fn sections_screen(v: &CostsView, w: usize) -> String {
        v.lines(&with_sections(), Palette::default(), 1_000_000, w)
            .0
            .iter()
            .map(crate::fit::plain)
            .collect::<Vec<_>>()
            .join("\n")
    }

    #[test]
    fn sections_fold_to_a_headline_on_e_and_open_all_prs_leads_both_caveats_show() {
        let mut v = on("models");
        v.key(KeyCode::Char('e'));
        let s = sections_screen(&v, 80);
        assert!(
            s.contains("+ SECTIONS  598 PRs in 7d, 52% first try"),
            "{s}"
        );
        assert!(!s.contains("All PRs"), "folded: no table\n{s}");
        v.key(KeyCode::Char('e'));
        let s = sections_screen(&v, 80);
        assert!(s.lines().all(|l| l.chars().count() <= 80), "{s}");
        let at = |n: &str| s.find(n).unwrap_or_else(|| panic!("{n} missing\n{s}"));
        assert!(at("All PRs") < at("Assets/Playground/Tests") && at("Tests") < at("docs"));
        assert!(s.contains("counts in every section it touches"), "{s}");
        assert!(
            s.contains("only the PRs a session claims (339 of 598"),
            "{s}"
        );
        assert!(!s.contains("window:"), "the spend tiles are on Spend");
    }

    #[test]
    fn t_sorts_the_sections_by_each_column_and_t_flips_it() {
        let mut v = on("models");
        v.key(KeyCode::Char('t'));
        assert_eq!(v.ssort, "section");
        // Descending by name: docs before Assets, All PRs still first.
        let s = sections_screen(&v, 80);
        assert!(s.find("All PRs").unwrap() < s.find("docs").unwrap(), "{s}");
        assert!(
            s.find("docs").unwrap() < s.find("Assets/Playground/Tests").unwrap(),
            "{s}"
        );
        v.key(KeyCode::Char('T'));
        let s = sections_screen(&v, 80);
        assert!(
            s.find("Assets/Playground/Tests").unwrap() < s.find("docs").unwrap(),
            "{s}"
        );
        assert!(
            s.contains("section ^"),
            "the header says its direction\n{s}"
        );
        assert!(!v.key(KeyCode::Char('r')), "r stays the page's refresh");
        v.key(KeyCode::Char('x'));
        assert!(
            v.ssort.is_empty() && v.sections_open,
            "x clears the sort, keeps the fold"
        );
    }

    #[test]
    fn esc_clears_a_sections_sort_t_starts_each_column_descending_and_a_link_opens_it() {
        let mut v = CostsView::default();
        v.key(KeyCode::Char('t'));
        v.key(KeyCode::Char('T'));
        assert!(!v.is_default());
        v.key(KeyCode::Char('t'));
        assert!(!v.sasc, "the next column starts descending");
        assert!(v.key(KeyCode::Esc) && v.ssort.is_empty() && !v.sasc);
        let mut v = CostsView::default();
        v.open("sections&ssort=prs&sdir=asc");
        assert!(v.sections_open && v.ssort == "prs" && v.sasc && v.q.is_empty());
    }

    #[test]
    fn a_narrow_screen_never_drops_the_sorted_column() {
        let mut v = CostsView::default();
        v.open("sections&ssort=tokens_per_pr");
        let s = sections_screen(&v, 60);
        assert!(s.contains("tokens/PR v"), "{s}");
    }

    #[test]
    fn no_claude_acct_data_says_so_and_still_shows_the_spend() {
        let s = screen(&on("limits"), 80);
        assert!(s.contains("\nBURN  no data from claude-acct"), "{s}");
        assert!(screen(&on("spend"), 80).contains("window:"));
    }

    fn screen(v: &CostsView, w: usize) -> String {
        v.lines(&costs(), Palette::default(), 1_000_000, w)
            .0
            .iter()
            .map(crate::fit::plain)
            .collect::<Vec<_>>()
            .join("\n")
    }

    fn paced() -> Costs {
        use hub_core::pace_conf::{Allowance, KeyRow, Schedule, View};
        let row = |value: &str, state: &'static str, by: &str, can_end| Schedule {
            value: value.into(),
            from: "-".into(),
            until: "-".into(),
            by: by.into(),
            state,
            start: None,
            can_end,
        };
        let mut c = burning();
        c.pace = View {
            error: None,
            allowance: Some(Allowance {
                key: "BURN_OVER_PCT",
                in_force: "400".into(),
                source: "window to Tue 22:00".into(),
                default: "200".into(),
                max: Some(1000.0),
                allowed: Some(5.5),
                sustain: Some(1.37),
                burn: Some(4.52),
                spare: Some(3),
                as_of: Some(1_000_000 - 120),
                window_max_days: Some(7),
                note: "Loosens only committed.",
                rows: vec![
                    row("400", "In force", "agent-web", true),
                    row("200", "Default", "pace.conf", false),
                ],
            }),
            keys: vec![
                KeyRow {
                    key: "BURN_OVER_PCT".into(),
                    value: "400".into(),
                    source: "window to Tue 22:00".into(),
                    default: "200".into(),
                    editable: true,
                },
                KeyRow {
                    key: "RESERVE_PCT".into(),
                    value: "10".into(),
                    source: "default".into(),
                    default: "10".into(),
                    editable: false,
                },
            ],
        };
        c
    }

    #[test]
    fn limits_shows_the_allowance_with_its_schedule_and_every_pace_key_read_only() {
        let s = screen_of(&paced(), &on("limits"), 100);
        assert!(s.lines().all(|l| l.chars().count() <= 100), "{s}");
        let at = |n: &str| s.find(n).unwrap_or_else(|| panic!("{n} missing\n{s}"));
        assert!(
            at("BURN  ") < at("ALLOWANCE  400% (window to Tue 22:00), default 200%")
                && at("ALLOWANCE  400%") < at("PACE CONFIG  2 keys")
                && at("PACE CONFIG") < at("CONSUMERS"),
            "burn, allowance, pace config, consumers\n{s}"
        );
        assert!(
            s.contains(
                "4.52/h now against 1.37/h sustainable and 5.50/h allowed, 3 spare sessions"
            ),
            "{s}"
        );
        assert!(s.contains("In force") && s.contains("agent-web"), "{s}");
        assert!(s.contains("RESERVE_PCT") && s.contains("SETTABLE"), "{s}");
        assert!(s.contains("Set or end a window in agent-web"), "{s}");
    }

    #[test]
    fn an_unreadable_pace_config_says_why_in_both_sections() {
        let mut c = paced();
        c.pace = hub_core::pace_conf::view(Err("pace-conf: boom".into()), &c.burn);
        let s = screen_of(&c, &on("limits"), 100);
        assert!(s.contains("ALLOWANCE  pace-conf: boom"), "{s}");
        assert!(s.contains("PACE CONFIG  pace-conf: boom"), "{s}");
    }

    #[test]
    fn the_model_cut_fits_80_columns_with_its_evaluation() {
        let s = screen(&on("spend"), 80);
        assert!(s.lines().all(|l| l.chars().count() <= 80), "{s}");
        assert!(s.contains("[model]") && s.contains("[7d]"), "{s}");
        assert!(s.contains("LANDED") && s.contains("0.75"), "{s}");
        assert!(s.contains("opus-5-5") && s.contains("$12.50"), "{s}");
    }

    #[test]
    fn the_direct_line_shows_what_direct_cannot_see_and_the_pool_is_no_tile() {
        let mut c = costs();
        c.spend_days[0].unpriced = vec![hub_core::spend_history::Sess {
            sid: "oc-direct".into(),
            provider: Some("lazer".into()),
            tokens: Some(900.0),
            ..Default::default()
        }]
        .into();
        let s = screen_of(&c, &on("spend"), 80);
        assert!(s.lines().all(|l| l.chars().count() <= 80), "{s}");
        let direct = s.lines().find(|l| l.starts_with("DIRECT")).unwrap();
        assert!(direct.contains("$0.00 +1 unpriced"), "{s}");
        assert!(direct.ends_with(hub_core::costs::DIRECT_NOTE), "{s}");
        // the pool is a Burn row and its keys Consumers rows, never a line of their own
        assert!(
            !s.lines()
                .any(|l| l.starts_with("LAZER") || l.starts_with("GLM") || l.contains("RESERVE $")),
            "{s}"
        );
        let s = screen(&CostsView::default(), 80);
        assert!(!s.contains("unpriced"), "{s}");
    }

    #[test]
    fn burn_points_at_consumers_for_the_keys_under_a_pool() {
        let mut all = vec![];
        for (n, kind, used) in [
            ("lazer", "litellm-team", 90.0),
            ("reserve", "litellm-key", 96.0),
        ] {
            for (k, v) in [("week_used_percent", used), ("paced", 0.0)] {
                let mut s = series(n, k, v);
                s.labels.insert("kind".into(), kind.into());
                all.push(s);
            }
        }
        let mut parent = series("reserve", "parent", 1.0);
        parent.labels.insert("kind".into(), "litellm-key".into());
        parent.labels.insert("parent".into(), "lazer".into());
        all.push(parent);
        let mut age = series("", "textfile_age_seconds", 120.0);
        age.labels.remove("account");
        all.push(age);
        let c = Costs {
            burn: burn::build(&all, Default::default(), 1_000_000),
            ..costs()
        };
        let shut = screen_of(&c, &on("limits"), 200);
        let shut: Vec<&str> = shut.lines().collect();
        assert!(
            shut.iter().any(|l| l.starts_with("lazer")),
            "the pool is a row: {shut:?}"
        );
        assert!(
            !shut.iter().any(|l| l.starts_with("reserve")),
            "the key is not: {shut:?}"
        );
        assert!(
            shut.iter().any(
                |l| l.starts_with("KEYS  1 in lazer, 0 live, tightest reserve 96%")
                    && l.ends_with("rows in Consumers (K)")
            ),
            "{shut:?}"
        );
    }

    #[test]
    fn consumers_starts_open_and_k_still_folds_it() {
        assert!(consumers_open(None));
        assert!(
            !consumers_open(Some(false)),
            "negative control: the reader's fold wins"
        );
    }

    /// The gateway as `claude-acct gateway` writes it: a capped low pool and a must core team.
    fn gateway_read(confs: serde_json::Value) -> hub_core::gateway::Read {
        let snapshot = serde_json::from_value(serde_json::json!({
            "at": 1_000_000 - 600,
            "teams": [
                {"alias": "lazer-core", "spend": 0.5, "max_budget": 200.0, "priority": "must", "budget_duration": "1mo"},
                {"alias": "lazer-pool", "spend": 228.0, "max_budget": 50.0, "priority": "low", "budget_duration": "1mo"}
            ],
            "keys": [
                {"alias": "comms-triage", "team": "lazer-core", "spend": 0.02, "max_budget": 25.0, "budget_duration": "30d", "models": ["fast"], "priority": "must"},
                {"alias": "claude-reserve", "team": "lazer-pool", "spend": 92.0, "max_budget": 100.0, "budget_duration": "30d", "models": ["claude-sonnet-5"], "priority": "low"}
            ],
            "sources": [{"name": "codex", "kind": "codex", "reserve": 30, "priority": "low"}],
            "aliases": {"fast": "fast (gpt-oss-120b)"},
            "fallbacks": {"fast (gpt-oss-120b)": ["assist (gemini-flash)"]}
        }))
        .unwrap();
        hub_core::gateway::Read {
            snapshot: Some(snapshot),
            confs: serde_json::from_value(confs).unwrap(),
            errors: vec![],
        }
    }

    fn gateway_conf(name: &str, key: &str) -> serde_json::Value {
        serde_json::json!({
            "name": name, "enabled": true, "priority": "must", "harness": "raw", "model": "fast",
            "route": "gateway-fast", "route_transport": "openai-compatible", "route_model": "fast",
            "route_key": key
        })
    }

    #[test]
    fn green_consumers_start_open_and_k_folds_them_to_their_headline() {
        let c = Costs {
            consumers: gateway_read(serde_json::json!([gateway_conf(
                "version-summary",
                "rbw:litellm_comms_triage_key"
            )])),
            ..costs()
        };
        let mut v = on("limits");
        let open = screen_of(&c, &v, 80);
        assert_eq!(v.fold(KeyCode::Char('K'), None, Some("ok")), Some(None));
        let shut = screen_of(&c, &v, 80);
        let head = shut
            .lines()
            .find(|l| l.starts_with("+ CONSUMERS  "))
            .unwrap_or_else(|| panic!("{shut}"));
        assert!(head.contains("2 consumers: must 1, low 1"), "{shut}");
        assert!(!shut.contains("CONSUMER "), "folded, no table: {shut}");
        let mut linked = on("limits");
        linked.open("consumers");
        assert_eq!(
            screen_of(&c, &linked, 80),
            open,
            "`hub --tab 'costs consumers'` opens it"
        );
        assert!(open.lines().all(|l| l.chars().count() <= 80), "{open}");
        assert!(open.contains("- CONSUMERS  "), "{open}");
        let row = open
            .lines()
            .find(|l| l.starts_with("version-summary"))
            .unwrap_or_else(|| panic!("{open}"));
        assert!(row.contains("must") && row.contains("ok"), "{row}");
        assert!(open.contains("aliases: fast -> gpt-oss-120b"), "{open}");
        let legend: Vec<&str> = open
            .lines()
            .skip_while(|l| !l.starts_with("PRI: "))
            .collect();
        assert!(
            legend
                .join(" ")
                .contains("or the plan's week used. FALLBACK:"),
            "the legend wraps, never clips: {open}"
        );
    }

    #[test]
    fn a_must_runner_on_the_low_pool_is_a_red_mismatch_that_starts_open_in_80_columns() {
        let c = Costs {
            consumers: gateway_read(serde_json::json!([
                gateway_conf("version-summary", "rbw:litellm_comms_triage_key"),
                gateway_conf("nightly-thing", "rbw:litellm_claude_reserve_key"),
            ])),
            ..costs()
        };
        let s = screen_of(&c, &on("limits"), 80);
        assert!(s.lines().all(|l| l.chars().count() <= 80), "{s}");
        assert!(s.contains("- CONSUMERS  1 MISMATCH | "), "{s}");
        let lines: Vec<&str> = s.lines().collect();
        let header = lines
            .iter()
            .position(|l| l.starts_with("CONSUMER "))
            .unwrap_or_else(|| panic!("{s}"));
        assert!(
            lines[header + 1].starts_with("nightly-thing")
                && lines[header + 1].contains("MISMATCH: lazer-pool"),
            "a MISMATCH leads: {s}"
        );
        assert!(
            c.burn.keys.is_none() && !s.contains("KEYS  "),
            "no keys, no pointer"
        );
    }

    #[test]
    fn a_dollar_source_is_a_burn_row_with_its_kind_dollars_and_reserve() {
        let mut all = vec![];
        let mut kinded = |n: &str, kind: &str, k: &str, v: f64| {
            let mut s = series(n, k, v);
            s.labels.insert("kind".into(), kind.into());
            all.push(s);
        };
        for (k, v) in [
            ("week_used_percent", 41.0),
            ("usd_used", 41.0),
            ("usd_budget", 100.0),
            ("reserve_percent", 15.0),
            ("paced", 0.0),
            ("burn_points_per_hour", 9.0),
            ("sustain_points_per_hour", 1.0),
        ] {
            kinded("reserve", "litellm-key", k, v);
        }
        for (k, v) in [
            ("week_used_percent", 1.0),
            ("week_gone_percent", 14.0),
            ("reserve_percent", 5.0),
        ] {
            kinded("codex", "codex", k, v);
        }
        let mut pool = series("reserve", "parent", 1.0);
        pool.labels.insert("kind".into(), "litellm-key".into());
        pool.labels.insert("parent".into(), "lazer".into());
        all.push(pool);
        let mut age = series("", "textfile_age_seconds", 120.0);
        age.labels.remove("account");
        all.push(age);
        let c = Costs {
            burn: burn::build(&all, Default::default(), 1_000_000),
            ..costs()
        };
        let wide = on("limits")
            .lines(&c, Palette::default(), 1_000_000, 200)
            .0
            .iter()
            .map(crate::fit::plain)
            .collect::<Vec<_>>();
        let head = wide.iter().find(|l| l.starts_with("SOURCE")).unwrap();
        for col in ["KIND", "RESERVE", "BAR"] {
            assert!(head.contains(col), "{col} missing from {head}");
        }
        assert!(!head.contains("POOL"), "nesting says it now: {head}");
        let row = wide.iter().find(|l| l.starts_with("reserve")).unwrap();
        assert!(
            row.contains("litellm-key") && row.contains("41% $41/$100"),
            "{row}"
        );
        assert!(row.contains("15%"), "{row}");
        assert!(row.contains("[#####.....]"), "41% rounds up: {row}");
        // negative control: a dollar budget has no pace line, so its 9 pts/h burn is not printed
        assert!(!row.contains("9.00") && !row.contains("on pace"), "{row}");
        let codex = wide.iter().find(|l| l.starts_with("codex")).unwrap();
        assert!(
            codex.contains("codex") && codex.contains("5%") && codex.contains("14%"),
            "{codex}"
        );
    }

    #[test]
    fn the_keys_step_the_cut_the_window_and_the_sort() {
        let mut v = CostsView::default();
        assert!(v.key(KeyCode::Char('b')));
        assert_eq!(v.by, "harness");
        v.key(KeyCode::Char('B'));
        v.key(KeyCode::Char('B'));
        assert_eq!(v.by, "session");
        v.key(KeyCode::Char('w'));
        assert_eq!(v.window, "30d");
        v.key(KeyCode::Char('s'));
        assert_eq!(v.sort, "session");
        v.key(KeyCode::Char('S'));
        assert!(v.asc);
        assert!(!v.key(KeyCode::Char('r')), "r is the page's refresh");
        v.key(KeyCode::Char('x'));
        assert!(v.is_default() && v.by == "session", "x keeps the cut");
    }

    #[test]
    fn a_typed_query_filters_and_one_with_no_match_says_so() {
        let mut v = CostsView::default();
        v.key(KeyCode::Char('/'));
        for c in "harness:codex".chars() {
            assert!(v.key(KeyCode::Char(c)), "q types, it does not quit");
        }
        v.key(KeyCode::Enter);
        let s = screen(&v, 80);
        assert!(s.contains("gpt-5.6-sol") && !s.contains("opus-5-5"), "{s}");
        v.q = "harness:nope".into();
        assert!(screen(&v, 80).contains("nothing matches the query"));
    }

    #[test]
    fn a_link_names_the_cut_window_and_query() {
        let mut v = CostsView::default();
        v.open("by=runner&w=24h");
        assert_eq!((v.by, v.window), ("runner", "24h"));
        v.open("project 30d harness:codex");
        assert_eq!(
            (v.by, v.window, v.q.as_str()),
            ("project", "30d", "harness:codex")
        );
    }
}
