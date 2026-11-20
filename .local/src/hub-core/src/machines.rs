//! Every machine and every job kind, as the two tables both surfaces draw (Infra > Machines):
//! one row per machine with its readings, busy of its CI slots (each slot once), what they are
//! doing, what runs there, and the governor's verdict and power state for it; one row per job
//! kind with its queue, its slots and the machines that take it, and its last day. A slot can
//! take several kinds, so the kinds' slot counts overlap and never add up to the head. Built
//! once in `infra::prometheus` from the series it already read, so the hub TUI and agent-web
//! never join runners to machines themselves.
//!
//! A machine is one name. A runner or the governor can name it by its hostname where Prometheus
//! names it otherwise (`cachyos-x8664-main` is `workstation`); `Infra::aliases` joins the two.

use std::collections::{BTreeMap, BTreeSet, HashMap};

use serde::Serialize;

use crate::infra::{self, Infra};
use crate::links::{Kind, Link};
use crate::prom::Series;
use crate::reading::NO_DATA;
use crate::table::{Row, Val};

/// The job kind a machine's local Unity gates count under.
pub const LOCAL_POOL: &str = "gates";
/// Its name before 2026-11-18, still accepted by the pool page.
pub const LOCAL_POOL_OLD: &str = "unity-local";

/// The governor's verdict on a host this cycle.
#[derive(Serialize, Default, Clone, Debug, PartialEq)]
pub struct Governor {
    pub verdict: String,
    pub action: String,
    /// The slots it lets take jobs.
    pub admitted: Option<f64>,
}

impl Governor {
    /// This cycle's action, `admit` or `withhold`, or `-` for none.
    pub fn says(&self) -> String {
        match self.action.as_str() {
            "" => "-".to_string(),
            a => a.to_string(),
        }
    }
}

/// A host the governor powers on and off (`ci_governor_power_*`): a cloud runner.
#[derive(Serialize, Default, Clone, Debug, PartialEq)]
pub struct Power {
    /// The governor's name for the host, which its buttons send (agent-web cloud.rs checks it).
    pub host: String,
    /// `running`, `starting`, `draining`, `stopping` or `stopped`.
    pub state: String,
    pub reason: String,
    /// Hours run today, of `max` a day.
    pub hours: f64,
    pub max: Option<f64>,
    pub usd_per_hour: Option<f64>,
    /// A button's hold, `on` or `off`, and when it lapses (unix seconds); empty for none.
    #[serde(rename = "override")]
    pub hold: String,
    pub until: Option<f64>,
    /// The last change and when.
    pub changed: String,
    pub changed_at: Option<f64>,
    /// Where its power rule stands, from the governor's own numbers.
    pub rule: String,
}

/// One machine: anything Prometheus has readings for, or a CI runner, gate or governor names.
#[derive(Serialize, Default, Clone, Debug, PartialEq)]
pub struct Machine {
    pub host: String,
    /// `cloud` when any of its runners is, else `local`.
    #[serde(rename = "where")]
    pub place: String,
    /// `up` with readings, `NO_DATA` without, or the governor's power state when it is not
    /// running.
    pub state: String,
    /// CI slots, each physical slot once (`ci::slots_by_host`): a running runner, or an idle
    /// one not withheld; local gate slots fold in. `off`: its runners on the Down list
    /// (`Infra::runners_down`, filled by `Infra::derive`).
    pub busy: u32,
    pub slots: u32,
    pub off: u32,
    pub cpu: Option<f64>,
    pub cpu6h: Option<f64>,
    pub load: Option<f64>,
    pub cores: Option<f64>,
    pub mem: Option<f64>,
    /// Memory used and its total, bytes (`cc:host_mem_{used,total}_bytes`).
    pub mem_used: Option<f64>,
    pub mem_total: Option<f64>,
    pub temp: Option<f64>,
    /// Free share of its fullest disk.
    pub disk: Option<f64>,
    /// That disk's free bytes and size (`cc:host_disk_{avail,size}_bytes`).
    pub disk_avail: Option<f64>,
    pub disk_size: Option<f64>,
    /// Each core's busy share, in core order.
    pub core_busy: Vec<f64>,
    /// The cores each CI runner's job is using, the busiest first.
    pub runner_cores: Vec<(String, f64)>,
    /// The memory each CI runner uses, bytes, by name (`cc:runner_mem_bytes`).
    pub runner_mem: Vec<(String, f64)>,
    /// Its capacity in slot units and the units taken: the governor's `ci_governor_{capacity,busy}_units`
    /// (`ci::host_units`). None for both when the governor has no row for it.
    pub units: Option<f64>,
    pub units_busy: Option<f64>,
    /// Each job running there by kind and repo (`ci::running_by_host`): `[unity] unity-core-playground x2`.
    pub running: Vec<String>,
    /// The oldest waiting job that fits it (`ci::next_by_host`).
    pub next: Option<crate::ci::Next>,
    /// What its cores and memory go to, one line per class (`workload::Use::line`); empty with
    /// no class reading.
    pub split: Vec<String>,
    /// When it last booted, unix seconds.
    pub boot: Option<f64>,
    pub governor: Option<Governor>,
    pub power: Option<Power>,
}

impl Machine {
    /// It has a CI slot, or a slot doing something.
    pub fn carries_ci(&self) -> bool {
        self.slots > 0 || !self.running.is_empty()
    }

    /// Memory used of its total and free disk, short: `33/123G 482G free`, `1.5T free`. A
    /// missing reading is no data, never 0.
    pub fn space(&self) -> String {
        let b = crate::host_now::bytes;
        let mem = match (self.mem_used, self.mem_total) {
            (Some(u), Some(t)) => {
                let (u, t) = (b(u), b(t));
                // `33/123G`: one unit when both share it.
                match u.strip_suffix(&t[t.len() - 1..]) {
                    Some(n) => format!("{n}/{t}"),
                    None => format!("{u}/{t}"),
                }
            }
            (Some(u), None) => b(u),
            _ => String::new(),
        };
        let disk = self.disk_avail.map(|f| format!("{} free", b(f)));
        match (mem.is_empty(), disk) {
            (true, None) => NO_DATA.into(),
            (true, Some(d)) => d,
            (false, None) => mem,
            (false, Some(d)) => format!("{mem} {d}"),
        }
    }

