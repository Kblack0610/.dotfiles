//! The Alerts page: `hub_core::alerts`, the same join agent-web's Alerts tab draws. The inner
//! tabs' strip (`hub_core::layout`: Firing, Fixes, Watches, History, each with its count), then
//! the inner tab shown: Health and what is firing on the shared data table
//! (`datatable`: `/` query, `f` state, `s`/`S` sort, `x` clear) with the selected row opened
//! under it (an Alertmanager rule's row lists its alerts), the fixes, every watch, or the alert
//! pages of the week. A source that could not be read is an error line, never an empty (green)
//! section.

use hub_core::alerts::{Alert, Alerts};
use hub_core::home::{Chip, Level};
use hub_core::layout::{self, Tab, FOLD_ROWS};
use hub_core::reading::NO_DATA;
use ratatui::style::Style;
use ratatui::text::{Line, Span};

use crate::datatable::{DataTable, ROW};
use crate::fit::{cell, clip_line, wrap, Cell, Table};
use crate::fmt::{clock, Palette};
use crate::innertabs;

/// `Alert::COLUMNS` in capitals, in its order, the sort mark placed by that index.
const HEADER: [&str; 7] = [
    "SEV", "WHAT", "PROJECT", "SOURCE", "SINCE", "OWNER", "STATE",
];
/// The width of an opened row's labels, as the longest one.
const LABEL: usize = 14;

#[derive(Default)]
pub struct AlertsView {
    /// The query, state chip and sort over the firing rows, applied by `hub_core::table::View`.
    pub table: DataTable,
    /// Whether the selected row is opened under it.
    pub open: bool,
    /// The inner tab shown (a `layout::Inner` id of Alerts); "" is the first, Firing.
    pub inner: &'static str,
    /// Every inner tab one after another: a printed `hub --tab alerts` that names none.
    pub all: bool,
    /// The ok watches shown under the ones needing a look (`w`); folded to their count by default.
    pub ok_watches: bool,
    /// The selection moved since the last draw, so the draw keeps it in view.
    pub follow: bool,
}

/// The row a selection stands for, so a re-read keeps the same alert selected.
pub type RowId = (String, String, String);

/// Source, what and where: one Alertmanager rule fires once per place, under one summary.
pub fn row_id(a: &Alert) -> RowId {
    (a.source.clone(), a.what.clone(), a.place.clone())
}

/// Alerts' layout entry: its sections and inner tabs.
pub fn tab() -> &'static Tab {
    layout::resolve("alerts").expect("alerts is a layout tab")
}

fn status(l: Level) -> Option<f64> {
    match l {
        Level::Ok => Some(0.0),
        Level::Warn => Some(1.0),
        Level::Red => Some(2.0),
        Level::Nodata => None,
    }
}

fn heading(title: &str, rest: String, p: Palette) -> Line<'static> {
    Line::from(vec![
        Span::styled(title.to_string(), p.head()),
        Span::styled(rest, p.dim()),
    ])
}

