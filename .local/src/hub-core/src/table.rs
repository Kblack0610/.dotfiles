//! The one filter and sort model behind every data table on both surfaces (docs/dashboards.md
//! rule 7). A table's row type says what its columns and state chips are ([`Row`]); a [`View`]
//! holds what the human asked for: the query, the state chip, the sort column and its
//! direction. agent-web applies it on the server and sends the [`Summary`], so the page only
//! draws; the hub TUI applies it in place. Neither surface decides what a query means.
//!
//! The query: whitespace-separated terms, all of which must hold. `key:value` matches that
//! column, and the same key repeated means any of them (`source:unity source:k8s`). `-key:value`
//! excludes, `-word` excludes text. A bare word matches the row's text. Values match without
//! case, `key:value` by prefix (`key:=value` the whole value, for one record by its id) and a
//! word anywhere in the text; `key:"two words"` quotes. A key
//! that is not one of the table's columns is read as a bare word, so `http://x` still searches.

use std::cmp::Ordering;
use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};

use crate::links::Link;

/// A row's value in one column: what `key:value` matches and what the sort orders.
#[derive(Debug, Clone, PartialEq)]
pub enum Val {
    Text(String),
    Num(f64),
    /// No value; such a row sorts last in either direction.
    None,
}

/// A reading that may be missing: a missing one sorts last (`Val::None`).
impl From<Option<f64>> for Val {
    fn from(v: Option<f64>) -> Self {
        v.map_or(Val::None, Val::Num)
    }
}

impl Val {
    /// The cell as a surface draws it: text as written, a whole number without its `.0`.
    pub fn shown(&self) -> Option<String> {
        match self {
            Val::Text(t) => Some(t.clone()),
            Val::Num(n) if n.fract() == 0.0 => Some(format!("{n:.0}")),
            Val::Num(n) => Some(n.to_string()),
            Val::None => None,
        }
    }

    /// The lower-case text a `key:value` term matches by prefix.
    fn text(&self) -> Option<String> {
        match self {
            Val::Text(t) => Some(t.to_lowercase()),
            Val::Num(n) => Some(n.to_string()),
            Val::None => None,
        }
    }

    /// `apply` lower-cases a text sort key once, so two texts compare as they are.
    fn cmp(&self, o: &Val) -> Ordering {
        match (self, o) {
            (Val::Num(a), Val::Num(b)) => a.total_cmp(b),
            (Val::Text(a), Val::Text(b)) => a.cmp(b),
            _ => self.text().cmp(&o.text()),
        }
    }
}

/// A row of a table this module filters and sorts.
pub trait Row {
    /// The column keys in display order. Each is what the query, the sort and the URL name.
    const COLUMNS: &'static [&'static str];
    /// The state chips; the first is the view a table opens on, and keeps the rows `in_default` does.
    const STATES: &'static [&'static str];
    /// The columns whose values the web offers as dropdowns, each value a `key:value` term.
    const FACETS: &'static [&'static str];
    /// A chip no row is under is left out, unless it is the one in force: for a table with
    /// more kinds than usually have a row.
    const HIDE_EMPTY: bool = false;
    /// The column a phone row leads with, full width and wrapping. Empty keeps the plain table.
    const LEAD: &'static str = "";
    /// The few columns under the lead on a phone; the rest wait for a tap.
    const GLANCE: &'static [&'static str] = &[];
    /// What a state word the rows show means, one `(word, meaning)` per state (`hub_core::vocab`):
    /// a line under the TUI chips, a tile's hover on the web (`Chip::means`). Empty draws none.
    const LEGEND: &'static [(&'static str, &'static str)] = &[];
    /// A state word whose hue on this table differs from `vocab::tone`'s, one `(word, level)` each:
    /// Fleet's held runner is stopped (red) where a held Queue item only waits (amber).
    const TONES: &'static [(&'static str, crate::vocab::Level)] = &[];

    fn val(&self, col: &str) -> Val;
    /// Whether the row is under the chip `state`, one of `STATES` past the first.
    fn in_state(&self, state: &str) -> bool;
    /// Whether the first chip, the view the table opens on, keeps the row: every row, unless the
    /// table opens on less (Queue's `active` leaves done out, one chip away).
    fn in_default(&self) -> bool {
        true
    }
    /// What a bare word searches: every text column unless the table says otherwise.
    fn text(&self) -> String {
        Self::COLUMNS
            .iter()
            .filter_map(|c| match self.val(c) {
                Val::Text(t) => Some(t),
                _ => None,
            })
            .collect::<Vec<_>>()
            .join("\n")
            .to_lowercase()
    }
    /// What a `col:value` term tries, any of which will do: a column with many values at once
    /// (a row's tags) lists them here.
    fn vals(&self, col: &str) -> Vec<Val> {
        vec![self.val(col)]
    }
    /// What the sort orders `col` by, when that is not what it shows (`urgent` above `high`).
    fn rank(&self, col: &str) -> Val {
        self.val(col)
    }
    /// The record `col` names, which both surfaces open from that cell (`hub_core::links`).
    fn link(&self, _col: &str) -> Option<Link> {
        None
    }
}

