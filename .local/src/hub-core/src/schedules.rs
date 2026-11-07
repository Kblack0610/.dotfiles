//! The Schedules tab, both surfaces: everything that runs on its own, one row each, and why it
//! exists. Four sources join here: GitHub schedules (`schedules-sync`'s state.json), agentctl
//! runners, systemd user timers and k8s CronJobs. A row's triage comes from `fleet-bench`, which
//! owns the route table and the red items; the watches behind a row are Sentinel's own files. A
//! source that cannot be read is named in `errors` and the rest still list.

use std::collections::{BTreeMap, HashMap};
use std::path::{Path, PathBuf};

use chrono::{DateTime, Datelike, FixedOffset, Local, Timelike};
use serde::{Deserialize, Serialize};

use crate::fleet::{self, runner, runner::Watch, Conf};
use crate::jobs::{self, Job, State};
use crate::prom::{self, Series};
use crate::queue;
use crate::reds::{self, Red};
use crate::session_actions::Runner;
use crate::table::{Row, Val};
use crate::text::age;

/// How far back a streak looks; agentctl's ledger and the journal both hold a week.
const WEEK: i64 = 7 * 86400;
/// The furthest `cron_next` looks: a month and a day covers a monthly cron.
const NEXT_MINUTES: i64 = 32 * 1440;
const DAYS: [&str; 7] = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];

const CI: &str = "ci";
const AGENTCTL: &str = "agentctl";
const TIMER: &str = "timer";
const K8S: &str = "k8s";

/// One finished run, newest first on its row.
#[derive(Serialize, Debug, Default, Clone, PartialEq)]
pub struct Run {
    pub at: Option<i64>,
    pub result: String,
    pub ok: Option<bool>,
    /// A CI run's failed jobs.
    pub failed: Vec<String>,
    /// Where the run opens; empty when it has no page.
    pub url: String,
}

/// One thing that runs on its own.
#[derive(Serialize, Debug, Default, Clone, PartialEq)]
pub struct Schedule {
    /// `ci`, `agentctl`, `timer` or `k8s`.
    pub kind: String,
    pub name: String,
    /// A CI row's repository; empty on the others.
    pub repo: String,
    /// When, in words and local time.
    pub schedule: String,
    /// Why it exists. Empty is a gap to fill, drawn amber.
    pub purpose: String,
    pub last: Option<i64>,
    pub result: String,
    pub ok: Option<bool>,
    /// Finished runs in a row with the same outcome: above 0 green, below 0 red, 0 none known.
    pub streak: i32,
    /// The oldest run of a red streak.
    pub red_since: Option<i64>,
    /// An open red item (`<outcome> <slug>`), else the route a failure takes, else `-`.
    pub triage: String,
    pub next: Option<i64>,
    /// What one run is made of.
    pub inside: String,
    /// What starts it, as its source writes it.
    pub before: String,
    /// What reads its result: Sentinel, the triage route, held queue items.
    pub after: Vec<String>,
    /// Each open red item, `<slug> (<outcome>)`.
    pub open: Vec<String>,
    pub runs: Vec<Run>,
    /// The runner whose Fleet page this row opens instead of a detail of its own; empty if none.
    pub page: String,
    /// The detail's head: `red since 11-01, triage no fix ar-485, next 02:00`.
    pub status: String,
    /// `streak_text` for a surface that has only the JSON.
    pub streak_word: String,
    /// The service it starts, as a red's `unit <name>` names it.
    #[serde(skip)]
    unit: String,
    /// The words a watch's `where:` must all name to be about this row.
    #[serde(skip)]
    words: Vec<String>,
}

impl Schedule {
    fn red(&self) -> bool {
        self.streak < 0
    }

    /// The streak as the column shows it, empty with none.
    pub fn streak_text(&self) -> String {
        match self.streak {
            0 => String::new(),
            n if n < 0 => format!("red {}", -n),
            n => format!("green {n}"),
        }
    }

    /// Take `runs` as this row's history: its last result and its streak.
    fn settle(&mut self, mut runs: Vec<Run>) {
        runs.sort_by(|a, b| b.at.cmp(&a.at));
        if let Some(r) = runs.first() {
            self.last = r.at;
            self.result = r.result.clone();
            self.ok = r.ok;
        }
        (self.streak, self.red_since) = streak(&runs);
        self.runs = runs;
    }
}

impl Row for Schedule {
    // `repo` and `next` are last and undrawn: they filter and sort, and the first seven line up
    // with the columns each surface draws.
    const COLUMNS: &'static [&'static str] = &[
        "kind", "name", "schedule", "last", "result", "streak", "triage", "repo", "next",
    ];
    const STATES: &'static [&'static str] = &["all", "red", "ok", "unknown", "no-purpose"];
    const FACETS: &'static [&'static str] = &["kind", "repo", "result"];

    fn val(&self, col: &str) -> Val {
        let text = |s: &str| match s {
            "" | "-" => Val::None,
            s => Val::Text(s.to_string()),
        };
        let num = |v: Option<i64>| v.map_or(Val::None, |v| Val::Num(v as f64));
        match col {
            "kind" => text(&self.kind),
            "name" => text(&self.name),
            "schedule" => text(&self.schedule),
            "last" => num(self.last),
            "result" => text(&self.result),
            // Negated, so a header's first click (biggest first) puts the longest red on top.
            "streak" if self.streak != 0 => Val::Num(-f64::from(self.streak)),
            "triage" => text(&self.triage),
            "repo" => text(&self.repo),
            "next" => num(self.next),
            _ => Val::None,
        }
    }

    fn in_state(&self, state: &str) -> bool {
        match state {
            "red" => self.red(),
            "ok" => self.streak > 0,
            "unknown" => self.streak == 0,
            "no-purpose" => self.purpose.is_empty(),
            _ => true,
        }
    }

    fn text(&self) -> String {
        [
            &self.kind,
            &self.name,
            &self.schedule,
            &self.result,
            &self.triage,
            &self.repo,
            &self.purpose,
        ]
        .map(String::as_str)
        .join("\n")
        .to_lowercase()
    }
}

/// Every schedule, exceptions first: red, then no purpose, then by kind and name.
#[derive(Serialize, Debug, Default, Clone, PartialEq)]
pub struct Schedules {
    pub at: i64,
    /// `41 scheduled, 3 red, 2 no purpose, CI read 4m ago`.
    pub summary: String,
    pub rows: Vec<Schedule>,
    /// `<source>: <why>` for each source that could not be read.
    pub errors: Vec<String>,
}

/// The newest-first runs' streak and, when red, when it began. A run that neither passed nor
/// failed (cancelled, blocked) neither extends nor ends one.
fn streak(runs: &[Run]) -> (i32, Option<i64>) {
    let mut decided = runs.iter().filter(|r| r.ok.is_some());
    let Some(first) = decided.next() else {
        return (0, None);
    };
    let (mut n, mut since) = (1, first.at);
    for r in decided.take_while(|r| r.ok == first.ok) {
        n += 1;
        since = r.at;
    }
    if first.ok == Some(true) {
        (n, None)
    } else {
        (-n, since)
    }
}

/// A local minute of the day as `HH:MM`.
fn hhmm(t: i32) -> String {
    let t = t.rem_euclid(1440);
    format!("{:02}:{:02}", t / 60, t % 60)
}

