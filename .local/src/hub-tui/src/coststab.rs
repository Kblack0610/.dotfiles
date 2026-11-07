//! The Costs tab: `hub_core::costs::board`, the same view agent-web draws. `b`/`B` step the cut,
//! `w` the window, `/` types the query (the shared table's grammar), `s` sorts by the cut's next
//! column, `S` flips it, `x` clears; `o` opens the Grafana trends.

use hub_core::costs::{self, Board, Costs};
use hub_core::table::Val;
use ratatui::crossterm::event::KeyCode;
use ratatui::text::{Line, Span};

use crate::fit::{cell, clip_line, Cell, Table};
use crate::fmt::Palette;

pub struct CostsView {
    pub by: &'static str,
    pub window: &'static str,
    pub q: String,
    /// One of the cut's columns, or empty for its own order (the costliest first).
    pub sort: String,
    pub asc: bool,
    pub typing: Option<String>,
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
        self.typing.is_none() && self.q.is_empty() && self.sort.is_empty() && !self.asc
    }

    /// `hub --tab costs --q '<words>'`: a cut or window name sets it, `key=value` sets `by`, `w`
    /// or `q`, and any other word joins the query.
    pub fn open(&mut self, arg: &str) {
        let mut q = vec![];
        for word in arg.split(['&', ' ']).filter(|w| !w.is_empty()) {
            let (k, v) = word.split_once('=').unwrap_or(("", word));
            match k {
                "by" => self.by = costs::cut(v),
                "w" => self.window = costs::window(v).0,
                "q" => q.push(v.to_string()),
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
            KeyCode::Char('x') => {
                let (by, window) = (self.by, self.window);
                *self = CostsView {
                    by,
                    window,
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

    pub fn board(&self, c: &Costs) -> Board {
        let dir = if self.asc { "asc" } else { "desc" };
        costs::board(c, self.by, self.window, &self.q, &self.sort, dir)
    }

    pub fn lines(&self, c: &Costs, p: Palette, w: usize) -> Vec<Line<'static>> {
        let b = self.board(c);
        let mut out = vec![];
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
        out.push(clip_line(Line::from(sources(&b, p)), w));
        for e in &b.errors {
            out.push(clip_line(Line::styled(e.clone(), p.warn()), w));
        }
        if let Some(note) = b.unpriced {
            out.push(clip_line(Line::styled(note, p.warn()), w));
        }
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
        out
    }
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
    s.push(Span::styled("LAZER ", p.dim()));
    let pool = match (b.live.lazer_spend, b.live.lazer_budget) {
        (Some(sp), Some(cap)) if cap > 0.0 => format!(
            "{} of {} ({:.0}%)",
            costs::usd(Some(sp)),
            costs::usd(Some(cap)),
            sp / cap * 100.0
        ),
        (sp, _) => costs::usd(sp),
    };
    s.push(Span::raw(pool));
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

    fn screen(v: &CostsView, w: usize) -> String {
        v.lines(&costs(), Palette::default(), w)
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
