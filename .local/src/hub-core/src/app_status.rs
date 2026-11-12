//! One app's status page on both surfaces (`#releases/apps/<app>`): its Gatus checks with their
//! uptime, 90 daily bars, 24h latency and incidents, the banner the whole app reads as, and what is
//! live and watched there as links to the tabs that own those facts.
//!
//! The checks are the apps Gatus (home-config `apps/gatus/config.yaml`, its URL `CC_GATUS_URL`), whose
//! group is the project-map tracker key, and `<key>-<channel>` for a non-prod channel. Their
//! history is VictoriaMetrics (`prom::vm`), which keeps what Prometheus scrapes from Gatus for 2
//! years; it starts on 2026-11-12, so a day before that reads `No data`, never up.
//!
//! The rules are the fleet-platform status monitor's: a check is down after 2 failed results and
//! up again after 2 good ones, an uptime with any failure never rounds to 100, a monitor silent
//! for 5 minutes says so, and a check with no results is unknown, not up.

use std::collections::{BTreeMap, BTreeSet, HashMap};

use chrono::{Local, TimeZone};
use serde::Serialize;

use crate::kube_proxy::label;
use crate::links::{Kind, Link};
use crate::prom::{self, Series};
use crate::releases::{self, Badge, Level, Release};
use crate::session_actions::Runner;
use crate::session_page::Part;

/// The newest result older than this means the monitor, its scrape or the remote-write stopped.
pub const STALE_SECS: i64 = 300;
/// How many daily bars a check shows.
pub const DAYS: usize = 90;
/// The step incidents are read at: the scrape interval and the shortest check interval, so a
/// step holds one result and two failed steps in a row are two failed results in a row.
const STEP: i64 = 60;
/// How far back incidents are read: a week at `STEP` is 10,080 points a series, under
/// VictoriaMetrics' 30,000 a series; older outages are the daily bars' dips.
pub const INCIDENT_DAYS: i64 = 7;
/// The uptime windows a card shows.
const WINDOWS: [(&str, i64); 4] = [
    ("24h", 86_400),
    ("7d", 7 * 86_400),
    ("30d", 30 * 86_400),
    ("90d", 90 * 86_400),
];
/// Results in a row that make a check down, and that bring it back up.
const DOWN_AFTER: u64 = 2;
const UP_AFTER: u64 = 2;
/// How many incidents the page lists, newest first.
const INCIDENTS_SHOWN: usize = 20;
/// How far back a badge reads results: the page's own rule, a check is the app's while it
/// reported in 24h, so a badge and the page it links to read the same checks. 1,440 points a
/// series at `STEP`.
const BADGE_SECS: i64 = 86_400;
/// How far back a group's newest result is looked for; an app with none in that time has no check.
const NEWEST_RANGE: &str = "7d";
const NO_DATA: &str = "No data";

/// One day's bar: the 24 hours ending at `at`.
#[derive(Serialize, Debug, Clone, PartialEq)]
pub struct Day {
    pub at: i64,
    pub ok: u64,
    pub fail: u64,
    /// `100%`, `99.5%` or `No data`.
    pub text: String,
}

/// A stretch a check was down: from its first failed result until 2 good ones in a row.
#[derive(Serialize, Debug, Clone, PartialEq)]
pub struct Incident {
    pub check: String,
    pub from: i64,
    /// None while it is still down.
    pub to: Option<i64>,
    pub fails: u64,
    /// `11-03 14:02  down 6m` or `11-03 14:02  down, ongoing`.
    pub text: String,
}

/// One Gatus check of the app.
#[derive(Serialize, Debug, Default, Clone, PartialEq)]
pub struct Check {
    pub name: String,
    pub group: String,
    /// `Operational`, `Failing` (one failed result, not yet down), `Down` or `No data`.
    pub state: String,
    pub level: Level,
    /// Each window and its uptime: `("7d", "99.98%")`.
    pub uptime: Vec<(String, String)>,
    /// The last `DAYS` days, oldest first.
    pub days: Vec<Day>,
    /// The last 24h of response times: (unix seconds, milliseconds).
    pub latency: Vec<(i64, f64)>,
    /// `p50 180ms, p95 420ms`, or `No data`.
    pub latency_text: String,
}