fn hourly(min: i32) -> String {
    if min == 0 {
        "hourly".into()
    } else {
        format!("hourly at :{min:02}")
    }
}

/// A UTC cron in words, in the zone `off` seconds east: `02:00 daily`, `05:30 Sat`, `every 15m`.
/// A shape with no short wording stays the cron, marked UTC.
pub fn cron_words(cron: &str, off: i32) -> String {
    let raw = || format!("{cron} UTC");
    let f: Vec<&str> = cron.split_whitespace().collect();
    let [m, h, "*", "*", dow] = f[..] else {
        return raw();
    };
    if let (Some(n), "*", "*") = (m.strip_prefix("*/"), h, dow) {
        return format!("every {n}m");
    }
    let Ok(min) = m.parse::<i32>() else {
        return raw();
    };
    if dow == "*" {
        if h == "*" {
            return hourly(min);
        }
        if let (Some(n), 0) = (h.strip_prefix("*/"), min) {
            return format!("every {n}h");
        }
    }
    let Some(hours) = h
        .split(',')
        .map(|x| x.parse::<i32>().ok())
        .collect::<Option<Vec<_>>>()
    else {
        return raw();
    };
    let mut local: Vec<i32> = hours.iter().map(|x| x * 60 + min + off / 60).collect();
    if dow == "*" {
        local.sort_by_key(|t| t.rem_euclid(1440));
        let times: Vec<String> = local.into_iter().map(hhmm).collect();
        return format!("{} daily", times.join(", "));
    }
    match (dow.parse::<i32>(), &local[..]) {
        (Ok(d), [t]) => {
            let day = (d + t.div_euclid(1440)).rem_euclid(7);
            format!("{} {}", hhmm(*t), DAYS[day as usize])
        }
        _ => raw(),
    }
}

/// Whether `v` is in one cron field: `*`, `N`, `A-B`, a `/step` on any of them, or a list. `first`
/// is the field's lowest value, where a `*/N` counts from: days and months start at 1.
fn fits(field: &str, v: u32, first: u32) -> bool {
    field.split(',').any(|p| {
        let (range, step) = p.split_once('/').unwrap_or((p, "1"));
        let step = step.parse::<u32>().unwrap_or(1).max(1);
        let (lo, hi) = match range.split_once('-') {
            Some((a, b)) => (a.parse().unwrap_or(u32::MAX), b.parse().unwrap_or(0)),
            None if range == "*" => (first, u32::MAX),
            None => {
                let n = range.parse().unwrap_or(u32::MAX);
                (n, if p.contains('/') { u32::MAX } else { n })
            }
        };
        (lo..=hi).contains(&v) && (v - lo).is_multiple_of(step)
    })
}

/// A UTC cron's next start after `at`, by walking its minutes.
fn cron_next(cron: &str, at: i64) -> Option<i64> {
    let f: Vec<&str> = cron.split_whitespace().collect();
    let [m, h, dom, mon, dow] = f[..] else {
        return None;
    };
    let start = at - at.rem_euclid(60) + 60;
    (0..NEXT_MINUTES).map(|i| start + i * 60).find(|&t| {
        DateTime::from_timestamp(t, 0).is_some_and(|d| {
            let w = d.weekday().num_days_from_sunday();
            let on_date = fits(dom, d.day(), 1);
            let on_weekday = fits(dow, w, 0) || (w == 0 && fits(dow, 7, 0));
            // Cron runs on either when both are restricted, and on both otherwise.
            let on_day = if dom != "*" && dow != "*" {
                on_date || on_weekday
            } else {
                on_date && on_weekday
            };
            fits(m, d.minute(), 0) && fits(h, d.hour(), 0) && fits(mon, d.month(), 1) && on_day
        })
    })
}

/// A systemd `OnCalendar` in words: it is already local. Shapes with no short wording stay as
/// written.
pub fn calendar_words(spec: &str) -> String {
    let s = spec.trim();
    if matches!(s, "minutely" | "hourly" | "daily" | "weekly" | "monthly") {
        return s.to_string();
    }
    let mut parts: Vec<&str> = s.split_whitespace().collect();
    let Some(time) = parts.pop() else {
        return s.to_string();
    };
    if parts.last().is_some_and(|d| d.contains('-')) && parts.pop() != Some("*-*-*") {
        return s.to_string();
    }
    let day = parts.pop();
    if !parts.is_empty() {
        return s.to_string();
    }
    let t: Vec<&str> = time.split(':').collect();
    let (h, m) = match t[..] {
        [h, m] | [h, m, "00"] => (h, m),
        _ => return s.to_string(),
    };
    let min = m.parse::<i32>().ok();
    if day.is_none() {
        match (h, m.split_once('/'), min) {
            ("*", Some((_, n)), _) => return format!("every {}m", n.trim_start_matches('0')),
            ("*", None, Some(min)) => return hourly(min),
            ("*", None, None) if m.contains(',') => {
                return format!("hourly at :{}", m.replace(',', ", :"));
            }
            _ => {}
        }
        if let (Some((_, n)), Some(0)) = (h.split_once('/'), min) {
            return format!("every {}h", n.trim_start_matches('0'));
        }
    }
    let hours = h
        .split(',')
        .map(|x| x.parse::<i32>().ok())
        .collect::<Option<Vec<_>>>();
    match (hours, min) {
        (Some(hours), Some(min)) => {
            let times: Vec<String> = hours.iter().map(|x| hhmm(x * 60 + min)).collect();
            format!("{} {}", times.join(", "), day.unwrap_or("daily"))
        }
        _ => s.to_string(),
    }
}

#[derive(Deserialize, Default)]
#[serde(default)]
struct CiState {
    generated_at: Option<String>,
    repos: Vec<CiRepo>,
}

#[derive(Deserialize, Default)]
#[serde(default)]
struct CiRepo {
    repo: String,
    error: Option<String>,
    workflows: Vec<CiWorkflow>,
}

#[derive(Deserialize, Default)]
#[serde(default)]
struct CiWorkflow {
    path: String,
    name: String,
    crons: Vec<String>,
    purpose: Option<String>,
    jobs: Vec<CiJob>,
    runs: Vec<CiRun>,
}

#[derive(Deserialize, Default)]
#[serde(default)]
struct CiJob {
    id: String,
    name: Option<String>,
    needs: Vec<String>,
}

#[derive(Deserialize, Default)]
#[serde(default)]
struct CiRun {
    url: String,
    created_at: Option<String>,
    ended_at: Option<String>,
    status: String,
    conclusion: Option<String>,
    failed_jobs: Vec<String>,
}

/// The job graph as its layers: `Plan -> PlayMode -> PlayMode report`.
fn layers(jobs: &[CiJob]) -> String {
    let mut depth: HashMap<&str, usize> = HashMap::new();
    // One pass settles at least one more layer, and there are at most as many layers as jobs.
    for _ in 0..jobs.len() {
        for j in jobs {
            let d = j
                .needs
                .iter()
                .filter_map(|n| depth.get(n.as_str()))
                .map(|d| d + 1)
                .max();
            depth.insert(&j.id, d.unwrap_or(0));
        }
    }
    let mut by: BTreeMap<usize, Vec<&str>> = BTreeMap::new();
    for j in jobs {
        by.entry(depth[j.id.as_str()])
            .or_default()
            .push(j.name.as_deref().unwrap_or(&j.id));
    }
    let names: Vec<String> = by.values().map(|l| l.join(", ")).collect();
    names.join(" -> ")
}

