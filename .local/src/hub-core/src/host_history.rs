//! One machine's last days, for its page (`#infra/machines/<host>`, `machine_page`): its CPU
//! busy share and the cores each CI pool's jobs used, folded to one bucket an hour; the stretches
//! it gave no reading (`Down`, the downtime list); and, for a host the governor powers, each start
//! and stop with its reason and the hours it ran per UTC day. Read from Prometheus with range
//! queries only when a page is opened, never on the board's cadence, all at one step (`STEP`) over
//! `DAYS` days, which is what Prometheus keeps (home-config `helm-values.yaml` retention).
//!
//! | part   | series                                                                            |
//! |--------|-----------------------------------------------------------------------------------|
//! | cpu    | `cc:host_cpu_busy_ratio{host}`: node exporter's busy share; a missing sample is no reading |
//! | pools  | `cc:runner_cores_busy{host,runner}` joined to `github_runner_state{name,pool}`, summed by pool |
//! | power  | the governor's own `ci_governor_power_state{host}` (home-config apps/ci-runner-governor); hours counted from the samples, not from its `hours_today` gauge (that gauge restarted at 0 on an override start, 2026-11-10) |

use std::collections::BTreeMap;

use serde::Serialize;

use crate::prom::{self, Series};
use crate::table::{Row, Val};

/// How far back a history reaches.
pub const DAYS: u64 = 7;
/// Seconds between samples: the governor's cycle is about 2 minutes, so one sample per cycle,
/// and the `cc:*` rules evaluate every minute.
pub const STEP: u64 = 120;
/// Seconds per history bucket: an hour, so a week is 168 columns on either surface.
pub const BUCKET: u64 = 3600;
/// The state written for a stretch with no sample at all (the governor down or not yet run).
pub const NO_READING: &str = "no reading";

#[derive(Serialize, Debug, PartialEq, Clone)]
pub struct Change {
    /// Unix seconds of the first sample in this state.
    pub at: u64,
    /// stopped, starting, running, draining, stopping, or `NO_READING`.
    pub state: String,
    /// Why the governor last powered it (queue, idle, cap, override), "none" before it has.
    pub reason: String,
}

#[derive(Serialize, Debug, PartialEq, Clone)]
pub struct Day {
    /// The UTC day, YYYY-MM-DD: the governor's day cap resets at 00:00 UTC.
    pub day: String,
    /// Hours its samples read anything but stopped, `STEP` seconds per sample.
    pub hours: f64,
}

/// A powered host's starts and stops.
#[derive(Serialize, Debug, PartialEq, Clone)]
pub struct PowerHistory {
    pub host: String,
    pub from: u64,
    pub to: u64,
    pub step: u64,
    /// Oldest first: one row per change of state or reason.
    pub changes: Vec<Change>,
    /// Oldest first: only days with a sample.
    pub days: Vec<Day>,
}

/// A host name the governor could export: letters, digits, `-`, `_` and `.`, so it is safe
/// inside the query's label matcher.
pub fn valid_host(host: &str) -> bool {
    !host.is_empty()
        && host.len() <= 64
        && host
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || matches!(c, '-' | '_' | '.'))
}

/// One hour of the history.
#[derive(Serialize, Debug, PartialEq, Clone, Default)]
pub struct Hour {
    /// Unix seconds the hour starts.
    pub at: u64,
    /// The mean CPU busy share of the hour's samples; none when it gave no reading.
    pub cpu: Option<f64>,
    /// The mean cores each pool's CI jobs used, by pool.
    pub pools: BTreeMap<String, f64>,
    /// The share of the hour's steps with a CPU reading: 1 up all hour, 0 no reading.
    pub seen: f64,
}

/// A stretch with no CPU reading: the host down, asleep, powered off or not scraped.
#[derive(Serialize, Debug, PartialEq, Clone, Default)]
pub struct Down {
    /// Unix seconds of the last reading before it, else the window's start.
    pub from: u64,
    /// The first reading after it, else now while it lasts.
    pub to: u64,
    /// It lasts now.
    pub open: bool,
    /// `powered off by the governor` when its power state said so, else `no reading`.
    pub why: String,
}