/// The app's page.
#[derive(Serialize, Debug, Clone, PartialEq)]
pub struct AppStatus {
    pub app: String,
    /// The Gatus groups read: the key, and `<key>-<channel>` per non-prod channel.
    pub groups: Vec<String>,
    /// The groups with no check reporting: a channel nothing probes yet.
    pub unchecked: Vec<String>,
    /// `Operational`, `Failing check: <names>`, `Partial outage: <names>`, `Down`, `Waiting for
    /// every check to report`, `Monitor stopped reporting at <t>` or `not read: <why>`.
    pub banner: String,
    pub level: Level,
    /// The newest result of any check, unix seconds.
    pub newest: Option<i64>,
    /// What is live and watched, each linking to its own tab.
    pub context: Vec<Part>,
    pub checks: Vec<Check>,
    pub incidents: Vec<Incident>,
    /// Gatus itself (`CC_GATUS_URL`, a board setting), for a reader who wants its own page.
    pub monitor: Option<Link>,
    pub errors: Vec<String>,
    pub at: i64,
}

/// An app's Gatus groups: its key, and `<key>-<channel>` for each non-prod channel its project-map
/// targets declare. The match is exact, never a prefix: `binks-chat` is its own tracker, not a
/// channel of `binks`.
pub fn groups(app: &str, channels: &[Release]) -> Vec<String> {
    let mut out = vec![app.to_string()];
    for r in channels {
        if r.project != app || r.implicit || r.channel.is_empty() || r.channel == "prod" {
            continue;
        }
        let g = format!("{app}-{}", r.channel);
        if label(&g) && !out.contains(&g) {
            out.push(g);
        }
    }
    out
}

/// `ok` of `ok + fail` as the card says it: `No data` with no results, and with any failure at
/// most 99.99, cut rather than rounded, so a failure never reads as 100.
pub fn uptime(ok: u64, fail: u64) -> String {
    let n = ok + fail;
    if n == 0 {
        return NO_DATA.into();
    }
    if fail == 0 {
        return "100%".into();
    }
    let pct = (ok as f64 * 10_000.0 / n as f64).floor() / 100.0;
    let pct = pct.min(99.99);
    let s = format!("{pct:.2}");
    let s = s.trim_end_matches('0').trim_end_matches('.');
    format!("{s}%")
}

/// A check's identity in the series: its group and its name.
type Key = (String, String);
/// A check's result counts at each time: ok, then failed.
type Counts = (BTreeMap<i64, u64>, BTreeMap<i64, u64>);

/// A counter's `sum by (group,name,success)` series as ok and fail per check: from the instant
/// value, or at each point of a range.
fn split(series: &[Series]) -> BTreeMap<Key, Counts> {
    let mut out: BTreeMap<Key, Counts> = BTreeMap::new();
    for s in series {
        let key = (s.label("group").to_string(), s.label("name").to_string());
        let e = out.entry(key).or_default();
        let side = if s.label("success") == "true" {
            &mut e.0
        } else {
            &mut e.1
        };
        if let Some(v) = s.value {
            *side.entry(0).or_default() += v.round().max(0.0) as u64;
        }
        for (t, v) in &s.points {
            *side.entry(*t as i64).or_default() += v.round().max(0.0) as u64;
        }
    }
    out
}

/// The `DAYS` bars ending at `end`, oldest first: a day with no results is `No data`.
pub fn days(ok: &BTreeMap<i64, u64>, fail: &BTreeMap<i64, u64>, end: i64) -> Vec<Day> {
    (0..DAYS as i64)
        .rev()
        .map(|k| {
            let at = end - k * 86_400;
            let (o, f) = (
                ok.get(&at).copied().unwrap_or(0),
                fail.get(&at).copied().unwrap_or(0),
            );
            Day {
                at,
                ok: o,
                fail: f,
                text: uptime(o, f),
            }
        })
        .collect()
}

/// A check's down stretches from its results per step (oldest first, a step about one result),
/// and whether it is failing now without being down yet. Failed results in a row make a run,
/// down once it holds `DOWN_AFTER`; a pass before then drops it, and a down run ends at `UP_AFTER`
/// good results with none failed between them. A single failed result is no incident. A step
/// holding both is read failures first, so its passes count toward the way back up.
pub fn incidents(steps: &[(i64, u64, u64)]) -> (Runs, bool) {
    let mut out = Vec::new();
    let (mut start, mut fails, mut good, mut down) = (None::<i64>, 0u64, 0u64, false);
    for &(t, ok, fail) in steps {
        if fail > 0 {
            if good > 0 && !down {
                (start, fails) = (None, 0);
            }
            start.get_or_insert(t);
            fails += fail;
            good = 0;
            down |= fails >= DOWN_AFTER;
        }
        if start.is_none() || ok == 0 {
            continue;
        }
        good += ok;
        if !down && fail == 0 {
            (start, fails, good) = (None, 0, 0);
        } else if down && good >= UP_AFTER {
            out.push((start.unwrap_or(t), Some(t), fails));
            (start, fails, good, down) = (None, 0, 0, false);
        }
    }
    let failing = start.is_some() && !down;
    if down {
        out.push((start.unwrap_or(0), None, fails));
    }
    (out, failing)
}