impl AlertsView {
    /// The firing rows the view keeps, in its sort or the reader's order.
    pub fn shown<'a>(&self, a: &'a Alerts) -> Vec<&'a Alert> {
        self.table.view.apply(&a.firing)
    }

    pub fn selected<'a>(&self, a: &'a Alerts) -> Option<&'a Alert> {
        self.shown(a).get(self.table.sel).copied()
    }

    /// Move the selection to the row with this id after a re-read, or keep the index in range.
    pub fn reselect(&mut self, a: &Alerts, id: Option<RowId>) {
        let rows = self.shown(a);
        let at = id.and_then(|id| rows.iter().position(|r| row_id(r) == id));
        self.table.keep(at, rows.len());
    }

    /// The inner tab shown.
    pub fn on(&self) -> &'static str {
        layout::inner_tab(tab(), Some(self.inner)).map_or("", |i| i.id)
    }

    /// The page as lines, and where each section starts: the strip, then the inner tab's
    /// sections (every inner tab's with `all`), in `hub_core::layout`'s Alerts order,
    /// with `ROW` for the selected firing row.
    pub fn page(
        &self,
        a: &Alerts,
        p: Palette,
        now: i64,
        w: usize,
    ) -> (Vec<Line<'static>>, Vec<(&'static str, usize)>) {
        let nodata = NO_DATA.to_uppercase();
        let (style, word) = match a.level {
            Level::Red => (p.status(Some(2.0)).0, "FIRING"),
            Level::Warn => (p.status(Some(1.0)).0, "WARN"),
            Level::Ok => (p.status(Some(0.0)).0, "ALL CLEAR"),
            Level::Nodata => (p.status(None).0, nodata.as_str()),
        };
        let c = &a.counts;
        let strip = |i: &layout::Inner| a.strip.get(i.id).copied().unwrap_or(0);
        let mut l = vec![innertabs::strip_of(tab().inner, self.on(), strip, p, w)];
        l.push(clip_line(
            Line::from(vec![
                Span::styled("ALERTS  ", p.head()),
                Span::styled(format!(" {word} "), style),
                Span::styled(
                    format!(
                        "  read {}   {} open fixes, {} watches",
                        clock(a.at, now),
                        c.fixes_open,
                        c.watches
                    ),
                    p.dim(),
                ),
            ]),
            w,
        ));
        for e in &a.errors {
            l.push(clip_line(Line::styled(format!("  {e}"), p.bad()), w));
        }
        let mut at = vec![];
        let mut put = |name: &'static str, lines: Vec<Line<'static>>, l: &mut Vec<_>| {
            l.push(Line::raw(""));
            at.push((name, l.len()));
            l.extend(lines);
        };
        let t = tab();
        let shown = layout::inner_tab(t, Some(self.on())).map_or(&[][..], |i| i.sections);
        let mut row = None;
        for &sec in t.sections {
            if !(self.all || shown.contains(&sec)) {
                continue;
            }
            let lines = match sec {
                "health" => health(a, p, w),
                "firing" => {
                    let (lines, r) = self.firing(a, p, now, w);
                    row = r.map(|r| l.len() + 1 + r);
                    lines
                }
                "fixes" => fixes(a, p, now, w),
                "watches" => watch_lines(a, self.ok_watches, p, now, w),
                "history" => history(a, p, now, w),
                _ => continue,
            };
            put(sec, lines, &mut l);
        }
        if let Some(r) = row {
            at.push((ROW, r));
        }
        (l, at)
    }

    /// FIRING: its counts, the table's chips and query, then the table, the selected row opened
    /// under it. Also the line the selected row is on, counted from the heading.
    fn firing(
        &self,
        a: &Alerts,
        p: Palette,
        now: i64,
        w: usize,
    ) -> (Vec<Line<'static>>, Option<usize>) {
        let c = &a.counts;
        let alerts = match c.alertmanager_alerts {
            n if n == c.alertmanager => String::new(),
            n => format!(" ({n} alerts)"),
        };
        let mut out = vec![
            clip_line(
                heading(
                    "FIRING",
                    format!(
                        "  {}: {} trip, {} error, {} no owner, {} alertmanager{alerts}",
                        c.firing, c.tripped, c.errors, c.no_owner, c.alertmanager
                    ),
                    p,
                ),
                w,
            ),
            clip_line(Line::from(self.table.status(&a.firing, p)), w),
        ];
        let rows = self.shown(a);
        if rows.is_empty() {
            out.push(Line::styled(
                if a.firing.is_empty() {
                    "  Nothing is firing."
                } else {
                    "  No firing row matches (/ query, f state, x clears)."
                },
                p.dim(),
            ));
            return (out, None);
        }
        let cells: Vec<Vec<Cell>> = rows.iter().map(|r| row(r, p, now)).collect();
        // WHAT wraps under itself so the columns after it stay in line.
        let (mut table, starts) = Table {
            header: HEADER.to_vec(),
            rows: cells,
            keep: vec![1, 6, 5, 0, 4, 2, 3],
            flex: Some(1),
            flexmin: 16,
            flexkeep: true,
            right: vec![4],
            cap: vec![(5, 22), (2, 16)],
            mark: self.table.mark::<Alert>(),
        }
        .fit_wrapped(w, p.head());
        let sel = starts.get(self.table.sel).copied();
        if let Some(i) = sel {
            let end = starts
                .get(self.table.sel + 1)
                .copied()
                .unwrap_or(table.len());
            for l in &mut table[i..end] {
                l.style = p.sel();
            }
            if self.open {
                table.splice(end..end, detail(rows[self.table.sel], p, now, w));
            }
        }
        let first = out.len();
        out.extend(table);
        (out, sel.map(|i| first + i))
    }
}