    /// `2.5/3`, the units taken of its capacity, or `-` with no governor row.
    pub fn taken_cell(&self) -> String {
        match self.units {
            None => "-".into(),
            Some(cap) => format!("{}/{cap:.0}", crate::ci::units_of(self.units_busy)),
        }
    }
}

/// One kind of job, or the local Unity gates: its jobs running now, the slots that could start
/// one now, and the last day of its queue.
#[derive(Serialize, Default, Clone, Debug, PartialEq)]
pub struct Pool {
    pub pool: String,
    /// Its jobs running now (`cc:pool_busy`, by the kind of job a runner runs).
    pub running: Option<f64>,
    pub waiting: Option<f64>,
    /// Seconds the oldest waiting job has waited.
    pub oldest: Option<f64>,
    pub done: Option<f64>,
    pub pass: Option<f64>,
    /// The share of a slot one of its jobs takes (`ci_governor_kind_weight`), as every surface
    /// prints it (`weight_text`); None for the local gates and while the governor has no series.
    pub weight: Option<String>,
    /// The machines with a runner that takes its cap, the most online slots first.
    pub machines: Vec<Seat>,
}

/// A machine that takes a kind, and how many of its slots for it are online (running or idle);
/// 0 when every one is offline or missing, as a stopped cloud host's are.
#[derive(Serialize, Clone, Debug, PartialEq)]
pub struct Seat {
    pub host: String,
    pub slots: u32,
    /// Its machine page; the web gets it as its href.
    #[serde(rename = "href")]
    pub link: Link,
}

/// `0.66`, or `1*` for a weight the governor has not measured. The one place the weight is
/// formatted: the TUI, agent-web and the waybar hover print `Pool::weight` as it is.
pub fn weight_text(weight: f64, measured: bool) -> String {
    let n = format!("{weight:.2}");
    let n = n.trim_end_matches('0').trim_end_matches('.');
    format!("{n}{}", if measured { "" } else { "*" })
}

impl Pool {
    /// `deskslim-2 5, ms-a2 4, aws-spot-1 0`: where its slots are, each machine's online ones.
    fn machines_cell(&self) -> Val {
        let m: Vec<String> = self
            .machines
            .iter()
            .map(|s| format!("{} {}", s.host, s.slots))
            .collect();
        text(&m.join(", "))
    }

    pub fn hosts(&self) -> impl Iterator<Item = &str> {
        self.machines.iter().map(|s| s.host.as_str())
    }
}

fn text(s: &str) -> Val {
    if s.is_empty() {
        Val::None
    } else {
        Val::Text(s.to_string())
    }
}

/// The machines table on both surfaces.
impl Row for Machine {
    const COLUMNS: &'static [&'static str] = &[
        "machine", "state", "taken", "cpu", "6h", "load", "mem", "temp", "disk", "running", "next",
        "governor", "power", "up",
    ];
    const STATES: &'static [&'static str] = &["all", "busy", "idle", NO_DATA, "cloud", "governed"];
    const FACETS: &'static [&'static str] = &["state"];
    const HIDE_EMPTY: bool = true;
    const LEAD: &'static str = "machine";
    const GLANCE: &'static [&'static str] = &["taken", "cpu", "temp"];

    fn val(&self, col: &str) -> Val {
        match col {
            "machine" => text(&self.host),
            "state" => text(&self.state),
            "taken" => self.units_busy.into(),
            "cpu" => self.cpu.into(),
            "6h" => self.cpu6h.into(),
            "load" => self.load.into(),
            "mem" => self.mem.into(),
            "temp" => self.temp.into(),
            "disk" => self.disk.into(),
            "running" => text(&self.running.join(", ")),
            "next" => self
                .next
                .as_ref()
                .map_or(Val::None, |n| Val::Text(n.line(crate::text::age))),
            "governor" => self
                .governor
                .as_ref()
                .map_or(Val::None, |g| Val::Text(g.says())),
            "power" => self.power.as_ref().map_or(Val::None, |p| text(&p.state)),
            "up" => self.boot.into(),
            _ => Val::None,
        }
    }
    fn in_state(&self, s: &str) -> bool {
        match s {
            "busy" => self.busy > 0,
            "idle" => self.slots > 0 && self.busy == 0,
            NO_DATA => self.state == NO_DATA,
            "cloud" => self.place == "cloud",
            "governed" => self.governor.is_some() || self.power.is_some(),
            _ => false,
        }
    }
    /// A bare word finds a machine by its name, what its slots do, jobs and the governor's words.
    fn text(&self) -> String {
        let mut t = vec![self.host.clone(), self.place.clone(), self.state.clone()];
        t.extend(self.running.iter().cloned());
        if let Some(n) = &self.next {
            t.push(n.job.clone());
            t.push(n.repo.clone());
        }
        if let Some(g) = &self.governor {
            t.extend([g.says(), g.verdict.clone()]);
        }
        if let Some(p) = &self.power {
            t.extend([p.state.clone(), p.rule.clone()]);
        }
        t.join("\n").to_lowercase()
    }
    fn link(&self, col: &str) -> Option<Link> {
        match col {
            "machine" => Some(Link::to(Kind::Machine, &self.host)),
            _ => None,
        }
    }
}