/// A check's results per step as `(t, ok, failed)`, oldest first, a step with none dropped.
fn results(c: Option<&Counts>) -> Vec<(i64, u64, u64)> {
    let Some((ok, fail)) = c else {
        return vec![];
    };
    let ts: BTreeSet<i64> = ok.keys().chain(fail.keys()).copied().collect();
    ts.into_iter()
        .map(|t| {
            (
                t,
                ok.get(&t).copied().unwrap_or(0),
                fail.get(&t).copied().unwrap_or(0),
            )
        })
        .filter(|s| s.1 + s.2 > 0)
        .collect()
}

/// A check's state from its results (`No data`, `Down`, `Failing` or `Operational`) and its down
/// stretches, as [`incidents`] reads them.
type Runs = Vec<(i64, Option<i64>, u64)>;
fn state(results: &[(i64, u64, u64)]) -> (&'static str, Runs) {
    let (runs, failing) = incidents(results);
    let s = if results.is_empty() {
        NO_DATA
    } else if runs.last().is_some_and(|r| r.1.is_none()) {
        "Down"
    } else if failing {
        "Failing"
    } else {
        "Operational"
    };
    (s, runs)
}

/// `11-03 14:02` in local time.
fn hm(t: i64) -> String {
    Local
        .timestamp_opt(t, 0)
        .single()
        .map_or_else(|| t.to_string(), |d| d.format("%m-%d %H:%M").to_string())
}

fn span(secs: i64) -> String {
    match secs {
        s if s < 3600 => format!("{}m", (s / 60).max(1)),
        s if s < 86_400 => format!("{}h{}m", s / 3600, s % 3600 / 60),
        s => format!("{}d{}h", s / 86_400, s % 86_400 / 3600),
    }
}

/// The banner over every check: unknown is never up, and a silent monitor is said before what
/// its last results claim.
pub fn banner(checks: &[Check], newest: Option<i64>, now: i64) -> (String, Level) {
    let waiting = ("Waiting for every check to report".to_string(), Level::Warn);
    let Some(newest) = newest else {
        return waiting;
    };
    if now - newest > STALE_SECS {
        return (
            format!("Monitor stopped reporting at {}", hm(newest)),
            Level::Warn,
        );
    }
    if checks.is_empty() {
        return waiting;
    }
    if checks.iter().any(|c| c.state == NO_DATA) {
        return waiting;
    }
    let down: Vec<&str> = checks
        .iter()
        .filter(|c| c.state == "Down")
        .map(|c| c.name.as_str())
        .collect();
    if down.len() == checks.len() {
        return ("Down".into(), Level::Bad);
    }
    if !down.is_empty() {
        return (format!("Partial outage: {}", down.join(", ")), Level::Bad);
    }
    let failing: Vec<&str> = checks
        .iter()
        .filter(|c| c.state == "Failing")
        .map(|c| c.name.as_str())
        .collect();
    if !failing.is_empty() {
        return (
            format!("Failing check: {}", failing.join(", ")),
            Level::Warn,
        );
    }
    ("Operational".into(), Level::Ok)
}

/// The watches on the app's channels and which are firing, each a link to Alerts. What is
/// deployed is the app page's own channels, so it is not said again here.
pub fn context(channels: &Result<Vec<Release>, String>) -> Vec<Part> {
    let Ok(rows) = channels else {
        return vec![];
    };
    let mut out = vec![];
    let mut watches: BTreeMap<&str, &str> = BTreeMap::new();
    for r in rows {
        for w in &r.telemetry {
            let s = watches.entry(&w.watch).or_insert(&w.state);
            if w.state == "TRIP" {
                *s = "TRIP";
            }
        }
    }
    let firing: Vec<&str> = watches
        .iter()
        .filter(|(_, s)| **s == "TRIP")
        .map(|(w, _)| *w)
        .collect();
    out.push(
        Part::new(
            "Watches",
            format!(
                "{} watch{}, {} firing",
                watches.len(),
                if watches.len() == 1 { "" } else { "es" },
                firing.len()
            ),
        )
        .link(Link::tab("alerts"))
        .warn(!firing.is_empty()),
    );
    for w in firing {
        out.push(
            Part::new("Firing", w)
                .link(Link::to(Kind::Alert, w))
                .warn(true),
        );
    }
    out
}