/// WATCHES: the watches needing a look, then the ok ones folded to their count until `w` shows
/// them, as agent-web folds them.
fn watch_lines(a: &Alerts, ok: bool, p: Palette, now: i64, w: usize) -> Vec<Line<'static>> {
    let c = &a.counts;
    let mut out = vec![clip_line(
        heading(
            "WATCHES",
            format!(
                "  {}: {} tripped, {} error, {} ok, {} new",
                c.watches, c.watches_tripped, c.watches_error, c.watches_ok, c.watches_new
            ),
            p,
        ),
        w,
    )];
    if a.watches.is_empty() {
        out.push(Line::styled("  No watch defined.", p.dim()));
        return out;
    }
    let at = |t: Option<i64>| t.map_or("-".into(), |t| clock(t, now));
    let folded = if ok {
        0
    } else {
        a.watches.iter().filter(|x| x.state == "OK").count()
    };
    let rows: Vec<Vec<Cell>> = a
        .watches
        .iter()
        .filter(|x| ok || x.state != "OK")
        .map(|x| {
            let style = match x.state.as_str() {
                "TRIP" | "ERROR" => p.bad(),
                "OK" => p.good(),
                _ => p.dim(),
            };
            vec![
                x.name.clone().into(),
                cell(x.state.clone(), style),
                cell(x.severity.clone(), p.dim()),
                cell(dash(&x.project), p.dim()),
                at(x.since).into(),
                at(x.lastrun).into(),
                cell(x.place.clone(), p.dim()),
            ]
        })
        .collect();
    if !rows.is_empty() {
        out.extend(
            Table {
                header: vec![
                    "WATCH", "STATE", "SEVERITY", "PROJECT", "SINCE", "LAST RUN", "WHERE",
                ],
                rows,
                keep: vec![0, 1, 4, 5, 2, 3, 6],
                flex: Some(6),
                flexmin: 10,
                ..Default::default()
            }
            .fit(w, p.head()),
        );
    }
    if folded > 0 {
        out.push(Line::styled(
            format!("  +{folded} ok (w shows them)"),
            p.dim(),
        ));
    }
    out
}

/// A project cell: its name, or `-` for a fleet-wide watch.
fn dash(project: &str) -> String {
    if project.is_empty() { "-" } else { project }.into()
}

fn row(r: &Alert, p: Palette, now: i64) -> Vec<Cell> {
    let sev = if matches!(r.sev.as_str(), "urgent" | "high") {
        p.bad()
    } else {
        p.dim()
    };
    let state = match r.state.as_str() {
        "error" | "no owner" | "unfixed" => p.bad(),
        "fixing" | "queued" => p.warn(),
        _ => Style::default(),
    };
    vec![
        cell(r.sev.clone(), sev),
        match r.pages.as_slice() {
            [] => r.what.clone().into(),
            [one] if one.what != r.what => format!("{}: {}", r.what, one.what).into(),
            [_] => r.what.clone().into(),
            many => format!("{} ({} alerts)", r.what, many.len()).into(),
        },
        cell(dash(&r.project), p.dim()),
        cell(r.source.clone(), p.dim()),
        r.since
            .map_or("-".into(), |t| hub_core::text::age(now - t))
            .into(),
        r.owner.clone().into(),
        cell(r.state.clone(), state),
    ]
}

/// An opened row: what the watch checks, where, what to do, its fix and how to reach it, then
/// its last probe output; a row no watch file describes says so.
pub fn detail(r: &Alert, p: Palette, now: i64, w: usize) -> Vec<Line<'static>> {
    if !r.pages.is_empty() {
        return pages(r, p, now, w);
    }
    let mut out = vec![];
    let width = w.saturating_sub(LABEL + 5).max(20);
    let mut part = |label: &str, text: &str| {
        let words: Vec<&str> = text.split_whitespace().collect();
        for (i, l) in wrap(&words, " ", width).into_iter().enumerate() {
            let name = if i == 0 { label } else { "" };
            out.push(clip_line(
                Line::from(vec![
                    Span::styled(format!("    {name:<LABEL$} "), p.dim()),
                    Span::raw(l),
                ]),
                w,
            ));
        }
    };
    part("What it checks", &r.about);
    part("Where", &r.place);
    part("What to do", &r.action);
    if !r.slug.is_empty() {
        part("Its fix", &format!("{}: i opens it on Queue", r.owner));
    }
    if let Some(u) = &r.pr_url {
        part("Fix PR", &format!("{u} (o opens it)"));
    }
    for e in r.evidence.lines() {
        out.push(clip_line(Line::styled(format!("      {e}"), p.dim()), w));
    }
    if out.is_empty() {
        out.push(clip_line(
            Line::styled(
                format!(
                    "    No watch file says more: {} reports only that it is red.",
                    r.source
                ),
                p.dim(),
            ),
            w,
        ));
    }
    out
}

/// An Alertmanager rule's opened row: what its alerts all say (`hub_core::alerts::am_rows`),
/// then each alert, worst first, with where it fires, since when, and the description and what
/// to do that are its own.
fn pages(r: &Alert, p: Palette, now: i64, w: usize) -> Vec<Line<'static>> {
    let mut out = vec![];
    for (label, text) in [("What it checks", &r.about), ("What to do", &r.action)] {
        if !text.is_empty() {
            out.push(clip_line(
                Line::from(vec![
                    Span::styled(format!("    {label:<LABEL$} "), p.dim()),
                    Span::raw(text.clone()),
                ]),
                w,
            ));
        }
    }
    for x in &r.pages {
        let since = x.since.map_or("-".into(), |t| hub_core::text::age(now - t));
        out.push(clip_line(
            Line::from(vec![
                Span::styled(format!("      {:<8} {:>4}  ", x.sev, since), p.dim()),
                Span::raw(format!("{}  ", x.what)),
                Span::styled(x.place.clone(), p.dim()),
            ]),
            w,
        ));
        for (shared, own) in [(&r.about, &x.about), (&r.action, &x.action)] {
            if shared.is_empty() && !own.is_empty() {
                out.push(clip_line(
                    Line::styled(format!("                     {own}"), p.dim()),
                    w,
                ));
            }
        }
    }
    out
}