/// The job kinds table on both surfaces (section `pools`), the longest queue first: its jobs
/// running, queue and last day, and the machines that take it.
impl Row for Pool {
    const COLUMNS: &'static [&'static str] = &[
        "pool", "weight", "running", "waiting", "oldest", "done", "pass", "machines",
    ];
    const STATES: &'static [&'static str] = &["all", "waiting"];
    const FACETS: &'static [&'static str] = &[];
    const HIDE_EMPTY: bool = true;
    const LEAD: &'static str = "pool";
    const GLANCE: &'static [&'static str] = &["waiting", "oldest", "pass"];
    const LEGEND: &'static [(&'static str, &'static str)] = &[(
        "weight",
        "the share of a slot one job of the kind takes, the governor's hourly p90 measurement; 1* is not measured yet, counted as a whole slot",
    )];

    fn val(&self, col: &str) -> Val {
        match col {
            "pool" => text(&self.pool),
            "weight" => self.weight.as_deref().map_or(Val::None, text),
            "running" => self.running.into(),
            "waiting" => self.waiting.into(),
            "oldest" => self.oldest.into(),
            "done" => self.done.into(),
            "pass" => self.pass.into(),
            "machines" => self.machines_cell(),
            _ => Val::None,
        }
    }
    fn in_state(&self, s: &str) -> bool {
        match s {
            "waiting" => self.waiting.is_some_and(|x| x > 0.0),
            _ => false,
        }
    }
    fn link(&self, col: &str) -> Option<Link> {
        match col {
            "pool" => Some(Link::to(Kind::Pool, &self.pool)),
            _ => None,
        }
    }
}

/// Where the governor's power rule stands for a host, from its own numbers (governor.py
/// `decide()`).
fn rule(p: &Power, v: &HashMap<&str, f64>) -> String {
    let mins = |k: &str| (v.get(k).copied().unwrap_or(0.0) / 60.0).floor() as i64;
    let until = || {
        p.until
            .map_or("?".into(), |u| crate::capacity::clock(u as i64))
    };
    let want = v.get("want").copied().unwrap_or(0.0) as i64;
    let excess = v
        .get("start_min_excess")
        .map_or("?".into(), |x| format!("{x:.0}"));
    let max = p.max.unwrap_or(0.0);
    let capped = max > 0.0 && p.hours >= max;
    match p.hold.as_str() {
        "on" => return format!("held on by the button until {}", until()),
        "off" => return format!("held off by the button until {}", until()),
        _ => {}
    }
    match p.state.as_str() {
        "starting" => "booting: its slots count once their runners are online".into(),
        "stopping" => "stopping".into(),
        "draining" if capped => format!("{max:.0} h used today: stops once no slot is busy"),
        "draining" => "stops once no slot is busy".into(),
        "running" if v.get("idle_seconds").copied().unwrap_or(0.0) < 60.0 => "busy".into(),
        "running" => format!(
            "idle {} of {} min, then stops",
            mins("idle_seconds"),
            mins("idle_off_seconds")
        ),
        _ if capped => format!("{max:.0} h used today: no start until 00:00 UTC"),
        _ if v.get("held_seconds").copied().unwrap_or(0.0) > 0.0 => format!(
            "{want} jobs past the home hosts, held {} of {} min, then starts",
            mins("held_seconds"),
            mins("start_after_seconds")
        ),
        _ if want > 0 => format!(
            "{want} job{} past the home hosts, starts at {excess}",
            if want == 1 { "" } else { "s" }
        ),
        _ => format!("no job past the home hosts; starts at {excess}"),
    }
}

/// Each powered host from its `ci_governor_power_*` series.
fn power(infra: &Infra, alias: &HashMap<String, String>) -> BTreeMap<String, Power> {
    let mut vals: BTreeMap<String, (Power, HashMap<&str, f64>)> = BTreeMap::new();
    for s in infra.get("power") {
        let h = s.label("host");
        if h.is_empty() {
            continue;
        }
        let (p, v) = vals.entry(infra::host(alias, h)).or_default();
        p.host = h.into();
        let k = s.label("__name__").trim_start_matches("ci_governor_power_");
        match k {
            "state" if s.value == Some(1.0) => {
                p.state = s.label("state").into();
                p.reason = s.label("reason").into();
            }
            "state" => {}
            "override" => {
                p.hold = match s.label("action") {
                    "none" => String::new(),
                    a => a.into(),
                };
                p.until = s.value;
            }
            "last_change" => {
                p.changed = s.label("action").into();
                p.changed_at = s.value;
            }
            k => {
                if let Some(x) = s.value {
                    v.insert(k, x);
                }
            }
        }
    }
    vals.into_iter()
        .map(|(h, (mut p, v))| {
            p.hours = v.get("hours_today").copied().unwrap_or(0.0);
            p.max = v.get("max_hours_day").copied();
            p.usd_per_hour = v.get("usd_per_hour").copied();
            if p.reason == "none" {
                p.reason.clear();
            }
            p.rule = rule(&p, &v);
            (h, p)
        })
        .collect()
}

/// The governor's per-host verdict.
fn governor(infra: &Infra, alias: &HashMap<String, String>) -> BTreeMap<String, Governor> {
    let mut by: BTreeMap<String, Governor> = BTreeMap::new();
    for s in infra.get("governor") {
        let h = s.label("host");
        if h.is_empty() {
            continue;
        }
        let g = by.entry(infra::host(alias, h)).or_default();
        match s.label("__name__").trim_start_matches("ci_governor_") {
            "decision" => {
                g.verdict = s.label("verdict").into();
                g.action = s.label("action").into();
            }
            "admitted" => g.admitted = s.value,
            _ => {}
        }
    }
    by
}

/// The machine of that name, added when new.
fn at(by: &mut BTreeMap<String, Machine>, h: String) -> &mut Machine {
    by.entry(h.clone()).or_insert_with(|| Machine {
        host: h,
        place: "local".into(),
        ..Default::default()
    })
}

/// A per-core label (`3`, or `0,1` for a core and its thread) as numbers to sort by.
fn core_key(cpu: &str) -> Vec<u32> {
    cpu.split(',')
        .map(|c| c.trim().parse().unwrap_or(u32::MAX))
        .collect()
}

