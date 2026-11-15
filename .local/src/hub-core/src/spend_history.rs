//! The Costs tab's History section: the whole fleet's dollars per day, month and year, from the
//! `fleet_cost.total` of every nightly token snapshot (`agent-usage tokens snapshot`, the one
//! writer). Rolled up here on read and never stored, so the hub TUI, `hub --once` and agent-web
//! show the same rows (dashboards rule 8). A day with no figure is missing, never $0.

use crate::fleet_cost::dollars;
use crate::table::{Row, Summary, Val, View};
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::path::Path;
use std::sync::{Arc, Mutex};
use std::time::SystemTime;

/// Day rows shown before the "+N older" line.
pub const DAY_ROWS: usize = 14;
/// Calendar days the day chart covers, ending on the newest snapshot.
pub const CHART_DAYS: usize = 30;
/// Session rows a day shows before the "+N more" line.
pub const SESSION_ROWS: usize = 50;

/// The days the newest day is set against in the headline.
const MEDIAN_DAYS: usize = 7;

pub const NOTE: &str = "$ is the whole fleet's day from the nightly token snapshot; vs prev compares $/day with the period before; $/session is what one session cost on an average day, from the day's session rows (- before they were kept); est. is the share priced from tokens, not billed, and it is 100% on a day priced after Prometheus aged out its bills, and that day's $ is a floor, since helper calls never reach a transcript.";

#[derive(Deserialize, Default)]
#[serde(default)]
struct Snap {
    fleet_cost: Option<Fc>,
}

#[derive(Deserialize, Default)]
#[serde(default)]
struct Fc {
    total: Option<Total>,
    by_session: Vec<Sess>,
}

#[derive(Deserialize, Default)]
#[serde(default)]
struct Total {
    usd: f64,
    estimated: f64,
}

/// What one session cost on one day: a row of the snapshot's `fleet_cost.by_session`.
#[derive(Clone, Debug, Default, PartialEq, Deserialize, Serialize)]
#[serde(default)]
pub struct Sess {
    pub sid: String,
    pub usd: f64,
    pub measured: f64,
    pub origin: Option<String>,
    pub harness: Option<String>,
    pub agent: Option<String>,
    pub account: Option<String>,
    pub project: Option<String>,
    pub title: Option<String>,
    pub item: Option<String>,
}

/// One priced day. `sessions` is empty for a day snapshotted before the rows were kept; it is
/// shared, so a cached or cloned day never copies its few hundred rows.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Day {
    pub date: String,
    pub usd: f64,
    pub estimated: f64,
    pub sessions: Arc<Vec<Sess>>,
}

/// One bar of a chart: a day (`key` 2026-11-09) or a month (2026-11). `usd` is None for a day
/// with no figure, which draws as a gap, never a $0 bar.
#[derive(Clone, Debug, Default, PartialEq, Serialize)]
pub struct Bar {
    pub key: String,
    pub label: String,
    pub usd: Option<f64>,
    pub measured: f64,
    pub estimated: f64,
    pub tip: String,
}

/// One row: a year (`2026`), a month (`2026-11`) or a day (`11-09`).
#[derive(Clone, Debug, Default, PartialEq, Serialize)]
pub struct Period {
    pub kind: &'static str,
    pub period: String,
    pub total: String,
    pub days: usize,
    pub per_day: String,
    /// The period's session rows over their count: one session's day, `-` with no rows.
    pub per_session: String,
    pub vs_prev: String,
    pub est: String,
}

/// The section both surfaces draw. `why` is set when there is nothing to show.
#[derive(Clone, Debug, Default, PartialEq, Serialize)]
pub struct History {
    pub why: Option<String>,
    /// The headline's two clauses: this month's pace against the last, then the last day
    /// against its median. Each surface draws them on lines of their own.
    pub month: String,
    pub last_day: String,
    pub rows: Vec<Period>,
    /// Priced days older than the day rows shown.
    pub older: usize,
    /// Days from the first snapshot to the newest with no figure: no file, or a $0 or null total.
    pub missing: usize,
    pub stale: bool,
    pub note: &'static str,
    /// The last `CHART_DAYS` calendar days, oldest first, a gap where a day has no figure.
    pub chart: Vec<Bar>,
    /// Every month with a priced day, oldest first: its total, $/day in the tip.
    pub months: Vec<Bar>,
}

/// Parsed snapshot days, by file: a past day's file changes only when a backfill rewrites it, so a
/// read parses only what is new or changed (a day with its session rows is a few hundred KB).
/// A parsed day, by its file's path, and the file's (mtime, size) when it was parsed.
type Parsed = HashMap<std::path::PathBuf, (SystemTime, u64, Day)>;
static PARSED: Mutex<Option<Parsed>> = Mutex::new(None);

/// Every snapshot day, oldest first. A file that does not parse, or a total that is missing or $0
/// (no rate to price it with), reads as $0, which `build` counts as missing.
pub fn read(dir: &Path) -> Vec<Day> {
    let mut guard = PARSED.lock().unwrap_or_else(|e| e.into_inner());
    let kept = guard.get_or_insert_with(HashMap::new);
    let days = crate::boards::days(dir);
    let paths: Vec<std::path::PathBuf> =
        days.iter().map(|d| dir.join(format!("{d}.json"))).collect();
    kept.retain(|k, _| k.parent() != Some(dir) || paths.contains(k));
    days.into_iter()
        .zip(paths)
        .map(|(date, path)| {
            let stamp = std::fs::metadata(&path)
                .ok()
                .map(|m| (m.modified().unwrap_or(SystemTime::UNIX_EPOCH), m.len()));
            if let (Some((at, len)), Some((kat, klen, d))) = (stamp, kept.get(&path)) {
                if at == *kat && len == *klen {
                    return d.clone();
                }
            }
            let fc = std::fs::read_to_string(&path)
                .ok()
                .and_then(|text| serde_json::from_str::<Snap>(&text).ok())
                .and_then(|s| s.fleet_cost)
                .unwrap_or_default();
            let t = fc.total.unwrap_or_default();
            let d = Day {
                date: date.clone(),
                usd: t.usd.max(0.0),
                estimated: t.estimated,
                sessions: Arc::new(fc.by_session),
            };
            if let Some((at, len)) = stamp {
                kept.insert(path, (at, len, d.clone()));
            }
            d
        })
        .collect()
}