/// A table over rows borrowed from a longer list: a surface narrows to its scope first (one
/// project's rows) and hands the references to the view.
impl<T: Row> Row for &T {
    const COLUMNS: &'static [&'static str] = T::COLUMNS;
    const STATES: &'static [&'static str] = T::STATES;
    const FACETS: &'static [&'static str] = T::FACETS;
    const LEAD: &'static str = T::LEAD;
    const GLANCE: &'static [&'static str] = T::GLANCE;
    const LEGEND: &'static [(&'static str, &'static str)] = T::LEGEND;
    const TONES: &'static [(&'static str, crate::vocab::Level)] = T::TONES;

    fn val(&self, col: &str) -> Val {
        (*self).val(col)
    }
    fn in_state(&self, state: &str) -> bool {
        (*self).in_state(state)
    }
    fn in_default(&self) -> bool {
        (*self).in_default()
    }
    fn text(&self) -> String {
        (*self).text()
    }
    fn vals(&self, col: &str) -> Vec<Val> {
        (*self).vals(col)
    }
    fn rank(&self, col: &str) -> Val {
        (*self).rank(col)
    }
    fn link(&self, col: &str) -> Option<Link> {
        (*self).link(col)
    }
}

#[derive(Serialize, Deserialize, Clone, Copy, Debug, Default, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum Dir {
    /// Biggest or newest first, what a header's first click gives.
    #[default]
    Desc,
    Asc,
}

/// What the human asked of one table. Blank `state` and `sort` are the first chip and the
/// table's own order. Built with [`View::new`], which drops a chip or column the table does
/// not have, so a stale link shows everything rather than nothing.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct View {
    pub q: String,
    pub state: String,
    pub sort: String,
    pub dir: Dir,
}

/// One term of a query, as typed (`raw`) and as read.
#[derive(Debug, Clone, PartialEq)]
struct Term {
    raw: String,
    neg: bool,
    /// A column of the table, or None for a bare word.
    key: Option<&'static str>,
    /// `key:=value`: the whole value, not a prefix of it.
    exact: bool,
    value: String,
}

/// The query split into terms; whitespace inside double quotes does not split.
fn tokens(q: &str) -> Vec<String> {
    let mut out = vec![];
    let mut cur = String::new();
    let mut quoted = false;
    for c in q.chars() {
        match c {
            '"' => {
                quoted = !quoted;
                cur.push(c);
            }
            c if c.is_whitespace() && !quoted => {
                if !cur.is_empty() {
                    out.push(std::mem::take(&mut cur));
                }
            }
            c => cur.push(c),
        }
    }
    if !cur.is_empty() {
        out.push(cur);
    }
    out
}

fn terms<R: Row>(q: &str) -> Vec<Term> {
    tokens(q)
        .into_iter()
        .filter_map(|raw| {
            let body = raw.strip_prefix('-').filter(|b| !b.is_empty());
            let neg = body.is_some();
            let body = body.unwrap_or(&raw);
            let (key, value) = match body.split_once(':') {
                Some((k, v)) => match R::COLUMNS.iter().find(|c| c.eq_ignore_ascii_case(k)) {
                    Some(c) => (Some(*c), v),
                    None => (None, body),
                },
                None => (None, body),
            };
            let (exact, value) = match value.strip_prefix('=').filter(|_| key.is_some()) {
                Some(v) => (true, v),
                None => (false, value),
            };
            let value = value.trim_matches('"').to_lowercase();
            (!value.is_empty() && value != "-").then(|| Term {
                raw: raw.clone(),
                neg,
                key,
                exact,
                value,
            })
        })
        .collect()
}

/// `rest` (a query with no term on `key`) and `key` set to `value`.
fn joined(rest: &str, key: &str, value: &str) -> String {
    let t = term(key, value);
    if rest.is_empty() {
        t
    } else {
        format!("{rest} {t}")
    }
}

