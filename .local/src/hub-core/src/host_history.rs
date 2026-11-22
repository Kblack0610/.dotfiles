//! One machine's last days, for its page (`#infra/machines/<host>`, `machine_page`): its CPU
//! busy share and the cores each CI pool's jobs used, folded to one bucket an hour; its downtime
//! records (`Down`, the downtime list); and, for a host the governor powers, each start and stop
//! with its reason and the hours it ran per UTC day. Read only when a page is opened, never on
//! the board's cadence: the series from Prometheus with range queries at one step (`STEP`) over
//! `DAYS` days, which is what Prometheus keeps (home-config `helm-values.yaml` retention), the
//! records from Loki over the same days.
//!
//! | part   | series                                                                            |
//! |--------|-----------------------------------------------------------------------------------|
//! | cpu    | `cc:host_cpu_busy_ratio{host}`: node exporter's busy share; a missing sample is no reading |
//! | temp   | `cc:host_temp_c{host}`: its hottest CPU sensor, the hour's largest sample              |
//! | pools  | `cc:job_kind_cores{host,runner,kind}`: a busy runner's cores by its job's kind, summed by kind |
//! | power  | the governor's own `ci_governor_power_state{host}` (home-config apps/ci-runner-governor); hours counted from the samples, not from its `hours_today` gauge (that gauge restarted at 0 on an override start, 2026-11-10) |
//! | down   | Loki `{job="host-downtime", host}`: one JSON record per boot or Ready drop with its cause, written by home-config's cluster-janitor (`docs/host-tiers.md` "Downtime records"), through `kube_proxy` (`CC_KUBE_CONTEXT`, `CC_LOKI_SERVICE`) |

use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};

use crate::kube_proxy::{self, encode};
use crate::prom::{self, Series};
use crate::reading::NO_DATA;
use crate::table::{Row, Val};

/// How far back a history reaches.
pub const DAYS: u64 = 7;
/// Seconds between samples: the governor's cycle is about 2 minutes, so one sample per cycle,
/// and the `cc:*` rules evaluate every minute.
pub const STEP: u64 = 120;

// A history stays under the Prometheus point cap of 11,000 per series.
const _: () = assert!(DAYS * 86_400 / STEP < 11_000);

/// Seconds per history bucket: an hour, so a week is 168 columns on either surface.
pub const BUCKET: u64 = 3600;

#[derive(Serialize, Debug, PartialEq, Clone)]
pub struct Change {
    /// Unix seconds of the first sample in this state.
    pub at: u64,
    /// stopped, starting, running, draining, stopping, or `NO_DATA` for a gap.
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

/// A host (or pool) name the governor could export: letters, digits, `-`, `_` and `.`, so it
/// is safe inside the query's label matcher.
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
    /// The mean cores each kind of CI job used, by kind (the pool names `cc:pool_*` use).
    pub pools: BTreeMap<String, f64>,
    /// The share of the hour's steps with a CPU reading: 1 up all hour, 0 no reading.
    pub seen: f64,
    /// Its CPU's hottest sample of the hour, degrees C; none when it gave no reading.
    pub temp: Option<f64>,
}

/// One downtime record: a boot or Ready drop of the host, with the scrape loss around it, and
/// its cause. The cluster-janitor writes it once the downtime has been over 5 minutes, so one
/// still going has none yet (NodeDown pages while it lasts).
#[derive(Serialize, Debug, PartialEq, Clone, Default)]
pub struct Down {
    /// `<host>@<start>`, the same on every janitor run; a taint reason names it.
    pub id: String,
    /// Unix seconds it started.
    pub from: u64,
    /// Unix seconds it ended.
    pub to: u64,
    /// planned, power, control-plane, network, kernel, host or unknown.
    pub cause: String,
    /// The evidence for the cause, `; ` between lines.
    pub why: String,
}