/// The section from the snapshot days (oldest first) and today's local date (`YYYY-MM-DD`).
pub fn build(all: &[Day], today: &str) -> History {
    // Cheap: a day's session rows are shared, not copied.
    let days: Vec<Day> = all.iter().filter(|d| d.usd > 0.0).cloned().collect();
    let days = days.as_slice();
    let (Some(first), Some(last)) = (all.first(), days.last()) else {
        return History {
            why: Some("no snapshot with a fleet figure yet (agent-usage tokens snapshot)".into()),
            note: NOTE,
            ..History::default()
        };
    };
    let newest = all.last().map_or(&last.date, |d| &d.date);
    let span = day_number(newest) - day_number(&first.date) + 1;
    let mut rows = rollup(days, "year", 4);
    rows.extend(rollup(days, "month", 7));
    let mut daily: Vec<Period> = days
        .iter()
        .enumerate()
        .map(|(i, d)| {
            let prev = i
                .checked_sub(1)
                .map(|j| &days[j])
                .filter(|p| day_number(&d.date) - day_number(&p.date) == 1);
            period(
                "day",
                d.date.get(5..).unwrap_or(&d.date),
                Sums::of(d),
                prev.map(|p| p.usd),
            )
        })
        .collect();
    daily.reverse();
    let older = daily.len().saturating_sub(DAY_ROWS);
    daily.truncate(DAY_ROWS);
    rows.extend(daily);
    let (month, last_day) = headline(days);
    History {
        why: None,
        month,
        last_day,
        rows,
        older,
        missing: (span as usize).saturating_sub(days.len()),
        // the newest snapshot is of yesterday; older means the nightly run stopped
        stale: day_number(today) - day_number(&last.date) > 1,
        note: NOTE,
        chart: chart(all, newest),
        months: month_bars(days),
    }
}

/// The `CHART_DAYS` calendar days ending on `newest`, oldest first; a day with no file or no figure
/// is a gap.
fn chart(all: &[Day], newest: &str) -> Vec<Bar> {
    let end = day_number(newest);
    let by: HashMap<i64, &Day> = all.iter().map(|d| (day_number(&d.date), d)).collect();
    (0..CHART_DAYS as i64)
        .rev()
        .map(|back| {
            let n = end - back;
            let date = date_of(n);
            let label = date.get(5..).unwrap_or(&date).to_string();
            match by.get(&n).filter(|d| d.usd > 0.0) {
                Some(d) => Bar {
                    tip: format!(
                        "{date}: {} ({} billed, {} estimated){}",
                        dollars(d.usd),
                        dollars(d.usd - d.estimated),
                        dollars(d.estimated),
                        if d.sessions.is_empty() {
                            String::new()
                        } else {
                            format!(", {} sessions", d.sessions.len())
                        }
                    ),
                    key: date,
                    label,
                    usd: Some(d.usd),
                    measured: (d.usd - d.estimated).max(0.0),
                    estimated: d.estimated,
                },
                None => Bar {
                    tip: format!("{date}: no figure"),
                    key: date,
                    label,
                    ..Bar::default()
                },
            }
        })
        .collect()
}

/// One bar per month with a priced day, oldest first.
fn month_bars(days: &[Day]) -> Vec<Bar> {
    let mut out: Vec<(Bar, usize)> = vec![];
    for d in days {
        let key = d.date.get(..7).unwrap_or(&d.date).to_string();
        let measured = (d.usd - d.estimated).max(0.0);
        match out.last_mut() {
            Some((b, n)) if b.key == key => {
                b.usd = Some(b.usd.unwrap_or(0.0) + d.usd);
                b.measured += measured;
                b.estimated += d.estimated;
                *n += 1;
            }
            _ => out.push((
                Bar {
                    label: month_name(&key),
                    key,
                    usd: Some(d.usd),
                    measured,
                    estimated: d.estimated,
                    tip: String::new(),
                },
                1,
            )),
        }
    }
    out.into_iter()
        .map(|(mut b, n)| {
            let usd = b.usd.unwrap_or(0.0);
            b.tip = format!(
                "{}: {} over {n} priced days, {}/day",
                b.key,
                dollars(usd),
                dollars(usd / n as f64)
            );
            b
        })
        .collect()
}

/// The cuts of the spend table: who spent (the origin, runner or harness, in words), and the
/// session rows' own project, harness and account; `sessions` is no cut, the plain list.
pub const GROUPS: [&str; 5] = ["who", "project", "harness", "account", "sessions"];
/// The live day's name: the fleet's last 24 hours, from `fleet-cost.json`, not a nightly snapshot.
pub const LIVE: &str = "24h";

/// Who spent a session, in words: a codex or opencode session is its harness, a runner is its
/// name (`runner, ask-judge`, and `dream` for the nightly sweep), and every other origin is the
/// way a Claude session started. A queue item's origin is free-form (`fleet-dispatch` also writes
/// `resume`), so an origin not listed is one more way a queue item started.
pub fn who(s: &Sess) -> String {
    let harness = s.harness.as_deref().filter(|h| !h.is_empty());
    if let Some(h) = harness.filter(|h| *h != "claude") {
        return h.to_string();
    }
    match (s.origin.as_deref().unwrap_or(""), s.agent.as_deref()) {
        ("runner", Some("dream")) => "dream".into(),
        ("runner", Some(a)) if !a.is_empty() => format!("runner, {a}"),
        ("runner", _) => "runner, unnamed".into(),
        ("run", _) => "queue, dispatch run".into(),
        ("hand", _) => "queue, hand-started".into(),
        ("plan", _) => "queue, plan".into(),
        ("queue", _) => "queue items".into(),
        ("shepherd", _) => "shepherd".into(),
        ("interactive", _) => "you, interactive".into(),
        ("", _) => "unknown".into(),
        (other, _) => format!("queue, {other}"),
    }
}