/// The answers the page is made from, read by [`read`] or handed in by a test.
pub struct Answers {
    /// Each window's `sum by (group,name,success)(increase(...[w]))`, in `WINDOWS` order.
    pub windows: Vec<Result<Vec<Series>, String>>,
    /// The same over 1d, at a 1d step for `DAYS`, ending at `at`.
    pub days: Result<Vec<Series>, String>,
    /// The same over 1m, at a `STEP` step for `INCIDENT_DAYS`.
    pub steps: Result<Vec<Series>, String>,
    /// Each hour's average response time in seconds, at a 1h step for 24h.
    pub latency: Result<Vec<Series>, String>,
    /// The p50 and p95 response time over 24h, each series labelled `q` = `50` or `95`.
    pub pct: Result<Vec<Series>, String>,
    /// The newest result's time.
    pub newest: Result<Vec<Series>, String>,
}

/// The page from its answers. A failed answer is an error line; when it is one the banner rests
/// on (24h uptime, incidents, newest result), the banner is `not read`, and a failed daily bars or
/// latency read leaves the banner to the rest. The checks are those that reported in 24h, so a
/// retired or renamed check drops off instead of holding the banner at waiting or down.
pub fn build(
    app: &str,
    groups: Vec<String>,
    channels: &Result<Vec<Release>, String>,
    a: Answers,
    now: i64,
) -> AppStatus {
    let mut errors = Vec::new();
    // The first failed read the banner rests on.
    let mut blind: Option<String> = None;
    let mut take = |what: &str, core: bool, r: Result<Vec<Series>, String>| match r {
        Ok(s) => s,
        Err(e) => {
            let line = format!("{what}: {e}");
            if core && blind.is_none() {
                blind = Some(line.clone());
            }
            errors.push(line);
            vec![]
        }
    };
    let windows: Vec<_> = a
        .windows
        .into_iter()
        .zip(WINDOWS)
        .enumerate()
        .map(|(i, (r, (w, _)))| split(&take(&format!("uptime {w}"), i == 0, r)))
        .collect();
    let day = split(&take("daily bars", false, a.days));
    let steps = split(&take("incidents", true, a.steps));
    let latency = take("latency", false, a.latency);
    let pct = take("latency percentiles", false, a.pct);
    let newest = take("newest result", true, a.newest)
        .iter()
        .filter_map(|s| s.value)
        .map(|v| v as i64)
        .max();

    // A check is current when it reported in 24h; with the 24h read failed, any it ever had.
    let current = |(o, f): &Counts| o.values().chain(f.values()).sum::<u64>() > 0;
    let keys: BTreeSet<Key> = match windows.first() {
        Some(w) if !w.is_empty() || blind.is_none() => w
            .iter()
            .filter(|(_, c)| current(c))
            .map(|(k, _)| k.clone())
            .collect(),
        _ => windows
            .iter()
            .chain([&day, &steps])
            .flat_map(|m| m.keys().cloned())
            .collect(),
    };
    let empty = BTreeMap::new();
    let mut checks = Vec::new();
    let mut incidents_all = Vec::new();
    for key in keys {
        let uptime = WINDOWS
            .iter()
            .zip(&windows)
            .map(|((w, _), m)| {
                let (o, f) = m.get(&key).map_or((0, 0), |(o, f)| {
                    (o.values().sum::<u64>(), f.values().sum::<u64>())
                });
                (w.to_string(), uptime(o, f))
            })
            .collect();
        let (dok, dfail) = day.get(&key).map_or((&empty, &empty), |(o, f)| (o, f));
        let end = dok.keys().chain(dfail.keys()).max().copied().unwrap_or(now);
        let (state, runs) = state(&results(steps.get(&key)));
        for (from, to, fails) in runs {
            incidents_all.push(Incident {
                check: key.1.clone(),
                from,
                to,
                fails,
                text: match to {
                    Some(to) => format!("{}  down {}", hm(from), span(to - from)),
                    None => format!("{}  down, ongoing", hm(from)),
                },
            });
        }
        let mine = |s: &&Series| s.label("group") == key.0 && s.label("name") == key.1;
        // A point at t averages the hour before it, so it is drawn at that hour's start.
        let lat: Vec<(i64, f64)> = latency
            .iter()
            .filter(mine)
            .flat_map(|s| s.points.iter().map(|(t, v)| (*t as i64 - 3600, v * 1000.0)))
            .collect();
        let q = |p: &str| {
            pct.iter()
                .filter(mine)
                .find(|s| s.label("q") == p)
                .and_then(|s| s.value)
        };
        let latency_text = match (q("50"), q("95")) {
            (Some(p50), Some(p95)) => {
                format!("p50 {:.0}ms, p95 {:.0}ms", p50 * 1000.0, p95 * 1000.0)
            }
            _ => NO_DATA.into(),
        };
        checks.push(Check {
            level: match state {
                "Down" => Level::Bad,
                "Operational" => Level::Ok,
                _ => Level::Warn,
            },
            state: state.into(),
            name: key.1,
            group: key.0,
            uptime,
            days: days(dok, dfail, end),
            latency: lat,
            latency_text,
        });
    }
    incidents_all.sort_by_key(|i| std::cmp::Reverse(i.from));
    incidents_all.truncate(INCIDENTS_SHOWN);
    let (banner, level) = match blind {
        Some(e) => (format!("not read: {e}"), Level::Warn),
        None => banner(&checks, newest, now),
    };
    let unchecked = groups
        .iter()
        .filter(|g| !checks.iter().any(|c| &c.group == *g))
        .cloned()
        .collect();
    AppStatus {
        app: app.into(),
        groups,
        unchecked,
        banner,
        level,
        newest,
        context: context(channels),
        checks,
        incidents: incidents_all,
        monitor: None,
        errors,
        at: now,
    }
}