/// The HEALTH line: green collapses to one line, and only the chips that
/// are not green are drawn, then how many are green.
fn health_line(chips: &[Chip], p: Palette, w: usize) -> Line<'static> {
    let mut strip = vec![Span::styled("HEALTH   ", p.head())];
    let bad: Vec<&Chip> = chips.iter().filter(|c| c.level != Level::Ok).collect();
    if chips.is_empty() {
        strip.push(Span::styled(hub_core::reading::NO_DATA, p.dim()));
    } else if bad.is_empty() {
        strip.push(Span::styled(
            format!("all green ({})", chips.len()),
            p.good(),
        ));
    } else {
        for c in &bad {
            let v = match c.level {
                Level::Ok => Some(0.0),
                Level::Warn => Some(1.0),
                Level::Red => Some(2.0),
                Level::Nodata => None,
            };
            let (style, word) = p.status(v);
            strip.push(Span::styled(format!(" {} {word} ", c.name), style));
            strip.push(Span::raw(" "));
        }
        strip.push(Span::styled(
            format!("{} green", chips.len() - bad.len()),
            p.dim(),
        ));
    }
    clip_line(Line::from(strip), w)
}

/// HEALTH: every domain chip (`health_line`), then why: each component not green.
fn health(a: &Alerts, p: Palette, w: usize) -> Vec<Line<'static>> {
    let mut out = vec![health_line(&a.health, p, w)];
    for c in &a.components {
        let (style, word) = p.status(status(c.level));
        out.push(clip_line(
            Line::from(vec![
                Span::raw("  "),
                Span::styled(format!(" {word} "), style),
                Span::raw(format!(" {}/{}", c.domain, c.name)),
            ]),
            w,
        ));
    }
    out
}

/// FIXES: each red the triage queued as a fix in the window (`hub_core::reds`, which orders the
/// open rows worst first and words the summary), the open rows one a line up to `FOLD_ROWS` then
/// "+N more", and the settled ones folded to a count. A failed read is this section's error,
/// never an empty list that reads as all fixed.
pub fn fixes(a: &Alerts, p: Palette, now: i64, w: usize) -> Vec<Line<'static>> {
    let head = |rest: String, style| {
        Line::from(vec![
            Span::styled("FIXES", p.head()),
            Span::styled(format!("  {rest}"), style),
        ])
    };
    if let Some(e) = a.errors.iter().find(|e| e.starts_with("fleet-bench reds:")) {
        return vec![
            head("read failed".into(), p.bad()),
            clip_line(Line::styled(format!("  {e}"), p.bad()), w),
        ];
    }
    let r = &a.fixes;
    let summary = if r.summary.is_empty() {
        format!("{} open", r.open.len())
    } else {
        r.summary.clone()
    };
    let mut out = vec![clip_line(head(summary, Style::default()), w)];
    for f in r.open.iter().take(FOLD_ROWS) {
        let style = match f.outcome.as_str() {
            "came back" | "still red" | "no fix" => p.bad(),
            "needs merge" => p.warn(),
            _ => Style::default(),
        };
        // The number only: a URL or `owner/repo#N` would push the age off a narrow line.
        let pr = f.pr.as_deref().map_or(String::new(), |n| {
            let n = n.trim_end_matches('/');
            let tail = n.rsplit(['#', '/']).next().unwrap_or(n);
            if !tail.is_empty() && tail.chars().all(|c| c.is_ascii_digit()) {
                format!("  #{tail}")
            } else {
                format!("  PR {n}")
            }
        });
        out.push(clip_line(
            Line::from(vec![
                Span::styled(format!("  {:<11}", f.outcome.to_uppercase()), style),
                Span::raw(format!(
                    "  {}{}  {}{pr}  ",
                    f.red,
                    if f.project.is_empty() {
                        String::new()
                    } else {
                        format!("  {}", f.project)
                    },
                    f.slug
                )),
                Span::styled(f.age(now), p.dim()),
            ]),
            w,
        ));
    }
    if r.open.len() > FOLD_ROWS {
        out.push(Line::styled(
            format!("  +{} more", r.open.len() - FOLD_ROWS),
            p.dim(),
        ));
    }
    if !r.settled.is_empty() {
        out.push(Line::styled(
            format!("  +{} settled", r.settled.len()),
            p.dim(),
        ));
    }
    if r.open.is_empty() && r.settled.is_empty() {
        out.push(Line::styled(
            "  No red was queued as a fix this week.",
            p.dim(),
        ));
    }
    out
}