/// A session's value under a cut (`GROUPS`); a row that has none reads `unknown`.
fn cut(s: &Sess, group: &str) -> String {
    let some = |v: &Option<String>| {
        v.as_deref()
            .filter(|v| !v.is_empty())
            .unwrap_or("unknown")
            .to_string()
    };
    match group {
        "project" => some(&s.project),
        "harness" => some(&s.harness),
        "account" => some(&s.account),
        _ => who(s),
    }
}

/// One session's row in a day's table.
#[derive(Clone, Debug, Default, PartialEq, Serialize)]
pub struct SessRow {
    pub sid: String,
    /// What the session was: its title, else its queue item, else its agent.
    pub session: String,
    /// Who spent it (`who`).
    pub who: String,
    pub project: Option<String>,
    pub harness: Option<String>,
    pub cost: f64,
    /// Percent of the day's whole-fleet figure.
    pub share: f64,
    /// Percent of the row priced from tokens, not billed.
    pub est: f64,
    /// Days in the chart's range this session cost anything.
    pub days: u64,
}

impl Row for SessRow {
    const COLUMNS: &'static [&'static str] = &[
        "session", "who", "project", "harness", "cost", "share", "est", "days",
    ];
    const STATES: &'static [&'static str] = &["all"];
    const FACETS: &'static [&'static str] = &[];
    const LEAD: &'static str = "session";
    const GLANCE: &'static [&'static str] = &["cost", "share", "who"];

    fn val(&self, col: &str) -> Val {
        let text = |s: &Option<String>| s.as_ref().map_or(Val::None, |s| Val::Text(s.clone()));
        match col {
            "session" => Val::Text(self.session.clone()),
            "who" => Val::Text(self.who.clone()),
            "project" => text(&self.project),
            "harness" => text(&self.harness),
            "cost" => Val::Num(self.cost),
            "share" => Val::Num(self.share),
            "est" => Val::Num(self.est),
            "days" => Val::Num(self.days as f64),
            _ => Val::None,
        }
    }
    fn in_state(&self, _: &str) -> bool {
        true
    }
    fn text(&self) -> String {
        [Some(&self.session), Some(&self.sid), Some(&self.who)]
            .into_iter()
            .flatten()
            .chain(self.project.as_ref())
            .cloned()
            .collect::<Vec<_>>()
            .join("\n")
            .to_lowercase()
    }
}

/// A set of a day's session rows added up: the day's total row, a group's row, the opened group.
#[derive(Clone, Debug, Default, PartialEq, Serialize)]
pub struct Tot {
    pub name: String,
    pub sessions: usize,
    pub cost: f64,
    /// Percent of the day's whole-fleet figure.
    pub share: f64,
    /// Percent of the rows' dollars priced from tokens, not billed.
    pub est: f64,
    /// What one of these sessions cost: the dollars over the rows.
    pub per_session: f64,
}

/// `part` as a percent of `whole`, 0 when there is no whole.
fn pct(part: f64, whole: f64) -> f64 {
    if whole > 0.0 {
        part / whole * 100.0
    } else {
        0.0
    }
}

/// The percent of `usd` priced from tokens rather than billed.
fn est_pct(usd: f64, measured: f64) -> f64 {
    if usd > 0.0 {
        pct(usd - measured, usd).clamp(0.0, 100.0)
    } else {
        0.0
    }
}

fn tot(name: &str, rows: &[&Sess], day_usd: f64) -> Tot {
    let cost: f64 = rows.iter().map(|s| s.usd).sum();
    let measured: f64 = rows.iter().map(|s| s.measured).sum();
    Tot {
        name: name.to_string(),
        sessions: rows.len(),
        cost,
        share: pct(cost, day_usd),
        est: est_pct(cost, measured),
        per_session: if rows.is_empty() {
            0.0
        } else {
            cost / rows.len() as f64
        },
    }
}

/// The spend table of one day: its total, its groups (or its sessions), the opened group and the
/// opened session's own days.
#[derive(Clone, Debug, Default, PartialEq, Serialize)]
pub struct DayView {
    /// The day shown (`YYYY-MM-DD`, or `LIVE`); empty when no snapshot has session rows yet.
    pub day: String,
    pub head: String,
    pub why: Option<String>,
    /// The cut shown (`GROUPS`).
    pub group: String,
    /// Every cut the table can regroup by, for the switch.
    pub cuts: &'static [&'static str],
    /// The day shown is the live last 24h, and whether there is one to go back to.
    pub live: bool,
    pub has_live: bool,
    /// The opened group's value; empty when none is open.
    pub in_group: String,
    /// All of the day's session rows added up: the total row, on top of every view.
    pub total: Option<Tot>,
    /// The opened group's own row, beside the total.
    pub open: Option<Tot>,
    /// What the day spent outside any session row (helper calls, the gateway, and on a snapshot
    /// the gap to the fleet figure); empty when there is none.
    pub outside: String,
    /// One row per group, costliest first; empty while a group is open or the cut is `sessions`.
    pub groups: Vec<Tot>,
    /// The sessions, when the cut is `sessions` or a group is open.
    pub rows: Vec<SessRow>,
    /// Rows past the `SESSION_ROWS` shown.
    pub more: usize,
    /// What the shown rows add up to.
    pub shown_usd: String,
    /// The session table's controls; None while the groups are shown.
    pub table: Option<Summary>,
    /// The opened session (`sid`): one bar per chart day, a gap where it cost nothing.
    pub series: Option<Series>,
}

#[derive(Clone, Debug, Default, PartialEq, Serialize)]
pub struct Series {
    pub sid: String,
    pub session: String,
    pub total: String,
    pub bars: Vec<Bar>,
}

