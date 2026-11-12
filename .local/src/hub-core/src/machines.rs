//! Every machine and every runner pool, as the two tables both surfaces draw (Infra > Machines):
//! one row per machine with its readings, its CI slots per pool, what runs there, and the
//! governor's verdict and power state for it; one row per pool with its slots and queue. Built
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
use crate::table::{Row, Val};

/// The pool a machine's local Unity gates count under, as `cc:site_slots` folds them into local.
pub const LOCAL_POOL: &str = "unity-local";

/// The governor's verdict on a host this cycle.
#[derive(Serialize, Default, Clone, Debug, PartialEq)]
pub struct Governor {
    /// It acts for real; a dry-run host is logged, never changed.
    pub live: bool,
    pub verdict: String,
    pub action: String,
    /// The slots it lets take jobs.
    pub admitted: Option<f64>,
}

impl Governor {
    /// `live, admit` or `dry run, withhold`.
    pub fn says(&self) -> String {
        let mode = if self.live { "live" } else { "dry run" };
        match self.action.as_str() {
            "" => mode.to_string(),
            a => format!("{mode}, {a}"),
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
    /// `up` with readings, `no reading` without, or the governor's power state when it is not
    /// running.
    pub state: String,
    /// CI slots as `cc:pool_slots` counts them: a running runner, or an idle one not withheld;
    /// local gate slots fold in. `off`: runners offline or missing.
    pub busy: u32,
    pub slots: u32,
    pub off: u32,
    pub cpu: Option<f64>,
    pub cpu6h: Option<f64>,
    pub load: Option<f64>,
    pub cores: Option<f64>,
    pub mem: Option<f64>,
    pub temp: Option<f64>,
    /// Free share of its fullest disk.
    pub disk: Option<f64>,
    /// Each core's busy share, in core order.
    pub core_busy: Vec<f64>,
    /// The cores each CI runner's job is using, the busiest first.
    pub runner_cores: Vec<(String, f64)>,
    /// Busy of slots per pool there: `unity 1/2`, `unity withheld 0/1`, `unity-local 1/1+1`.
    pub pools: Vec<String>,
    /// The pools alone, what the pool facet offers.
    pub pool_names: Vec<String>,
    /// The CI jobs and local gates running there: `Multi game#2210`.
    pub running: Vec<String>,
    /// When it last booted, unix seconds.
    pub boot: Option<f64>,
    pub governor: Option<Governor>,
    pub power: Option<Power>,
}

impl Machine {
    /// It has a CI slot or a pool to show.
    pub fn carries_ci(&self) -> bool {
        self.slots > 0 || !self.pools.is_empty()
    }

    /// `1/5`, or `-` with no slot.
    pub fn busy_cell(&self) -> String {
        if self.busy + self.slots == 0 {
            "-".into()
        } else {
            format!("{}/{}", self.busy, self.slots)
        }
    }
}

/// One runner pool, or the local Unity gates, with its slots and the last day of its queue.
#[derive(Serialize, Default, Clone, Debug, PartialEq)]
pub struct Pool {
    pub pool: String,
    pub slots: Option<f64>,
    pub busy: Option<f64>,
    pub withheld: Option<f64>,
    pub waiting: Option<f64>,
    /// Seconds the oldest waiting job has waited.
    pub oldest: Option<f64>,
    pub done: Option<f64>,
    pub pass: Option<f64>,
    /// The machines with a runner in it.
    pub machines: Vec<String>,
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
        "machine", "where", "state", "busy", "cpu", "6h", "load", "mem", "temp", "disk", "pools",
        "running", "governor", "power", "up",
    ];
    const STATES: &'static [&'static str] =
        &["all", "busy", "idle", "no reading", "cloud", "governed"];
    const FACETS: &'static [&'static str] = &["where", "state", "pools"];
    const HIDE_EMPTY: bool = true;
    const LEAD: &'static str = "machine";
    const GLANCE: &'static [&'static str] = &["busy", "cpu", "temp"];

    fn val(&self, col: &str) -> Val {
        match col {
            "machine" => text(&self.host),
            "where" => text(&self.place),
            "state" => text(&self.state),
            "busy" if self.busy + self.slots == 0 => Val::None,
            "busy" => Val::Num(self.busy as f64),
            "cpu" => self.cpu.into(),
            "6h" => self.cpu6h.into(),
            "load" => self.load.into(),
            "mem" => self.mem.into(),
            "temp" => self.temp.into(),
            "disk" => self.disk.into(),
            "pools" => text(&self.pools.join("  ")),
            "running" => text(&self.running.join(", ")),
            "governor" => self
                .governor
                .as_ref()
                .map_or(Val::None, |g| Val::Text(g.says())),
            "power" => self.power.as_ref().map_or(Val::None, |p| text(&p.state)),
            "up" => self.boot.into(),
            _ => Val::None,
        }
    }
    fn vals(&self, col: &str) -> Vec<Val> {
        match col {
            "pools" => self
                .pool_names
                .iter()
                .map(|p| Val::Text(p.clone()))
                .collect(),
            c => vec![self.val(c)],
        }
    }
    fn in_state(&self, s: &str) -> bool {
        match s {
            "busy" => self.busy > 0,
            "idle" => self.slots > 0 && self.busy == 0,
            "no reading" => self.state == "no reading",
            "cloud" => self.place == "cloud",
            "governed" => self.governor.is_some() || self.power.is_some(),
            _ => false,
        }
    }
    /// A bare word finds a machine by its name, pools, jobs and the governor's words.
    fn text(&self) -> String {
        let mut t = vec![self.host.clone(), self.place.clone(), self.state.clone()];
        t.extend(self.pools.iter().cloned());
        t.extend(self.running.iter().cloned());
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

/// The pools table on both surfaces, the longest queue first.
impl Row for Pool {
    const COLUMNS: &'static [&'static str] = &[
        "pool", "slots", "busy", "withheld", "waiting", "oldest", "done", "pass", "machines",
    ];
    const STATES: &'static [&'static str] = &["all", "waiting", "busy", "idle"];
    const FACETS: &'static [&'static str] = &["machines"];
    const HIDE_EMPTY: bool = true;
    const LEAD: &'static str = "pool";
    const GLANCE: &'static [&'static str] = &["waiting", "oldest", "pass"];

    fn val(&self, col: &str) -> Val {
        match col {
            "pool" => text(&self.pool),
            "slots" => self.slots.into(),
            "busy" => self.busy.into(),
            "withheld" => self.withheld.into(),
            "waiting" => self.waiting.into(),
            "oldest" => self.oldest.into(),
            "done" => self.done.into(),
            "pass" => self.pass.into(),
            "machines" => text(&self.machines.join(", ")),
            _ => Val::None,
        }
    }
    fn vals(&self, col: &str) -> Vec<Val> {
        match col {
            "machines" => self.machines.iter().map(|m| Val::Text(m.clone())).collect(),
            c => vec![self.val(c)],
        }
    }
    fn in_state(&self, s: &str) -> bool {
        let has = |v: Option<f64>| v.is_some_and(|x| x > 0.0);
        match s {
            "waiting" => has(self.waiting),
            "busy" => has(self.busy),
            "idle" => has(self.slots) && !has(self.busy),
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
            "live" => g.live = s.value == Some(1.0),
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
    // Pools in the order the pool table lists them, so a machine's pools read the same way.
    let pools = pools(infra, &cc, &alias);
    let rank = |p: &str| {
        pools
            .iter()
            .position(|x| x.pool == p)
            .unwrap_or(pools.len())
    };
    let held: BTreeSet<&str> = infra
        .get("withheld")
        .iter()
        .map(|s| s.label("name"))
        .collect();
    let mut per: BTreeMap<(String, usize, String), (u32, u32)> = BTreeMap::new();
    let mut names: BTreeMap<String, BTreeSet<(usize, String)>> = BTreeMap::new();
    let mut busy_cores: HashMap<&str, f64> = HashMap::new();
    for s in infra.get("runner_cores") {
        if s.label("__name__") == "cc:runner_cores_busy" {
            if let Some(v) = s.value {
                busy_cores.insert(s.label("runner"), v);
            }
        }
    }
    for s in infra.get("runners") {
        let h = host(s);
        let mm = at(&mut by, h.clone());
        if s.label("site") == "cloud" {
            mm.place = "cloud".into();
        }
        if let Some(v) = busy_cores.get(s.label("name")) {
            mm.runner_cores.push((s.label("name").into(), *v));
        }
        let state = s.label("state");
        if !matches!(state, "running" | "idle") {
            mm.off += 1;
            continue;
        }
        let is_held = held.contains(s.label("name"));
        let run = state == "running";
        if run || !is_held {
            mm.slots += 1;
        }
        if run {
            mm.busy += 1;
        }
        let pool = s.label("pool").to_string();
        let r = rank(&pool);
        names
            .entry(h.clone())
            .or_default()
            .insert((r, pool.clone()));
        let name = if is_held {
            format!("{pool} withheld")
        } else {
            pool
        };
        let e = per.entry((h, r, name)).or_default();
        e.1 += 1;
        if run {
            e.0 += 1;
        }
    }
    for ((h, _, pool), (b, n)) in per {
        at(&mut by, h).pools.push(format!("{pool} {b}/{n}"));
    }
    let local = keyed("cc:host_local_slots");
    let mut gates: BTreeMap<String, u32> = BTreeMap::new();
    for g in infra.get("gates") {
        *gates.entry(host(g)).or_default() += 1;
    }
    for (h, n) in gates {
        if !local.contains(&h) {
            let mm = at(&mut by, h.clone());
            mm.pools.push(format!("{n} gates"));
            names
                .entry(h)
                .or_default()
                .insert((rank(LOCAL_POOL), LOCAL_POOL.into()));
        }
    }
    for h in &local {
        let busy = get("cc:host_local_busy", h);
        let open = get("cc:host_local_open_slots", h);
        let room = (get("cc:host_local_slots", h).unwrap_or(0.0) - open.unwrap_or(0.0)).round();
        let n = |v: Option<f64>| v.map_or("?".into(), |x| format!("{x:.0}"));
        let mut cell = format!("{LOCAL_POOL} {}/{}", n(busy), n(open));
        if room > 0.0 {
            cell += &format!("+{room:.0}");
        }
        let mm = at(&mut by, h.clone());
        let (b, o) = (busy.unwrap_or(0.0) as u32, open.unwrap_or(0.0) as u32);
        mm.busy += b;
        mm.slots += o.max(b);
        mm.pools.push(cell);
        names
            .entry(h.clone())
            .or_default()
            .insert((rank(LOCAL_POOL), LOCAL_POOL.into()));
    }
    for (h, ns) in names {
        at(&mut by, h).pool_names = ns.into_iter().map(|(_, p)| p).collect();
    }
    for r in infra.ci.rows.iter().filter(|r| r.state == "busy") {
        let what = r.reference();
        at(&mut by, r.host.clone())
            .running
            .push(if what.is_empty() {
                r.job.clone()
            } else {
                format!("{} {what}", r.job)
            });
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
            mm.temp = get("cc:host_temp_c", &h);
            mm.disk = disk.get(&h).copied();
            mm.boot = boot.get(&h).copied();
            if let Some(mut c) = cores.remove(&h) {
                c.sort_by(|a, b| a.0.cmp(&b.0));
                mm.core_busy = c.into_iter().map(|(_, v)| v).collect();
            }
            mm.runner_cores.sort_by(|a, b| b.1.total_cmp(&a.1));
            mm.state = match mm.power.as_ref().map(|p| p.state.as_str()) {
                Some(s) if !s.is_empty() && s != "running" => s.to_string(),
                _ if [mm.cpu, mm.load, mm.cores, mm.mem]
                    .iter()
                    .any(Option::is_some) =>
                {
                    "up".into()
                }
                _ => "no reading".into(),
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
    let mut hosts: BTreeMap<&str, BTreeSet<String>> = BTreeMap::new();
    for s in infra.get("runners") {
        hosts
            .entry(s.label("pool"))
            .or_default()
            .insert(infra::host(alias, s.label("host")));
    }
    let get = |rule: &str, k: &str| cc.get(&format!("{rule}/{k}")).copied();
    let mut out: Vec<Pool> = names
        .into_iter()
        .map(|p| Pool {
            slots: get("cc:pool_slots", &p),
            busy: get("cc:pool_busy", &p),
            withheld: get("cc:pool_withheld", &p),
            waiting: get("cc:pool_waiting", &p),
            oldest: get("cc:pool_oldest_wait_seconds", &p),
            done: get("cc:pool_done_24h", &p),
            pass: get("cc:pool_pass_ratio_24h", &p),
            machines: hosts
                .get(p.as_str())
                .map(|h| h.iter().cloned().collect())
                .unwrap_or_default(),
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
            // As each machine counts it: a busy gate past the open slots is still a slot.
            slots: Some(
                local
                    .iter()
                    .map(|h| {
                        let open = get("cc:host_local_open_slots", h).unwrap_or(0.0);
                        open.max(get("cc:host_local_busy", h).unwrap_or(0.0))
                    })
                    .sum(),
            ),
            busy: sum("cc:host_local_busy"),
            waiting: sum("cc:host_local_queued"),
            done: sum("cc:host_local_done_24h"),
            pass: (ran > 0.0).then(|| passed / ran),
            machines: local,
            ..Default::default()
        });
    }
    out.sort_by(|a, b| {
        b.waiting
            .unwrap_or(0.0)
            .total_cmp(&a.waiting.unwrap_or(0.0))
            .then_with(|| a.pool.cmp(&b.pool))
    });
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::table::View;
    use serde_json::{json, Value};

    /// Prometheus `/api/v1/query` answers, as `infra::prometheus` reads them.
    fn series(rows: Vec<Value>) -> Vec<Series> {
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

    /// The workstation as Prometheus names it, its runner and governor by its hostname, a cloud
    /// burst host the governor stopped, a Pi with readings and no CI, and a laptop with a runner
    /// and no exporter.
    fn fleet() -> Infra {
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
        let runner = |host: &str, name: &str, state: &str, pool: &str, site: &str| {
            json!({"__name__": "github_runner_state", "host": host, "name": name, "state": state,
                "pool": pool, "site": site, "v": "1"})
        };
        i.instant.insert(
            "runners",
            series(vec![
                runner(
                    "cachyos-x8664-main",
                    "ws-unity-1",
                    "running",
                    "unity",
                    "home",
                ),
                runner("cachyos-x8664-main", "ws-unity-2", "idle", "unity", "home"),
                runner("aws-burst-1", "burst-1", "offline", "unity", "cloud"),
                runner("mac-mini", "mini-1", "idle", "macos", "home"),
            ]),
        );
        i.instant.insert(
            "withheld",
            series(vec![json!({"name": "ws-unity-2", "v": "1"})]),
        );
        i.instant.insert(
            "governor",
            series(vec![
                json!({"__name__": "ci_governor_live", "host": "cachyos-x8664-main", "v": "1"}),
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
            ws.pools,
            ["unity 1/1", "unity withheld 0/1", "unity-local 1/1+1"]
        );
        assert_eq!(ws.pool_names, ["unity", "unity-local"]);
        assert_eq!(ws.governor.as_ref().unwrap().says(), "live, withhold");
        // A host that names itself is no alias.
        assert_eq!(machine(&ms, "raspberrypi").state, "up");
    }

    #[test]
    fn a_stopped_cloud_host_and_one_without_an_exporter_still_get_a_row() {
        let (ms, _) = build(&fleet());
        let burst = machine(&ms, "aws-burst-1");
        assert_eq!(
            (burst.place.as_str(), burst.state.as_str()),
            ("cloud", "stopped")
        );
        assert_eq!((burst.busy, burst.slots, burst.off), (0, 0, 1));
        let p = burst.power.as_ref().unwrap();
        assert_eq!(
            (p.reason.as_str(), p.hours, p.max),
            ("idle", 2.0, Some(8.0))
        );
        assert_eq!(p.rule, "no job past the home hosts; starts at 3");
        let mini = machine(&ms, "mac-mini");
        assert_eq!(mini.state, "no reading");
        assert_eq!(mini.pools, ["macos 0/1"]);
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
        assert_eq!((local.slots, local.busy), (Some(2.0), Some(2.0)));
    }

    #[test]
    fn the_machine_table_has_its_chips_facets_and_links() {
        let (ms, _) = build(&fleet());
        let (rows, s) = View::new::<Machine>("", "", "", "").summary(&ms);
        assert_eq!(rows.len(), 4);
        let chip = |n: &str| s.states.iter().find(|c| c.name == n).map(|c| c.n);
        assert_eq!(chip("busy"), Some(1));
        assert_eq!(chip("idle"), Some(1));
        assert_eq!(chip("no reading"), Some(1));
        assert_eq!(chip("cloud"), Some(1));
        assert_eq!(chip("governed"), Some(2));
        let facet = |k: &str| -> Vec<String> {
            let f = s.facets.iter().find(|f| f.key == k).unwrap();
            f.values.iter().map(|v| v.value.clone()).collect()
        };
        assert_eq!(facet("where"), ["cloud", "local"]);
        assert!(facet("pools").contains(&"unity-local".to_string()));
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
    fn pools_list_the_longest_queue_first_with_the_local_gates_as_one() {
        let (_, ps) = build(&fleet());
        let names: Vec<&str> = ps.iter().map(|p| p.pool.as_str()).collect();
        assert_eq!(names, ["unity", "macos", "unity-local"]);
        assert_eq!(ps[0].machines, ["aws-burst-1", "workstation"]);
        let local = &ps[2];
        assert_eq!(
            (local.slots, local.busy, local.pass),
            (Some(1.0), Some(1.0), Some(0.5))
        );
        assert_eq!(local.machines, ["workstation"]);
        let (rows, s) = View::new::<Pool>("", "waiting", "", "").summary(&ps);
        assert_eq!(rows.len(), 1);
        assert_eq!(s.links[0]["pool"], "#infra/pools/unity");
    }
}