/// The downtime list on both surfaces, newest first.
impl Row for Down {
    const COLUMNS: &'static [&'static str] = &["from", "to", "took", "why"];
    const STATES: &'static [&'static str] = &["all", "now", "powered off"];
    const FACETS: &'static [&'static str] = &["why"];
    const LEAD: &'static str = "from";
    const GLANCE: &'static [&'static str] = &["took"];

    fn val(&self, col: &str) -> Val {
        match col {
            "from" => Val::Num(self.from as f64),
            "to" if self.open => Val::None,
            "to" => Val::Num(self.to as f64),
            "took" => Val::Num(self.to.saturating_sub(self.from) as f64),
            "why" => Val::Text(self.why.clone()),
            _ => Val::None,
        }
    }
    fn in_state(&self, s: &str) -> bool {
        match s {
            "now" => self.open,
            "powered off" => self.why == POWERED_OFF,
            _ => false,
        }
    }
}

/// Why a stretch had no reading, when the governor had the host powered off then.
pub const POWERED_OFF: &str = "powered off by the governor";

/// A machine's last `DAYS` days.
#[derive(Serialize, Debug, PartialEq, Clone, Default)]
pub struct HostHistory {
    pub host: String,
    pub from: u64,
    pub to: u64,
    pub step: u64,
    pub bucket: u64,
    /// Oldest first, one per `BUCKET` from `from`.
    pub hours: Vec<Hour>,
    /// Newest first.
    pub down: Vec<Down>,
    /// How many CPU samples it gave: 0 is a host with no node exporter reading in the window.
    pub readings: usize,
    /// The governor's power history, for a host it powers.
    pub power: Option<PowerHistory>,
    /// `<part>: <why>` for each part that could not be read; the rest still show.
    pub errors: Vec<String>,
}

/// One range query over the window at `STEP`.
fn range(base: &str, q: String, from: u64, now: u64) -> Result<Vec<Series>, String> {
    prom::query(
        base,
        "query_range",
        &[
            ("query", q),
            ("start", from.to_string()),
            ("end", now.to_string()),
            ("step", STEP.to_string()),
        ],
    )
}