/// A term with this value for `key`, quoted when it holds whitespace.
fn term(key: &str, value: &str) -> String {
    if value.chars().any(char::is_whitespace) {
        format!("{key}:\"{value}\"")
    } else {
        format!("{key}:{value}")
    }
}

impl Term {
    fn hits<R: Row>(&self, r: &R, text: &mut Option<String>) -> bool {
        match self.key {
            Some(k) => r.vals(k).iter().any(|v| {
                v.text().is_some_and(|t| {
                    if self.exact {
                        t == self.value
                    } else {
                        t.starts_with(&self.value)
                    }
                })
            }),
            None => text.get_or_insert_with(|| r.text()).contains(&self.value),
        }
    }
}

/// Whether the terms keep `r`: every bare word and exclusion holds, and each key has a value
/// that matches.
fn keeps<R: Row>(ts: &[Term], r: &R) -> bool {
    let mut text = None;
    ts.iter().all(|t| match t.key {
        Some(k) if !t.neg => ts
            .iter()
            .any(|u| !u.neg && u.key == Some(k) && u.hits(r, &mut text)),
        _ => t.hits(r, &mut text) != t.neg,
    })
}

/// A state chip and how many rows the query leaves under it, with its hue while it holds any
/// row (`vocab::tone`; a chip at zero is plain) and what its word means when the table's
/// legend defines it (`Row::LEGEND`).
#[derive(Serialize, Debug, Clone, PartialEq)]
pub struct Chip {
    pub name: &'static str,
    pub n: usize,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub tone: Option<crate::vocab::Level>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub means: Option<&'static str>,
}

/// A column header: whether it is the sort, and the sort a click on it gives.
#[derive(Serialize, Debug, Clone, PartialEq)]
pub struct Column {
    pub key: &'static str,
    pub sort: Option<Dir>,
    pub next_sort: String,
    pub next_dir: Dir,
    /// How a phone draws it: `lead`, `glance`, or empty for a column that waits for a tap.
    pub role: &'static str,
}

/// One table's phone layout: what the render harness draws its fixtures with.
#[derive(Serialize, Debug)]
pub struct PhoneTable {
    pub columns: &'static [&'static str],
    pub lead: &'static str,
    pub glance: &'static [&'static str],
}

/// How a phone draws the column `key` of a table with this lead and glance.
pub fn role_of(key: &str, lead: &str, glance: &[&str]) -> &'static str {
    if key == lead {
        "lead"
    } else if glance.contains(&key) {
        "glance"
    } else {
        ""
    }
}

fn phone_table<R: Row>() -> PhoneTable {
    PhoneTable {
        columns: R::COLUMNS,
        lead: R::LEAD,
        glance: R::GLANCE,
    }
}

/// Every table that names a phone layout, each Costs cut being one of its own.
pub fn phone_tables() -> Vec<PhoneTable> {
    let cuts = crate::costs::CUTS.iter().map(|cut| {
        let columns = crate::costs::columns(cut);
        PhoneTable {
            columns,
            lead: columns[0],
            glance: crate::costs::CUT_GLANCE,
        }
    });
    let rows = [
        phone_table::<crate::home::Need>(),
        phone_table::<crate::home::Running>(),
        phone_table::<crate::proposals::Proposal>(),
        phone_table::<crate::queue::QueueRow<'static>>(),
        phone_table::<crate::queue::Candidate>(),
        phone_table::<crate::tasks::Row>(),
        phone_table::<crate::projects::Card>(),
        phone_table::<crate::deliverables::Deliverable>(),
        phone_table::<crate::session_table::SessionRow>(),
        phone_table::<crate::jobs::Job>(),
        phone_table::<crate::actions::Action>(),
        phone_table::<crate::alerts::Alert>(),
        phone_table::<crate::fleet::runner::Watch>(),
        phone_table::<crate::fleet::who::Who>(),
        phone_table::<crate::fleet::AskVerdict>(),
        phone_table::<crate::schedules::Schedule>(),
        phone_table::<crate::releases::App>(),
        phone_table::<crate::builds::Run>(),
        phone_table::<crate::pipelines::Pipeline>(),
        phone_table::<crate::junit::Suite>(),
        phone_table::<crate::junit::Case>(),
        phone_table::<crate::quarantine::Entry>(),
        phone_table::<crate::sections::Section>(),
        phone_table::<crate::spend_history::SessRow>(),
        phone_table::<crate::worklog::Work>(),
        phone_table::<crate::machines::Machine>(),
        phone_table::<crate::machines::Pool>(),
        phone_table::<crate::ci::Slot>(),
        phone_table::<crate::ci::Queued>(),
        phone_table::<crate::ci::LocalFail>(),
    ];
    rows.into_iter().chain(cuts).collect()
}

