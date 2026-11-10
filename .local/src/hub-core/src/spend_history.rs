//! The Costs tab's History section: the whole fleet's dollars per day, month and year, from the
//! `fleet_cost.total` of every nightly token snapshot (`agent-usage tokens snapshot`, the one
//! writer). Rolled up here on read and never stored, so the hub TUI, `hub --once` and agent-web
//! show the same rows (dashboards rule 8). A day with no figure is missing, never $0.

use serde::{Deserialize, Serialize};
use std::path::Path;

/// Day rows shown before the "+N older" line.
pub const DAY_ROWS: usize = 14;
/// The days the newest day is set against in the headline.
const MEDIAN_DAYS: usize = 7;

pub const NOTE: &str = "$ is the whole fleet's day from the nightly token snapshot; vs prev compares $/day with the period before; est. is the share priced from tokens, not billed (100% before billing records, 2026-10-29).";

#[derive(Deserialize, Default)]
#[serde(default)]
struct Snap {
    fleet_cost: Option<Fc>,
}

#[derive(Deserialize, Default)]
#[serde(default)]
struct Fc {
    total: Option<Total>,
}

#[derive(Deserialize, Default)]
#[serde(default)]
struct Total {
    usd: f64,
    estimated: f64,
}

/// One priced day.
#[derive(Clone, Debug, PartialEq)]
pub struct Day {
    pub date: String,
    pub usd: f64,
    pub estimated: f64,
}

/// One row: a year (`2026`), a month (`2026-11`) or a day (`11-09`).
#[derive(Clone, Debug, Default, PartialEq, Serialize)]
pub struct Period {
    pub kind: &'static str,
    pub period: String,
    pub total: String,
    pub days: usize,
    pub per_day: String,
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
}

/// Every snapshot day, oldest first. A file that does not parse, or a total that is missing or $0
/// (no rate to price it with), reads as $0, which `build` counts as missing.
pub fn read(dir: &Path) -> Vec<Day> {
    crate::boards::days(dir)
        .into_iter()
        .map(|date| {
            let t = std::fs::read_to_string(dir.join(format!("{date}.json")))
                .ok()
                .and_then(|text| serde_json::from_str::<Snap>(&text).ok())
                .and_then(|s| s.fleet_cost?.total)
                .unwrap_or_default();
            Day {
                date,
                usd: t.usd.max(0.0),
                estimated: t.estimated,
            }
        })
        .collect()
}

/// The section from the snapshot days (oldest first) and today's local date (`YYYY-MM-DD`).
pub fn build(all: &[Day], today: &str) -> History {
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
                d.usd,
                d.estimated,
                1,
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
    }
}

/// Year or month rows, newest first, each against the calendar period before it by $/day; a period
/// after one with no priced day is set against nothing.
fn rollup(days: &[Day], kind: &'static str, len: usize) -> Vec<Period> {
    let mut groups: Vec<(String, f64, f64, usize)> = vec![];
    for d in days {
        let key = d.date.get(..len).unwrap_or(&d.date);
        match groups.last_mut() {
            Some(g) if g.0 == key => {
                g.1 += d.usd;
                g.2 += d.estimated;
                g.3 += 1;
            }
            _ => groups.push((key.to_string(), d.usd, d.estimated, 1)),
        }
    }
    let mut out: Vec<Period> = groups
        .iter()
        .enumerate()
        .map(|(i, (key, usd, est, n))| {
            let prev = i
                .checked_sub(1)
                .map(|j| &groups[j])
                .filter(|g| g.0 == previous(key))
                .map(|g| g.1 / g.3 as f64);
            period(kind, key, *usd, *est, *n, prev)
        })
        .collect();
    out.reverse();
    out
}

fn period(
    kind: &'static str,
    key: &str,
    usd: f64,
    est: f64,
    n: usize,
    prev_per_day: Option<f64>,
) -> Period {
    let per_day = usd / n as f64;
    Period {
        kind,
        period: key.to_string(),
        total: dollars(usd),
        days: n,
        per_day: dollars(per_day),
        vs_prev: prev_per_day.map_or("-".into(), |p| change(per_day, p)),
        est: format!("{:.0}%", (est / usd * 100.0).clamp(0.0, 100.0)),
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

fn month_name(ym: &str) -> String {
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
}