/// Which day to show (`LIVE`, or empty for it), the cut and the group opened, the session table's
/// own sort, and the session opened.
#[derive(Clone, Copy, Debug, Default)]
pub struct Pick<'a> {
    pub day: &'a str,
    pub sort: &'a str,
    pub dir: &'a str,
    pub sid: &'a str,
    pub group: &'a str,
    pub in_group: &'a str,
}

/// The live day, from `fleet-cost.json`: the whole fleet's figure and its session rows.
pub fn live(f: crate::fleet_cost::File) -> Day {
    let (usd, estimated) = f.figure();
    Day {
        date: LIVE.into(),
        usd: usd.max(0.0),
        estimated,
        sessions: Arc::new(f.by_session),
    }
}

/// The spend table for `pick.day` (the live day when empty, else the newest snapshot with rows).
pub fn day_view(all: &[Day], live: Option<&Day>, pick: &Pick) -> DayView {
    let Pick {
        day,
        sort,
        dir,
        sid,
        group,
        in_group,
    } = *pick;
    let live = live.filter(|d| !d.sessions.is_empty());
    let none = |why: String| DayView {
        day: day.to_string(),
        why: Some(why),
        ..DayView::default()
    };
    let d =
        if day == LIVE {
            match live {
                Some(d) => d,
                None => {
                    return none(
                        "the last 24h: no session rows (agent-usage fleet-cost by_session)".into(),
                    )
                }
            }
        } else if day.is_empty() {
            match live.or_else(|| all.iter().rev().find(|d| !d.sessions.is_empty())) {
                Some(d) => d,
                None => return DayView {
                    why: Some(
                        "no snapshot keeps session rows yet (agent-usage fleet-cost by_session)"
                            .into(),
                    ),
                    ..DayView::default()
                },
            }
        } else {
            match all.iter().find(|d| d.date == day && !d.sessions.is_empty()) {
                Some(d) => d,
                None => {
                    return none(format!(
                        "{day}: no session rows (no snapshot, or one from before they were kept)"
                    ))
                }
            }
        };
    let group = GROUPS
        .iter()
        .find(|g| **g == group)
        .copied()
        .unwrap_or(GROUPS[0]);
    let everyone: Vec<&Sess> = d.sessions.iter().collect();
    let members: Vec<&Sess> = if group == "sessions" || in_group.is_empty() {
        vec![]
    } else {
        everyone
            .iter()
            .filter(|s| cut(s, group) == in_group)
            .copied()
            .collect()
    };
    // A group no row is in (a stale link) is no group: the groups show.
    let opened = !members.is_empty();
    let label = if d.date == LIVE { "last 24h" } else { &d.date };
    let sum: f64 = everyone.iter().map(|s| s.usd).sum();
    let gap = d.usd - sum;
    let outside = if gap >= 0.5 {
        format!(
            "+{} not in a session row{}",
            dollars(gap),
            if d.date == LIVE {
                " (helper calls and the gateway)"
            } else {
                ""
            }
        )
    } else {
        String::new()
    };
    let mut groups: Vec<Tot> = vec![];
    if group != "sessions" && !opened {
        let mut by: HashMap<String, Vec<&Sess>> = HashMap::new();
        for s in &everyone {
            by.entry(cut(s, group)).or_default().push(s);
        }
        groups = by.iter().map(|(k, v)| tot(k, v, d.usd)).collect();
        groups.sort_by(|a, b| b.cost.total_cmp(&a.cost).then_with(|| a.name.cmp(&b.name)));
    }
    let mut view = DayView {
        day: d.date.clone(),
        head: format!(
            "{label}: {} sessions, {} of the day's {}",
            d.sessions.len(),
            dollars(sum),
            dollars(d.usd)
        ),
        group: group.to_string(),
        cuts: &GROUPS,
        live: d.date == LIVE,
        has_live: live.is_some(),
        in_group: if opened {
            in_group.to_string()
        } else {
            String::new()
        },
        total: Some(tot("total", &everyone, d.usd)),
        open: opened.then(|| tot(in_group, &members, d.usd)),
        outside,
        groups,
        ..DayView::default()
    };
    if group != "sessions" && !opened {
        return view;
    }
    // The chart's 30 days, which the opened session's bars cover too.
    let newest = all.last().map_or(d.date.as_str(), |x| x.date.as_str());
    let since = day_number(newest) - CHART_DAYS as i64;
    let mut seen: HashMap<&str, u64> = HashMap::new();
    for x in all.iter().filter(|x| day_number(&x.date) > since) {
        for s in x.sessions.iter() {
            *seen.entry(s.sid.as_str()).or_default() += 1;
        }
    }
    let shown: &[&Sess] = if opened { &members } else { &everyone };
    // Costliest first under no sort, whatever order the file kept.
    let mut all_rows: Vec<SessRow> = shown
        .iter()
        .map(|s| SessRow {
            sid: s.sid.clone(),
            session: name(s),
            who: who(s),
            project: s.project.clone(),
            harness: s.harness.clone(),
            cost: s.usd,
            share: pct(s.usd, d.usd),
            est: est_pct(s.usd, s.measured),
            days: seen.get(s.sid.as_str()).copied().unwrap_or(1),
        })
        .collect();
    all_rows.sort_by(|a, b| b.cost.total_cmp(&a.cost).then_with(|| a.sid.cmp(&b.sid)));
    let v = View::new::<SessRow>("", "", sort, dir);
    let (kept, table) = v.summary(&all_rows);
    view.more = kept.len().saturating_sub(SESSION_ROWS);
    view.shown_usd = dollars(kept.iter().map(|r| r.cost).sum());
    view.rows = kept.into_iter().take(SESSION_ROWS).cloned().collect();
    view.table = Some(table);
    // The opened session is named as the picked day's row names it, else as its newest day does.
    view.series = d
        .sessions
        .iter()
        .chain(all.iter().rev().flat_map(|x| x.sessions.iter()))
        .find(|s| !sid.is_empty() && s.sid == sid)
        .map(|s| {
            let mut bars = chart(&[], newest);
            let mut total = 0.0;
            for b in &mut bars {
                let hit = all
                    .iter()
                    .find(|x| x.date == b.key)
                    .and_then(|x| x.sessions.iter().find(|y| y.sid == sid));
                if let Some(h) = hit {
                    total += h.usd;
                    b.usd = Some(h.usd);
                    b.measured = h.measured;
                    b.estimated = (h.usd - h.measured).max(0.0);
                    b.tip = format!("{}: {}", b.key, dollars(h.usd));
                } else {
                    b.tip = format!("{}: nothing", b.key);
                }
            }
            Series {
                sid: sid.to_string(),
                session: name(s),
                total: dollars(total),
                bars,
            }
        });
    view
}