/// One dropdown value: how many rows it adds, whether it is ticked, and the whole query a
/// tick on it gives (it joins the column's picks, or leaves them).
#[derive(Serialize, Debug, Clone, PartialEq)]
pub struct FacetValue {
    pub value: String,
    pub n: usize,
    pub on: bool,
    pub q: String,
}

/// A dropdown over one column: the values picked (the query's terms on it, which OR), the
/// query with that column's terms taken out, and every value in the rows.
#[derive(Serialize, Debug, Clone, PartialEq)]
pub struct Facet {
    pub key: &'static str,
    pub on: Vec<String>,
    pub clear: String,
    pub values: Vec<FacetValue>,
}

/// Everything a surface needs to draw a table's controls, sent to the web beside the rows.
#[derive(Serialize, Debug, Clone, PartialEq)]
pub struct Summary {
    pub q: String,
    pub state: String,
    pub sort: String,
    pub dir: Dir,
    pub total: usize,
    pub shown: usize,
    pub states: Vec<Chip>,
    pub columns: Vec<Column>,
    pub facets: Vec<Facet>,
    /// Row i of the rows sent beside it: each column that names a record and that record's href
    /// ([`links`]). Absent when no row links anything. A surface that reshapes the rows after the
    /// view (Fleet's folds) sends `links` of what it reshaped to.
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub links: Vec<BTreeMap<&'static str, String>>,
    /// `Row::LEGEND` as one line ([`legend`]); absent when the table has none.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub legend: Option<String>,
}

/// `ready: starts when ...; held: waits on ...`: the TUI's line under the chips, the web search box's hover.
pub fn legend<R: Row>() -> Option<String> {
    let parts: Vec<String> = R::LEGEND.iter().map(|(w, m)| format!("{w}: {m}")).collect();
    (!parts.is_empty()).then(|| parts.join("; "))
}

/// Each row's linked columns with their hrefs, in the rows' order; empty when none links.
pub fn links<R: Row>(rows: &[&R]) -> Vec<BTreeMap<&'static str, String>> {
    let out: Vec<BTreeMap<&'static str, String>> = rows
        .iter()
        .map(|r| {
            R::COLUMNS
                .iter()
                .filter_map(|c| r.link(c).map(|l| (*c, l.href())))
                .collect()
        })
        .collect();
    if out.iter().all(BTreeMap::is_empty) {
        vec![]
    } else {
        out
    }
}

/// One table's view keys as a request names them (`q`, `s`, `sort`, `dir`), for a function that
/// builds a board holding a second table, which a surface reads under its own prefixed keys.
#[derive(Debug, Clone, Copy, Default)]
pub struct Keys<'a> {
    pub q: &'a str,
    pub s: &'a str,
    pub sort: &'a str,
    pub dir: &'a str,
}

impl Keys<'_> {
    /// The view of an `R` table these keys ask for ([`View::new`]).
    pub fn view<R: Row>(&self) -> View {
        View::new::<R>(self.q, self.s, self.sort, self.dir)
    }
}

impl View {
    /// A view of an `R` table; a chip or sort column `R` does not have is dropped, and any
    /// direction but `asc` is descending.
    pub fn new<R: Row>(q: &str, state: &str, sort: &str, dir: &str) -> View {
        let pick = |list: &[&str], v: &str| {
            list.iter()
                .find(|x| x.eq_ignore_ascii_case(v))
                .map_or(String::new(), |x| x.to_string())
        };
        let mut state = pick(R::STATES, state);
        if R::STATES.first().is_some_and(|f| *f == state) {
            state.clear();
        }
        View {
            q: q.trim().to_string(),
            state,
            sort: pick(R::COLUMNS, sort),
            dir: if dir.eq_ignore_ascii_case("asc") {
                Dir::Asc
            } else {
                Dir::Desc
            },
        }
    }

    pub fn is_default(&self) -> bool {
        *self == View::default()
    }