/// The rows, when the state file was written, and the repos it could not read.
type CiRead = (Vec<Schedule>, Option<i64>, Vec<String>);

/// The GitHub rows, and when the state file was written. A workflow with no cron is not a
/// schedule; a run still going has no result yet.
fn ci_rows(text: &str, at: i64, off: i32) -> Result<CiRead, String> {
    let st: CiState = serde_json::from_str(text).map_err(|e| format!("state.json: {e}"))?;
    let mut rows = vec![];
    let mut errors = vec![];
    for repo in st.repos {
        let short = repo
            .repo
            .rsplit('/')
            .next()
            .unwrap_or(&repo.repo)
            .to_string();
        if let Some(e) = repo.error.filter(|e| !e.is_empty()) {
            errors.push(format!("ci {short}: {e}"));
        }
        for w in repo.workflows.into_iter().filter(|w| !w.crons.is_empty()) {
            let words: Vec<String> = w.crons.iter().map(|c| cron_words(c, off)).collect();
            let raw: Vec<String> = w.crons.iter().map(|c| format!("cron {c} UTC")).collect();
            let file = w.path.rsplit('/').next().unwrap_or(&w.path).to_string();
            let mut row = Schedule {
                kind: CI.into(),
                name: format!("{short} / {}", w.name),
                repo: short.clone(),
                schedule: words.join(", "),
                purpose: w.purpose.unwrap_or_default().trim().to_string(),
                next: w.crons.iter().filter_map(|c| cron_next(c, at)).min(),
                inside: layers(&w.jobs),
                before: raw.join(", "),
                words: vec![short.clone(), file],
                ..Default::default()
            };
            let runs = w
                .runs
                .into_iter()
                .filter(|r| r.status == "completed")
                .map(|r| {
                    let c = r.conclusion.unwrap_or_default();
                    Run {
                        at: r.ended_at.or(r.created_at).as_deref().and_then(fleet::ts),
                        ok: jobs::conclusion_ok(&c),
                        result: c,
                        failed: r.failed_jobs,
                        url: r.url,
                    }
                })
                .collect();
            row.settle(runs);
            rows.push(row);
        }
    }
    Ok((rows, st.generated_at.as_deref().and_then(fleet::ts), errors))
}

/// `name`'s finished runs among `jobs`.
fn runs_of(jobs: &[Job], name: &str) -> Vec<Run> {
    jobs.iter()
        .filter(|j| j.name == name && j.state == State::Done)
        .map(|j| Run {
            at: j.finished.or(j.started),
            result: j.result.clone(),
            ok: j.ok,
            ..Default::default()
        })
        .collect()
}

/// `systemctl list-timers -o json`, one timer: times in microseconds, 0 or null for none.
#[derive(Deserialize, Default, Clone)]
#[serde(default)]
struct Listed {
    unit: String,
    activates: String,
    next: Option<u64>,
    last: Option<u64>,
}

fn secs(us: Option<u64>) -> Option<i64> {
    us.filter(|&t| t > 0).map(|t| (t / 1_000_000) as i64)
}

/// The enabled runners with a schedule. Their history lives on their Fleet page, so a row carries
/// only the summary and opens that page.
fn agentctl_rows(confs: Vec<Conf>, runs: &[Job], timers: &[Listed]) -> Vec<Schedule> {
    confs
        .into_iter()
        .filter(|c| c.enabled && !c.schedule.is_empty())
        .map(|c| {
            let unit = format!("agentctl@{}.service", c.name);
            let mut row = Schedule {
                kind: AGENTCTL.into(),
                schedule: calendar_words(&c.schedule),
                purpose: c.description.trim().to_string(),
                next: timers
                    .iter()
                    .find(|t| t.activates == unit)
                    .and_then(|t| secs(t.next)),
                before: format!("OnCalendar {}", c.schedule),
                page: c.name.clone(),
                words: vec![c.name.clone()],
                name: c.name,
                unit,
                ..Default::default()
            };
            row.settle(runs_of(runs, &row.name));
            row.runs.clear();
            row
        })
        .collect()
}

/// One unit's `systemctl show` properties, in order. A property can repeat.
type Props = Vec<(String, String)>;

/// `systemctl show` output: each unit's properties by its `Id`.
fn parse_show(text: &str) -> HashMap<String, Props> {
    text.split("\n\n")
        .filter_map(|b| {
            let kv: Props = b
                .lines()
                .filter_map(|l| l.split_once('='))
                .map(|(k, v)| (k.to_string(), v.to_string()))
                .collect();
            let id = kv.iter().find(|(k, _)| k == "Id")?.1.clone();
            Some((id, kv))
        })
        .collect()
}

fn prop<'a>(kv: Option<&'a Props>, key: &str) -> &'a str {
    kv.and_then(|kv| kv.iter().find(|(k, _)| k == key))
        .map_or("", |(_, v)| v.as_str())
}

/// A unit's own Description. systemd falls back to the unit's name, which says nothing.
fn described(kv: Option<&Props>) -> &str {
    let d = prop(kv, "Description");
    if d == prop(kv, "Id") {
        ""
    } else {
        d
    }
}

/// A timer's triggers as words and as written, from `TimersCalendar={ OnCalendar=x ; ... }` and
/// `TimersMonotonic={ OnUnitActiveUSec=5min ; ... }`.
fn triggers(kv: Option<&Props>) -> (String, String) {
    let (mut words, mut raw) = (vec![], vec![]);
    for (k, v) in kv.into_iter().flatten() {
        if k != "TimersCalendar" && k != "TimersMonotonic" {
            continue;
        }
        let inner = v.trim_start_matches("{ ");
        let Some((key, rest)) = inner.split_once('=') else {
            continue;
        };
        let value = rest.split(" ;").next().unwrap_or(rest).trim();
        raw.push(format!("{key} {value}"));
        match key {
            "OnCalendar" => words.push(calendar_words(value)),
            "OnUnitActiveUSec" | "OnUnitInactiveUSec" => words.push(format!("every {value}")),
            _ => {}
        }
    }
    if words.is_empty() {
        words.clone_from(&raw);
    }
    (words.join(", "), raw.join(", "))
}

/// The command in `ExecStart={ path=... ; argv[]=<command> ; ... }`, with the home folded.
fn exec(kv: Option<&Props>, home: &str) -> String {
    let e = prop(kv, "ExecStart");
    let cmd = e
        .split_once("argv[]=")
        .and_then(|(_, r)| r.split(" ;").next())
        .unwrap_or("")
        .trim();
    match cmd.strip_prefix(home) {
        Some(r) if !home.is_empty() => format!("~{r}"),
        _ => cmd.to_string(),
    }
}

