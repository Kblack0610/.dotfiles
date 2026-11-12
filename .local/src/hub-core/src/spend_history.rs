//! The Costs tab's History section: the whole fleet's dollars per day, month and year, from the
//! `fleet_cost.total` of every nightly token snapshot (`agent-usage tokens snapshot`, the one
//! writer). Rolled up here on read and never stored, so the hub TUI, `hub --once` and agent-web
//! show the same rows (dashboards rule 8). A day with no figure is missing, never $0.

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
    pub head: String,
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
    History {
        why: None,
        head: headline(days),
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

/// One session's row in a day's table.
#[derive(Clone, Debug, Default, PartialEq, Serialize)]
pub struct SessRow {
    pub sid: String,
    /// What the session was: its title, else its queue item, else its agent.
    pub session: String,
    pub project: Option<String>,
    pub origin: Option<String>,
    pub agent: Option<String>,
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
        "session", "project", "origin", "agent", "harness", "cost", "share", "est", "days",
    ];
    const STATES: &'static [&'static str] = &["all"];
    const FACETS: &'static [&'static str] = &[];
    const LEAD: &'static str = "session";
    const GLANCE: &'static [&'static str] = &["cost", "share", "project"];

    fn val(&self, col: &str) -> Val {
        let text = |s: &Option<String>| s.as_ref().map_or(Val::None, |s| Val::Text(s.clone()));
        match col {
            "session" => Val::Text(self.session.clone()),
            "project" => text(&self.project),
            "origin" => text(&self.origin),
            "agent" => text(&self.agent),
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
        [
            Some(&self.session),
            Some(&self.sid),
            self.project.as_ref(),
            self.origin.as_ref(),
            self.agent.as_ref(),
        ]
        .into_iter()
        .flatten()
        .cloned()
        .collect::<Vec<_>>()
        .join("\n")
        .to_lowercase()
    }
}

/// One day's sessions, and the opened session's own days.
#[derive(Clone, Debug, Default, PartialEq, Serialize)]
pub struct DayView {
    /// The day shown (`YYYY-MM-DD`); empty when no snapshot has session rows yet.
    pub day: String,
    pub head: String,
    pub why: Option<String>,
    pub rows: Vec<SessRow>,
    /// Rows past the `SESSION_ROWS` shown.
    pub more: usize,
    /// What the day's rows add up to.
    pub shown_usd: String,
    /// The table's controls; None when there are no session rows to show.
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

/// Which day's sessions to show, the table's own sort, and the session opened.
#[derive(Clone, Copy, Debug, Default)]
pub struct Pick<'a> {
    pub day: &'a str,
    pub sort: &'a str,
    pub dir: &'a str,
    pub sid: &'a str,
}