/// HISTORY: Sentinel's pages of the window, newest first; every sender's are on Log's Actions.
fn history(a: &Alerts, p: Palette, now: i64, w: usize) -> Vec<Line<'static>> {
    let c = &a.counts;
    let mut out = vec![heading(
        "HISTORY",
        format!(
            "  {} pages in {} days",
            c.history + c.history_older,
            hub_core::alerts::DAYS
        ),
        p,
    )];
    if a.history.is_empty() {
        out.push(Line::styled("  No alert paged this week.", p.dim()));
    }
    for x in &a.history {
        out.push(clip_line(
            Line::from(vec![
                Span::styled(format!("  {:<11} ", clock(x.at, now)), p.dim()),
                Span::styled(format!("{} ", x.verb), p.dim()),
                Span::raw(x.text.clone()),
            ]),
            w,
        ));
    }
    if c.history_older > 0 {
        out.push(Line::styled(
            format!(
                "  +{} older on {}, Actions",
                c.history_older,
                hub_core::layout::bar_label("log")
            ),
            p.dim(),
        ));
    }
    out
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    use crate::fit::plain;
    use hub_core::fleet::runner::Watch;
    use hub_core::reds::Reds;

    const NOW: i64 = 1_762_200_000;

    fn watch(name: &str, state: &str) -> Watch {
        Watch {
            name: name.into(),
            state: state.into(),
            severity: "high".into(),
            since: Some(NOW - 3 * 3600),
            place: "GitHub, unity".into(),
            what: "the nightly on main".into(),
            action: "read the run".into(),
            evidence: if state == "TRIP" {
                "PlayMode 2 failed".into()
            } else {
                String::new()
            },
            ..Default::default()
        }
    }

    fn reds(rows: &[&str]) -> Reds {
        hub_core::reds::split(
            rows.iter()
                .map(|l| serde_json::from_str(l).unwrap())
                .collect(),
        )
    }

    /// The board fixture (one `cc:red_now` watch, an offline runner, a stuck run) joined with
    /// a tripped watch whose fix is open, an error watch and an ok one.
    pub(crate) fn sample() -> Alerts {
        let fix = reds(&[
            r#"{"slug":"ar-9","red":"watch playground-nightly","queued":"2025-11-03T10:00:00Z","outcome":"fixing","pr":"Kblack0610/.dotfiles#1170","pr_url":"https://github.com/Kblack0610/.dotfiles/pull/1170"}"#,
        ]);
        hub_core::alerts::join(
            &crate::board::tests::fixture(),
            Ok(vec![
                watch("playground-nightly", "TRIP"),
                watch("dream", "ERROR"),
                watch("disk", "OK"),
            ]),
            Ok(fix),
            Ok(String::new()),
            NOW,
        )
    }

    fn text(lines: &[Line]) -> String {
        lines.iter().map(plain).collect::<Vec<_>>().join("\n")
    }

    /// A view drawing every inner tab, as a printed `hub --tab alerts` does.
    fn every() -> AlertsView {
        AlertsView {
            all: true,
            ..Default::default()
        }
    }

    fn page(v: &AlertsView, a: &Alerts, w: usize) -> (String, Vec<(&'static str, usize)>) {
        let (l, at) = v.page(a, Palette { no_color: true }, NOW, w);
        (text(&l), at)
    }

    #[test]
    fn the_header_is_hub_cores_columns() {
        use hub_core::table::Row;
        let lower: Vec<String> = HEADER.iter().map(|h| h.to_lowercase()).collect();
        assert_eq!(lower, Alert::COLUMNS);
    }

    #[test]
    fn the_sections_come_in_the_layouts_order_each_at_its_heading() {
        let a = sample();
        let all = AlertsView {
            all: true,
            ..Default::default()
        };
        let (s, at) = page(&all, &a, 160);
        let lines: Vec<&str> = s.lines().collect();
        let want = hub_core::layout::resolve("alerts").unwrap().sections;
        let names: Vec<&str> = at.iter().map(|x| x.0).filter(|n| *n != ROW).collect();
        assert_eq!(names, want);
        for (name, i) in at.iter().filter(|x| x.0 != ROW) {
            assert!(
                lines[*i].starts_with(&name.to_uppercase()),
                "{name} at {i}: {s}"
            );
        }
        assert!(lines[1].starts_with("ALERTS   FIRING"), "{s}");
        // Each heading once, so a section is never drawn twice.
        for name in want {
            let head = name.to_uppercase();
            let n = lines.iter().filter(|l| l.starts_with(&head)).count();
            assert_eq!(n, 1, "{head}: {s}");
        }
    }

    #[test]
    fn the_strip_leads_with_each_inner_tabs_count_and_shows_health_then_the_one_open() {
        let a = sample();
        let mut v = AlertsView::default();
        let (s, at) = page(&v, &a, 160);
        let first = s.lines().next().unwrap();
        let n = |id: &str| a.strip[id];
        assert!(
            first.starts_with(&format!(
                "[Firing {}] Fixes {}  Watches {}  History",
                n("firing"),
                n("fixes"),
                n("watches")
            )),
            "{first}"
        );
        let names: Vec<&str> = at.iter().map(|x| x.0).filter(|n| *n != ROW).collect();
        assert_eq!(names, ["health", "firing"]);
        v.inner = "history";
        let (s, at) = page(&v, &a, 160);
        let names: Vec<&str> = at.iter().map(|x| x.0).collect();
        assert_eq!(
            names,
            ["history"],
            "no Health and no selected row off Firing"
        );
        assert!(s.lines().next().unwrap().contains("[History]"), "{s}");
        assert!(!s.contains("SOURCE"), "{s}");
    }

    #[test]
    fn a_rule_row_names_its_alert_count_and_opens_to_each_alert_with_its_own_text() {
        let mut a = sample();
        let am = |place: &str, sev: &str| Alert {
            sev: sev.into(),
            what: format!("CVEs in {place}"),
            source: "alertmanager".into(),
            place: format!("image={place}"),
            since: Some(NOW - 7200),
            about: format!("HomelabCriticalVulnerability: {place} has 3"),
            action: "routed to ntfy".into(),
            ..Default::default()
        };
        let rule = |pages: Vec<Alert>, about: &str| Alert {
            what: "HomelabCriticalVulnerability".into(),
            about: about.into(),
            place: String::new(),
            pages,
            ..am("api", "high")
        };
        a.firing
            .insert(0, rule(vec![am("api", "high"), am("web", "normal")], ""));
        let v = AlertsView {
            open: true,
            ..Default::default()
        };
        let (s, _) = page(&v, &a, 160);
        assert!(s.contains("HomelabCriticalVulnerability (2 alerts)"), "{s}");
        assert!(s.contains("What to do     routed to ntfy"), "{s}");
        assert!(s.contains("high       2h  CVEs in api  image=api"), "{s}");
        assert!(s.contains("CVEs in web  image=web"), "{s}");
        // The descriptions differ, so each alert keeps its own and the row has none.
        assert!(s.contains("HomelabCriticalVulnerability: web has 3"), "{s}");
        assert!(!s.contains("What it checks"), "{s}");
        // Negative control: a single alert's row opens to what its watch says.
        assert!(!s.contains("playground-nightly ("), "{s}");

        // One alert: its summary beside the rule, its description shared on the row.
        a.firing[0] = rule(
            vec![am("api", "high")],
            "HomelabCriticalVulnerability: api has 3",
        );
        let (s, _) = page(&v, &a, 160);
        assert!(
            s.contains("HomelabCriticalVulnerability: CVEs in api"),
            "{s}"
        );
        assert!(
            s.contains("What it checks HomelabCriticalVulnerability: api has 3"),
            "{s}"
        );
        assert_eq!(s.matches("api has 3").count(), 1, "said once: {s}");
    }

    #[test]
    fn firing_leads_with_the_tripped_watch_and_its_owner_then_red_now_and_the_machinery() {
        let a = sample();
        let (s, _) = page(&AlertsView::default(), &a, 160);
        let at = |w: &str| s.find(w).unwrap_or_else(|| panic!("no {w} in {s}"));
        assert!(s.contains("FIRING  "), "{s}");
        assert!(at("playground-nightly") < at("dream"), "{s}");
        assert!(at("ar-9 fixing") < at("watch mac_studio_mlx"), "{s}");
        assert!(
            at("watch mac_studio_mlx") < at("ci runner mini-1 offline"),
            "{s}"
        );
        assert!(s.contains("stuck run: platform develop"), "{s}");
        // The selected row is the first, and the app is told where it is.
        let row = s.lines().position(|l| l.contains("playground-nightly"));
        let (_, secs) = page(&AlertsView::default(), &a, 160);
        assert_eq!(secs.iter().find(|x| x.0 == ROW).map(|x| x.1), row);
    }

    #[test]
    fn a_runner_the_governor_powered_off_is_not_firing() {
        let flat = |v: serde_json::Value| {
            hub_core::prom::flatten(
                &serde_json::json!({"status": "success", "data": {"result": [v]}}),
            )
            .unwrap()
        };
        let mut i = crate::board::tests::fixture();
        i.instant
            .get_mut("runners")
            .unwrap()
            .extend(flat(serde_json::json!({"metric":
            {"host": "aws-burst-1", "name": "aws-1", "state": "offline", "pool": "unity",
            "site": "cloud"}, "value": [0, "0"]})));
        let firing = |i: &hub_core::infra::Infra| {
            let a =
                hub_core::alerts::join(i, Ok(vec![]), Ok(Reds::default()), Ok(String::new()), NOW);
            page(&AlertsView::default(), &a, 160).0
        };
        let power = |state: &str| {
            flat(
                serde_json::json!({"metric": {"__name__": "ci_governor_power_state",
                "host": "aws-burst-1", "state": state}, "value": [0, "1"]}),
            )
        };
        assert!(firing(&i).contains("aws-1 offline"), "unmanaged: down");
        i.instant.insert("power", power("running"));
        assert!(
            firing(&i).contains("aws-1 offline"),
            "governor running: down"
        );
        i.instant.insert("power", power("stopped"));
        let s = firing(&i);
        assert!(!s.contains("aws-1"), "{s}");
        assert!(s.contains("mini-1 offline"), "{s}");
    }

    #[test]
    fn enter_opens_what_the_watch_says_under_its_row_and_a_bare_red_says_there_is_no_more() {
        let a = sample();
        let mut v = AlertsView {
            open: true,
            ..Default::default()
        };
        let (s, _) = page(&v, &a, 120);
        let lines: Vec<&str> = s.lines().collect();
        let row = lines
            .iter()
            .position(|l| l.contains("playground-nightly"))
            .unwrap();
        assert!(
            lines[row + 1].contains("What it checks the nightly on main"),
            "{s}"
        );
        assert!(
            s.contains("Its fix        ar-9 fixing: i opens it on Queue"),
            "{s}"
        );
        assert!(s.contains("pull/1170 (o opens it)"), "{s}");
        assert!(s.contains("      PlayMode 2 failed"), "{s}");
        assert!(lines.iter().all(|l| l.chars().count() <= 120), "{s}");
        // A cc:red_now row has no watch file behind it.
        let red = v
            .shown(&a)
            .iter()
            .position(|r| r.source == "red_now")
            .unwrap();
        v.table.sel = red;
        let (s, _) = page(&v, &a, 120);
        assert!(
            s.contains("No watch file says more: red_now reports only that it is red."),
            "{s}"
        );
        // Shut, no detail line is drawn.
        v.open = false;
        assert!(!page(&v, &a, 120).0.contains("No watch file says more"));
    }

    #[test]
    fn a_reselect_follows_the_row_after_a_reread() {
        let a = sample();
        let mut v = AlertsView::default();
        let dream = a.firing.iter().find(|r| r.what == "dream").map(row_id);
        v.reselect(&a, dream);
        assert_eq!(v.selected(&a).map(|r| r.what.as_str()), Some("dream"));
        v.table.sel = 99;
        v.reselect(&a, Some(("sentinel".into(), "gone".into(), String::new())));
        assert_eq!(v.table.sel, v.shown(&a).len() - 1);
    }

    #[test]
    fn health_names_the_domains_then_each_component_that_is_not_green() {
        let mut i = crate::board::tests::fixture();
        i.instant.get_mut("cc").unwrap().extend(
            hub_core::prom::flatten(&serde_json::json!({"status": "success", "data":
                {"result": [{"metric": {"__name__": "cc:component_status", "domain": "llm",
                "component": "gateway"}, "value": [0, "2"]}]}}))
            .unwrap(),
        );
        let a = hub_core::alerts::join(&i, Ok(vec![]), Ok(Reds::default()), Ok(String::new()), NOW);
        let (s, _) = page(&AlertsView::default(), &a, 160);
        let at = |w: &str| s.find(w).unwrap_or_else(|| panic!("no {w} in {s}"));
        assert!(at("HEALTH") < at("llm RED"), "{s}");
        assert!(s.contains("   RED  llm/gateway"), "{s}");
    }

    #[test]
    fn a_source_that_failed_is_an_error_line_never_an_empty_green() {
        let a = hub_core::alerts::join(
            &crate::board::tests::fixture(),
            Err("no such dir".into()),
            Err("exit 1".into()),
            Ok(String::new()),
            NOW,
        );
        let (s, _) = page(&every(), &a, 160);
        assert!(s.contains("  watches: no such dir"), "{s}");
        assert!(
            s.contains("FIXES  read failed\n  fleet-bench reds: exit 1"),
            "{s}"
        );
        assert!(!s.contains("No red was queued"), "{s}");
        // Negative control: read, the same section is the list.
        let (s, _) = page(&every(), &sample(), 160);
        assert!(!s.contains("read failed"), "{s}");
    }

    #[test]
    fn fixes_shows_open_rows_worst_first_folds_settled_and_caps_at_fold_rows() {
        let mut a = sample();
        a.fixes = reds(&[
            r#"{"slug":"ar-1","red":"watch a","queued":"2026-11-06T10:00:00Z","merged":"x","fix_min":34,"pr":"Kblack0610/.dotfiles#1185","outcome":"fixed"}"#,
            r#"{"slug":"ar-2","red":"watch playground-nightly","queued":"2026-11-06T11:00:00Z","outcome":"queued"}"#,
            r#"{"slug":"ar-3","red":"runner dream","queued":"2026-11-05T12:00:00Z","merged":"y","fix_min":60,"pr":"Kblack0610/.dotfiles#1170","outcome":"came back"}"#,
            r#"{"slug":"ar-4","red":"watch b","queued":"2026-11-06T09:00:00Z","outcome":"cancelled"}"#,
        ]);
        let now = chrono::DateTime::parse_from_rfc3339("2026-11-06T12:00:00Z")
            .unwrap()
            .timestamp();
        let p = Palette { no_color: true };
        let s = text(&fixes(&a, p, now, 160));
        let lines: Vec<&str> = s.lines().collect();
        assert_eq!(
            lines[0],
            "FIXES  2 open: 1 came back, 1 queued | 1 fixed, 1 cancelled in 7d, fix p50 34m"
        );
        assert_eq!(lines[1], "  CAME BACK    runner dream  ar-3  #1170  24h");
        assert_eq!(
            lines[2],
            "  QUEUED       watch playground-nightly  ar-2  1h"
        );
        assert_eq!(lines[3], "  +2 settled");
        assert_eq!(lines.len(), 4, "settled rows fold to their count: {s}");

        let many: Vec<String> = (0..FOLD_ROWS + 2)
            .map(|n| format!(r#"{{"slug":"ar-{n}","red":"watch w{n}","outcome":"queued"}}"#))
            .collect();
        a.fixes = reds(&many.iter().map(String::as_str).collect::<Vec<_>>());
        let s: Vec<String> = fixes(&a, p, 0, 160).iter().map(plain).collect();
        assert_eq!(s.len(), 1 + FOLD_ROWS + 1, "{s:?}");
        assert_eq!(s.last().map(String::as_str), Some("  +2 more"));
    }

    #[test]
    fn watches_list_the_ones_needing_a_look_and_fold_the_ok_ones_until_w() {
        let a = hub_core::alerts::join(
            &crate::board::tests::fixture(),
            Ok(vec![watch("disk", "OK"), watch("dream", "OK")]),
            Ok(Reds::default()),
            Ok(String::new()),
            NOW,
        );
        let mut v = AlertsView::default();
        assert!(!page(&v, &a, 160).0.contains("WATCHES"), "on Firing");
        v.inner = "watches";
        let (s, _) = page(&v, &a, 160);
        assert!(
            s.contains("WATCHES  2: 0 tripped, 0 error, 2 ok, 0 new\n  +2 ok (w shows them)"),
            "{s}"
        );
        assert!(!s.contains("LAST RUN"), "{s}");
        assert!(s.lines().next().unwrap().contains("[Watches]"), "{s}");
        v.ok_watches = true;
        let s = page(&v, &a, 160).0;
        assert!(s.contains("LAST RUN") && s.contains("dream"), "{s}");
        assert!(!s.contains("+2 ok"), "{s}");
        // The ones needing a look are the table and put their count on the strip; ok ones fold.
        v.ok_watches = false;
        let s = page(&v, &sample(), 160).0;
        assert!(s.lines().next().unwrap().contains("[Watches 2]"), "{s}");
        let at = |w: &str| s.find(w).unwrap_or_else(|| panic!("no {w} in {s}"));
        assert!(at("playground-nightly") < at("+1 ok (w shows them)"), "{s}");
        assert!(!s.contains("disk"), "{s}");
    }

    #[test]
    fn history_counts_the_pages_and_sends_the_older_ones_to_log() {
        let mut a = sample();
        a.history = vec![hub_core::actions::Action {
            at: NOW - 600,
            actor: "sentinel".into(),
            verb: "tripped".into(),
            text: "Sentinel: playground-nightly".into(),
            priority: None,
            failed: false,
            reference: None,
            source: "agent-notify".into(),
        }];
        a.counts.history = 1;
        a.counts.history_older = 3;
        let (s, _) = page(&every(), &a, 160);
        assert!(s.contains("HISTORY  4 pages in 7 days"), "{s}");
        assert!(s.contains("tripped Sentinel: playground-nightly"), "{s}");
        assert!(s.contains("  +3 older on 2 Log, Actions"), "{s}");
    }

    #[test]
    fn a_narrow_page_fits() {
        let a = sample();
        let v = AlertsView {
            open: true,
            all: true,
            ..Default::default()
        };
        let (s, _) = page(&v, &a, 60);
        for l in s.lines() {
            assert!(l.chars().count() <= 60, "{l:?}");
        }
    }
}