/// The downtime list on both surfaces, newest first.
impl Row for Down {
    const COLUMNS: &'static [&'static str] = &["from", "to", "took", "cause", "why"];
    const STATES: &'static [&'static str] = &["all", "unexplained"];
    const FACETS: &'static [&'static str] = &["cause"];
    const LEAD: &'static str = "from";
    const GLANCE: &'static [&'static str] = &["took", "cause"];

    fn val(&self, col: &str) -> Val {
        match col {
            "from" => Val::Num(self.from as f64),
            "to" => Val::Num(self.to as f64),
            "took" => Val::Num(self.to.saturating_sub(self.from) as f64),
            "cause" => Val::Text(self.cause.clone()),
            "why" => Val::Text(self.why.clone()),
            _ => Val::None,
        }
    }
    /// `unexplained`: the janitor found no cause, the records HostDownUnexplained pages on.
    fn in_state(&self, s: &str) -> bool {
        s == "unexplained" && self.cause == "unknown"
    }
}

/// The Loki stream the records are on, and the most asked of it for one machine: a week of one
/// host is a few dozen records.
const RECORDS: &str = "host-downtime";
const RECORD_LIMIT: usize = 1000;

/// A record as the janitor writes it (home-config `apps/cluster-janitor/downtime.py` `records`).
#[derive(Deserialize)]
struct Record {
    id: String,
    start: String,
    end: String,
    cause: String,
    evidence: Vec<String>,
}

/// The API server path that asks Loki for the records of the hosts `alt` matches (an
/// `alternation`), written between `from` and `to`.
fn records_path(alt: &str, from: u64, to: u64) -> String {
    let q = format!(r#"{{job="{RECORDS}", host=~"{alt}"}}"#);
    format!(
        "/loki/api/v1/query_range?query={}&start={}&end={}&limit={RECORD_LIMIT}&direction=backward",
        encode(&q),
        from * 1_000_000_000,
        to * 1_000_000_000,
    )
}

/// Loki's answer as the records of downtimes that ended at or after `from`, newest first, each
/// id once. A line that is no record is an error: the writer and this reader disagree.
pub fn records(body: &str, from: u64) -> Result<Vec<Down>, String> {
    let v: serde_json::Value =
        serde_json::from_str(body).map_err(|e| format!("Loki answer: {e}"))?;
    let streams = v["data"]["result"]
        .as_array()
        .ok_or("Loki answer has no data.result")?;
    let unix = |s: &str| {
        chrono::DateTime::parse_from_rfc3339(s)
            .map(|t| t.timestamp() as u64)
            .map_err(|e| format!("record time {s:?}: {e}"))
    };
    let mut out = vec![];
    for line in streams
        .iter()
        .flat_map(|s| s["values"].as_array().into_iter().flatten())
        .filter_map(|e| e[1].as_str())
    {
        let r: Record = serde_json::from_str(line).map_err(|e| format!("record {line:?}: {e}"))?;
        let d = Down {
            from: unix(&r.start)?,
            to: unix(&r.end)?,
            id: r.id,
            cause: r.cause,
            why: r.evidence.join("; "),
        };
        if d.to >= from {
            out.push(d);
        }
    }
    out.sort_by(|a, b| b.from.cmp(&a.from).then_with(|| a.id.cmp(&b.id)));
    out.dedup_by(|a, b| a.id == b.id);
    Ok(out)
}

/// Ask Loki for the records of the hosts `alt` matches since `from`.
fn downtime(alt: &str, from: u64, now: u64) -> Result<Vec<Down>, String> {
    let body = kube_proxy::get(
        &crate::session_actions::System,
        "CC_LOKI_SERVICE",
        &records_path(alt, from, now),
    )?;
    records(&body, from)
}

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
    /// Its downtime records, newest first (`read` fills them from Loki).
    pub down: Vec<Down>,
    /// How many CPU samples it gave: 0 is a host with no node exporter reading in the window.
    pub readings: usize,
    /// The governor's power history, for a host it powers.
    pub power: Option<PowerHistory>,
    /// `<part>: <why>` for each part that could not be read; the rest still show.
    pub errors: Vec<String>,
}