/// A session's name in the table: its title, else its queue item, else its agent, else its id.
fn name(s: &Sess) -> String {
    [&s.title, &s.item, &s.agent]
        .into_iter()
        .flatten()
        .find(|t| !t.is_empty())
        .cloned()
        .unwrap_or_else(|| s.sid.chars().take(8).collect())
}

/// `YYYY-MM-DD` for a `day_number`.
fn date_of(n: i64) -> String {
    (chrono::NaiveDate::default() + chrono::Duration::days(n))
        .format("%Y-%m-%d")
        .to_string()
}

/// Year or month rows, newest first, each against the calendar period before it by $/day; a period
/// after one with no priced day is set against nothing.
fn rollup(days: &[Day], kind: &'static str, len: usize) -> Vec<Period> {
    let mut groups: Vec<(String, Sums)> = vec![];
    for d in days {
        let key = d.date.get(..len).unwrap_or(&d.date);
        match groups.last_mut() {
            Some(g) if g.0 == key => g.1.add(Sums::of(d)),
            _ => groups.push((key.to_string(), Sums::of(d))),
        }
    }
    let mut out: Vec<Period> = groups
        .iter()
        .enumerate()
        .map(|(i, (key, sums))| {
            let prev = i
                .checked_sub(1)
                .map(|j| &groups[j])
                .filter(|g| g.0 == previous(key))
                .map(|g| g.1.usd / g.1.days as f64);
            period(kind, key, *sums, prev)
        })
        .collect();
    out.reverse();
    out
}

/// What a period adds up: the fleet's dollars and the estimated part, its priced days, and its
/// session rows (a session on two days is two rows) and what they cost.
#[derive(Clone, Copy, Default)]
struct Sums {
    usd: f64,
    est: f64,
    days: usize,
    sess_usd: f64,
    sess_n: usize,
}

impl Sums {
    fn of(d: &Day) -> Sums {
        Sums {
            usd: d.usd,
            est: d.estimated,
            days: 1,
            sess_usd: d.sessions.iter().map(|s| s.usd).sum(),
            sess_n: d.sessions.len(),
        }
    }
    fn add(&mut self, o: Sums) {
        self.usd += o.usd;
        self.est += o.est;
        self.days += o.days;
        self.sess_usd += o.sess_usd;
        self.sess_n += o.sess_n;
    }
}

fn period(kind: &'static str, key: &str, s: Sums, prev_per_day: Option<f64>) -> Period {
    let per_day = s.usd / s.days as f64;
    Period {
        kind,
        period: key.to_string(),
        total: dollars(s.usd),
        days: s.days,
        per_day: dollars(per_day),
        per_session: if s.sess_n == 0 {
            "-".into()
        } else {
            dollars(s.sess_usd / s.sess_n as f64)
        },
        vs_prev: prev_per_day.map_or("-".into(), |p| change(per_day, p)),
        est: format!("{:.0}%", (s.est / s.usd * 100.0).clamp(0.0, 100.0)),
    }
}

/// The month clause and the last day clause: `Nov $1,579/day vs Oct $1,102/day (+43%)` and
/// `11-09 $1,312 vs 7d median $1,120 (+17%)`; either is empty with nothing to say.
fn headline(days: &[Day]) -> (String, String) {
    let months = rollup(days, "month", 7);
    let per_day = |p: &Period| format!("{} {}/day", month_name(&p.period), p.per_day);
    let mut month = String::new();
    if let Some(now) = months.first() {
        month = per_day(now);
        if let Some(prev) = months.get(1).filter(|m| m.period == previous(&now.period)) {
            month += &format!(" vs {} ({})", per_day(prev), now.vs_prev);
        }
    }
    let mut day = String::new();
    if let Some((last, before)) = days.split_last() {
        let mut s = format!(
            "{} {}",
            last.date.get(5..).unwrap_or(&last.date),
            dollars(last.usd)
        );
        let since = day_number(&last.date) - MEDIAN_DAYS as i64;
        let mut prior: Vec<f64> = before
            .iter()
            .filter(|d| day_number(&d.date) >= since)
            .map(|d| d.usd)
            .collect();
        if !prior.is_empty() {
            prior.sort_by(f64::total_cmp);
            let m = prior.len();
            let med = if m % 2 == 1 {
                prior[m / 2]
            } else {
                (prior[m / 2 - 1] + prior[m / 2]) / 2.0
            };
            s += &format!(
                " vs {m}d median {} ({})",
                dollars(med),
                change(last.usd, med)
            );
        }
        day = s;
    }
    (month, day)
}

/// The period before `2026` or `2026-01`: `2025`, `2025-12`.
fn previous(key: &str) -> String {
    let year = key
        .get(..4)
        .and_then(|y| y.parse::<i32>().ok())
        .unwrap_or(0);
    match key.get(5..7).and_then(|m| m.parse::<u32>().ok()) {
        Some(1) => format!("{}-12", year - 1),
        Some(m) => format!("{year}-{:02}", m - 1),
        None => (year - 1).to_string(),
    }
}

fn change(now: f64, prev: f64) -> String {
    if prev <= 0.0 {
        return "-".into();
    }
    format!("{:+.0}%", (now - prev) / prev * 100.0)
}