/// Every machine and every pool. Machines that carry CI first, then the busiest; pools the
/// longest queue first.
pub fn build(infra: &Infra) -> (Vec<Machine>, Vec<Pool>) {
    let alias = infra.aliases();
    let host = |s: &Series| infra::host(&alias, s.label("host"));
    let cc = infra.cc_values();
    let get = |rule: &str, h: &str| cc.get(&format!("{rule}/{h}")).copied();
    let keyed = |rule: &str| -> Vec<String> {
        let pre = format!("{rule}/");
        cc.keys()
            .filter_map(|k| k.strip_prefix(&pre).map(String::from))
            .collect()
    };
    let mut by: BTreeMap<String, Machine> = BTreeMap::new();
    for h in keyed("cc:host_cores") {
        at(&mut by, h);
    }
    let pools = pools(infra, &cc, &alias);
    let busy_cores = infra.runner_use("cc:runner_cores_busy");
    let mem = infra.runner_use("cc:runner_mem_bytes");
    for s in infra.get("runners") {
        let mm = at(&mut by, host(s));
        if s.label("site") == "cloud" {
            mm.place = "cloud".into();
        }
        if let Some(v) = busy_cores.get(s.label("name")) {
            mm.runner_cores.push((s.label("name").into(), *v));
        }
        if let Some(v) = mem.get(s.label("name")) {
            mm.runner_mem.push((s.label("name").into(), *v));
        }
    }
    // Off is the Down list's count here, so a held, lent, stopped-cloud or stale runner the
    // Down list leaves out never reads `+N off` on its machine.
    for s in &infra.down {
        at(&mut by, host(s)).off += 1;
    }
    for (h, (b, n)) in crate::ci::slots_by_host(infra) {
        let mm = at(&mut by, h);
        (mm.busy, mm.slots) = (b, n);
    }
    for (h, jobs) in crate::ci::running_by_host(infra) {
        at(&mut by, h).running = jobs;
    }
    for (h, n) in crate::ci::next_by_host(infra) {
        at(&mut by, h).next = Some(n);
    }
    // A host the governor reports but that has no machine row gets none made for it.
    for (h, (cap, used)) in crate::ci::host_units(infra) {
        if let Some(mm) = by.get_mut(&h) {
            (mm.units, mm.units_busy) = (Some(cap), Some(used));
        }
    }
    let mut cores: HashMap<String, Vec<(Vec<u32>, f64)>> = HashMap::new();
    for s in infra.get("cores") {
        cores
            .entry(host(s))
            .or_default()
            .push((core_key(s.label("cpu")), s.value.unwrap_or(0.0)));
    }
    let one = |q: &str| -> HashMap<String, f64> {
        infra
            .get(q)
            .iter()
            .filter_map(|s| Some((host(s), s.value?)))
            .collect()
    };
    let (disk, boot) = (one("disk"), one("boot"));
    for (h, g) in governor(infra, &alias) {
        at(&mut by, h).governor = Some(g);
    }
    for (h, p) in power(infra, &alias) {
        // Only a cloud host has a power state; a stopped one has no runner series to say so.
        let mm = at(&mut by, h);
        mm.place = "cloud".into();
        mm.power = Some(p);
    }
    let mut out: Vec<Machine> = by
        .into_values()
        .map(|mut mm| {
            let h = mm.host.clone();
            mm.cpu = get("cc:host_cpu_busy_ratio", &h);
            mm.cpu6h = get("cc:host_cpu_busy_ratio:avg6h", &h);
            mm.load = get("cc:host_load1", &h);
            mm.cores = get("cc:host_cores", &h);
            mm.mem = get("cc:host_mem_used_ratio", &h);
            mm.mem_used = get("cc:host_mem_used_bytes", &h);
            mm.mem_total = get("cc:host_mem_total_bytes", &h);
            mm.disk_avail = get("cc:host_disk_avail_bytes", &h);
            mm.disk_size = get("cc:host_disk_size_bytes", &h);
            mm.temp = get("cc:host_temp_c", &h);
            mm.disk = disk.get(&h).copied();
            mm.boot = boot.get(&h).copied();
            if let Some(mut c) = cores.remove(&h) {
                c.sort_by(|a, b| a.0.cmp(&b.0));
                mm.core_busy = c.into_iter().map(|(_, v)| v).collect();
            }
            mm.runner_cores.sort_by(|a, b| b.1.total_cmp(&a.1));
            mm.runner_mem.sort_by(|a, b| b.1.total_cmp(&a.1));
            mm.state = match mm.power.as_ref().map(|p| p.state.as_str()) {
                Some(s) if !s.is_empty() && s != "running" => s.to_string(),
                _ if [mm.cpu, mm.load, mm.cores, mm.mem]
                    .iter()
                    .any(Option::is_some) =>
                {
                    "up".into()
                }
                _ => NO_DATA.into(),
            };
            mm
        })
        .collect();
    out.sort_by(|a, b| {
        b.carries_ci()
            .cmp(&a.carries_ci())
            .then_with(|| b.cpu.unwrap_or(-1.0).total_cmp(&a.cpu.unwrap_or(-1.0)))
            .then_with(|| a.host.cmp(&b.host))
    });
    (out, pools)
}