/// A `host=~"a|b"` matcher over a machine's names, each checked by `valid_host`.
fn hosts_matcher(names: &[String]) -> Result<String, String> {
    if let Some(bad) = names.iter().find(|h| !valid_host(h)) {
        return Err(format!("{bad:?} is not a host name"));
    }
    // A name holds only letters, digits, `-`, `_` and `.`: only the dot needs escaping.
    let alts: Vec<String> = names.iter().map(|h| h.replace('.', "\\\\.")).collect();
    Ok(format!(r#"host=~"{}""#, alts.join("|")))
}

/// Ask Prometheus for a machine's last `DAYS` days: `names` are every name it goes by (its host
/// label first), `powered` the governor's name for it when the governor powers it. A part that
/// fails is an error line; the rest still read.
pub fn read(names: &[String], powered: Option<&str>, now: u64) -> Result<HostHistory, String> {
    let host = names.first().ok_or("no host name")?.clone();
    let m = hosts_matcher(names)?;
    if let Some(p) = powered.filter(|p| !valid_host(p)) {
        return Err(format!("{p:?} is not a host name"));
    }
    let base = prom::base()?;
    let from = now.saturating_sub(DAYS * 86_400);
    let mut errors = vec![];
    let mut part = |name: &str, r: Result<Vec<Series>, String>| {
        r.map_err(|e| errors.push(format!("{name}: {e}")))
            .unwrap_or_default()
    };
    let cpu = part(
        "cpu",
        range(
            &base,
            format!("max(cc:host_cpu_busy_ratio{{{m}}})"),
            from,
            now,
        ),
    );
    let pools = part(
        "pools",
        range(
            &base,
            format!(
                r#"sum by (pool) (cc:runner_cores_busy{{{m}}} * on (runner) group_left (pool) group by (runner, pool) (label_replace(github_runner_state, "runner", "$1", "name", "(.+)")))"#
            ),
            from,
            now,
        ),
    );
    let power = powered.and_then(|p| {
        power(&base, p, from, now)
            .map_err(|e| errors.push(format!("power: {e}")))
            .ok()
    });
    let mut h = history(&host, &cpu, &pools, power, from, now);
    h.errors = errors;
    Ok(h)
}

/// The history from the CPU and pool series and the power history: pure, for the tests.
pub fn history(
    host: &str,
    cpu: &[Series],
    pools: &[Series],
    power: Option<PowerHistory>,
    from: u64,
    to: u64,
) -> HostHistory {
    let n = to.saturating_sub(from).div_ceil(BUCKET).max(1);
    let mut hours: Vec<Hour> = (0..n)
        .map(|i| Hour {
            at: from + i * BUCKET,
            ..Default::default()
        })
        .collect();
    let slot = |t: u64| ((t.saturating_sub(from)) / BUCKET).min(n - 1) as usize;
    let mut times: Vec<u64> = vec![];
    let mut sums: Vec<(f64, u32)> = vec![(0.0, 0); n as usize];
    for s in cpu {
        for (t, v) in &s.points {
            let t = *t as u64;
            times.push(t);
            let e = &mut sums[slot(t)];
            e.0 += v;
            e.1 += 1;
        }
    }
    times.sort();
    times.dedup();
    let per = (BUCKET / STEP) as f64;
    for (h, (sum, k)) in hours.iter_mut().zip(&sums) {
        if *k > 0 {
            h.cpu = Some(sum / *k as f64);
        }
    }
    let mut seen = vec![0u32; n as usize];
    for t in &times {
        seen[slot(*t)] += 1;
    }
    for (h, k) in hours.iter_mut().zip(seen) {
        h.seen = (k as f64 / per).min(1.0);
    }
    for s in pools {
        let pool = s.label("pool");
        if pool.is_empty() {
            continue;
        }
        let mut by: BTreeMap<usize, (f64, u32)> = BTreeMap::new();
        for (t, v) in &s.points {
            let e = by.entry(slot(*t as u64)).or_default();
            e.0 += v;
            e.1 += 1;
        }
        for (i, (sum, k)) in by {
            // The mean over the hour's steps, a missing step counting as no cores used.
            hours[i]
                .pools
                .insert(pool.to_string(), sum / per.max(k as f64));
        }
    }
    let mut down = gaps(&times, from, to);
    for d in &mut down {
        d.why = match &power {
            Some(p) if off_at(p, d.from + STEP) => POWERED_OFF.into(),
            _ => NO_READING.into(),
        };
    }
    down.reverse();
    HostHistory {
        host: host.to_string(),
        from,
        to,
        step: STEP,
        bucket: BUCKET,
        hours,
        readings: times.len(),
        down,
        power,
        errors: vec![],
    }
}

/// The stretches between readings more than one step apart, and an open one from the last
/// reading to now when the readings stop. None at all is one open stretch over the whole window.
fn gaps(times: &[u64], from: u64, to: u64) -> Vec<Down> {
    let mut out = vec![];
    let (Some(first), Some(last)) = (times.first(), times.last()) else {
        return vec![Down {
            from,
            to,
            open: true,
            ..Default::default()
        }];
    };
    if *first > from + 2 * STEP {
        out.push(Down {
            from,
            to: *first,
            ..Default::default()
        });
    }
    for w in times.windows(2) {
        if w[1] > w[0] + STEP {
            out.push(Down {
                from: w[0],
                to: w[1],
                ..Default::default()
            });
        }
    }
    if to > last + 2 * STEP {
        out.push(Down {
            from: *last,
            to,
            open: true,
            ..Default::default()
        });
    }
    out
}

/// The governor had it stopped (or stopping) at `t`: its last change at or before then says so.
fn off_at(p: &PowerHistory, t: u64) -> bool {
    p.changes
        .iter()
        .rev()
        .find(|c| c.at <= t)
        .is_some_and(|c| matches!(c.state.as_str(), "stopped" | "stopping"))
}

/// Ask Prometheus for the governor's power samples of `host` (its own name for it) since `from`.
fn power(base: &str, host: &str, from: u64, now: u64) -> Result<PowerHistory, String> {
    let q = format!(r#"max by (state, reason) (ci_governor_power_state{{host="{host}"}})"#);
    Ok(fold(host, &range(base, q, from, now)?, from, now))
}

/// Each sample as (time, state, reason), oldest first, then one change per new state or
/// reason, and a `NO_READING` change where samples skip more than one step.
pub fn fold(host: &str, series: &[Series], from: u64, to: u64) -> PowerHistory {
    let mut samples: Vec<(u64, &str, &str)> = series
        .iter()
        .flat_map(|s| {
            let (state, reason) = (s.label("state"), s.label("reason"));
            s.points
                .iter()
                .map(move |(t, _)| (*t as u64, state, reason))
        })
        .collect();
    samples.sort();
    // One sample per time: two series at one step (a change on a scrape boundary) count once.
    samples.dedup_by_key(|(t, _, _)| *t);
    let mut changes: Vec<Change> = Vec::new();
    let mut hours: BTreeMap<String, f64> = BTreeMap::new();
    let mut last_t: Option<u64> = None;
    for (t, state, reason) in samples {
        let gap_from = last_t.map_or(from, |prev| prev + STEP);
        if t > gap_from + STEP {
            push(&mut changes, gap_from, NO_READING, "");
        }
        push(&mut changes, t, state, reason);
        let day = hours.entry(utc_day(t)).or_default();
        if state != "stopped" {
            *day += STEP as f64 / 3600.0;
        }
        last_t = Some(t);
    }
    // Samples that end before `to`: the governor stopped exporting, so its last state is not now.
    if let Some(prev) = last_t {
        if to > prev + 2 * STEP {
            push(&mut changes, prev + STEP, NO_READING, "");
        }
    }
    PowerHistory {
        host: host.to_string(),
        from,
        to,
        step: STEP,
        changes,
        days: hours
            .into_iter()
            .map(|(day, h)| Day {
                day,
                hours: (h * 10.0).round() / 10.0,
            })
            .collect(),
    }
}

fn push(changes: &mut Vec<Change>, at: u64, state: &str, reason: &str) {
    if changes
        .last()
        .is_some_and(|c| c.state == state && c.reason == reason)
    {
        return;
    }
    changes.push(Change {
        at,
        state: state.to_string(),
        reason: reason.to_string(),
    });
}

fn utc_day(t: u64) -> String {
    chrono::DateTime::from_timestamp(t as i64, 0)
        .map(|d| d.format("%Y-%m-%d").to_string())
        .unwrap_or_default()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn series(state: &str, reason: &str, times: &[u64]) -> Series {
        Series {
            labels: [("state", state), ("reason", reason)]
                .into_iter()
                .map(|(k, v)| (k.to_string(), v.to_string()))
                .collect(),
            value: None,
            points: times.iter().map(|t| (*t as f64, 1.0)).collect(),
        }
    }

    // 2026-11-10 23:56Z: two samples before midnight, two after.
    const T: u64 = 1_794_354_960;

    #[test]
    fn the_same_state_twice_is_one_change_and_a_new_reason_is_another() {
        let h = fold(
            "aws-burst-1",
            &[
                series("running", "queue", &[T, T + STEP]),
                series("stopped", "idle", &[T + 2 * STEP]),
                series("stopped", "cap", &[T + 3 * STEP]),
            ],
            T,
            T + 3 * STEP,
        );
        let got: Vec<_> = h
            .changes
            .iter()
            .map(|c| (c.at, c.state.as_str(), c.reason.as_str()))
            .collect();
        assert_eq!(
            got,
            vec![
                (T, "running", "queue"),
                (T + 2 * STEP, "stopped", "idle"),
                (T + 3 * STEP, "stopped", "cap"),
            ]
        );
    }

    #[test]
    fn hours_are_counted_per_utc_day_from_the_samples() {
        let h = fold(
            "aws-burst-1",
            &[series(
                "running",
                "override",
                &(0..60).map(|i| T + i * STEP).collect::<Vec<_>>(),
            )],
            T,
            T + 59 * STEP,
        );
        // 2 samples on 11-10, 58 on 11-11, 2 minutes each.
        assert_eq!(
            h.days,
            vec![
                Day {
                    day: "2026-11-10".into(),
                    hours: 0.1
                },
                Day {
                    day: "2026-11-11".into(),
                    hours: 1.9
                },
            ]
        );
    }

    #[test]
    fn a_stopped_day_reads_zero_and_a_gap_reads_no_reading() {
        let h = fold(
            "aws-burst-2",
            &[
                series("stopped", "idle", &[T + 10 * STEP]),
                series("running", "queue", &[T]),
            ],
            T,
            T + 10 * STEP,
        );
        let states: Vec<_> = h.changes.iter().map(|c| c.state.as_str()).collect();
        assert_eq!(states, vec!["running", NO_READING, "stopped"]);
        assert_eq!(h.changes[1].at, T + STEP);
        assert_eq!(
            h.days[1],
            Day {
                day: "2026-11-11".into(),
                hours: 0.0
            }
        );
    }

    #[test]
    fn a_duplicate_time_counts_once_and_missing_ends_read_no_reading() {
        let h = fold(
            "aws-burst-1",
            &[
                series("running", "queue", &[T + 5 * STEP]),
                series("stopped", "idle", &[T + 5 * STEP]),
            ],
            T,
            T + 20 * STEP,
        );
        let states: Vec<_> = h.changes.iter().map(|c| c.state.as_str()).collect();
        assert_eq!(states, vec![NO_READING, "running", NO_READING]);
        assert_eq!(
            h.days,
            vec![Day {
                day: "2026-11-11".into(),
                hours: 0.0
            }]
        );
    }

    #[test]
    fn a_history_stays_under_prometheus_point_cap() {
        assert!(DAYS * 86_400 / STEP < 11_000);
    }

    #[test]
    fn only_a_plain_host_name_reaches_the_query() {
        assert!(valid_host("aws-burst-1"));
        assert!(!valid_host(r#"x"} or vector(1) #"#));
        assert!(!valid_host(""));
    }

    fn cpu(times: &[u64]) -> Series {
        Series {
            labels: Default::default(),
            value: None,
            points: times.iter().map(|t| (*t as f64, 0.5)).collect(),
        }
    }

    fn pool(name: &str, points: &[(u64, f64)]) -> Series {
        Series {
            labels: [("pool".to_string(), name.to_string())]
                .into_iter()
                .collect(),
            value: None,
            points: points.iter().map(|(t, v)| (*t as f64, *v)).collect(),
        }
    }

    #[test]
    fn a_gap_in_the_readings_is_a_downtime_and_a_stop_at_the_end_is_open() {
        let mut t: Vec<u64> = (0..10).map(|i| T + i * STEP).collect();
        t.extend((20..25).map(|i| T + i * STEP));
        let h = history("razer-laptop", &[cpu(&t)], &[], None, T, T + 40 * STEP);
        let got: Vec<_> = h.down.iter().map(|d| (d.from, d.to, d.open)).collect();
        assert_eq!(
            got,
            vec![
                (T + 24 * STEP, T + 40 * STEP, true),
                (T + 9 * STEP, T + 20 * STEP, false),
            ],
            "newest first"
        );
        assert!(h.down.iter().all(|d| d.why == NO_READING));
        assert_eq!(h.readings, 15);
    }

    #[test]
    fn a_host_with_no_reading_at_all_is_one_open_stretch_and_says_so() {
        let h = history("aws-burst-1", &[], &[], None, T, T + 7200);
        assert_eq!(h.readings, 0);
        assert_eq!(
            h.down,
            vec![Down {
                from: T,
                to: T + 7200,
                open: true,
                why: NO_READING.into()
            }]
        );
        assert!(h.hours.iter().all(|x| x.cpu.is_none() && x.seen == 0.0));
    }

    #[test]
    fn a_stretch_the_governor_had_it_stopped_says_powered_off() {
        let p = fold(
            "aws-burst-1",
            &[
                series("running", "queue", &[T]),
                series("stopped", "idle", &[T + STEP]),
            ],
            T,
            T + 30 * STEP,
        );
        let h = history(
            "aws-burst-1",
            &[cpu(&[T, T + 20 * STEP])],
            &[],
            Some(p),
            T,
            T + 20 * STEP,
        );
        assert_eq!(h.down.len(), 1);
        assert_eq!(h.down[0].why, POWERED_OFF);
        assert!(h.down[0].in_state("powered off"));
    }

    #[test]
    fn each_hour_holds_its_mean_cpu_its_seen_share_and_each_pools_cores() {
        let t: Vec<u64> = (0..15).map(|i| T + i * STEP).collect();
        let h = history(
            "razer-laptop",
            &[cpu(&t)],
            &[pool("unity", &[(T, 3.0), (T + STEP, 3.0)])],
            None,
            T,
            T + 2 * BUCKET,
        );
        assert_eq!(h.hours.len(), 2);
        assert_eq!(h.hours[0].cpu, Some(0.5));
        assert_eq!(h.hours[0].seen, 0.5, "15 of 30 steps");
        assert_eq!(h.hours[1].cpu, None);
        // Two steps at 3 cores of the hour's 30: a missing step used none.
        assert_eq!(h.hours[0].pools["unity"], 0.2);
    }

    #[test]
    fn every_name_goes_into_the_matcher_and_a_bad_one_is_refused() {
        assert_eq!(
            hosts_matcher(&["workstation".into(), "cachyos-x8664-main".into()]).unwrap(),
            r#"host=~"workstation|cachyos-x8664-main""#
        );
        assert_eq!(
            hosts_matcher(&["a.lan".into()]).unwrap(),
            r#"host=~"a\\.lan""#
        );
        assert!(hosts_matcher(&[r#"x"} or vector(1) #"#.into()]).is_err());
    }
}