/// `{group=~"^(a|a-preview)$"}` for the groups, each a DNS-1123 label so none can break out.
fn selector(groups: &[String]) -> String {
    format!(r#"{{group=~"^({})$"}}"#, groups.join("|"))
}

/// The PromQL each answer asks, over `sel`.
fn queries(sel: &str) -> (Vec<String>, String, String, String, String, String) {
    let inc =
        |w: &str| format!("sum by (group,name,success) (increase(gatus_results_total{sel}[{w}]))");
    (
        WINDOWS.iter().map(|(w, _)| inc(w)).collect(),
        inc("1d"),
        inc("1m"),
        // The gauge holds the latest result; scraped at the checks' own cadence, its samples
        // are the results.
        format!("avg by (group,name) (avg_over_time(gatus_results_duration_seconds{sel}[1h]))"),
        [("50", "0.5"), ("95", "0.95")]
            .map(|(l, q)| {
                format!(
                    r#"label_set(max by (group,name) (quantile_over_time({q}, gatus_results_duration_seconds{sel}[24h])), "q", "{l}")"#
                )
            })
            .join(" or "),
        format!("max(tlast_over_time(gatus_results_total{sel}[{NEWEST_RANGE}]))"),
    )
}

/// `app`'s page, read now: its channels from release-state and its checks from VictoriaMetrics,
/// the nine queries at once, so a slow cluster costs one call's time and not nine. An app with
/// no channel and no check is not one, so its name is an error (a 404 on the web).
pub fn read(runner: &(dyn Runner + Sync), app: &str, now: i64) -> Result<AppStatus, String> {
    if !label(app) {
        return Err(format!("no app named {app}"));
    }
    let channels = releases::channels(runner, app);
    let groups = groups(app, channels.as_deref().unwrap_or(&[]));
    let (windows, day, step, lat, pct, newest) = queries(&selector(&groups));
    // Hour-aligned and ending on the last whole hour, so each point averages exactly one clock
    // hour and the 24 points are the 24 hours before this one.
    let hour = now / 3600 * 3600;
    let mut asks: Vec<(&str, Option<prom::Range>)> =
        windows.iter().map(|w| (w.as_str(), None)).collect();
    asks.extend([
        (
            day.as_str(),
            Some((now - (DAYS as i64 - 1) * 86_400, now, 86_400)),
        ),
        (
            step.as_str(),
            Some((now - INCIDENT_DAYS * 86_400, now, STEP)),
        ),
        (lat.as_str(), Some((hour - 23 * 3600, hour, 3600))),
        (pct.as_str(), None),
        (newest.as_str(), None),
    ]);
    let mut got: Vec<Result<Vec<Series>, String>> = std::thread::scope(|s| {
        let handles: Vec<_> = asks
            .iter()
            .map(|(q, r)| s.spawn(move || prom::vm(runner, q, *r)))
            .collect();
        handles
            .into_iter()
            .map(|h| h.join().unwrap_or_else(|_| Err("query panicked".into())))
            .collect()
    });
    let mut next = || got.remove(0);
    let a = Answers {
        windows: WINDOWS.iter().map(|_| next()).collect(),
        days: next(),
        steps: next(),
        latency: next(),
        pct: next(),
        newest: next(),
    };
    let mut page = build(app, groups, &channels, a, now);
    page.monitor = prom::config("CC_GATUS_URL").map(Link::Url);
    if page.checks.is_empty() && page.errors.is_empty() && channels.is_ok_and(|c| c.is_empty()) {
        return Err(format!("no app named {app}"));
    }
    Ok(page)
}

/// Each app's banner as a badge for its Releases row and its Projects card, from two queries
/// over every app's groups at once, so a tab of 20 apps costs two calls and not 180: the last
/// `BADGE_SECS` of results at `STEP` and each group's newest result. `apps` is each app with its [`groups`]. An app with no result in
/// `NEWEST_RANGE` is absent: it has no check, which project-map-doctor names.
pub fn badges(
    runner: &(dyn Runner + Sync),
    apps: &[(String, Vec<String>)],
    now: i64,
) -> Result<HashMap<String, Badge>, String> {
    let all: BTreeSet<String> = apps.iter().flat_map(|(_, g)| g.iter().cloned()).collect();
    if all.is_empty() {
        return Ok(HashMap::new());
    }
    let sel = selector(&all.into_iter().collect::<Vec<_>>());
    let step = format!("sum by (group,name,success) (increase(gatus_results_total{sel}[1m]))");
    let newest =
        format!("max by (group) (tlast_over_time(gatus_results_total{sel}[{NEWEST_RANGE}]))");
    let join = |h: std::thread::ScopedJoinHandle<'_, Result<Vec<Series>, String>>| {
        h.join().unwrap_or_else(|_| Err("query panicked".into()))
    };
    let (steps, newest) = std::thread::scope(|s| {
        let a = s.spawn(|| prom::vm(runner, &step, Some((now - BADGE_SECS, now, STEP))));
        let b = s.spawn(|| prom::vm(runner, &newest, None));
        (join(a), join(b))
    });
    match (steps, newest) {
        (Ok(s), Ok(n)) => Ok(verdicts(apps, &s, &n, now)),
        (Err(a), Err(b)) if a == b => Err(a),
        (Err(a), Err(b)) => Err(format!("{a}; {b}")),
        (Err(e), _) | (_, Err(e)) => Err(e),
    }
}

