//! The Costs tab: `hub_core::costs::board`, the same view agent-web draws. `b`/`B` step the cut,
//! `w` the window, `/` types the query (the shared table's grammar), `s` sorts by the cut's next
//! column, `S` flips it, `x` clears; `o` opens the Grafana trends. Burn has one row per source
//! (the Fleet tab's accounts table until 2026-11-07), and `K` opens the keys folded under their
//! pool. Under it the token folds
//! (tokens.rs): `u` opens where the tokens go, `U` its window, `l` what Langfuse sees. The
//! Sections block is folded to its headline: `e` opens it, `t` steps its sort column and `T`
//! flips it.

use hub_core::burn::{self, Account, Burn, Keys};
use hub_core::costs::{self, Board, Costs};
use hub_core::sections::{self, Block};
use hub_core::table::Val;
use ratatui::crossterm::event::KeyCode;
use ratatui::style::Style;
use ratatui::text::{Line, Span};

use crate::fit::{cell, clip_line, Cell, Table};
use crate::fmt::Palette;
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
    /// One of the Sections columns, or empty for fleet-bench's order (the most gate hours first).
    pub ssort: String,
    pub sasc: bool,
    /// The tokens fold (`u`) and its window (`U`).
    pub tokens: TokensView,
    /// The Langfuse fold (`l`); None while it follows its amber state.
    pub langfuse: Option<bool>,
    /// The keys fold under the pool (`K`); None while it follows its amber state.
    pub keys: Option<bool>,
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
            sections_open: false,
            ssort: String::new(),
            sasc: false,
            tokens: TokensView::default(),
            langfuse: None,
            keys: None,
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
        "kind" => "KIND",
        "project" => "PROJECT",
        "harness" => "HARNESS",
        "model" => "MODEL",
        "runner" => "RUNNER",
        "sessions" => "SESS",
        "calls" => "CALLS",
        "tokens" => "TOKENS",
        "cost" => "COST",
        "share" => "SHARE",
        "landed" => "LANDED",
        "redo" => "REDO",
        "reverts" => "REV",
        "per_pr" => "$/PR",
        "src" => "SRC",
        "pr" => "PR",
        "at" => "UPDATED",
        _ => "",
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
    }

    /// `hub --tab costs --q '<words>'`: a cut or window name sets it, `key=value` sets `by`, `w`
    /// or `q`, a section's name opens its fold (the page scrolls there), and any other word joins
    /// the query.
    pub fn open(&mut self, arg: &str) {
        let mut q = vec![];
        for word in arg.split(['&', ' ']).filter(|w| !w.is_empty()) {
            let (k, v) = word.split_once('=').unwrap_or(("", word));
            match k {
                "by" => self.by = costs::cut(v),
                "w" => self.window = costs::window(v).0,
                "q" => q.push(v.to_string()),
                "ssort" => self.ssort = v.to_string(),
                "sdir" => self.sasc = v == "asc",
                _ if word == "sections" => self.sections_open = true,
                _ if word == "tokens" => self.tokens.open = Some(true),
                _ if word == "langfuse" => self.langfuse = Some(true),
                _ if hub_core::layout::resolve("costs")
                    .is_some_and(|t| t.sections.contains(&word)) => {}
                _ if costs::CUTS.contains(&v) => self.by = costs::cut(v),
                _ if costs::WINDOWS.iter().any(|w| w.0 == v) => self.window = costs::window(v).0,
                _ => q.push(word.to_string()),
            }
        }
        if !q.is_empty() {
            self.q = q.join(" ");
        }
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
        match code {
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
            KeyCode::Char('e') => self.sections_open = !self.sections_open,
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
                let (tokens, langfuse) = (self.tokens, self.langfuse);
                *self = CostsView {
                    by,
                    window,
                    sections_open: open,
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

    /// The folds' keys: `K` opens or folds the keys under the pool, `u` where the tokens go, `U`
    /// switches its window, `l` opens or folds what Langfuse sees. None leaves the key to `key`;
    /// Some carries the section to scroll to (a fold that opened), or None for one that shut.
    pub fn fold(
        &mut self,
        code: KeyCode,
        t: Option<&hub_core::tokens::Tokens>,
        keys: Option<&Keys>,
    ) -> Option<Option<&'static str>> {
        if self.typing.is_some() {
            return None;
        }
        if code == KeyCode::Char('K') {
            self.keys = Some(!keys_open(keys?, self.keys));
            return Some(None);
        }
        let t = t?;
        match code {
            KeyCode::Char('u') => {
                let open = !self.tokens.is_open(Some(t));
                self.tokens.open = Some(open);
                Some(open.then_some("tokens"))
            }
            KeyCode::Char('U') => {
                self.tokens.day = !self.tokens.day;
                Some(None)
            }
            KeyCode::Char('l') => {
                let open = !tokens::langfuse_open(t, self.langfuse);
                self.langfuse = Some(open);
                Some(open.then_some("langfuse"))
            }
            _ => None,
        }
    }

    pub fn board(&self, c: &Costs) -> Board {
        let dir = if self.asc { "asc" } else { "desc" };
        let sdir = if self.sasc { "asc" } else { "desc" };
        costs::board(
            c,
            self.by,
            self.window,
            &self.q,
            &self.sort,
            dir,
            (&self.ssort, sdir),
        )
    }

    /// The page, and where each of its sections starts (layout.rs's Costs sections, for `seek`).
    pub fn lines(
        &self,
        c: &Costs,
        p: Palette,
        now: i64,
        w: usize,
    ) -> (Vec<Line<'static>>, Vec<(&'static str, usize)>) {
        let b = self.board(c);
        let mut out = burn(&b.burn, self.keys, p, w);
        let mut at = vec![("burn", 0), ("tokens", out.len())];
        out.extend(tokens::tokens(b.tokens.as_ref(), self.tokens, p, now, w));
        at.push(("langfuse", out.len()));
        out.extend(tokens::langfuse(b.tokens.as_ref(), self.langfuse, p, w));
        if b.tokens.is_some() {
            out.push(Line::raw(""));
        }
        at.push(("sections", out.len()));
        out.extend(sections(&b.sections, self.sections_open, p, w));
        at.push(("totals", out.len()));
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
        out.push(clip_line(Line::from(tiles(&b, p)), w));
        out.push(clip_line(Line::from(direct(&b, p)), w));
        out.push(clip_line(Line::from(sources(&b, p)), w));
        for e in &b.errors {
            out.push(clip_line(Line::styled(e.clone(), p.warn()), w));
        }
        if let Some(note) = b.unpriced {
            out.push(clip_line(Line::styled(note, p.warn()), w));
        }
        at.push(("table", out.len()));
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
                costs::usd(Some(b.shown_usd).filter(|_| b.unpriced.is_none()))
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
            out.extend(table(&b, p, w));
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
        (out, at)
    }
}