pub(crate) fn month_name(ym: &str) -> String {
    const NAMES: [&str; 12] = [
        "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
    ];
    ym.get(5..7)
        .and_then(|m| m.parse::<usize>().ok())
        .and_then(|m| NAMES.get(m.wrapping_sub(1)))
        .map_or_else(|| ym.to_string(), |n| n.to_string())
}

/// Days since the epoch for `YYYY-MM-DD`; a malformed date is day 0.
fn day_number(date: &str) -> i64 {
    chrono::NaiveDate::parse_from_str(date, "%Y-%m-%d")
        .map(|d| {
            d.signed_duration_since(chrono::NaiveDate::default())
                .num_days()
        })
        .unwrap_or(0)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn day(date: &str, usd: f64, est: f64) -> Day {
        Day {
            date: date.into(),
            usd,
            estimated: est,
            ..Day::default()
        }
    }

    #[test]
    fn months_compare_per_day_so_a_running_month_is_not_read_as_cheaper() {
        // October: 2 days at $100; November so far: 1 day at $150.
        let d = [
            day("2026-10-30", 100.0, 100.0),
            day("2026-10-31", 100.0, 0.0),
            day("2026-11-01", 150.0, 30.0),
        ];
        let h = build(&d, "2026-11-02");
        let nov = h.rows.iter().find(|r| r.period == "2026-11").unwrap();
        assert_eq!(
            (
                nov.total.as_str(),
                nov.per_day.as_str(),
                nov.vs_prev.as_str()
            ),
            ("$150", "$150", "+50%")
        );
        let oct = h.rows.iter().find(|r| r.period == "2026-10").unwrap();
        assert_eq!(
            (oct.days, oct.est.as_str(), oct.vs_prev.as_str()),
            (2, "50%", "-")
        );
        let year = &h.rows[0];
        assert_eq!(
            (
                year.kind,
                year.period.as_str(),
                year.total.as_str(),
                year.days
            ),
            ("year", "2026", "$350", 3)
        );
        assert_eq!(
            (h.month.as_str(), h.last_day.as_str()),
            (
                "Nov $150/day vs Oct $100/day (+50%)",
                "11-01 $150 vs 2d median $100 (+50%)"
            )
        );
        assert!(!h.stale);
    }

    #[test]
    fn a_gap_day_is_missing_not_free_and_breaks_the_day_comparison() {
        let d = [day("2026-11-01", 100.0, 0.0), day("2026-11-03", 200.0, 0.0)];
        let h = build(&d, "2026-11-04");
        assert_eq!(h.missing, 1);
        let days: Vec<_> = h.rows.iter().filter(|r| r.kind == "day").collect();
        assert_eq!(days[0].period, "11-03");
        assert_eq!(
            days[0].vs_prev, "-",
            "11-02 has no figure, so 11-03 is set against nothing"
        );
        let nov = h.rows.iter().find(|r| r.kind == "month").unwrap();
        assert_eq!((nov.days, nov.per_day.as_str()), (2, "$150"));
    }

    #[test]
    fn a_month_after_an_empty_one_and_a_median_across_a_gap_compare_only_what_is_adjacent() {
        let d = [
            day("2025-12-31", 70.0, 0.0),
            day("2026-01-01", 80.0, 0.0),
            day("2026-03-03", 90.0, 0.0),
            day("2026-03-09", 60.0, 0.0),
        ];
        let h = build(&d, "2026-03-10");
        let row = |p: &str| {
            h.rows
                .iter()
                .find(|r| r.period == p)
                .unwrap()
                .vs_prev
                .clone()
        };
        assert_eq!(
            (row("2026-03"), row("2026-01"), row("2026")),
            ("-".into(), "+14%".into(), "+10%".into())
        );
        assert_eq!(
            (h.month.as_str(), h.last_day.as_str()),
            ("Mar $75/day", "03-09 $60 vs 1d median $90 (-33%)"),
            "February is empty; 03-03 is the one day in the 7 before 03-09"
        );
    }

    #[test]
    fn day_rows_cap_and_count_the_older_ones() {
        let d: Vec<Day> = (1..=20)
            .map(|i| day(&format!("2026-11-{i:02}"), 10.0, 0.0))
            .collect();
        let h = build(&d, "2026-11-21");
        assert_eq!(h.rows.iter().filter(|r| r.kind == "day").count(), DAY_ROWS);
        assert_eq!(h.older, 20 - DAY_ROWS);
        assert_eq!(
            h.rows.iter().find(|r| r.kind == "day").unwrap().period,
            "11-20",
            "newest day first"
        );
    }

    #[test]
    fn a_stopped_nightly_run_is_stale() {
        assert!(build(&[day("2026-11-01", 1.0, 0.0)], "2026-11-05").stale);
    }

    #[test]
    fn no_snapshot_says_so_and_shows_no_dollars() {
        let h = build(&[], "2026-11-05");
        assert!(h.why.is_some());
        assert!(h.rows.is_empty());
    }

    #[test]
    fn read_keeps_days_with_no_figure_at_zero_and_build_counts_them_missing() {
        let dir = std::env::temp_dir().join(format!("spend-history-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let put = |d: &str, s: &str| std::fs::write(dir.join(format!("{d}.json")), s).unwrap();
        put(
            "2026-11-01",
            r#"{"fleet_cost":{"total":{"usd":12.5,"estimated":2.5}},"other":[1,2]}"#,
        );
        put("2026-11-02", r#"{"fleet_cost":null}"#);
        put(
            "2026-11-03",
            r#"{"fleet_cost":{"total":{"usd":0,"estimated":0}}}"#,
        );
        put("2026-11-04", "not json");
        let got = read(&dir);
        std::fs::remove_dir_all(&dir).unwrap();
        assert_eq!(
            got.iter().map(|d| d.usd).collect::<Vec<_>>(),
            vec![12.5, 0.0, 0.0, 0.0]
        );
        let h = build(&got, "2026-11-05");
        assert_eq!(
            (h.missing, h.rows.iter().filter(|r| r.kind == "day").count()),
            (3, 1)
        );
        assert!(h.stale, "the newest priced day is 11-01");
    }

    #[test]
    fn unpriced_days_before_the_first_priced_one_are_missing() {
        let d = [
            day("2026-10-30", 0.0, 0.0),
            day("2026-10-31", 0.0, 0.0),
            day("2026-11-01", 50.0, 0.0),
        ];
        let h = build(&d, "2026-11-02");
        assert_eq!(h.missing, 2);
        assert!(
            h.rows.iter().all(|r| r.period != "2026-10"),
            "an unpriced month gets no row"
        );
    }

    fn sess(sid: &str, usd: f64, measured: f64, project: &str) -> Sess {
        Sess {
            sid: sid.into(),
            usd,
            measured,
            project: Some(project.into()),
            ..Sess::default()
        }
    }

    #[test]
    fn the_chart_is_thirty_calendar_days_with_a_gap_never_a_zero_bar() {
        let h = build(
            &[
                day("2026-11-07", 30.0, 10.0),
                day("2026-11-08", 0.0, 0.0),
                day("2026-11-10", 50.0, 0.0),
            ],
            "2026-11-11",
        );
        assert_eq!(h.chart.len(), CHART_DAYS);
        assert_eq!(h.chart.last().unwrap().key, "2026-11-10");
        assert_eq!(h.chart[0].key, "2026-10-12");
        let at = |k: &str| h.chart.iter().find(|b| b.key == k).unwrap();
        assert_eq!(at("2026-11-08").usd, None, "an unpriced day is a gap");
        assert_eq!(at("2026-11-09").usd, None, "a day with no file is a gap");
        assert_eq!(at("2026-11-08").tip, "2026-11-08: no figure");
        assert_eq!(
            (at("2026-11-07").measured, at("2026-11-07").estimated),
            (20.0, 10.0)
        );
        assert_eq!(h.months.len(), 1);
        assert_eq!(h.months[0].usd, Some(80.0), "the $0 day adds nothing");
    }

    fn sess_of(sid: &str, usd: f64, origin: &str, project: &str) -> Sess {
        Sess {
            origin: Some(origin.into()),
            ..sess(sid, usd, usd, project)
        }
    }

    #[test]
    fn who_names_every_origin_runner_and_harness_the_way_the_old_fleet_rows_did() {
        let s = |origin: Option<&str>, harness: Option<&str>, agent: Option<&str>| {
            who(&Sess {
                origin: origin.map(Into::into),
                harness: harness.map(Into::into),
                agent: agent.map(Into::into),
                ..Sess::default()
            })
        };
        let claude = Some("claude");
        assert_eq!(s(Some("queue"), claude, None), "queue items");
        assert_eq!(s(Some("run"), claude, None), "queue, dispatch run");
        assert_eq!(s(Some("hand"), claude, None), "queue, hand-started");
        assert_eq!(s(Some("plan"), claude, None), "queue, plan");
        assert_eq!(s(Some("shepherd"), claude, None), "shepherd");
        assert_eq!(s(Some("interactive"), claude, None), "you, interactive");
        assert_eq!(s(Some("resume"), claude, None), "queue, resume");
        assert_eq!(s(Some("runner"), claude, Some("dream")), "dream");
        assert_eq!(
            s(Some("runner"), claude, Some("ask-judge")),
            "runner, ask-judge"
        );
        assert_eq!(s(Some("runner"), None, None), "runner, unnamed");
        assert_eq!(
            s(None, None, None),
            "unknown",
            "an old snapshot row has no origin"
        );
        assert_eq!(
            s(Some("interactive"), Some("codex"), None),
            "codex",
            "another harness is its own name, whatever started it"
        );
        assert_eq!(s(Some("hand"), Some("opencode"), Some("x")), "opencode");
    }

    fn spend_days() -> Vec<Day> {
        let mut a = day("2026-11-08", 40.0, 0.0);
        a.sessions = vec![sess("s1", 10.0, 10.0, "dotfiles")].into();
        let mut b = day("2026-11-09", 100.0, 0.0);
        b.sessions = vec![
            sess("s1", 20.0, 5.0, "dotfiles"),
            sess("s2", 70.0, 70.0, "playground"),
        ]
        .into();
        vec![day("2026-11-07", 9.0, 0.0), a, b]
    }

    #[test]
    fn the_session_table_ranks_opens_a_sessions_own_days_and_rows_carry_a_session_day() {
        let all = spend_days();
        let by_sessions = Pick {
            group: "sessions",
            ..Pick::default()
        };
        let v = day_view(&all, None, &by_sessions);
        assert_eq!(
            v.day, "2026-11-09",
            "no live day and none picked: the newest with rows"
        );
        assert_eq!(
            v.rows.iter().map(|r| r.sid.as_str()).collect::<Vec<_>>(),
            ["s2", "s1"]
        );
        assert_eq!(
            (v.rows[1].share, v.rows[1].est, v.rows[1].days),
            (20.0, 75.0, 2)
        );
        assert_eq!(v.head, "2026-11-09: 2 sessions, $90 of the day's $100");
        assert!(v.table.as_ref().unwrap().facets.is_empty(), "no dropdowns");
        // $/session: a day's session rows over their count, a month weighted by its rows, and a
        // day from before rows were kept is `-`, never $0.
        let h = build(&all, "2026-11-10");
        let per = |k: &str| {
            h.rows
                .iter()
                .find(|r| r.period == k)
                .map(|r| r.per_session.clone())
                .unwrap()
        };
        assert_eq!(per("11-09"), "$45");
        assert_eq!(per("11-08"), "$10");
        assert_eq!(per("11-07"), "-");
        assert_eq!(
            per("2026-11"),
            "$33",
            "three rows cost $100, not the mean of $45 and $10"
        );
        let back = day_view(
            &all,
            None,
            &Pick {
                day: "2026-11-08",
                ..by_sessions
            },
        );
        assert_eq!(back.rows.len(), 1);
        let none = day_view(
            &all,
            None,
            &Pick {
                day: "2026-11-07",
                ..by_sessions
            },
        );
        assert_eq!(none.day, "2026-11-07", "the picked day stays picked");
        assert!(none.rows.is_empty() && none.why.as_deref().unwrap().contains("no session rows"));
        let s = day_view(
            &all,
            None,
            &Pick {
                sid: "s1",
                ..by_sessions
            },
        )
        .series
        .unwrap();
        assert_eq!(s.total, "$30");
        let got: Vec<_> = s
            .bars
            .iter()
            .filter_map(|b| b.usd.map(|u| (b.key.as_str(), u)))
            .collect();
        assert_eq!(got, [("2026-11-08", 10.0), ("2026-11-09", 20.0)]);
        assert!(day_view(&[], None, &Pick::default()).why.is_some());
    }

    #[test]
    fn the_table_opens_grouped_by_who_with_a_total_that_the_groups_add_up_to() {
        let mut live = day(LIVE, 130.0, 20.0);
        live.sessions = vec![
            sess_of("a", 60.0, "queue", "dotfiles"),
            sess_of("b", 30.0, "queue", "playground"),
            Sess {
                agent: Some("dream".into()),
                ..sess_of("c", 10.0, "runner", "dotfiles")
            },
            Sess {
                agent: Some("ask-judge".into()),
                ..sess_of("d", 20.0, "runner", "dotfiles")
            },
        ]
        .into();
        let all = spend_days();
        let v = day_view(&all, Some(&live), &Pick::default());
        assert_eq!(v.day, LIVE, "the live day is the default pick");
        assert_eq!(v.group, "who");
        assert_eq!(v.head, "last 24h: 4 sessions, $120 of the day's $130");
        let t = v.total.as_ref().unwrap();
        assert_eq!((t.sessions, t.cost, t.per_session), (4, 120.0, 30.0));
        assert!((t.share - 120.0 / 130.0 * 100.0).abs() < 1e-9);
        assert_eq!(
            v.groups
                .iter()
                .map(|g| (g.name.as_str(), g.cost))
                .collect::<Vec<_>>(),
            [
                ("queue items", 90.0),
                ("runner, ask-judge", 20.0),
                ("dream", 10.0)
            ],
            "costliest first"
        );
        let sum: f64 = v.groups.iter().map(|g| g.cost).sum();
        assert_eq!(sum, t.cost, "the groups add up to the total row");
        assert_eq!(
            v.outside, "+$10 not in a session row (helper calls and the gateway)",
            "the fleet figure less its session rows"
        );
        assert!(
            v.rows.is_empty() && v.table.is_none(),
            "groups, not sessions"
        );
        // another cut: the same rows, regrouped, with the same total
        let by = |group: &str| {
            day_view(
                &all,
                Some(&live),
                &Pick {
                    group,
                    ..Pick::default()
                },
            )
        };
        let p = by("project");
        assert_eq!(
            p.groups
                .iter()
                .map(|g| (g.name.as_str(), g.sessions))
                .collect::<Vec<_>>(),
            [("dotfiles", 3), ("playground", 1)]
        );
        assert_eq!(p.total, v.total);
        let h = by("harness");
        assert_eq!(
            h.groups[0].name, "unknown",
            "a row with no harness is unknown, not dropped"
        );
        assert_eq!(by("account").groups.len(), 1);
        assert_eq!(by("nonsense").group, "who", "an unknown cut is the default");
        // a group opened: its sessions, its own total, the day's total unchanged
        let o = day_view(
            &all,
            Some(&live),
            &Pick {
                in_group: "queue items",
                ..Pick::default()
            },
        );
        assert_eq!(o.in_group, "queue items");
        assert_eq!(
            o.rows.iter().map(|r| r.sid.as_str()).collect::<Vec<_>>(),
            ["a", "b"]
        );
        let g = o.open.as_ref().unwrap();
        assert_eq!(
            (g.name.as_str(), g.sessions, g.cost, g.per_session),
            ("queue items", 2, 90.0, 45.0)
        );
        assert_eq!(o.total, v.total);
        assert!(o.groups.is_empty() && o.table.is_some());
        // a link to a group no row is in shows the groups again
        let stale = day_view(
            &all,
            Some(&live),
            &Pick {
                in_group: "nobody",
                ..Pick::default()
            },
        );
        assert!(stale.in_group.is_empty() && !stale.groups.is_empty());
        // a chart bar picks a snapshot day over the live one, and the live day is `24h`
        let past = day_view(
            &all,
            Some(&live),
            &Pick {
                day: "2026-11-09",
                ..Pick::default()
            },
        );
        assert_eq!(past.day, "2026-11-09");
        assert_eq!(past.outside, "+$10 not in a session row");
        assert_eq!(
            day_view(
                &all,
                Some(&live),
                &Pick {
                    day: LIVE,
                    ..Pick::default()
                }
            )
            .day,
            LIVE
        );
        assert!(day_view(
            &all,
            None,
            &Pick {
                day: LIVE,
                ..Pick::default()
            }
        )
        .why
        .is_some());
    }

    #[test]
    fn a_live_file_with_no_session_rows_leaves_the_newest_snapshot_the_default() {
        let all = spend_days();
        let empty = day(LIVE, 50.0, 0.0);
        assert_eq!(
            day_view(&all, Some(&empty), &Pick::default()).day,
            "2026-11-09"
        );
    }

    #[test]
    fn a_fleet_cost_file_becomes_the_live_day() {
        let f: crate::fleet_cost::File = serde_json::from_value(serde_json::json!({
            "total": {"usd": 50.0, "measured": 40.0, "estimated": 10.0},
            "by_session": [{"sid": "x", "usd": 30.0, "measured": 30.0, "origin": "hand"}]
        }))
        .unwrap();
        let d = live(f);
        assert_eq!(
            (d.date.as_str(), d.usd, d.estimated, d.sessions.len()),
            (LIVE, 50.0, 10.0, 1)
        );
    }
}