    /// The rows the query and chip keep: in the sort, or in the table's own order without one.
    pub fn apply<'a, R: Row>(&self, rows: &'a [R]) -> Vec<&'a R> {
        let ts = terms::<R>(&self.q);
        let kept = rows.iter().filter(|r| {
            keeps(&ts, *r)
                && if self.state.is_empty() {
                    r.in_default()
                } else {
                    r.in_state(&self.state)
                }
        });
        if self.sort.is_empty() {
            return kept.collect();
        }
        let mut keyed: Vec<(Val, &R)> = kept
            .map(|r| match r.rank(&self.sort) {
                Val::Text(t) => (Val::Text(t.to_lowercase()), r),
                v => (v, r),
            })
            .collect();
        keyed.sort_by(|(a, _), (b, _)| match (a, b) {
            (Val::None, Val::None) => Ordering::Equal,
            (Val::None, _) => Ordering::Greater,
            (_, Val::None) => Ordering::Less,
            _ if self.dir == Dir::Asc => a.cmp(b),
            _ => b.cmp(a),
        });
        keyed.into_iter().map(|(_, r)| r).collect()
    }

    /// Each state chip's count under the query; the chip in force does not narrow the others.
    pub fn states<R: Row>(&self, rows: &[R]) -> Vec<Chip> {
        let ts = terms::<R>(&self.q);
        let kept: Vec<&R> = rows.iter().filter(|r| keeps(&ts, *r)).collect();
        R::STATES
            .iter()
            .enumerate()
            .map(|(i, s)| {
                let n = if i == 0 {
                    kept.iter().filter(|r| r.in_default()).count()
                } else {
                    kept.iter().filter(|r| r.in_state(s)).count()
                };
                Chip {
                    name: s,
                    n,
                    tone: if n > 0 {
                        crate::vocab::tone(R::TONES, s)
                    } else {
                        None
                    },
                    means: R::LEGEND.iter().find(|(w, _)| w == s).map(|(_, m)| *m),
                }
            })
            .enumerate()
            .filter(|(i, c)| !R::HIDE_EMPTY || *i == 0 || c.n > 0 || c.name == self.state)
            .map(|(_, c)| c)
            .collect()
    }

    /// The query without any term on `key`.
    fn without<R: Row>(&self, key: &str) -> String {
        terms::<R>(&self.q)
            .into_iter()
            .filter(|t| t.key != Some(key))
            .map(|t| t.raw)
            .collect::<Vec<_>>()
            .join(" ")
    }

    /// Each of `R::FACETS` as a multi-pick dropdown. A value's count is what it adds: the rest
    /// of the query and the chip still apply, the column's own terms do not, so the counts hold
    /// still while values are ticked. A value's `q` toggles it among the column's picks, which
    /// OR (a repeated key); the dropdown owns its column's terms, so a tick drops an exclusion
    /// typed on that column.
    pub fn facets<R: Row>(&self, rows: &[R]) -> Vec<Facet> {
        let ts = terms::<R>(&self.q);
        R::FACETS
            .iter()
            .map(|key| {
                let mut on: Vec<String> = vec![];
                for t in ts.iter().filter(|t| t.key == Some(*key) && !t.neg) {
                    if !on.contains(&t.value) {
                        on.push(t.value.clone());
                    }
                }
                let clear = self.without::<R>(key);
                let base = View {
                    q: clear.clone(),
                    ..self.clone()
                };
                let mut counts = std::collections::BTreeMap::<String, usize>::new();
                // Each value a row holds counts once, as the filter matches it (`vals`), so a
                // row in two pools counts under both.
                for r in base.apply(rows) {
                    let mut seen = std::collections::BTreeSet::new();
                    for v in r.vals(key).iter().filter_map(Val::text) {
                        if !v.is_empty() && seen.insert(v.clone()) {
                            *counts.entry(v).or_default() += 1;
                        }
                    }
                }
                // A prefix term (`source:ag`) is its own option, so the dropdown shows what is on.
                let prefixes: Vec<&String> =
                    on.iter().filter(|v| !counts.contains_key(*v)).collect();
                for v in prefixes {
                    let n = counts
                        .iter()
                        .filter(|(k, _)| k.starts_with(v.as_str()))
                        .map(|(_, n)| n)
                        .sum();
                    counts.insert(v.clone(), n);
                }
                let values = counts
                    .into_iter()
                    .map(|(value, n)| {
                        let picked = on.contains(&value);
                        let picks: Vec<&String> = if picked {
                            on.iter().filter(|v| **v != value).collect()
                        } else {
                            on.iter().chain(std::iter::once(&value)).collect()
                        };
                        FacetValue {
                            q: picks.iter().fold(clear.clone(), |q, v| joined(&q, key, v)),
                            on: picked,
                            value,
                            n,
                        }
                    })
                    .collect();
                Facet {
                    key,
                    on,
                    clear,
                    values,
                }
            })
            .collect()
    }

    /// The sort a click on `col`'s header gives: descending, then ascending, then the
    /// table's own order.
    pub fn click(&self, col: &str) -> (String, Dir) {
        if self.sort != col {
            (col.to_string(), Dir::Desc)
        } else if self.dir == Dir::Desc {
            (col.to_string(), Dir::Asc)
        } else {
            (String::new(), Dir::Desc)
        }
    }

    /// The TUI's `f`: the next state chip, back to every row after the last. A table that hides
    /// its empty chips steps with `cycle_shown`, which has the rows.
    pub fn cycle_state<R: Row>(&mut self) {
        debug_assert!(
            !R::HIDE_EMPTY,
            "{} hides empty chips: use cycle_shown",
            R::COLUMNS[0]
        );
        self.state = next_of(&R::STATES[1.min(R::STATES.len())..], &self.state);
    }

    /// `f` over the chips `states` draws for these rows, so a hidden empty chip is never stepped on.
    pub fn cycle_shown<R: Row>(&mut self, rows: &[R]) {
        let shown: Vec<&str> = self.states(rows).iter().skip(1).map(|c| c.name).collect();
        self.state = next_of(&shown, &self.state);
    }

    /// The TUI's `s`: sort by the next column, descending, back to the table's order after the last.
    pub fn cycle_sort<R: Row>(&mut self) {
        self.sort = next_of(R::COLUMNS, &self.sort);
        self.dir = Dir::Desc;
    }

    /// The TUI's `S`: the other direction (a view with no sort has nothing to flip).
    pub fn flip(&mut self) {
        if !self.sort.is_empty() {
            self.dir = match self.dir {
                Dir::Desc => Dir::Asc,
                Dir::Asc => Dir::Desc,
            };
        }
    }

    /// The rows the view keeps and the controls that drew them.
    pub fn summary<'a, R: Row>(&self, rows: &'a [R]) -> (Vec<&'a R>, Summary) {
        let shown = self.apply(rows);
        let columns = R::COLUMNS
            .iter()
            .map(|key| {
                let (next_sort, next_dir) = self.click(key);
                Column {
                    key,
                    sort: (self.sort == *key).then_some(self.dir),
                    next_sort,
                    next_dir,
                    role: role_of(key, R::LEAD, R::GLANCE),
                }
            })
            .collect();
        let s = Summary {
            q: self.q.clone(),
            state: self.state.clone(),
            sort: self.sort.clone(),
            dir: self.dir,
            total: rows.len(),
            shown: shown.len(),
            states: self.states(rows),
            columns,
            facets: self.facets(rows),
            links: links(&shown),
            legend: legend::<R>(),
        };
        (shown, s)
    }
}

