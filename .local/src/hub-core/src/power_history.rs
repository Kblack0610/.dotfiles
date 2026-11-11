//! A governed cloud host's power over the last days, for the Infra tab's Cloud runners card:
//! each start and stop with its reason, and the hours it ran per UTC day. Read from the
//! governor's own `ci_governor_power_state` series (home-config apps/ci-runner-governor), one
//! sample every `STEP` seconds, so the hours are counted from the samples, not from the
//! governor's `hours_today` gauge (that gauge restarted at 0 on an override start, 2026-11-10).
//! Read only when a host's history is opened, never on the board's cadence.

use std::collections::BTreeMap;

use serde::Serialize;

use crate::prom::{self, Series};

/// How far back a history reaches.
pub const DAYS: u64 = 7;
/// Seconds between samples: the governor's cycle is about 2 minutes, so one sample per cycle.
pub const STEP: u64 = 120;
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

#[derive(Serialize, Debug, PartialEq, Clone)]
pub struct History {
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

/// Ask Prometheus for `host`'s last `DAYS` days and fold them.
pub fn read(host: &str, now: u64) -> Result<History, String> {
    if !valid_host(host) {
        return Err(format!("{host:?} is not a host name"));
    }
    let base = prom::base()?;
    let from = now.saturating_sub(DAYS * 86_400);
    let q = format!(r#"max by (state, reason) (ci_governor_power_state{{host="{host}"}})"#);
    let series = prom::query(
        &base,
        "query_range",
        &[
            ("query", q),
            ("start", from.to_string()),
            ("end", now.to_string()),
            ("step", STEP.to_string()),
        ],
    )?;
    Ok(fold(host, &series, from, now))
}

/// Each sample as (time, state, reason), oldest first, then one change per new state or
/// reason, and a `NO_READING` change where samples skip more than one step.
pub fn fold(host: &str, series: &[Series], from: u64, to: u64) -> History {
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
    History {
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
}