/// The user timers agentctl does not own. A run the journal does not hold still shows, from
/// systemd's own last start and result, as a streak of one.
fn timer_rows(
    listed: &[Listed],
    timers: &HashMap<String, Props>,
    services: &HashMap<String, Props>,
    runs: &[Job],
    home: &str,
) -> Vec<Schedule> {
    listed
        .iter()
        .filter(|t| !t.activates.starts_with("agentctl@"))
        .map(|t| {
            let (tk, sk) = (timers.get(&t.unit), services.get(&t.activates));
            let name = t.unit.strip_suffix(".timer").unwrap_or(&t.unit).to_string();
            let (schedule, before) = triggers(tk);
            let purpose = Some(described(tk))
                .filter(|d| !d.is_empty())
                .unwrap_or(described(sk));
            let mut row = Schedule {
                kind: TIMER.into(),
                schedule,
                purpose: purpose.to_string(),
                next: secs(t.next),
                inside: exec(sk, home),
                before,
                unit: t.activates.clone(),
                words: vec![name.clone()],
                name,
                ..Default::default()
            };
            let service = t.activates.strip_suffix(".service").unwrap_or(&t.activates);
            row.settle(runs_of(runs, service));
            if row.last.is_none() {
                row.last = secs(t.last);
                if row.last.is_some() {
                    row.result = prop(sk, "Result").to_string();
                    row.ok = Some(row.result == "success");
                    row.streak = if row.ok == Some(true) { 1 } else { -1 };
                    row.red_since = row.last.filter(|_| row.streak < 0);
                }
            }
            row
        })
        .collect()
}

/// The k8s Prometheus series `k8s_rows` joins, each keyed by namespace and cronjob.
#[derive(Default)]
struct Cron {
    info: Vec<Series>,
    next: Vec<Series>,
    suspended: Vec<Series>,
    annotations: Vec<Series>,
}

/// The CronJobs kube-state-metrics reports. Its cron is in the controller's zone, UTC here. The
/// purpose is the `description` annotation, once its allowlist exposes it.
fn k8s_rows(c: &Cron, runs: &[Job], off: i32) -> Vec<Schedule> {
    fn find<'a>(of: &'a [Series], ns: &str, job: &str) -> Option<&'a Series> {
        of.iter()
            .find(|s| s.label("namespace") == ns && s.label("cronjob") == job)
    }
    let mut seen: BTreeMap<(String, String), String> = BTreeMap::new();
    for s in &c.info {
        seen.insert(
            (s.label("namespace").into(), s.label("cronjob").into()),
            s.label("schedule").into(),
        );
    }
    seen.into_iter()
        .map(|((ns, job), cron)| {
            let suspended = find(&c.suspended, &ns, &job).and_then(|s| s.value) == Some(1.0);
            let name = format!("{ns}/{job}");
            let mut row = Schedule {
                kind: K8S.into(),
                schedule: format!(
                    "{}{}",
                    cron_words(&cron, off),
                    if suspended { ", suspended" } else { "" }
                ),
                purpose: find(&c.annotations, &ns, &job)
                    .map(|s| s.label("annotation_description").trim().to_string())
                    .unwrap_or_default(),
                next: find(&c.next, &ns, &job)
                    .and_then(|s| s.value)
                    .filter(|_| !suspended)
                    .map(|v| v as i64),
                before: format!("cron {cron} UTC"),
                words: vec![job],
                name,
                ..Default::default()
            };
            row.settle(runs_of(runs, &row.name));
            row
        })
        .collect()
}

/// Whether `text` has `word` on its own: `unity-core` is not in `unity-core-playground`.
fn mentions(text: &str, word: &str) -> bool {
    let part = |c: char| c.is_alphanumeric() || c == '-' || c == '_';
    text.match_indices(word).any(|(i, _)| {
        !text[..i].chars().next_back().is_some_and(part)
            && !text[i + word.len()..].chars().next().is_some_and(part)
    })
}

/// Whether the watch looks at this row: it shares the row's name, or its `where:` names all the
/// row's words. Only the `where:`: the rest of a watch file mentions tools it runs and fixes it
/// suggests, and none of those is what the watch looks at.
fn about(row: &Schedule, watch: &Watch) -> bool {
    watch.name == row.name || row.words.iter().all(|w| mentions(&watch.place, w))
}

/// A route from the table, as `fleet-bench triage --route` prints it, by the key asked about.
#[derive(Debug, Clone, PartialEq)]
struct Route {
    route: String,
    skill: String,
    tags: String,
}

impl Route {
    fn word(&self) -> String {
        match self.skill.as_str() {
            "" | "-" => self.route.clone(),
            s => format!("{} {s}", self.route),
        }
    }
}

fn parse_routes(out: &str) -> HashMap<String, Route> {
    out.lines()
        .filter_map(|l| {
            let mut f = l.split('\t');
            let key = f.next()?.to_string();
            let route = f.next()?.to_string();
            let skill = f.next().unwrap_or("").to_string();
            let tags = f.next().unwrap_or("").to_string();
            Some((key, Route { route, skill, tags }))
        })
        .filter(|(_, r)| r.route != "-")
        .collect()
}

/// What `fleet-bench` calls `row`'s failures, its watches first: a red's `red`, a route's key.
fn red_keys(row: &Schedule, mine: &[&Watch]) -> Vec<String> {
    let mut keys: Vec<String> = mine.iter().map(|w| format!("watch {}", w.name)).collect();
    if row.kind == AGENTCTL {
        keys.push(format!("runner {}", row.name));
    }
    if !row.unit.is_empty() {
        keys.push(format!("unit {}", row.unit));
    }
    keys
}

/// Fill what depends on the rest of the fleet: the triage word, the open reds, and After.
fn join(
    row: &mut Schedule,
    mine: &[&Watch],
    routes: &HashMap<String, Route>,
    reds: &[Red],
    held: &HashMap<String, usize>,
) {
    let keys = red_keys(row, mine);
    let open: Vec<&Red> = reds.iter().filter(|r| keys.contains(&r.red)).collect();
    row.open = open
        .iter()
        .map(|r| format!("{} ({})", r.slug, r.outcome))
        .collect();
    let route = keys.iter().find_map(|k| routes.get(k));
    row.triage = match (open.first(), &route) {
        (Some(r), _) => format!("{} {}", r.outcome, r.slug),
        (None, Some(r)) => r.word(),
        _ => "-".into(),
    };
    row.after = mine
        .iter()
        .map(|w| {
            let tripped = if w.state == "TRIP" { ", tripped" } else { "" };
            format!("Sentinel {} (pages {}{tripped})", w.name, w.severity)
        })
        .collect();
    if let Some(r) = route {
        row.after.push(format!("triage {}", r.word()));
        for t in r
            .tags
            .split_whitespace()
            .filter(|t| t.starts_with("nightly:"))
        {
            let n = held.get(t).copied().unwrap_or(0);
            row.after.push(format!("{t} releases {n} held items"));
        }
    }
}

fn local(t: i64, off: i32, fmt: &str) -> String {
    let zone = FixedOffset::east_opt(off).unwrap_or(FixedOffset::east_opt(0).expect("UTC"));
    DateTime::from_timestamp(t, 0)
        .map(|d| d.with_timezone(&zone).format(fmt).to_string())
        .unwrap_or_default()
}

/// The detail's head line: how it stands, what is on it, when it next runs.
fn status(row: &Schedule, at: i64, off: i32) -> String {
    let mut parts = vec![];
    match (row.streak, row.red_since) {
        (n, Some(t)) if n < 0 => parts.push(format!("red since {}", local(t, off, "%m-%d"))),
        (n, _) if n > 0 => parts.push("green".to_string()),
        _ => parts.push("no result yet".to_string()),
    }
    if row.triage != "-" {
        parts.push(format!("triage {}", row.triage));
    }
    if let Some(t) = row.next {
        let fmt = if t - at < 86400 {
            "%H:%M"
        } else {
            "%m-%d %H:%M"
        };
        parts.push(format!("next {}", local(t, off, fmt)));
    }
    parts.join(", ")
}