/// The value after `cur` in `list`, then blank.
fn next_of(list: &[&str], cur: &str) -> String {
    let after = list.iter().position(|v| *v == cur).map_or(0, |i| i + 1);
    list.get(after).map_or(String::new(), |v| v.to_string())
}

#[cfg(test)]
mod tests {
    #[test]
    fn phone_roles_name_real_columns() {
        for t in super::phone_tables() {
            assert!(t.columns.contains(&t.lead), "lead {}", t.lead);
            assert!(t.glance.len() <= 3, "{} glances at too much", t.lead);
            for g in t.glance {
                assert!(t.columns.contains(g) && *g != t.lead, "glance {g}");
            }
        }
    }

    use super::*;

    struct T {
        name: &'static str,
        project: &'static str,
        kind: &'static str,
        n: Option<f64>,
        live: bool,
    }

    impl Row for T {
        const COLUMNS: &'static [&'static str] = &["name", "project", "kind", "n"];
        const STATES: &'static [&'static str] = &["all", "live", "off"];
        const FACETS: &'static [&'static str] = &["project", "kind"];
        fn val(&self, col: &str) -> Val {
            match col {
                "name" => Val::Text(self.name.into()),
                "project" => Val::Text(self.project.into()),
                "kind" => Val::Text(self.kind.into()),
                "n" => self.n.map_or(Val::None, Val::Num),
                _ => Val::None,
            }
        }
        fn in_state(&self, s: &str) -> bool {
            (s == "live") == self.live
        }
    }

    #[test]
    fn a_table_that_links_nothing_sends_no_links() {
        let (_, t) = View::default().summary(&rows());
        assert!(t.links.is_empty());
        assert!(serde_json::to_value(&t).unwrap().get("links").is_none());
    }

    fn rows() -> Vec<T> {
        let t = |name, project, kind, n, live| T {
            name,
            project,
            kind,
            n,
            live,
        };
        vec![
            t("nightly fix", "playground", "fix", Some(3.0), true),
            t("queue table", "dotfiles", "feat", Some(10.0), false),
            t("hub sort", "dotfiles", "fix", None, true),
            t("ci cost", "platform", "chore", Some(1.5), false),
        ]
    }

    fn names(v: &View) -> Vec<&'static str> {
        v.apply(&rows()).iter().map(|r| r.name).collect()
    }

    fn q(s: &str) -> View {
        View::new::<T>(s, "", "", "")
    }

    #[test]
    fn terms_and_and_a_repeated_key_ors() {
        assert_eq!(names(&q("project:dotfiles kind:fix")), ["hub sort"]);
        assert_eq!(
            names(&q("project:playground project:platform")),
            ["nightly fix", "ci cost"]
        );
        assert_eq!(
            names(&q("project:playground project:dotfiles kind:fix")),
            ["nightly fix", "hub sort"]
        );
    }

    #[test]
    fn a_minus_excludes_and_a_bare_word_searches_the_text() {
        assert_eq!(names(&q("-project:dotfiles")), ["nightly fix", "ci cost"]);
        assert_eq!(names(&q("TABLE")), ["queue table"], "case does not matter");
        assert_eq!(names(&q("-fix")), ["queue table", "ci cost"]);
        assert_eq!(names(&q("dotfiles -sort")), ["queue table"]);
    }

    #[test]
    fn values_match_by_prefix_and_numbers_as_written() {
        assert_eq!(names(&q("project:dot")), ["queue table", "hub sort"]);
        assert_eq!(
            names(&q("project:otfiles")).len(),
            0,
            "a prefix, not anywhere"
        );
        assert_eq!(names(&q("n:10")), ["queue table"]);
        assert_eq!(names(&q("n:1.5")), ["ci cost"]);
        assert_eq!(names(&q("n:1")).len(), 2, "1 is a prefix of 10");
        assert_eq!(names(&q("n:=1")).len(), 0, "= is the whole value");
        assert_eq!(names(&q("n:=10")), ["queue table"]);
        assert_eq!(names(&q("-n:=10")).len(), 3);
    }

    #[test]
    fn an_unknown_key_is_a_word_and_quotes_hold_spaces() {
        assert_eq!(names(&q("owner:x")).len(), 0, "not a column, so the text");
        assert_eq!(names(&q("name:\"nightly fix\"")), ["nightly fix"]);
        assert_eq!(
            names(&q("Project:PLAY")),
            ["nightly fix"],
            "keys ignore case"
        );
        assert_eq!(names(&q("   ")).len(), 4);
        assert_eq!(names(&q("project: -")).len(), 4, "empty terms are dropped");
    }

    #[test]
    fn the_chip_narrows_and_counts_follow_the_query_but_not_the_chip() {
        let v = View::new::<T>("project:dotfiles", "off", "", "");
        assert_eq!(names(&v), ["queue table"]);
        let n: Vec<(&str, usize)> = v.states(&rows()).iter().map(|c| (c.name, c.n)).collect();
        assert_eq!(n, [("all", 2), ("live", 1), ("off", 1)]);
    }

    #[test]
    fn a_sort_goes_both_ways_and_a_row_with_no_value_stays_last() {
        let by = |col: &str, dir: &str| names(&View::new::<T>("", "", col, dir));
        assert_eq!(
            by("n", ""),
            ["queue table", "nightly fix", "ci cost", "hub sort"]
        );
        assert_eq!(
            by("n", "asc"),
            ["ci cost", "nightly fix", "queue table", "hub sort"]
        );
        assert_eq!(
            by("name", "asc"),
            ["ci cost", "hub sort", "nightly fix", "queue table"]
        );
        assert_eq!(
            by("nonsense", "asc"),
            ["nightly fix", "queue table", "hub sort", "ci cost"],
            "an unknown column keeps the table's order"
        );
    }

    #[test]
    fn a_stale_link_shows_everything_rather_than_nothing() {
        let v = View::new::<T>("", "gone", "gone", "sideways");
        assert!(v.is_default());
        assert!(View::new::<T>("", "all", "", "").is_default());
    }

    #[test]
    fn a_header_click_goes_desc_asc_then_default() {
        let mut v = View::default();
        for want in [("n", Dir::Desc), ("n", Dir::Asc), ("", Dir::Desc)] {
            let (s, d) = v.click("n");
            assert_eq!((s.as_str(), d), want);
            v.sort = s;
            v.dir = d;
        }
        v.sort = "name".into();
        assert_eq!(
            v.click("n"),
            ("n".into(), Dir::Desc),
            "another column starts over"
        );
    }

    #[test]
    fn the_tui_keys_cycle_and_come_back_to_the_start() {
        let mut v = View::default();
        v.cycle_state::<T>();
        assert_eq!(v.state, "live");
        v.cycle_state::<T>();
        v.cycle_state::<T>();
        assert!(v.state.is_empty());
        v.flip();
        assert!(v.is_default(), "no sort, nothing to flip");
        for c in T::COLUMNS {
            v.cycle_sort::<T>();
            assert_eq!(v.sort, *c);
        }
        v.flip();
        assert_eq!(v.dir, Dir::Asc);
        v.cycle_sort::<T>();
        assert!(v.is_default());
    }

    #[test]
    fn a_facet_lists_the_values_and_the_query_each_one_picks() {
        let v = q("kind:fix nightly");
        let fs = v.facets(&rows());
        let kind = &fs[1];
        assert_eq!(kind.on, ["fix"]);
        assert_eq!(kind.clear, "nightly");
        let vals: Vec<(&str, usize, bool, &str)> = kind
            .values
            .iter()
            .map(|f| (f.value.as_str(), f.n, f.on, f.q.as_str()))
            .collect();
        assert_eq!(
            vals,
            [("fix", 1, true, "nightly")],
            "a tick on a pick takes it off"
        );
        let project = &fs[0];
        assert!(project.on.is_empty());
        assert_eq!(project.values[0].q, "kind:fix nightly project:playground");
        assert_eq!(joined("", "name", "hub sort"), "name:\"hub sort\"");
    }

    #[test]
    fn a_facet_ticks_several_values_that_or_and_counts_hold_still() {
        let qs = |v: &View, key: &str| -> Vec<(String, usize, bool, String)> {
            let fs = v.facets(&rows());
            let f = fs.iter().find(|f| f.key == key).unwrap();
            f.values
                .iter()
                .map(|x| (x.value.clone(), x.n, x.on, x.q.clone()))
                .collect()
        };
        let one = q("kind:fix");
        let kinds = qs(&one, "kind");
        let s = |a: &str, n, on, q: &str| (a.to_string(), n, on, q.to_string());
        assert_eq!(
            kinds,
            [
                s("chore", 1, false, "kind:fix kind:chore"),
                s("feat", 1, false, "kind:fix kind:feat"),
                s("fix", 2, true, ""),
            ],
            "a tick adds a value beside the pick; counts are the column's own, not narrowed by it"
        );
        let two = q("kind:fix kind:feat");
        assert_eq!(names(&two), ["nightly fix", "queue table", "hub sort"]);
        let fs = two.facets(&rows());
        assert_eq!(fs[1].on, ["fix", "feat"]);
        assert_eq!(qs(&two, "kind")[1], s("feat", 1, true, "kind:fix"));
        assert_eq!(qs(&two, "kind")[0].1, 1, "counts hold still while ticking");
        assert_eq!(
            qs(&two, "project")[0],
            s("dotfiles", 2, false, "kind:fix kind:feat project:dotfiles"),
            "another column ANDs with this one's picks"
        );
        let pre = q("project:dot project:play");
        let fs = pre.facets(&rows());
        assert_eq!(fs[0].on, ["dot", "play"]);
        let dot = fs[0].values.iter().find(|x| x.value == "dot").unwrap();
        assert_eq!((dot.n, dot.on, dot.q.as_str()), (2, true, "project:play"));
    }

    #[test]
    fn the_summary_marks_the_sort_and_the_next_click() {
        let v = View::new::<T>("", "live", "n", "asc");
        let rs = rows();
        let (shown, s) = v.summary(&rs);
        assert_eq!(s.total, 4);
        assert_eq!(s.shown, shown.len());
        assert_eq!(shown.len(), 2);
        let n = s.columns.iter().find(|c| c.key == "n").unwrap();
        assert_eq!(n.sort, Some(Dir::Asc));
        assert_eq!((n.next_sort.as_str(), n.next_dir), ("", Dir::Desc));
        let name = s.columns.iter().find(|c| c.key == "name").unwrap();
        assert_eq!((name.sort, name.next_sort.as_str()), (None, "name"));
    }
}