/// The Burn section, first on the tab: the headline coloured by `level`, the drip and its hold
/// badge, when each account is back on pace, and one row per source claude-acct reads.
/// Amber starts open (dashboards rule 4); the reader's `K` wins after that.
fn keys_open(k: &Keys, set: Option<bool>) -> bool {
    set.unwrap_or(k.level != "ok")
}

/// Cells of the usage bar, brackets apart.
const BAR_CELLS: usize = 10;

fn burn(b: &Burn, keys_set: Option<bool>, p: Palette, w: usize) -> Vec<Line<'static>> {
    let dim = |s: &str| Span::styled(s.to_string(), p.dim());
    if b.accounts.is_empty() {
        return vec![clip_line(
            Line::from(vec![dim("BURN  "), Span::raw("no data from claude-acct")]),
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
            format!("   dispatch held -> {}", burn::HOLD_BADGE),
            p.warn(),
        ));
    }
    let mut out = vec![
        clip_line(
            Line::from(vec![dim("BURN  "), Span::styled(b.head.clone(), style)]),
            w,
        ),
        clip_line(Line::from(drip), w),
        clip_line(
            Line::from(vec![dim("BACK ON PACE  "), Span::raw(b.pace_text(&time))]),
            w,
        ),
    ];
    // A source with no figures has a line of its own, so its words do not widen the columns.
    let note = |a: &&Account| {
        let (text, style) = match a.state {
            "unreadable" => ("usage unreadable", p.bad()),
            "stale" => (burn::STALE_NOTE, p.bad()),
            "idle" => (burn::idle_note(&a.kind), p.dim()),
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
    let (top, nested): (Vec<&Account>, Vec<&Account>) = b.accounts.iter().partition(|a| !a.nested);
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
                costs::usd(a.cost_24h).into(),
            ]
        })
        .collect::<Vec<_>>();
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
            // The 5h window and the day's dollars were Fleet's accounts table's; $24H goes first.
            keep: vec![0, 7, 4, 1, 8, 9, 2, 14, 10, 11, 3, 5, 6, 12, 13, 15, 16],
            right: vec![2, 4, 5, 6, 8, 9, 14, 16],
            ..Default::default()
        }
        .fit(w, p.head()),
    );
    out.extend(top.iter().filter_map(note));
    if let Some(k) = &b.keys {
        let open = keys_open(k, keys_set);
        let head = if k.level == "ok" { p.dim() } else { p.warn() };
        out.push(clip_line(
            Line::from(vec![
                dim(if open { "- KEYS  " } else { "+ KEYS  " }),
                Span::styled(k.head.clone(), head),
                dim("   K folds"),
            ]),
            w,
        ));
        if open {
            let rows = nested
                .iter()
                .filter(has_figures)
                .map(|a| {
                    vec![
                        name(a),
                        a.live.to_string().into(),
                        usage(a),
                        a.used_text.clone().into(),
                        pc(a.reserve).into(),
                        room(a),
                        a.resets.map_or("-".into(), time).into(),
                        costs::usd(a.cost_24h).into(),
                    ]
                })
                .collect::<Vec<_>>();
            out.extend(
                Table {
                    header: vec![
                        "SOURCE", "LIVE", "BAR", "USED", "RESERVE", "ROOM", "RESETS", "$24H",
                    ],
                    rows,
                    keep: vec![0, 5, 3, 1, 6, 4, 7, 2],
                    right: vec![1, 3, 4, 7],
                    ..Default::default()
                }
                .fit(w, p.head()),
            );
            out.extend(nested.iter().filter_map(note));
        }
    }
    out.push(clip_line(
        Line::styled(
            "BURN/H: last 6h rate per session. KEEPS/H: what the week can carry. BAR: use, | is the week gone.",
            p.dim(),
        ),
        w,
    ));
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