/// Every pool a `cc:pool_*` series names, then the local gates as one pool over the machines
/// that publish them; the longest queue first.
fn pools(infra: &Infra, cc: &HashMap<String, f64>, alias: &HashMap<String, String>) -> Vec<Pool> {
    let mut names: BTreeSet<String> = BTreeSet::new();
    for rule in ["cc:pool_slots", "cc:pool_waiting", "cc:pool_done_24h"] {
        let pre = format!("{rule}/");
        names.extend(
            cc.keys()
                .filter_map(|k| k.strip_prefix(&pre).map(String::from)),
        );
    }
    let mut hosts: BTreeMap<&str, BTreeMap<String, u32>> = BTreeMap::new();
    for s in infra.get("runner_caps") {
        let n = hosts
            .entry(s.label("pool"))
            .or_default()
            .entry(infra::host(alias, s.label("host")))
            .or_default();
        *n += matches!(s.label("state"), "running" | "idle") as u32;
    }
    let get = |rule: &str, k: &str| cc.get(&format!("{rule}/{k}")).copied();
    let weights: HashMap<&str, (f64, bool)> = infra
        .get("kind_weight")
        .iter()
        .filter_map(|s| Some((s.label("kind"), (s.value?, s.label("measured") == "true"))))
        .collect();
    let mut out: Vec<Pool> = names
        .into_iter()
        .map(|p| Pool {
            weight: weights.get(p.as_str()).map(|&(w, m)| weight_text(w, m)),
            running: get("cc:pool_busy", &p),
            waiting: get("cc:pool_waiting", &p),
            oldest: get("cc:pool_oldest_wait_seconds", &p),
            done: get("cc:pool_done_24h", &p),
            pass: get("cc:pool_pass_ratio_24h", &p),
            machines: seats(
                hosts
                    .get(p.as_str())
                    .into_iter()
                    .flatten()
                    .map(|(h, n)| (h, *n)),
            ),
            pool: p,
        })
        .collect();
    let local: Vec<String> = cc
        .keys()
        .filter_map(|k| k.strip_prefix("cc:host_local_slots/").map(String::from))
        .collect::<BTreeSet<_>>()
        .into_iter()
        .collect();
    if !local.is_empty() {
        let sum = |rule: &str| -> Option<f64> {
            let v: Vec<f64> = local.iter().filter_map(|h| get(rule, h)).collect();
            (!v.is_empty()).then(|| v.iter().sum())
        };
        // The day's pass rate over every machine's runs, each weighed by how many it ran.
        let (mut passed, mut ran) = (0.0, 0.0);
        for h in &local {
            if let (Some(p), Some(d)) = (
                get("cc:host_local_pass_ratio_24h", h),
                get("cc:host_local_done_24h", h),
            ) {
                passed += p * d;
                ran += d;
            }
        }
        out.push(Pool {
            pool: LOCAL_POOL.into(),
            running: sum("cc:host_local_busy"),
            waiting: sum("cc:host_local_queued"),
            done: sum("cc:host_local_done_24h"),
            pass: (ran > 0.0).then(|| passed / ran),
            machines: seats(local.iter().map(|h| {
                let open = get("cc:host_local_open_slots", h).unwrap_or(0.0);
                (
                    h,
                    open.max(get("cc:host_local_busy", h).unwrap_or(0.0)) as u32,
                )
            })),
            ..Default::default()
        });
    }
    // `other` is the exporter's bucket for a job no kind's label names: a kind only while
    // something waits there, since its few finished jobs say nothing to act on.
    out.retain(|p| p.pool != "other" || p.waiting.is_some_and(|w| w > 0.0));
    out.sort_by(|a, b| {
        b.waiting
            .unwrap_or(0.0)
            .total_cmp(&a.waiting.unwrap_or(0.0))
            .then_with(|| a.pool.cmp(&b.pool))
    });
    out
}