/// One range query over the window at `STEP`.
pub(crate) fn range(base: &str, q: String, from: u64, now: u64) -> Result<Vec<Series>, String> {
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
    Ok(format!(r#"host=~"{}""#, alternation(names)?))
}

/// `a|b\\.c`: a PromQL regex string matching any of `names`, refused unless each is a host name.
pub(crate) fn alternation(names: &[String]) -> Result<String, String> {
    if let Some(bad) = names.iter().find(|h| !valid_host(h)) {
        return Err(format!("{bad:?} is not a host name"));
    }
    // A name holds only letters, digits, `-`, `_` and `.`: only the dot needs escaping.
    let alts: Vec<String> = names.iter().map(|h| h.replace('.', "\\\\.")).collect();
    Ok(alts.join("|"))
}

/// The cores each kind of CI job used on the hosts `m` matches: `cc:job_kind_cores`, a busy
/// runner's cores labelled with its job's kind (home-config's recording rule over
/// `ci_runner_job`). A runner row is not keyed by its job's kind (an agnostic slot takes every
/// kind), so it is not what the cores are summed by.
fn pools_query(m: &str) -> String {
    format!("sum by (kind) (cc:job_kind_cores{{{m}}})")
}

/// Ask Prometheus and Loki for a machine's last `DAYS` days: `names` are every name it goes by
/// (its host label first), `powered` the governor's name for it when the governor powers it. A
/// part that fails is an error line; the rest still read.
pub fn read(names: &[String], powered: Option<&str>, now: u64) -> Result<HostHistory, String> {
    let host = names.first().ok_or("no host name")?.clone();
    let m = hosts_matcher(names)?;
    let alt = alternation(names)?;
    if let Some(p) = powered.filter(|p| !valid_host(p)) {
        return Err(format!("{p:?} is not a host name"));
    }
    let base = prom::base()?;
    let from = now.saturating_sub(DAYS * 86_400);
    let pools_q = pools_query(&m);
    // Each query reads 7 days; they run at once (power on this thread), so the page waits for
    // the slowest only.
    let base = base.as_str();
    let (cpu, temp, pools, down, power) = std::thread::scope(|s| {
        let q = |q: String| s.spawn(move || range(base, q, from, now));
        let cpu = q(format!("max(cc:host_cpu_busy_ratio{{{m}}})"));
        let temp = q(format!("max(cc:host_temp_c{{{m}}})"));
        let pools = q(pools_q);
        let down = s.spawn(|| downtime(&alt, from, now));
        let power = powered.map(|p| power(base, p, from, now));
        let down = down.join().unwrap_or_else(|_| Err("panicked".to_string()));
        let join = |h: std::thread::ScopedJoinHandle<'_, _>| {
            h.join().unwrap_or_else(|_| Err("panicked".to_string()))
        };
        (join(cpu), join(temp), join(pools), down, power)
    });
    let mut errors = vec![];
    let mut part = |name: &str, r: Result<Vec<Series>, String>| {
        r.map_err(|e| errors.push(format!("{name}: {e}")))
            .unwrap_or_default()
    };
    let (cpu, temp, pools) = (part("cpu", cpu), part("temp", temp), part("pools", pools));
    let power = power.and_then(|r| r.map_err(|e| errors.push(format!("power: {e}"))).ok());
    let down = down
        .map_err(|e| errors.push(format!("down: {e}")))
        .unwrap_or_default();
    let mut h = history(&host, &cpu, &temp, &pools, power, from, now);
    h.down = down;
    h.errors = errors;
    Ok(h)
}

/// One hour's samples: their sum, how many, and the largest.
#[derive(Debug, PartialEq, Clone, Copy)]
pub struct Bucket {
    pub sum: f64,
    pub n: u32,
    pub max: f64,
}

impl Default for Bucket {
    fn default() -> Self {
        Self {
            sum: 0.0,
            n: 0,
            max: f64::MIN,
        }
    }
}

impl Bucket {
    /// The mean of its samples; none when it had none.
    pub fn mean(&self) -> Option<f64> {
        (self.n > 0).then(|| self.sum / self.n as f64)
    }
    /// The largest of its samples; none when it had none.
    pub fn most(&self) -> Option<f64> {
        (self.n > 0).then_some(self.max)
    }
}

/// A window cut into `BUCKET`s from `from`: every page's history folds its range samples by
/// these hours (this module's, `pool_page`'s).
#[derive(Debug, Clone, Copy)]
pub struct Hours {
    pub from: u64,
    /// How many: at least one, the last holding a sample past its end.
    pub n: usize,
}

impl Hours {
    pub fn new(from: u64, to: u64) -> Self {
        Self {
            from,
            n: to.saturating_sub(from).div_ceil(BUCKET).max(1) as usize,
        }
    }
    /// Unix seconds hour `i` starts.
    pub fn at(&self, i: usize) -> u64 {
        self.from + i as u64 * BUCKET
    }
    /// The hour a sample at `t` falls in.
    pub fn slot(&self, t: u64) -> usize {
        ((t.saturating_sub(self.from) / BUCKET) as usize).min(self.n - 1)
    }
    /// Every sample of `series`, each in its hour.
    pub fn fold(&self, series: &[Series]) -> Vec<Bucket> {
        let mut by = vec![Bucket::default(); self.n];
        for s in series {
            for (t, v) in &s.points {
                let b = &mut by[self.slot(*t as u64)];
                b.sum += v;
                b.n += 1;
                b.max = b.max.max(*v);
            }
        }
        by
    }
}

/// The history from the CPU, temperature and pool series and the power history: pure, for the
/// tests.
pub fn history(
    host: &str,
    cpu: &[Series],
    temp: &[Series],
    pools: &[Series],
    power: Option<PowerHistory>,
    from: u64,
    to: u64,
) -> HostHistory {
    let span = Hours::new(from, to);
    let mut hours: Vec<Hour> = span
        .fold(cpu)
        .iter()
        .zip(span.fold(temp))
        .enumerate()
        .map(|(i, (b, t))| Hour {
            at: span.at(i),
            cpu: b.mean(),
            temp: t.most(),
            ..Default::default()
        })
        .collect();
    let mut times: Vec<u64> = cpu
        .iter()
        .flat_map(|s| s.points.iter().map(|(t, _)| *t as u64))
        .collect();
    times.sort();
    times.dedup();
    let per = (BUCKET / STEP) as f64;
    let mut seen = vec![0u32; span.n];
    for t in &times {
        seen[span.slot(*t)] += 1;
    }
    for (h, k) in hours.iter_mut().zip(seen) {
        h.seen = (k as f64 / per).min(1.0);
    }
    for s in pools {
        let kind = s.label("kind");
        if kind.is_empty() {
            continue;
        }
        for (h, b) in hours.iter_mut().zip(span.fold(std::slice::from_ref(s))) {
            // The mean over the hour's steps, a missing step counting as no cores used.
            if b.n > 0 {
                h.pools
                    .insert(kind.to_string(), b.sum / per.max(b.n as f64));
            }
        }
    }
    HostHistory {
        host: host.to_string(),
        from,
        to,
        step: STEP,
        bucket: BUCKET,
        hours,
        readings: times.len(),
        down: vec![],
        power,
        errors: vec![],
    }
}

/// Ask Prometheus for the governor's power samples of `host` (its own name for it) since `from`.
fn power(base: &str, host: &str, from: u64, now: u64) -> Result<PowerHistory, String> {
    let q = format!(r#"max by (state, reason) (ci_governor_power_state{{host="{host}"}})"#);
    Ok(fold(host, &range(base, q, from, now)?, from, now))
}

/// Each sample as (time, state, reason), oldest first, then one change per new state or
/// reason, and a `NO_DATA` change where samples skip more than one step.
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
            push(&mut changes, gap_from, NO_DATA, "");
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
            push(&mut changes, prev + STEP, NO_DATA, "");
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
        assert_eq!(states, vec!["running", NO_DATA, "stopped"]);
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
        assert_eq!(states, vec![NO_DATA, "running", NO_DATA]);
        assert_eq!(
            h.days,
            vec![Day {
                day: "2026-11-11".into(),
                hours: 0.0
            }]
        );
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

    fn kind(name: &str, points: &[(u64, f64)]) -> Series {
        Series {
            labels: [("kind".to_string(), name.to_string())]
                .into_iter()
                .collect(),
            value: None,
            points: points.iter().map(|(t, v)| (*t as f64, *v)).collect(),
        }
    }

    #[test]
    fn a_host_with_no_reading_at_all_has_no_reading_in_any_hour() {
        let h = history("aws-burst-1", &[], &[], &[], None, T, T + 7200);
        assert_eq!(h.readings, 0);
        assert!(
            h.down.is_empty(),
            "the downtime list is the records, not the gaps"
        );
        assert!(h.hours.iter().all(|x| x.cpu.is_none() && x.seen == 0.0));
    }

    /// A Loki answer holding `lines` as the values of two streams, the way Loki splits a host's
    /// records by their `cause` label.
    fn loki(lines: &[&str]) -> String {
        let (a, b) = lines.split_at(lines.len() / 2);
        let values = |ls: &[&str]| -> Vec<serde_json::Value> {
            ls.iter()
                .enumerate()
                .map(|(i, l)| {
                    serde_json::json!([format!("{}", 1_800_000_000_000_000_000u64 + i as u64), l])
                })
                .collect()
        };
        serde_json::json!({"status": "success", "data": {"resultType": "streams", "result": [
            {"stream": {"job": "host-downtime", "host": "asus-laptop", "cause": "kernel"}, "values": values(a)},
            {"stream": {"job": "host-downtime", "host": "asus-laptop", "cause": "unknown"}, "values": values(b)},
        ]}})
        .to_string()
    }

    // Lines as home-config's cluster-janitor writes them (test_downtime.RecordTests).
    const NVME: &str = r#"{"id": "asus-laptop@2026-11-20T14:02:12Z", "host": "asus-laptop", "start": "2026-11-20T14:02:12Z", "end": "2026-11-20T14:02:48Z", "cause": "kernel", "hosts": 1, "evidence": ["HostNvmeReset 14:10Z"]}"#;
    const LATER: &str = r#"{"id": "asus-laptop@2026-11-20T17:15:33Z", "host": "asus-laptop", "start": "2026-11-20T17:15:33Z", "end": "2026-11-20T17:15:48Z", "cause": "unknown", "hosts": 2, "evidence": ["shared with deskslim-1, fewer than 3 hosts", "no kernel line"]}"#;
    // 2026-11-20T14:00:00Z.
    const DAY: u64 = 1_795_183_200;

    #[test]
    fn records_read_newest_first_with_their_cause_and_evidence() {
        let got = records(&loki(&[NVME, LATER]), DAY).unwrap();
        assert_eq!(
            got,
            vec![
                Down {
                    id: "asus-laptop@2026-11-20T17:15:33Z".into(),
                    from: DAY + 3 * 3600 + 15 * 60 + 33,
                    to: DAY + 3 * 3600 + 15 * 60 + 48,
                    cause: "unknown".into(),
                    why: "shared with deskslim-1, fewer than 3 hosts; no kernel line".into(),
                },
                Down {
                    id: "asus-laptop@2026-11-20T14:02:12Z".into(),
                    from: DAY + 132,
                    to: DAY + 168,
                    cause: "kernel".into(),
                    why: "HostNvmeReset 14:10Z".into(),
                },
            ]
        );
        assert!(got[0].in_state("unexplained") && !got[1].in_state("unexplained"));
        assert_eq!(got[1].val("took"), Val::Num(36.0));
    }

    #[test]
    fn a_record_twice_reads_once_and_one_ended_before_the_window_not_at_all() {
        let got = records(&loki(&[NVME, LATER, LATER]), DAY).unwrap();
        assert_eq!(got.len(), 2, "{got:?}");
        let got = records(&loki(&[NVME, LATER]), DAY + 3600).unwrap();
        assert_eq!(got.len(), 1);
        assert_eq!(got[0].cause, "unknown");
        assert_eq!(records(&loki(&[]), DAY).unwrap(), vec![]);
    }

    #[test]
    fn a_line_that_is_no_record_is_an_error_not_a_shorter_list() {
        let e = records(&loki(&[NVME, r#"{"id": "x"}"#]), DAY).unwrap_err();
        assert!(e.starts_with("record "), "{e}");
        assert!(records("<html>", DAY)
            .unwrap_err()
            .starts_with("Loki answer"));
    }

    #[test]
    fn the_records_query_names_only_the_stream_and_this_machines_hosts() {
        let alt = alternation(&["workstation".into(), "a.lan".into()]).unwrap();
        let p = records_path(&alt, 10, 20);
        let q = r#"{job="host-downtime", host=~"workstation|a\\.lan"}"#;
        assert_eq!(
            p,
            format!(
                "/loki/api/v1/query_range?query={}&start=10000000000&end=20000000000&limit=1000&direction=backward",
                encode(q)
            )
        );
    }

    #[test]
    fn hours_fold_each_sample_into_its_hour_and_a_late_one_into_the_last() {
        let span = Hours::new(T, T + 2 * BUCKET);
        assert_eq!((span.n, span.at(1)), (2, T + BUCKET));
        let b = span.fold(&[kind(
            "unity",
            &[(T, 2.0), (T + 60, 4.0), (T + 9 * BUCKET, 7.0)],
        )]);
        assert_eq!(
            (b[0].mean(), b[0].most(), b[0].n),
            (Some(3.0), Some(4.0), 2)
        );
        assert_eq!(
            (b[1].mean(), b[1].n),
            (Some(7.0), 1),
            "past the end lands in the last hour"
        );
        let none = Hours::new(T, T).fold(&[]);
        assert_eq!(
            (none.len(), none[0].mean(), none[0].most()),
            (1, None, None)
        );
    }

    #[test]
    fn each_hour_holds_its_mean_cpu_hottest_temp_seen_share_and_each_pools_cores() {
        let t: Vec<u64> = (0..15).map(|i| T + i * STEP).collect();
        let h = history(
            "razer-laptop",
            &[cpu(&t)],
            &[kind("temp", &[(T, 70.0), (T + STEP, 82.0)])],
            &[
                kind("unity", &[(T, 3.0), (T + STEP, 3.0)]),
                kind("light", &[(T, 1.5)]),
            ],
            None,
            T,
            T + 2 * BUCKET,
        );
        assert_eq!(h.hours.len(), 2);
        assert_eq!(h.hours[0].cpu, Some(0.5));
        assert_eq!(h.hours[0].seen, 0.5, "15 of 30 steps");
        assert_eq!(h.hours[1].cpu, None);
        assert_eq!(h.hours[0].temp, Some(82.0), "the hour's hottest sample");
        assert_eq!(h.hours[1].temp, None);
        // Two steps at 3 cores of the hour's 30: a missing step used none.
        assert_eq!(h.hours[0].pools["unity"], 0.2);
        // Each kind of job apart, though both ran on the same agnostic slots.
        assert_eq!(h.hours[0].pools["light"], 0.05);
    }

    #[test]
    fn the_cores_are_summed_by_the_kind_of_job_not_the_runners_pool() {
        let q = pools_query(r#"host=~"ms-a2""#);
        assert_eq!(q, r#"sum by (kind) (cc:job_kind_cores{host=~"ms-a2"})"#);
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