/// Exceptions first, then a stable order to read down.
fn rank(rows: &mut [Schedule]) {
    let weight = |r: &Schedule| {
        if r.red() {
            0
        } else if r.purpose.is_empty() {
            1
        } else {
            2
        }
    };
    rows.sort_by(|a, b| (weight(a), &a.kind, &a.name).cmp(&(weight(b), &b.kind, &b.name)));
}

fn summary(rows: &[Schedule], ci_at: Option<i64>, at: i64) -> String {
    let red = rows.iter().filter(|r| r.red()).count();
    let gaps = rows.iter().filter(|r| r.purpose.is_empty()).count();
    let read = ci_at.map_or("CI not read".to_string(), |t| {
        format!("CI read {} ago", age(at - t))
    });
    format!(
        "{} scheduled, {red} red, {gaps} no purpose, {read}",
        rows.len()
    )
}

/// `home`'s path `rel`, or the variable's when it is set.
fn path(var: &str, home: &str, rel: &str) -> PathBuf {
    std::env::var_os(var)
        .filter(|v| !v.is_empty())
        .map(PathBuf::from)
        .unwrap_or_else(|| Path::new(home).join(rel))
}

/// `systemctl --user show` for `units`, or nothing with none to ask about.
fn show(
    runner: &dyn Runner,
    units: &[&str],
    props: &str,
) -> Result<HashMap<String, Props>, String> {
    if units.is_empty() {
        return Ok(HashMap::new());
    }
    let mut argv: Vec<String> = ["systemctl", "--user", "show", "-p", props]
        .map(String::from)
        .to_vec();
    argv.extend(units.iter().map(|u| u.to_string()));
    runner.run(&argv).map(|o| parse_show(&o))
}

/// `r`'s value, or its error noted under `src` and nothing.
fn noted<T: Default>(r: Result<T, String>, src: &str, errors: &mut Vec<String>) -> T {
    r.unwrap_or_else(|e| {
        errors.push(format!("{src}: {e}"));
        T::default()
    })
}

fn tagged(found: Vec<String>, src: &str, errors: &mut Vec<String>) {
    errors.extend(found.into_iter().map(|e| format!("{src}: {e}")));
}

/// The k8s rows and what went wrong reading them.
fn read_k8s(at: i64, off: i32) -> (Vec<Schedule>, Vec<String>) {
    let mut errors = vec![];
    let cron = match prom::base() {
        Ok(base) => {
            let mut q = |m: &str| noted(prom::instant(&base, m), "k8s", &mut errors);
            Cron {
                info: q("kube_cronjob_info"),
                next: q("kube_cronjob_next_schedule_time"),
                suspended: q("kube_cronjob_spec_suspend"),
                annotations: q("kube_cronjob_annotations"),
            }
        }
        Err(e) => {
            errors.push(format!("k8s: {e}"));
            Cron::default()
        }
    };
    let (runs, e) = jobs::k8s_runs(at, at - WEEK);
    tagged(e, "k8s", &mut errors);
    (k8s_rows(&cron, &runs, off), errors)
}

/// Every timer systemd lists, the rows of those agentctl does not own, and what went wrong.
fn read_timers(
    runner: &dyn Runner,
    at: i64,
    home: &str,
) -> (Vec<Listed>, Vec<Schedule>, Vec<String>) {
    let mut errors = vec![];
    let list = runner
        .run(&["systemctl", "--user", "list-timers", "--all", "-o", "json"].map(String::from))
        .and_then(|o| serde_json::from_str(&o).map_err(|e| format!("list-timers: {e}")));
    let listed: Vec<Listed> = noted(list, "timers", &mut errors);
    let plain: Vec<&Listed> = listed
        .iter()
        .filter(|t| !t.activates.starts_with("agentctl@"))
        .collect();
    let units: Vec<&str> = plain.iter().map(|t| t.unit.as_str()).collect();
    let services: Vec<&str> = plain.iter().map(|t| t.activates.as_str()).collect();
    let timers = noted(
        show(
            runner,
            &units,
            "Id,Description,TimersCalendar,TimersMonotonic",
        ),
        "timers",
        &mut errors,
    );
    let ran = noted(
        show(runner, &services, "Id,Description,Result,ExecStart"),
        "timers",
        &mut errors,
    );
    let (runs, e) = jobs::timer_runs(at - WEEK, at);
    tagged(e, "timers", &mut errors);
    let rows = timer_rows(&listed, &timers, &ran, &runs, home);
    (listed, rows, errors)
}