/// Each machine's online slots for one kind, the most first, then by name.
fn seats<'a>(by_host: impl IntoIterator<Item = (&'a String, u32)>) -> Vec<Seat> {
    let mut out: Vec<Seat> = by_host
        .into_iter()
        .map(|(h, n)| Seat {
            host: h.clone(),
            slots: n,
            link: Link::to(Kind::Machine, h),
        })
        .collect();
    out.sort_by(|a, b| b.slots.cmp(&a.slots).then_with(|| a.host.cmp(&b.host)));
    out
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    use crate::table::View;
    use serde_json::{json, Value};

    /// `super::build` as `Infra::derive` calls it: after the CI board, whose rows say what runs.
    fn build(infra: &Infra) -> (Vec<Machine>, Vec<Pool>) {
        let mut i = infra.clone();
        i.ci = crate::ci::build(&i);
        super::build(&i)
    }

    /// Prometheus `/api/v1/query` answers, as `infra::prometheus` reads them.
    pub(crate) fn series(rows: Vec<Value>) -> Vec<Series> {
        let res: Vec<Value> = rows
            .into_iter()
            .map(|r| {
                let v = r["v"].as_str().unwrap_or("1").to_string();
                let mut m = r.clone();
                m.as_object_mut().unwrap().remove("v");
                json!({"metric": m, "value": [0, v]})
            })
            .collect();
        crate::prom::flatten(&json!({"status": "success", "data": {"result": res}})).unwrap()
    }

    /// Runners as the exporter writes them, `(host, name, state, caps, site)` with caps
    /// comma-separated: one `github_runner_state` row each, with no pool (a slot of several caps
    /// has none), one `github_runner_pool_slot` row per cap, and for a running one a
    /// `ci_runner_job` row: here its job is always of its first cap's kind. Replaces all three.
    fn runners(i: &mut Infra, rows: &[(&str, &str, &str, &str, &str)]) {
        let (mut state, mut slot, mut kind) = (vec![], vec![], vec![]);
        for (host, name, st, caps, site) in rows {
            let row = |metric: &str| {
                json!({"__name__": metric, "host": host, "name": name, "state": st,
                    "site": site, "v": "1"})
            };
            let caps: Vec<&str> = caps.split(',').collect();
            state.push(row("github_runner_state"));
            slot.extend(caps.iter().map(|c| {
                let mut r = row("github_runner_pool_slot");
                r["pool"] = json!(c);
                r
            }));
            if *st == "running" {
                kind.push(
                    json!({"__name__": "ci_runner_job", "runner": name, "kind": caps[0], "v": "1"}),
                );
            }
        }
        i.instant.insert("runners", series(state));
        i.instant.insert("runner_caps", series(slot));
        i.instant.insert("job_kind", series(kind));
    }

    /// The workstation as Prometheus names it, its runner and governor by its hostname, a cloud
    /// burst host the governor stopped, a Pi with readings and no CI, and a laptop with a runner
    /// and no exporter.
    pub(crate) fn fleet() -> Infra {
        let mut i = Infra {
            ok: true,
            ..Default::default()
        };
        let cc = |name: &str, k: &str, id: &str, v: &str| json!({"__name__": name, k: id, "v": v});
        i.instant.insert(
            "cc",
            series(vec![
                cc("cc:host_cores", "host", "workstation", "24"),
                cc("cc:host_cpu_busy_ratio", "host", "workstation", "0.62"),
                cc("cc:host_temp_c", "host", "workstation", "71"),
                cc("cc:host_local_slots", "host", "workstation", "2"),
                cc("cc:host_local_open_slots", "host", "workstation", "1"),
                cc("cc:host_local_busy", "host", "workstation", "1"),
                cc("cc:host_local_done_24h", "host", "workstation", "4"),
                cc("cc:host_local_pass_ratio_24h", "host", "workstation", "0.5"),
                cc("cc:host_cores", "host", "raspberrypi", "4"),
                cc("cc:host_cpu_busy_ratio", "host", "raspberrypi", "0.05"),
                cc("cc:pool_slots", "pool", "unity", "3"),
                cc("cc:pool_busy", "pool", "unity", "1"),
                cc("cc:pool_waiting", "pool", "unity", "2"),
                cc("cc:pool_oldest_wait_seconds", "pool", "unity", "900"),
                cc("cc:pool_slots", "pool", "macos", "1"),
                cc("cc:pool_waiting", "pool", "macos", "0"),
            ]),
        );
        i.instant.insert(
            "uname",
            series(vec![
                json!({"host": "workstation", "nodename": "cachyos-x8664-main"}),
                json!({"host": "raspberrypi", "nodename": "raspberrypi"}),
            ]),
        );
        runners(
            &mut i,
            &[
                (
                    "cachyos-x8664-main",
                    "ws-unity-1",
                    "running",
                    "unity",
                    "home",
                ),
                ("cachyos-x8664-main", "ws-unity-2", "idle", "unity", "home"),
                ("aws-burst-1", "burst-1", "offline", "unity", "cloud"),
                ("mac-mini", "mini-1", "idle", "macos", "home"),
            ],
        );
        i.instant.insert(
            "withheld",
            series(vec![json!({"name": "ws-unity-2", "v": "1"})]),
        );
        i.instant.insert(
            "governor",
            series(vec![
                json!({"__name__": "ci_governor_decision", "host": "cachyos-x8664-main",
                    "verdict": "hot", "action": "withhold", "v": "1"}),
            ]),
        );
        i.instant.insert(
            "power",
            series(vec![
                json!({"__name__": "ci_governor_power_state", "host": "aws-burst-1",
                    "state": "stopped", "reason": "idle", "v": "1"}),
                json!({"__name__": "ci_governor_power_state", "host": "aws-burst-1",
                    "state": "running", "reason": "none", "v": "0"}),
                json!({"__name__": "ci_governor_power_hours_today", "host": "aws-burst-1", "v": "2"}),
                json!({"__name__": "ci_governor_power_max_hours_day", "host": "aws-burst-1", "v": "8"}),
                json!({"__name__": "ci_governor_power_start_min_excess", "host": "aws-burst-1", "v": "3"}),
            ]),
        );
        i
    }

    fn machine<'a>(ms: &'a [Machine], h: &str) -> &'a Machine {
        ms.iter()
            .find(|m| m.host == h)
            .unwrap_or_else(|| panic!("no {h}"))
    }

    #[test]
    fn a_runner_and_the_governor_by_hostname_join_the_machine_prometheus_names() {
        let (ms, _) = build(&fleet());
        assert!(!ms.iter().any(|m| m.host == "cachyos-x8664-main"));
        let ws = machine(&ms, "workstation");
        assert_eq!(ws.place, "local");
        assert_eq!(ws.state, "up");
        // One running runner, one withheld idle one that is no slot, one local gate of one open.
        assert_eq!((ws.busy, ws.slots, ws.off), (2, 2, 0));
        assert_eq!(
            ws.running,
            ["[gates]", "[unity]"],
            "a held slot says nothing"
        );
        assert_eq!(ws.governor.as_ref().unwrap().says(), "withhold");
        // The same held slot, lent to its pair, says nothing either, and is no slot here.
        let mut f = fleet();
        f.instant.insert(
            "lent",
            series(vec![json!({"name": "ws-unity-2", "to": "tests", "v": "1"})]),
        );
        let (ms, _) = build(&f);
        let ws = machine(&ms, "workstation");
        assert_eq!(
            ws.running,
            ["[gates]", "[unity]"],
            "a lent slot says nothing"
        );
        assert_eq!((ws.busy, ws.slots), (2, 2));
        // Lent to a Forgejo seat that is up, the slot is that seat's: it says nothing here, and
        // the seat's job says forgejo, the kind the exporter gives a busy Forgejo seat.
        let mut f = fleet();
        f.instant.insert(
            "lent",
            series(vec![json!({"name": "ws-unity-2", "to": "forgejo",
                "seat": "ws-unity-2-forgejo", "v": "1"})]),
        );
        let mut rows = f.get("runners").to_vec();
        rows.extend(series(vec![json!({"__name__": "github_runner_state",
            "host": "cachyos-x8664-main", "name": "ws-unity-2-forgejo", "state": "running",
            "site": "local", "forge": "forgejo", "v": "1"})]));
        f.instant.insert("runners", rows);
        f.instant.get_mut("job_kind").unwrap().extend(series(vec![json!({
            "__name__": "ci_runner_job", "runner": "ws-unity-2-forgejo", "kind": "forgejo", "v": "1"})]));
        let (ms, _) = build(&f);
        let ws = machine(&ms, "workstation");
        assert_eq!(ws.running, ["[forgejo]", "[gates]", "[unity]"]);
        assert_eq!((ws.busy, ws.slots), (3, 3));
        // The seat idle is a slot like any other, so busy/slots agrees and it runs nothing.
        let mut rows = f.get("runners").to_vec();
        rows.retain(|s| s.label("name") != "ws-unity-2-forgejo");
        rows.extend(series(vec![json!({"__name__": "github_runner_state",
            "host": "cachyos-x8664-main", "name": "ws-unity-2-forgejo", "state": "idle",
            "site": "local", "forge": "forgejo", "v": "1"})]));
        f.instant.insert("runners", rows);
        let (ms, _) = build(&f);
        let ws = machine(&ms, "workstation");
        assert_eq!(ws.running, ["[gates]", "[unity]"]);
        assert_eq!((ws.busy, ws.slots), (2, 3));
        // A host that names itself is no alias.
        assert_eq!(machine(&ms, "raspberrypi").state, "up");
    }

    /// ar-3326: a runner with three caps is one slot of its machine, and what it does is the kind
    /// it runs, never once per cap.
    #[test]
    fn a_runner_with_three_caps_is_one_slot_of_its_machine() {
        let mut i = fleet();
        runners(
            &mut i,
            &[
                ("ms-a2", "ms-a2-heavy-1", "idle", "heavy,light", "local"),
                (
                    "ms-a2",
                    "ms-a2-unity-pool-1",
                    "running",
                    "unity,light,heavy",
                    "local",
                ),
                ("ms-a2", "ms-a2-light-1", "idle", "light", "local"),
            ],
        );
        let cc = |pool: &str, slots: &str, busy: &str| {
            [
                json!({"__name__": "cc:pool_slots", "pool": pool, "v": slots}),
                json!({"__name__": "cc:pool_busy", "pool": pool, "v": busy}),
            ]
        };
        i.instant.insert(
            "cc",
            series(
                [
                    cc("heavy", "2", "1"),
                    cc("light", "3", "1"),
                    cc("unity", "1", "1"),
                ]
                .concat(),
            ),
        );
        let (ms, pools) = build(&i);
        let m = machine(&ms, "ms-a2");
        assert_eq!((m.busy, m.slots), (1, 3));
        assert_eq!(m.running, ["[unity]"]);
        let kinds: Vec<&str> = pools.iter().map(|p| p.pool.as_str()).collect();
        assert_eq!(kinds, ["heavy", "light", "unity"]);
    }

    #[test]
    fn a_stopped_cloud_host_and_one_without_an_exporter_still_get_a_row() {
        let (ms, _) = build(&fleet());
        let burst = machine(&ms, "aws-burst-1");
        assert_eq!(
            (burst.place.as_str(), burst.state.as_str()),
            ("cloud", "stopped")
        );
        // Its runner is offline because the governor stopped the host: not down, so not off.
        assert_eq!((burst.busy, burst.slots, burst.off), (0, 0, 0));
        // A runner on the Down list is its machine's off.
        let mut f = fleet();
        f.down = series(vec![json!({"__name__": "github_runner_state",
            "host": "mac-mini", "name": "mini-2", "state": "offline", "v": "1"})]);
        assert_eq!(machine(&build(&f).0, "mac-mini").off, 1);
        let p = burst.power.as_ref().unwrap();
        assert_eq!(
            (p.reason.as_str(), p.hours, p.max),
            ("idle", 2.0, Some(8.0))
        );
        assert_eq!(p.rule, "no job past the home hosts; starts at 3");
        let mini = machine(&ms, "mac-mini");
        assert_eq!(mini.state, NO_DATA);
        assert!(mini.running.is_empty());
        // CI carriers first, the busiest of them first; the Pi last.
        let order: Vec<&str> = ms.iter().map(|m| m.host.as_str()).collect();
        assert_eq!(
            order,
            ["workstation", "mac-mini", "raspberrypi", "aws-burst-1"]
        );
    }

    #[test]
    fn a_powered_host_with_no_runner_is_cloud_and_a_busy_gate_past_the_open_slots_is_a_slot() {
        let mut i = fleet();
        let p = json!({"__name__": "ci_governor_power_state", "host": "aws-burst-2",
            "state": "stopped", "reason": "idle", "v": "1"});
        i.instant.get_mut("power").unwrap().extend(series(vec![p]));
        let cc = |name: &str, v: &str| json!({"__name__": name, "host": "raspberrypi", "v": v});
        i.instant.get_mut("cc").unwrap().extend(series(vec![
            cc("cc:host_local_slots", "1"),
            cc("cc:host_local_open_slots", "0"),
            cc("cc:host_local_busy", "1"),
        ]));
        let (ms, pools) = build(&i);
        let b2 = machine(&ms, "aws-burst-2");
        assert_eq!((b2.place.as_str(), b2.state.as_str()), ("cloud", "stopped"));
        let pi = machine(&ms, "raspberrypi");
        assert_eq!((pi.busy, pi.slots), (1, 1));
        let local = pools.iter().find(|p| p.pool == LOCAL_POOL).unwrap();
        assert_eq!(local.running, Some(2.0));
    }

    #[test]
    fn the_machine_table_has_its_chips_facets_and_links() {
        let (ms, _) = build(&fleet());
        let (rows, s) = View::new::<Machine>("", "", "", "").summary(&ms);
        assert_eq!(rows.len(), 4);
        let chip = |n: &str| s.states.iter().find(|c| c.name == n).map(|c| c.n);
        assert_eq!(chip("busy"), Some(1));
        assert_eq!(chip("idle"), Some(1));
        assert_eq!(chip(NO_DATA), Some(1));
        assert_eq!(chip("cloud"), Some(1));
        assert_eq!(chip("governed"), Some(2));
        let facet = |k: &str| -> Vec<String> {
            let f = s.facets.iter().find(|f| f.key == k).unwrap();
            f.values.iter().map(|v| v.value.clone()).collect()
        };
        assert_eq!(facet("state"), [NO_DATA, "stopped", "up"]);
        assert!(s
            .facets
            .iter()
            .all(|f| f.key != "where" && f.key != "pools"));
        assert_eq!(s.links[0]["machine"], "#infra/machines/workstation");
        let (cloud, _) = View::new::<Machine>("", "cloud", "", "").summary(&ms);
        assert_eq!(
            cloud.iter().map(|m| m.host.as_str()).collect::<Vec<_>>(),
            ["aws-burst-1"]
        );
        let (found, _) = View::new::<Machine>("withhold", "", "", "").summary(&ms);
        assert_eq!(found.len(), 1);
    }

    #[test]
    fn space_is_short_with_one_unit_when_both_share_it() {
        let g = 1024f64.powi(3);
        let m = |u: Option<f64>, t: Option<f64>, d: Option<f64>| Machine {
            mem_used: u,
            mem_total: t,
            disk_avail: d,
            ..Default::default()
        };
        assert_eq!(
            m(Some(12.0 * g), Some(60.0 * g), Some(1536.0 * g)).space(),
            "12/60G 1.5T free"
        );
        assert_eq!(m(None, None, Some(482.0 * g)).space(), "482G free");
        assert_eq!(m(None, None, None).space(), NO_DATA);
    }

    #[test]
    fn a_machine_search_finds_the_job_it_will_take_next() {
        let m = Machine {
            host: "razer".into(),
            next: Some(crate::ci::Next {
                job: "Checks (web)".into(),
                repo: "app".into(),
                n: 1,
                wait: 300,
            }),
            ..Machine::default()
        };
        assert!(m.text().contains("checks (web)"));
        assert!(m.text().contains("app"));
    }

    #[test]
    fn pools_list_the_longest_queue_first_with_the_local_gates_as_one() {
        let (_, ps) = build(&fleet());
        let names: Vec<&str> = ps.iter().map(|p| p.pool.as_str()).collect();
        assert_eq!(names, ["unity", LOCAL_POOL, "macos"]);
        let seats = |p: &Pool| p.val("machines");
        assert_eq!(seats(&ps[0]), text("workstation 2, aws-burst-1 0"));
        let local = &ps[1];
        assert_eq!(seats(local), text("workstation 1"));
        assert_eq!((local.running, local.pass), (Some(1.0), Some(0.5)));
        let (rows, s) = View::new::<Pool>("", "waiting", "", "").summary(&ps);
        assert_eq!(rows.len(), 1);
        assert_eq!(s.links[0]["pool"], "#infra/pools/unity");
    }

    #[test]
    fn a_kind_says_its_own_jobs_running_never_busy_of_its_caps() {
        let mut i = fleet();
        let cc = |name: &str, pool: &str, v: &str| json!({"__name__": name, "pool": pool, "v": v});
        i.instant.insert(
            "cc",
            series(vec![
                cc("cc:pool_slots", "light", "8"),
                cc("cc:pool_busy", "light", "3"),
                cc("cc:pool_withheld", "light", "1"),
                cc("cc:pool_lent", "light", "1"),
                cc("cc:pool_waiting", "light", "4"),
                // 9 slots carry heavy, 7 of them busy with unity jobs: no heavy job runs.
                cc("cc:pool_slots", "heavy", "9"),
                cc("cc:pool_busy", "heavy", "0"),
                cc("cc:pool_slots", "macos", "1"),
                cc("cc:pool_busy", "macos", "0"),
                cc("cc:pool_waiting", "macos", "0"),
                cc("cc:pool_waiting", "windows", "1"),
            ]),
        );
        let light: Vec<(&str, String, &str)> = [("a", 3), ("b", 5)]
            .into_iter()
            .flat_map(|(h, n)| {
                (0..n).map(move |k| {
                    (
                        h,
                        format!("{h}-{k}"),
                        if k == 0 { "running" } else { "idle" },
                    )
                })
            })
            .collect();
        let mut rows = vec![("mac-mini", "mini-1", "idle", "macos", "home")];
        rows.extend(
            light
                .iter()
                .map(|(h, name, st)| (*h, name.as_str(), *st, "light", "home")),
        );
        rows.push(("b", "b-light-old", "offline", "light", "home"));
        rows.push(("win", "win-1", "missing", "windows", "home"));
        runners(&mut i, &rows);
        let (_, ps) = build(&i);
        let kind = |k: &str| ps.iter().find(|p| p.pool == k).unwrap();
        let light = kind("light");
        // Its withheld and lent series are read by nothing, and its slot count is no cell.
        assert_eq!(light.running, Some(3.0));
        let heavy = kind("heavy");
        assert_eq!(
            heavy.val("running"),
            Val::Num(0.0),
            "slots busy with another kind's jobs are not its running"
        );
        assert_eq!(
            light.val("machines"),
            text("b 5, a 3"),
            "online slots, most first"
        );
        assert_eq!(kind("macos").val("machines"), text("mac-mini 1"));
        assert_eq!(kind("macos").running, Some(0.0));
        // A kind with no online runner names where its slots would be, and no count.
        let win = kind("windows");
        assert_eq!((win.running, win.val("machines")), (None, text("win 0")));
        // Every machine with a runner for a kind, and none without one.
        assert!(!light.hosts().any(|h| h == "mac-mini"));
        assert_eq!(kind("macos").hosts().collect::<Vec<_>>(), ["mac-mini"]);
        assert_eq!(
            serde_json::to_value(&light.machines[0]).unwrap()["href"],
            "#infra/machines/b",
            "each machine opens its page"
        );
    }

    #[test]
    fn a_kind_weighs_what_the_governor_measured_and_an_unmeasured_one_says_so() {
        let mut i = fleet();
        let cc = |name: &str, pool: &str, v: &str| json!({"__name__": name, "pool": pool, "v": v});
        i.instant.insert(
            "cc",
            series(vec![
                cc("cc:pool_waiting", "light", "0"),
                cc("cc:pool_waiting", "heavy", "0"),
                cc("cc:pool_waiting", "macos", "0"),
            ]),
        );
        let w = |kind: &str, measured: &str, v: &str| json!({"__name__": "ci_governor_kind_weight", "kind": kind, "measured": measured, "v": v});
        i.instant.insert(
            "kind_weight",
            series(vec![w("light", "true", "0.658"), w("heavy", "false", "1")]),
        );
        let (_, ps) = build(&i);
        let kind = |k: &str| ps.iter().find(|p| p.pool == k).unwrap();
        assert_eq!(kind("light").val("weight"), text("0.66"));
        assert_eq!(
            kind("heavy").val("weight"),
            text("1*"),
            "1 the governor did not measure"
        );
        assert_eq!(
            kind("macos").val("weight"),
            Val::None,
            "no series, no number"
        );
        assert_eq!(weight_text(0.5, true), "0.5");
        assert_eq!(weight_text(1.0, true), "1");
        assert_eq!(weight_text(0.283, true), "0.28");
    }
}