/// [`badges`] from its two answers: each app's checks that reported in the window, their states
/// and the newest result of its groups, through the page's own [`banner`].
pub fn verdicts(
    apps: &[(String, Vec<String>)],
    steps: &[Series],
    newest: &[Series],
    now: i64,
) -> HashMap<String, Badge> {
    let steps = split(steps);
    let newest: BTreeMap<&str, i64> = newest
        .iter()
        .filter_map(|s| Some((s.label("group"), s.value? as i64)))
        .collect();
    apps.iter()
        .filter_map(|(app, groups)| {
            let n = groups
                .iter()
                .filter_map(|g| newest.get(g.as_str()))
                .max()
                .copied()?;
            let checks: Vec<Check> = steps
                .iter()
                .filter(|((g, _), _)| groups.contains(g))
                .map(|((g, name), c)| Check {
                    name: name.clone(),
                    group: g.clone(),
                    state: state(&results(Some(c))).0.into(),
                    ..Check::default()
                })
                .collect();
            let (says, level) = banner(&checks, Some(n), now);
            Some((app.clone(), Badge { says, level }))
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn series(group: &str, name: &str, success: Option<bool>, points: &[(i64, f64)]) -> Series {
        let mut labels = BTreeMap::new();
        labels.insert("group".into(), group.into());
        labels.insert("name".into(), name.into());
        if let Some(s) = success {
            labels.insert("success".into(), s.to_string());
        }
        Series {
            labels,
            value: None,
            points: points.iter().map(|(t, v)| (*t as f64, *v)).collect(),
        }
    }

    fn instant(group: &str, name: &str, success: bool, v: f64) -> Series {
        Series {
            value: Some(v),
            ..series(group, name, Some(success), &[])
        }
    }

    const NOW: i64 = 1_800_000_000;

    fn answers(ok: f64, fail: f64, newest: i64) -> Answers {
        let w = || {
            Ok(vec![
                instant("pmp", "api", true, ok),
                instant("pmp", "api", false, fail),
            ])
        };
        Answers {
            windows: vec![w(), w(), w(), w()],
            days: Ok(vec![series("pmp", "api", Some(true), &[(NOW, ok)])]),
            steps: Ok(vec![series(
                "pmp",
                "api",
                Some(true),
                &[(NOW - 300, 5.0), (NOW, 5.0)],
            )]),
            latency: Ok(vec![series("pmp", "api", None, &[(NOW, 0.18)])]),
            pct: Ok(["50", "95"]
                .map(|q| {
                    let mut s = instant("pmp", "api", true, 0.18);
                    s.labels.remove("success");
                    s.labels.insert("q".into(), q.into());
                    s
                })
                .to_vec()),
            newest: Ok(vec![Series {
                value: Some(newest as f64),
                ..series("", "", None, &[])
            }]),
        }
    }

    fn page(a: Answers) -> AppStatus {
        build("pmp", vec!["pmp".into()], &Ok(vec![]), a, NOW)
    }

    #[test]
    fn a_day_with_no_results_is_no_data_never_up() {
        let mut ok = BTreeMap::new();
        ok.insert(NOW, 1440);
        let d = days(&ok, &BTreeMap::new(), NOW);
        assert_eq!(d.len(), DAYS);
        assert_eq!(d[DAYS - 1].text, "100%");
        assert_eq!(d[0].text, "No data");
        assert_eq!(d[DAYS - 2].at, NOW - 86_400);
        assert_eq!(uptime(0, 0), "No data");
    }

    #[test]
    fn latency_reads_the_percentiles_and_a_group_with_no_check_is_named() {
        let p = build(
            "pmp",
            vec!["pmp".into(), "pmp-beta".into()],
            &Ok(vec![]),
            answers(10.0, 0.0, NOW - 30),
            NOW,
        );
        assert_eq!(p.checks[0].latency_text, "p50 180ms, p95 180ms");
        assert_eq!(
            p.checks[0].latency,
            [(NOW - 3600, 180.0)],
            "an hour's point sits at its start"
        );
        assert_eq!(p.unchecked, ["pmp-beta"]);
        let mut a = answers(10.0, 0.0, NOW - 30);
        a.pct = Ok(vec![]);
        assert_eq!(page(a).checks[0].latency_text, "No data");
    }

    #[test]
    fn one_failure_never_rounds_to_100() {
        assert_eq!(uptime(9_999, 1), "99.99%");
        assert_eq!(uptime(99_999, 1), "99.99%");
        assert_eq!(uptime(999, 1), "99.9%");
        assert_eq!(uptime(1, 1), "50%");
        assert_eq!(uptime(10, 0), "100%");
        let p = page(answers(9_999.0, 1.0, NOW - 30));
        assert_eq!(p.checks[0].uptime[0], ("24h".into(), "99.99%".into()));
    }

    #[test]
    fn one_failed_result_is_no_incident_two_in_a_row_are() {
        let (runs, failing) = incidents(&[(0, 5, 0), (60, 4, 1), (120, 5, 0)]);
        assert!(runs.is_empty());
        assert!(!failing);
        let (runs, _) = incidents(&[(0, 5, 0), (60, 0, 1), (120, 0, 1), (180, 5, 0)]);
        assert_eq!(runs, vec![(60, Some(180), 2)]);
        let (runs, _) = incidents(&[(60, 0, 2), (120, 5, 0)]);
        assert_eq!(runs, vec![(60, Some(120), 2)], "two in one step");
        let (runs, _) = incidents(&[(0, 0, 1), (60, 0, 1)]);
        assert_eq!(runs, vec![(0, None, 2)], "still down");
        let (runs, failing) = incidents(&[(0, 5, 0), (60, 0, 1)]);
        assert!(runs.is_empty() && failing, "one fail: failing, not down");
        let (runs, failing) = incidents(&[(0, 0, 1), (60, 1, 0), (120, 0, 1), (180, 1, 0)]);
        assert!(
            runs.is_empty() && !failing,
            "isolated failures with passes between them are no incident"
        );
        let (runs, _) = incidents(&[(0, 0, 2), (60, 1, 0), (120, 0, 1), (180, 2, 0)]);
        assert_eq!(
            runs,
            vec![(0, Some(180), 3)],
            "one good result does not end a down run"
        );
    }

    #[test]
    fn a_silent_monitor_says_so_before_its_last_results() {
        let p = page(answers(100.0, 0.0, NOW - STALE_SECS - 1));
        assert!(
            p.banner.starts_with("Monitor stopped reporting at "),
            "{}",
            p.banner
        );
        assert_eq!(page(answers(100.0, 0.0, NOW - 30)).banner, "Operational");
    }

    #[test]
    fn a_failed_query_is_not_read_never_up() {
        let mut a = answers(100.0, 0.0, NOW - 30);
        a.windows[0] = Err("CC_VM_SERVICE is not set".into());
        let p = page(a);
        assert_eq!(p.banner, "not read: uptime 24h: CC_VM_SERVICE is not set");
        assert_eq!(p.level, Level::Warn);
        assert_eq!(p.checks.len(), 1, "the other reads still name the check");

        let mut a = answers(100.0, 0.0, NOW - 30);
        a.windows[1] = Err("timed out".into());
        a.latency = Err("timed out".into());
        let p = page(a);
        assert_eq!(
            p.banner, "Operational",
            "a side read does not blind the banner"
        );
        assert_eq!(p.errors, ["uptime 7d: timed out", "latency: timed out"]);
    }

    #[test]
    fn a_check_that_stopped_reporting_drops_off() {
        let mut a = answers(100.0, 0.0, NOW - 30);
        a.days = Ok(vec![
            series("pmp", "api", Some(true), &[(NOW, 100.0)]),
            series("pmp", "old", Some(false), &[(NOW - 20 * 86_400, 9.0)]),
        ]);
        let p = page(a);
        assert_eq!(p.banner, "Operational");
        assert_eq!(p.checks.len(), 1);
    }

    #[test]
    fn no_checks_or_no_results_wait_rather_than_read_up() {
        let a = Answers {
            windows: vec![Ok(vec![]), Ok(vec![]), Ok(vec![]), Ok(vec![])],
            days: Ok(vec![]),
            steps: Ok(vec![]),
            latency: Ok(vec![]),
            pct: Ok(vec![]),
            newest: Ok(vec![]),
        };
        assert_eq!(page(a).banner, "Waiting for every check to report");
    }

    #[test]
    fn down_checks_name_the_outage() {
        let mut a = answers(100.0, 0.0, NOW - 30);
        a.steps = Ok(vec![
            series("pmp", "api", Some(false), &[(NOW - 300, 1.0), (NOW, 1.0)]),
            series("pmp", "web", Some(true), &[(NOW, 5.0)]),
        ]);
        let web = instant("pmp", "web", true, 100.0);
        a.windows[0].as_mut().unwrap().push(web);
        let p = page(a);
        assert_eq!(p.banner, "Partial outage: api");
        assert_eq!(p.incidents.len(), 1);
        assert!(p.incidents[0].text.ends_with("down, ongoing"));
    }

    #[test]
    fn the_join_is_exact_never_a_prefix() {
        let ch = |project: &str, channel: &str| Release {
            project: project.into(),
            channel: channel.into(),
            ..Release::default()
        };
        let rows = [
            ch("binks", "prod"),
            ch("binks-chat", "prod"),
            ch("shop", "preview"),
        ];
        assert_eq!(groups("binks", &rows), ["binks"]);
        assert_eq!(groups("binks-chat", &rows), ["binks-chat"]);
        assert_eq!(groups("shop", &rows), ["shop", "shop-preview"]);
        assert_eq!(selector(&groups("binks", &rows)), r#"{group=~"^(binks)$"}"#);
    }

    #[test]
    fn a_badge_is_the_pages_banner_and_absence_is_no_badge() {
        let now = 1_800_000_000;
        let apps = vec![
            ("pmp".to_string(), vec!["pmp".to_string()]),
            (
                "binks".to_string(),
                vec!["binks".to_string(), "binks-preview".to_string()],
            ),
            ("shop".to_string(), vec!["shop".to_string()]),
            ("quiet".to_string(), vec!["quiet".to_string()]),
        ];
        let at = |n: i64| now - 60 * n;
        let steps = [
            series(
                "pmp",
                "api",
                Some(true),
                &[(at(3), 1.0), (at(2), 1.0), (at(1), 1.0)],
            ),
            // Two failed results in a row in a non-prod group still count for the app.
            series("binks", "web", Some(true), &[(at(3), 1.0), (at(2), 1.0)]),
            series(
                "binks-preview",
                "chat",
                Some(false),
                &[(at(2), 1.0), (at(1), 1.0)],
            ),
            series("quiet", "web", Some(true), &[(at(90), 1.0)]),
        ];
        let newest_of = |g: &str, t: i64| Series {
            labels: BTreeMap::from([("group".to_string(), g.to_string())]),
            value: Some(t as f64),
            points: vec![],
        };
        let newest = [
            newest_of("pmp", at(1)),
            newest_of("binks", at(2)),
            newest_of("binks-preview", at(1)),
            newest_of("quiet", now - 2 * 3600),
        ];
        let b = verdicts(&apps, &steps, &newest, now);
        assert_eq!(b["pmp"].says, "Operational");
        assert_eq!(b["binks"].says, "Partial outage: chat");
        assert_eq!(b["binks"].level, Level::Bad);
        // No result in a week is no check: absent, so the surface says `no check`, never up.
        assert!(!b.contains_key("shop"));
        assert!(b["quiet"].says.starts_with("Monitor stopped reporting at "));
    }

    /// One live read as the page's JSON, for a screenshot of the page through the phone harness's
    /// routing (agent-web needs a signed-in session). `APP_STATUS_APP=binks APP_STATUS_OUT=f
    /// cargo test app_status::tests::dump_live_page -- --ignored --exact`; it needs the board's
    /// settings (CC_KUBE_CONTEXT, CC_VM_SERVICE) and the cluster.
    #[test]
    #[ignore]
    fn dump_live_page() {
        let app = std::env::var("APP_STATUS_APP").expect("APP_STATUS_APP is the app");
        let out = std::env::var("APP_STATUS_OUT").expect("APP_STATUS_OUT is the output path");
        let page = read(&crate::session_actions::System, &app, crate::jobs::now()).unwrap();
        std::fs::write(out, serde_json::to_string(&page).unwrap()).unwrap();
    }
}