/// Every schedule the four sources know of. They read at once, as `jobs::collect` does: only the
/// triage routes wait, on the rows they are asked about.
pub fn read(paths: &fleet::Paths, runner: &(dyn Runner + Sync)) -> Schedules {
    let at = jobs::now();
    let off = Local::now().offset().local_minus_utc();
    let home = std::env::var("HOME").unwrap_or_default();
    let mut errors = vec![];
    let mut rows = vec![];

    let (timers, k8s, reds, queued) = std::thread::scope(|s| {
        let timers = s.spawn(|| read_timers(runner, at, &home));
        let k8s = s.spawn(|| read_k8s(at, off));
        let reds = s.spawn(|| reds::read(runner).map(|r| r.open));
        let queued = s.spawn(|| queue::list(runner, "queued"));
        let gone = || "panicked".to_string();
        (
            timers
                .join()
                .unwrap_or_else(|_| (vec![], vec![], vec![gone()])),
            k8s.join().unwrap_or_else(|_| (vec![], vec![gone()])),
            reds.join().unwrap_or_else(|_| Err(gone())),
            queued.join().unwrap_or_else(|_| Err(gone())),
        )
    });

    let state = path(
        "SCHEDULES_STATE",
        &home,
        ".local/state/schedules/state.json",
    );
    let ci = std::fs::read_to_string(&state)
        .map_err(|e| format!("{}: {e}", state.display()))
        .and_then(|t| ci_rows(&t, at, off));
    let ci_at = match ci {
        Ok((r, generated, e)) => {
            rows.extend(r);
            errors.extend(e);
            generated
        }
        Err(e) => {
            errors.push(format!("ci: {e}"));
            None
        }
    };

    let (listed, timer_rows, e) = timers;
    errors.extend(e);
    let (confs, e) = fleet::read_confs(&paths.agents, &paths.jobs.agentctl);
    tagged(e, "agentctl", &mut errors);
    let (runs, e) = jobs::agentctl_runs(&paths.jobs, at - WEEK);
    tagged(e, "agentctl", &mut errors);
    rows.extend(agentctl_rows(confs, &runs, &listed));
    rows.extend(timer_rows);
    let (k8s_rows, e) = k8s;
    rows.extend(k8s_rows);
    errors.extend(e);

    let (dir, sentinel) = runner::watch_dirs(&home, |k| std::env::var(k).unwrap_or_default());
    let watches = noted(runner::watches(&dir, &sentinel), "sentinel", &mut errors);
    let mine: Vec<Vec<&Watch>> = rows
        .iter()
        .map(|r| watches.iter().filter(|w| about(r, w)).collect())
        .collect();

    let mut argv: Vec<String> = ["fleet-bench", "triage", "--route"]
        .map(String::from)
        .to_vec();
    let mut keys: Vec<String> = rows
        .iter()
        .zip(&mine)
        .flat_map(|(r, m)| red_keys(r, m))
        .collect();
    keys.sort();
    keys.dedup();
    argv.extend(keys);
    let routes = noted(
        runner.run(&argv).map(|o| parse_routes(&o)),
        "triage routes",
        &mut errors,
    );
    let reds = noted(reds, "reds", &mut errors);
    let queued = noted(queued, "queue", &mut errors);
    let mut held: HashMap<String, usize> = HashMap::new();
    for t in queued.iter().flat_map(|i| i.tag_list()) {
        if t.starts_with("nightly:") {
            *held.entry(t.to_string()).or_default() += 1;
        }
    }

    for (row, m) in rows.iter_mut().zip(&mine) {
        join(row, m, &routes, &reds, &held);
        row.status = status(row, at, off);
        row.streak_word = row.streak_text();
    }
    rank(&mut rows);
    Schedules {
        at,
        summary: summary(&rows, ci_at, at),
        rows,
        errors,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::table::View;

    const PST: i32 = -8 * 3600;
    /// 2026-11-06 22:00 UTC, a Friday.
    const AT: i64 = 1_794_002_400;

    fn run(ok: Option<bool>, at: i64) -> Run {
        Run {
            at: Some(at),
            ok,
            result: format!("{ok:?}"),
            ..Default::default()
        }
    }

    fn series(labels: &[(&str, &str)], value: f64) -> Series {
        Series {
            labels: labels
                .iter()
                .map(|(k, v)| (k.to_string(), v.to_string()))
                .collect(),
            value: Some(value),
            points: vec![],
        }
    }

    #[test]
    fn cron_words_are_local_and_a_shape_with_no_wording_stays_the_cron() {
        assert_eq!(cron_words("0 10 * * *", PST), "02:00 daily");
        assert_eq!(cron_words("30 12 * * *", PST), "04:30 daily");
        assert_eq!(cron_words("0 6,18 * * *", 0), "06:00, 18:00 daily");
        assert_eq!(cron_words("7 * * * *", PST), "hourly at :07");
        assert_eq!(cron_words("0 * * * *", PST), "hourly");
        assert_eq!(cron_words("*/15 * * * *", PST), "every 15m");
        assert_eq!(cron_words("0 */6 * * *", PST), "every 6h");
        assert_eq!(cron_words("30 */6 * * *", PST), "30 */6 * * * UTC");
        assert_eq!(cron_words("0 3 1 * *", PST), "0 3 1 * * UTC");
        assert_eq!(cron_words("nonsense", PST), "nonsense UTC");
    }

    #[test]
    fn a_weekly_cron_moves_to_the_local_day() {
        assert_eq!(cron_words("30 13 * * 6", PST), "05:30 Sat");
        // 04:15 Sunday UTC is the evening before on the coast.
        assert_eq!(cron_words("15 4 * * 0", PST), "20:15 Sat");
    }

    #[test]
    fn cron_next_finds_the_next_matching_minute() {
        // 22:00 Friday UTC: the next 10:00 is tomorrow, the next Sunday 04:15 is in 30h15m.
        assert_eq!(cron_next("0 10 * * *", AT), Some(AT + 12 * 3600));
        assert_eq!(cron_next("15 4 * * 0", AT), Some(AT + 30 * 3600 + 15 * 60));
        assert_eq!(cron_next("*/15 * * * *", AT), Some(AT + 15 * 60));
        assert_eq!(cron_next("bad", AT), None);
        // Sunday is 7 as well as 0.
        assert_eq!(cron_next("15 4 * * 7", AT), Some(AT + 30 * 3600 + 15 * 60));
    }

    #[test]
    fn cron_next_counts_days_and_months_from_one_and_takes_either_day_field() {
        let at = |y, m, d| {
            chrono::NaiveDate::from_ymd_opt(y, m, d)
                .and_then(|x| x.and_hms_opt(0, 0, 0))
                .map(|x| x.and_utc().timestamp())
                .unwrap()
        };
        // Odd days and January, April...: a */N from zero would land on even days and March.
        assert_eq!(
            cron_next("0 0 */2 * *", at(2026, 11, 1)),
            Some(at(2026, 11, 3))
        );
        assert_eq!(
            cron_next("0 0 1 */3 *", at(2026, 12, 15)),
            Some(at(2027, 1, 1))
        );
        // The 15th, or the next Monday, whichever comes first.
        assert_eq!(
            cron_next("0 0 15 * 1", at(2026, 11, 3)),
            Some(at(2026, 11, 9))
        );
        assert_eq!(
            cron_next("0 0 15 * 1", at(2026, 11, 11)),
            Some(at(2026, 11, 15))
        );
    }

    #[test]
    fn calendar_words_read_the_shapes_agentctl_and_systemd_write() {
        assert_eq!(calendar_words("*-*-* 05:00:00"), "05:00 daily");
        assert_eq!(calendar_words("Sat *-*-* 08:00:00"), "08:00 Sat");
        assert_eq!(calendar_words("*-*-* 06,18:45:00"), "06:45, 18:45 daily");
        assert_eq!(calendar_words("hourly"), "hourly");
        assert_eq!(calendar_words("*-*-* *:00:00"), "hourly");
        assert_eq!(calendar_words("*:7/30"), "every 30m");
        assert_eq!(calendar_words("*-*-* *:00,30:00"), "hourly at :00, :30");
        assert_eq!(calendar_words("*-*-* *:00/15:00"), "every 15m");
        assert_eq!(calendar_words("*-*-* 00/6:00:00"), "every 6h");
        assert_eq!(calendar_words("*-*-01 03:00:00"), "*-*-01 03:00:00");
    }

    #[test]
    fn a_streak_counts_the_same_outcome_and_skips_a_cancelled_run() {
        let reds = [
            run(None, 5),
            run(Some(false), 4),
            run(Some(false), 3),
            run(Some(true), 2),
        ];
        assert_eq!(streak(&reds), (-2, Some(3)));
        assert_eq!(streak(&[run(Some(true), 2), run(Some(true), 1)]), (2, None));
        assert_eq!(streak(&[run(None, 1)]), (0, None));
        assert_eq!(streak(&[]), (0, None));
    }

    const STATE: &str = r#"{"generated_at":"2026-11-06T21:30:00Z","repos":[
      {"repo":"Org/app","error":"gh: 502","workflows":[
        {"path":".github/workflows/test.yml","name":"Tests","crons":["0 10 * * *"],"purpose":" Every class. ",
         "jobs":[{"id":"report","name":"Report","needs":["play"]},{"id":"plan","name":"Plan","needs":[]},
                 {"id":"play","name":null,"needs":["plan"]},{"id":"lint","name":"Lint","needs":[]}],
         "runs":[
          {"url":"u3","created_at":"2026-11-06T10:00:00Z","status":"in_progress","conclusion":null},
          {"url":"u2","created_at":"2026-11-05T10:00:00Z","ended_at":"2026-11-05T11:00:00Z","status":"completed","conclusion":"failure","failed_jobs":["PlayMode 2"]},
          {"url":"u1","created_at":"2026-11-04T10:00:00Z","ended_at":"2026-11-04T11:00:00Z","status":"completed","conclusion":"success"}]},
        {"path":".github/workflows/pr.yml","name":"PR","crons":[],"jobs":[],"runs":[]}]}]}"#;

    #[test]
    fn a_ci_row_joins_its_workflow_and_its_finished_runs() {
        let (rows, at, errors) = ci_rows(STATE, AT, PST).unwrap();
        assert_eq!(errors, ["ci app: gh: 502"]);
        assert_eq!(at, fleet::ts("2026-11-06T21:30:00Z"));
        assert_eq!(rows.len(), 1, "a workflow with no cron is not a schedule");
        let r = &rows[0];
        assert_eq!((r.kind.as_str(), r.name.as_str()), (CI, "app / Tests"));
        assert_eq!(r.repo, "app");
        assert_eq!(r.schedule, "02:00 daily");
        assert_eq!(r.purpose, "Every class.");
        assert_eq!(r.inside, "Plan, Lint -> play -> Report");
        assert_eq!(r.before, "cron 0 10 * * * UTC");
        assert_eq!(r.next, Some(AT + 12 * 3600));
        assert_eq!(r.runs.len(), 2, "the run still going has no result");
        assert_eq!(r.result, "failure");
        assert_eq!(r.runs[0].failed, ["PlayMode 2"]);
        assert_eq!(r.runs[0].url, "u2");
        assert_eq!(r.streak, -1);
    }

    #[test]
    fn a_state_file_that_is_not_json_is_an_error_not_a_panic() {
        assert!(ci_rows("nope", AT, PST).is_err());
    }

    fn conf(name: &str, schedule: &str, enabled: bool) -> Conf {
        Conf {
            name: name.into(),
            schedule: schedule.into(),
            description: "Consolidates memory".into(),
            enabled,
            ..Default::default()
        }
    }

    fn done(name: &str, ok: bool, at: i64) -> Job {
        let mut j = Job::new(jobs::Source::Agentctl, name, State::Done);
        j.ok = Some(ok);
        j.result = if ok { "WORKED" } else { "FAILED" }.into();
        j.finished = Some(at);
        j
    }

    #[test]
    fn a_runner_row_keeps_the_summary_and_opens_its_fleet_page() {
        let confs = vec![
            conf("dream", "*-*-* 03:00:00", true),
            conf("called", "", true),
            conf("off", "hourly", false),
        ];
        let runs = [
            done("dream", true, 10),
            done("dream", true, 20),
            done("x", false, 30),
        ];
        let timers = [Listed {
            activates: "agentctl@dream.service".into(),
            next: Some(99_000_000),
            ..Default::default()
        }];
        let rows = agentctl_rows(confs, &runs, &timers);
        assert_eq!(
            rows.len(),
            1,
            "a called or disabled runner is not a schedule"
        );
        let r = &rows[0];
        assert_eq!(r.page, "dream");
        assert_eq!(r.schedule, "03:00 daily");
        assert_eq!(
            (r.last, r.result.as_str(), r.streak),
            (Some(20), "WORKED", 2)
        );
        assert_eq!(r.next, Some(99));
        assert!(r.runs.is_empty(), "its history is the Fleet page's");
    }

    const SHOW_TIMERS: &str = "Id=day-log.timer\nDescription=Day log\n\
TimersCalendar={ OnCalendar=*-*-* 23:00:00 ; next_elapse=x }\n\n\
Id=pulse.timer\nDescription=pulse.timer\n\
TimersMonotonic={ OnBootUSec=1min ; next_elapse=x }\n\
TimersMonotonic={ OnUnitActiveUSec=5min ; next_elapse=x }\n\n\
Id=bare.timer\nDescription=bare.timer\nTimersCalendar={ OnCalendar=weekly ; next_elapse=x }\n";
    const SHOW_UNITS: &str = "Id=day-log.service\nDescription=day-log.service\nResult=success\n\
ExecStart={ path=/h/bin/day-log ; argv[]=/h/bin/day-log --write ; ignore_errors=no ; }\n\n\
Id=pulse.service\nDescription=Fleet pulse\nResult=success\nExecStart=\n\n\
Id=bare.service\nDescription=bare.service\nResult=exit-code\nExecStart=\n";

    fn listed(name: &str, last: Option<u64>) -> Listed {
        Listed {
            unit: format!("{name}.timer"),
            activates: format!("{name}.service"),
            next: Some(0),
            last,
        }
    }

    #[test]
    fn a_timer_row_reads_its_purpose_triggers_and_command() {
        let list = [
            listed("day-log", None),
            listed("pulse", None),
            listed("bare", Some(7_000_000)),
            Listed {
                unit: "agentctl-dream.timer".into(),
                activates: "agentctl@dream.service".into(),
                ..Default::default()
            },
        ];
        let mut j = done("day-log", false, 40);
        j.source = jobs::Source::Timer;
        let rows = timer_rows(
            &list,
            &parse_show(SHOW_TIMERS),
            &parse_show(SHOW_UNITS),
            &[j],
            "/h",
        );
        assert_eq!(rows.len(), 3, "agentctl's timer is its runner's row");
        let (day, pulse, bare) = (&rows[0], &rows[1], &rows[2]);
        assert_eq!(day.purpose, "Day log");
        assert_eq!(day.schedule, "23:00 daily");
        assert_eq!(day.inside, "~/bin/day-log --write");
        assert_eq!(day.before, "OnCalendar *-*-* 23:00:00");
        assert_eq!(day.next, None, "0 is no next start");
        assert_eq!((day.last, day.streak), (Some(40), -1));
        assert_eq!(pulse.purpose, "Fleet pulse", "falls back to the service's");
        assert_eq!(pulse.schedule, "every 5min");
        assert_eq!(pulse.before, "OnBootUSec 1min, OnUnitActiveUSec 5min");
        assert_eq!(bare.purpose, "", "a unit's own name is no purpose");
        assert_eq!(
            bare.last,
            Some(7),
            "outside the journal, systemd still knows"
        );
        assert_eq!((bare.result.as_str(), bare.ok), ("exit-code", Some(false)));
        assert_eq!((bare.streak, bare.red_since), (-1, Some(7)));
    }

    #[test]
    fn a_cronjob_row_reads_its_annotation_and_a_suspended_one_has_no_next() {
        let id = [("namespace", "nas"), ("cronjob", "phones-backup")];
        let quiet = [("namespace", "nas"), ("cronjob", "quiet")];
        let info = |l: &[(&str, &str)]| {
            let mut v = l.to_vec();
            v.push(("schedule", "15 4 * * 0"));
            series(&v, 1.0)
        };
        let mut note = id.to_vec();
        note.push(("annotation_description", "Phone photos to the NAS"));
        let c = Cron {
            // A second scrape of the same CronJob is the same row.
            info: vec![info(&id), info(&id), info(&quiet)],
            next: vec![series(&id, 500.0), series(&quiet, 600.0)],
            suspended: vec![series(&id, 0.0), series(&quiet, 1.0)],
            annotations: vec![series(&note, 1.0)],
        };
        let mut j = done("nas/phones-backup", true, 50);
        j.source = jobs::Source::K8s;
        let rows = k8s_rows(&c, &[j], PST);
        assert_eq!(rows.len(), 2);
        let (a, b) = (&rows[0], &rows[1]);
        assert_eq!(a.name, "nas/phones-backup");
        assert_eq!(a.schedule, "20:15 Sat");
        assert_eq!(a.purpose, "Phone photos to the NAS");
        assert_eq!((a.next, a.streak), (Some(500), 1));
        assert_eq!(b.schedule, "20:15 Sat, suspended");
        assert_eq!(b.next, None);
        assert_eq!(b.purpose, "", "no annotation is a gap, drawn amber");
    }

    #[test]
    fn a_word_is_mentioned_only_on_its_own() {
        assert!(mentions(
            "GitHub Actions, Org/unity-core, test.yml",
            "unity-core"
        ));
        assert!(mentions("uses test.yml.", "test.yml"));
        assert!(!mentions("Org/unity-core-playground", "unity-core"));
        assert!(!mentions("nightly_test.yml", "test.yml"));
    }

    #[test]
    fn a_watch_is_about_the_rows_its_where_names_and_nothing_else_in_its_file() {
        let yaml =
            "name: n\nwhere: >-\n  GitHub, Org/app, test.yml\n  and multi.yml\nprobe: dream\n";
        let mut w = watch("nightly", "OK");
        w.place = runner::place(yaml);
        assert_eq!(
            runner::place("where: one line\nprobe: x").trim(),
            "one line"
        );
        assert_eq!(runner::place("name: none"), "");

        let row = |name: &str, words: &[&str]| Schedule {
            name: name.into(),
            words: words.iter().map(|w| w.to_string()).collect(),
            ..Default::default()
        };
        assert!(about(&row("app / Multi", &["app", "multi.yml"]), &w));
        assert!(
            !about(&row("app / Perf", &["app", "perf.yml"]), &w),
            "another file"
        );
        assert!(
            !about(&row("x / Tests", &["x", "test.yml"]), &w),
            "another repo"
        );
        assert!(!about(&row("dream", &["dream"]), &w), "probe is not where");
        assert!(
            about(&row("nightly", &["nightly"]), &w),
            "the watch's own name"
        );
    }

    fn watch(name: &str, state: &str) -> Watch {
        Watch {
            name: name.into(),
            state: state.into(),
            severity: "urgent".into(),
            ..Default::default()
        }
    }

    fn red(slug: &str, what: &str, outcome: &str) -> Red {
        Red {
            slug: slug.into(),
            red: what.into(),
            outcome: outcome.into(),
            ..Default::default()
        }
    }

    #[test]
    fn an_open_red_names_the_triage_and_the_route_fills_after() {
        let w = watch("nightly", "TRIP");
        let routes =
            parse_routes("watch nightly\tagent\tnightly-fix\t#size/m nightly:app\nother\t-\t-\t\n");
        assert_eq!(routes.len(), 1, "a dash is no route");
        let held = HashMap::from([("nightly:app".to_string(), 2)]);
        let reds = [
            red("ar-1", "watch nightly", "no fix"),
            red("ar-2", "watch elsewhere", "still red"),
        ];
        let mut row = Schedule {
            kind: CI.into(),
            ..Default::default()
        };
        join(&mut row, &[&w], &routes, &reds, &held);
        assert_eq!(row.triage, "no fix ar-1");
        assert_eq!(row.open, ["ar-1 (no fix)"]);
        assert_eq!(
            row.after,
            [
                "Sentinel nightly (pages urgent, tripped)",
                "triage agent nightly-fix",
                "nightly:app releases 2 held items",
            ]
        );
        join(&mut row, &[&w], &routes, &[], &held);
        assert_eq!(
            row.triage, "agent nightly-fix",
            "no item: the route it would take"
        );
    }

    #[test]
    fn a_runner_and_a_unit_match_their_own_reds_and_routes() {
        let routes = parse_routes("runner dream\talert\t-\t\n");
        let mut row = Schedule {
            kind: AGENTCTL.into(),
            name: "dream".into(),
            unit: "agentctl@dream.service".into(),
            ..Default::default()
        };
        join(&mut row, &[], &routes, &[], &HashMap::new());
        assert_eq!(row.triage, "alert");
        let reds = [red("ar-3", "unit agentctl@dream.service", "fixing")];
        join(&mut row, &[], &routes, &reds, &HashMap::new());
        assert_eq!(row.triage, "fixing ar-3");
        let mut none = Schedule {
            kind: K8S.into(),
            ..Default::default()
        };
        join(&mut none, &[], &routes, &[], &HashMap::new());
        assert_eq!(none.triage, "-", "no watch and no route says so");
    }

    fn row(kind: &str, name: &str, streak: i32, purpose: &str) -> Schedule {
        Schedule {
            kind: kind.into(),
            name: name.into(),
            streak,
            purpose: purpose.into(),
            triage: "-".into(),
            ..Default::default()
        }
    }

    #[test]
    fn exceptions_lead_and_the_summary_counts_them() {
        let mut rows = vec![
            row(TIMER, "b", 3, "why"),
            row(K8S, "gap", 1, ""),
            row(CI, "a", 2, "why"),
            row(TIMER, "red", -6, "why"),
        ];
        rank(&mut rows);
        let names: Vec<&str> = rows.iter().map(|r| r.name.as_str()).collect();
        assert_eq!(names, ["red", "gap", "a", "b"]);
        assert_eq!(
            summary(&rows, Some(AT - 600), AT),
            "4 scheduled, 1 red, 1 no purpose, CI read 10m ago"
        );
        assert!(summary(&rows, None, AT).ends_with("CI not read"));
    }

    #[test]
    fn the_table_filters_by_kind_repo_and_state_and_sorts_the_longest_red_first() {
        let mut ci = row(CI, "app / Tests", -6, "why");
        ci.repo = "app".into();
        let rows = vec![
            ci,
            row(TIMER, "pulse", 3, ""),
            row(TIMER, "log", -1, "the words"),
        ];
        let names =
            |v: View| -> Vec<String> { v.apply(&rows).iter().map(|r| r.name.clone()).collect() };
        let view = |q: &str, s: &str| View::new::<Schedule>(q, s, "", "");
        assert_eq!(names(view("kind:timer", "")), ["pulse", "log"]);
        assert_eq!(names(view("repo:app", "")), ["app / Tests"]);
        assert_eq!(names(view("", "red")), ["app / Tests", "log"]);
        assert_eq!(names(view("", "no-purpose")), ["pulse"]);
        assert_eq!(
            names(view("words", "")),
            ["log"],
            "a word searches the purpose"
        );
        let by_streak = View::new::<Schedule>("", "", "streak", "desc");
        assert_eq!(names(by_streak), ["app / Tests", "log", "pulse"]);
    }

    #[test]
    fn status_says_how_it_stands_what_is_on_it_and_when_next() {
        let mut r = row(CI, "x", -6, "why");
        r.red_since = Some(AT - 5 * 86400);
        r.triage = "no fix ar-1".into();
        r.next = Some(AT + 12 * 3600);
        assert_eq!(
            status(&r, AT, PST),
            "red since 11-01, triage no fix ar-1, next 02:00"
        );
        let mut r = row(TIMER, "x", 2, "why");
        r.next = Some(AT + 3 * 86400);
        assert_eq!(status(&r, AT, PST), "green, next 11-09 14:00");
        assert_eq!(status(&row(K8S, "x", 0, ""), AT, PST), "no result yet");
    }

    #[test]
    fn the_streak_reads_as_its_colour_and_count() {
        assert_eq!(row(CI, "x", -6, "").streak_text(), "red 6");
        assert_eq!(row(CI, "x", 9, "").streak_text(), "green 9");
        assert_eq!(row(CI, "x", 0, "").streak_text(), "");
    }
}