/// The table for `day` (the newest day with session rows when empty or unknown), under its own
/// sort, with the session `sid` opened when it is set.
pub fn day_view(all: &[Day], pick: &Pick) -> DayView {
    let Pick {
        day,
        sort,
        dir,
        sid,
    } = *pick;
    if !day.is_empty() && !all.iter().any(|d| d.date == day && !d.sessions.is_empty()) {
        return DayView {
            day: day.to_string(),
            why: Some(format!(
                "{day}: no session rows (no snapshot, or one from before they were kept)"
            )),
            ..DayView::default()
        };
    }
    let Some(d) = all
        .iter()
        .rev()
        .find(|d| !d.sessions.is_empty() && (day.is_empty() || d.date == day))
    else {
        return DayView {
            why: Some(
                "no snapshot keeps session rows yet (agent-usage fleet-cost by_session)".into(),
            ),
            ..DayView::default()
        };
    };
    // The chart's 30 days, which the opened session's bars cover too.
    let newest = all.last().map_or(d.date.as_str(), |x| x.date.as_str());
    let since = day_number(newest) - CHART_DAYS as i64;
    let mut seen: HashMap<&str, u64> = HashMap::new();
    for x in all.iter().filter(|x| day_number(&x.date) > since) {
        for s in x.sessions.iter() {
            *seen.entry(s.sid.as_str()).or_default() += 1;
        }
    }
    // Costliest first under no sort, whatever order the file kept.
    let mut all_rows: Vec<SessRow> = d
        .sessions
        .iter()
        .map(|s| SessRow {
            sid: s.sid.clone(),
            session: name(s),
            project: s.project.clone(),
            origin: s.origin.clone(),
            agent: s.agent.clone(),
            harness: s.harness.clone(),
            cost: s.usd,
            share: if d.usd > 0.0 {
                s.usd / d.usd * 100.0
            } else {
                0.0
            },
            est: if s.usd > 0.0 {
                ((s.usd - s.measured) / s.usd * 100.0).clamp(0.0, 100.0)
            } else {
                0.0
            },
            days: seen.get(s.sid.as_str()).copied().unwrap_or(1),
        })
        .collect();
    all_rows.sort_by(|a, b| b.cost.total_cmp(&a.cost).then_with(|| a.sid.cmp(&b.sid)));
    let v = View::new::<SessRow>("", "", sort, dir);
    let (kept, table) = v.summary(&all_rows);
    let shown: f64 = kept.iter().map(|r| r.cost).sum();
    let more = kept.len().saturating_sub(SESSION_ROWS);
    // The opened session is named as the picked day's row names it, else as its newest day does.
    let series = d
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
    DayView {
        day: d.date.clone(),
        head: format!(
            "{}: {} sessions, {} of the day's {}",
            d.date,
            d.sessions.len(),
            dollars(d.sessions.iter().map(|s| s.usd).sum()),
            dollars(d.usd)
        ),
        why: None,
        rows: kept.into_iter().take(SESSION_ROWS).cloned().collect(),
        more,
        shown_usd: dollars(shown),
        table: Some(table),
        series,
    }
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

/// `Nov $1,579/day vs Oct $1,102/day (+43%); 11-09 $1,312 vs 7d median $1,120 (+17%)`.
fn headline(days: &[Day]) -> String {
    let months = rollup(days, "month", 7);
    let per_day = |p: &Period| format!("{} {}/day", month_name(&p.period), p.per_day);
    let mut parts = vec![];
    if let Some(now) = months.first() {
        let mut s = per_day(now);
        if let Some(prev) = months.get(1).filter(|m| m.period == previous(&now.period)) {
            s += &format!(" vs {} ({})", per_day(prev), now.vs_prev);
        }
        parts.push(s);
    }
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
        parts.push(s);
    }
    parts.join("; ")
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

fn dollars(usd: f64) -> String {
    crate::fleet_cost::dollars(usd)
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
            h.head,
            "Nov $150/day vs Oct $100/day (+50%); 11-01 $150 vs 2d median $100 (+50%)"
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
            h.head, "Mar $75/day; 03-09 $60 vs 1d median $90 (-33%)",
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

    #[test]
    fn the_day_table_ranks_and_opens_a_sessions_own_days_and_rows_carry_a_session_day() {
        let mut a = day("2026-11-08", 40.0, 0.0);
        a.sessions = vec![sess("s1", 10.0, 10.0, "dotfiles")].into();
        let mut b = day("2026-11-09", 100.0, 0.0);
        b.sessions = vec![
            sess("s1", 20.0, 5.0, "dotfiles"),
            sess("s2", 70.0, 70.0, "playground"),
        ]
        .into();
        let older = day("2026-11-07", 9.0, 0.0);
        let all = [older, a, b];
        let v = day_view(&all, &Pick::default());
        assert_eq!(v.day, "2026-11-09", "no day picked: the newest with rows");
        assert_eq!(
            v.rows.iter().map(|r| r.sid.as_str()).collect::<Vec<_>>(),
            ["s2", "s1"]
        );
        assert_eq!(
            (v.rows[1].share, v.rows[1].est, v.rows[1].days),
            (20.0, 75.0, 2)
        );
        assert_eq!(v.head, "2026-11-09: 2 sessions, $90 of the day's $100");
        assert!(
            v.table.as_ref().unwrap().facets.is_empty(),
            "no dropdowns over the table"
        );
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
            &Pick {
                day: "2026-11-08",
                ..Pick::default()
            },
        );
        assert_eq!(back.rows.len(), 1);
        let none = day_view(
            &all,
            &Pick {
                day: "2026-11-07",
                ..Pick::default()
            },
        );
        assert_eq!(none.day, "2026-11-07", "the picked day stays picked");
        assert!(none.rows.is_empty() && none.why.as_deref().unwrap().contains("no session rows"));
        assert_eq!(
            day_view(&all, &Pick::default()).rows[1].days,
            2,
            "days counts the chart's range"
        );
        let s = day_view(
            &all,
            &Pick {
                sid: "s1",
                ..Pick::default()
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
        assert!(day_view(&[], &Pick::default()).why.is_some());
    }
}