/// The window's spend from the outcomes rows, then what Prometheus says now.
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
        s.push(Span::raw(format!("{}  ", costs::usd(Some(t.usd)))));
    }
    s.push(Span::styled("LIVE 24H ", p.dim()));
    s.push(Span::raw(format!("{}  ", costs::usd(b.live.claude_24h))));
    s
}

/// Direct Lazer use with what it cannot see beside it, so a low figure never reads as all of it.
fn direct(b: &Board, p: Palette) -> Vec<Span<'static>> {
    let d = &b.direct;
    let mut s = vec![
        Span::styled("DIRECT ", p.dim()),
        Span::raw(costs::usd(Some(d.usd))),
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
        let when = src
            .as_of
            .map_or("never".into(), |t| crate::fmt::clock(t, b.at));
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
pub fn show(l: &costs::Line, col: &str, now: i64) -> String {
    use hub_core::table::Row;
    match col {
        "cost" => costs::usd(Some(l.cost)),
        "per_pr" => costs::usd(l.per_pr),
        "tokens" => costs::tokens(l.tokens),
        "share" => format!("{:.0}%", l.share * 100.0),
        "landed" => l.landed.map_or("-".into(), |x| format!("{x:.2}")),
        "at" => crate::hometab::age(l.at, now),
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
                        show(l, c, b.at)
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
        "sessions", "calls", "tokens", "cost", "share", "landed", "redo", "reverts", "per_pr", "at",
    ];
    // The key column and its cost never drop; the evaluation goes before the share.
    let order = [
        "session", "tool", "kind", "project", "harness", "model", "runner", "cost", "landed",
        "per_pr", "sessions", "calls", "share", "tokens", "redo", "reverts", "src", "pr", "at",
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
            ("pr", 22),
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
    use hub_core::costs::{Eval, Spent};

    fn costs() -> Costs {
        let s = |id: &str, h: &str, m: &str, usd: f64| Spent {
            session_id: id.into(),
            project: "dotfiles".into(),
            harness: Some(h.into()),
            kind: Some("human".into()),
            models: vec![m.into()],
            cost_usd: Some(usd),
            updated_epoch: Some(1_000_000 - 60),
            ..Spent::default()
        };
        Costs {
            at: 1_000_000,
            sessions: vec![
                s("aaaaaaaa1", "claude", "claude-opus-5-5", 12.5),
                s("bbbbbbbb2", "codex", "gpt-5.6-sol", 3.0),
            ],
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
        let drip = hub_core::burn::Drip {
            hour: 15,
            day: 349,
            held: Some("fleet-assess says HOLD".into()),
        };
        Costs {
            burn: burn::build(&all, Some(0.116), drip, 1_000_000),
            ..costs()
        }
    }

    #[test]
    fn the_burn_section_leads_and_fits_80_columns() {
        let s = CostsView::default()
            .lines(&burning(), Palette::default(), 1_000_000, 80)
            .0
            .iter()
            .map(crate::fit::plain)
            .collect::<Vec<_>>()
            .join("\n");
        assert!(s.lines().all(|l| l.chars().count() <= 80), "{s}");
        let first = s.lines().next().unwrap();
        assert!(
            first.starts_with("BURN  4.5 pts/h vs 1.4 sustainable, 3.3x OVER, 39 live"),
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
            s.find("BURN").unwrap() < s.find("window:").unwrap(),
            "burn is above the spend tiles"
        );
    }

    #[test]
    fn a_burn_row_carries_the_five_hour_window_and_the_days_dollars() {
        let at = |w| {
            CostsView::default()
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
        v.open("langfuse");
        v.open("burn");
        assert_eq!(
            (v.langfuse, v.q.as_str()),
            (Some(true), ""),
            "a section is no query"
        );
        let (l, at) = v.lines(&c, Palette::default(), 1_000_000, 100);
        let l: Vec<String> = l.iter().map(crate::fit::plain).collect();
        let names: Vec<&str> = at.iter().map(|a| a.0).collect();
        assert_eq!(
            names,
            hub_core::layout::resolve("costs").unwrap().sections,
            "every Costs section has its anchor, in the layout's order"
        );
        let line = |sec| l[at.iter().find(|a| a.0 == sec).unwrap().1].as_str();
        assert!(line("burn").starts_with("BURN"), "{l:#?}");
        assert!(
            line("tokens").starts_with("- WHERE THE TOKENS GO"),
            "{l:#?}"
        );
        assert!(
            line("langfuse").starts_with("- WHAT LANGFUSE SEES"),
            "{l:#?}"
        );
        assert!(line("totals").starts_with("window:"), "{l:#?}");
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
    fn sections_are_a_headline_until_e_opens_them_then_all_prs_leads_both_caveats_show() {
        let mut v = CostsView::default();
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
        assert!(
            at("SECTIONS") < at("window:"),
            "under Burn, above the spend"
        );
    }

    #[test]
    fn t_sorts_the_sections_by_each_column_and_t_flips_it() {
        let mut v = CostsView::default();
        v.key(KeyCode::Char('e'));
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
        let s = screen(&CostsView::default(), 80);
        assert!(s.starts_with("BURN  no data from claude-acct"), "{s}");
        assert!(s.contains("window:"), "{s}");
    }

    fn screen(v: &CostsView, w: usize) -> String {
        v.lines(&costs(), Palette::default(), 1_000_000, w)
            .0
            .iter()
            .map(crate::fit::plain)
            .collect::<Vec<_>>()
            .join("\n")
    }

    #[test]
    fn the_model_cut_fits_80_columns_with_its_evaluation() {
        let s = screen(&CostsView::default(), 80);
        assert!(s.lines().all(|l| l.chars().count() <= 80), "{s}");
        assert!(s.contains("[model]") && s.contains("[7d]"), "{s}");
        assert!(s.contains("LANDED") && s.contains("0.75"), "{s}");
        assert!(s.contains("opus-5-5") && s.contains("$12.50"), "{s}");
    }

    #[test]
    fn the_direct_line_shows_what_direct_cannot_see_and_the_pool_is_no_tile() {
        let mut c = costs();
        c.sessions.push(Spent {
            session_id: "oc-direct".into(),
            harness: Some("opencode".into()),
            provider: Some("lazer".into()),
            cost_usd: Some(0.0),
            tokens_total: Some(900.0),
            updated_epoch: Some(c.at - 60),
            ..Spent::default()
        });
        let s = CostsView::default()
            .lines(&c, Palette::default(), 1_000_000, 80)
            .0
            .iter()
            .map(crate::fit::plain)
            .collect::<Vec<_>>()
            .join("\n");
        assert!(s.lines().all(|l| l.chars().count() <= 80), "{s}");
        let direct = s.lines().find(|l| l.starts_with("DIRECT")).unwrap();
        assert!(direct.contains("$0.00 +1 unpriced"), "{s}");
        assert!(direct.ends_with(hub_core::costs::DIRECT_NOTE), "{s}");
        // the pool and its keys are Burn rows now, never a line of their own
        assert!(
            !s.lines()
                .any(|l| l.starts_with("LAZER") || l.starts_with("GLM") || l.contains("RESERVE $")),
            "{s}"
        );
        let s = screen(&CostsView::default(), 80);
        assert!(!s.contains("unpriced"), "{s}");
    }

    #[test]
    fn the_keys_fold_under_their_pool_and_k_opens_them_in_80_columns() {
        let mut all = vec![];
        for (n, kind, used) in [
            ("lazer", "litellm-team", 90.0),
            ("glm", "litellm-key", 96.0),
        ] {
            for (k, v) in [("week_used_percent", used), ("paced", 0.0)] {
                let mut s = series(n, k, v);
                s.labels.insert("kind".into(), kind.into());
                all.push(s);
            }
        }
        let mut parent = series("glm", "parent", 1.0);
        parent.labels.insert("kind".into(), "litellm-key".into());
        parent.labels.insert("parent".into(), "lazer".into());
        all.push(parent);
        let mut age = series("", "textfile_age_seconds", 120.0);
        age.labels.remove("account");
        all.push(age);
        let c = Costs {
            burn: burn::build(&all, None, Default::default(), 1_000_000),
            ..costs()
        };
        let screen = |v: &CostsView, w: usize| {
            v.lines(&c, Palette::default(), 1_000_000, w)
                .0
                .iter()
                .map(crate::fit::plain)
                .collect::<Vec<_>>()
        };
        let mut v = CostsView::default();
        let shut = screen(&v, 200);
        assert!(
            shut.iter().any(|l| l.starts_with("lazer")),
            "the pool is a row: {shut:?}"
        );
        assert!(
            !shut.iter().any(|l| l.starts_with("glm")),
            "the key is not: {shut:?}"
        );
        assert!(
            shut.iter()
                .any(|l| l.starts_with("+ KEYS  1 in lazer, 0 live, tightest glm 96%")),
            "{shut:?}"
        );
        assert_eq!(
            v.fold(KeyCode::Char('K'), None, c.burn.keys.as_ref()),
            Some(None),
            "K works with no tokens snapshot"
        );
        let open = screen(&v, 200);
        let row = open.iter().find(|l| l.starts_with("glm")).unwrap();
        assert!(
            row.contains("[##########]") && !row.contains('|'),
            "a dollar budget has no tick: {row}"
        );
        assert!(open.iter().any(|l| l.starts_with("- KEYS")), "{open:?}");
        assert!(
            screen(&v, 80).iter().all(|l| l.chars().count() <= 80),
            "the open fold fits"
        );
    }

    #[test]
    fn a_warn_fold_starts_open_and_k_still_folds_it() {
        let k = Keys {
            head: "1 in lazer".into(),
            level: "warn",
        };
        assert!(keys_open(&k, None));
        assert!(!keys_open(&k, Some(false)));
        let quiet = Keys { level: "ok", ..k };
        assert!(!keys_open(&quiet, None), "negative control");
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
            burn: burn::build(&all, None, Default::default(), 1_000_000),
            ..costs()
        };
        let wide = CostsView::default()
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
