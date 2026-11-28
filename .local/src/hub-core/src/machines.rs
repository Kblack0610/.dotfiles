//! Every machine and every job kind, as the two tables both surfaces draw (Infra > Machines):
//! one row per machine with its readings, busy of its CI slots (each slot once), what they are
//! doing and what runs there; one row per job
//! kind with its queue, its slots and the machines that take it, and its last day. A slot can
//! take several kinds, so the kinds' slot counts overlap and never add up to the head. Built
//! once in `infra::prometheus` from the series it already read, so the hub TUI and agent-web
//! never join runners to machines themselves.
//!
//! A machine is one name. A runner can name it by its hostname where Prometheus
//! names it otherwise (`cachyos-x8664-main` is `workstation`); `Infra::aliases` joins the two.

use std::collections::{BTreeMap, BTreeSet, HashMap};

use serde::Serialize;

use crate::infra::{self, Infra};
use crate::links::{Kind, Link};
use crate::prom::Series;
use crate::reading::NO_DATA;
use crate::table::{Row, Val};
use crate::vocab::{pass_level, Level};

/// The job kind a machine's local Unity gates count under.
pub const LOCAL_POOL: &str = "gates";
/// Its name before 2026-11-18, still accepted by the pool page.
pub const LOCAL_POOL_OLD: &str = "unity-local";

/// Where a reading turns amber (red for the disk's last tenth): the one judgement both surfaces
/// draw, so a cell is the same hue in `hub` and in agent-web. A disk under `DISK_LOW` free is the
/// NodeDiskLow alert's line and under `DISK_CRIT` NodeDiskCritical's (home-config).
pub const CPU_HOT: f64 = 0.9;
pub const MEM_HIGH: f64 = 0.9;
pub const DISK_LOW: f64 = 0.2;
pub const DISK_CRIT: f64 = 0.1;
/// Load past this many times its cores.
pub const LOAD_PER_CORE: f64 = 1.5;

/// The hue of each judged cell of a machine row (`Machine::levels`). `Ok` is plain, `Neutral` a
/// reading nobody takes (muted), `Warn` amber and `Bad` red.
#[derive(Serialize, Default, Clone, Copy, Debug, PartialEq)]
pub struct Levels {
    pub cpu: Level,
    pub mem: Level,
    pub load: Level,
    pub temp: Level,
    pub disk: Level,
    pub booked: Level,
}

/// One machine: anything Prometheus has readings for, or a CI runner or gate names.
#[derive(Serialize, Default, Clone, Debug, PartialEq)]
pub struct Machine {
    pub host: String,
    /// `cloud` when any of its runners is, else `local`.
    #[serde(rename = "where")]
    pub place: String,
    /// `up` with readings, `NO_DATA` without; a cluster node that is not Ready, quarantined or
    /// cordoned says so instead (`jobpods::node_states`).
    pub state: String,
    /// Jobs running: its busy fixed slots (`ci::slots_by_host`) plus the job pods placed on it
    /// (`jobpods`). `slots`: its fixed slots, each once, running or idle. `off`: its runners on the Down list
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
    /// The CPU and memory every pod placed on it requests (job pods, the build-slot hold, other
    /// namespaces' pods) against its allocatable (`jobpods::booked`);
    /// None for a machine that is no CI node.
    pub booked: Option<crate::jobpods::Booked>,
    /// Each job running there by kind and repo (`ci::running_by_host`): `[unity] unity-core-playground x2`.
    pub running: Vec<String>,
    /// The oldest waiting job that fits it (`ci::next_by_host`).
    pub next: Option<crate::ci::Next>,
    /// What its cores and memory go to, one line per class (`workload::Use::line`); empty with
    /// no class reading.
    pub split: Vec<String>,
    /// When it last booted, unix seconds.
    pub boot: Option<f64>,
    /// The hue of each cell, judged once (`levels`, set by `build`).
    pub level: Levels,
}

impl Machine {
    /// The hue of each cell. Disk is red under `DISK_CRIT` free, amber under `DISK_LOW`; a cloud
    /// machine with no disk reading is amber, since the AWS hosts are never scraped and nothing
    /// alerts on their disks, and any other with none is muted.
    pub fn levels(&self) -> Levels {
        let over = |v: Option<f64>, line: f64| match v.is_some_and(|v| v > line) {
            true => Level::Warn,
            false => Level::Ok,
        };
        Levels {
            cpu: over(self.cpu, CPU_HOT),
            mem: match self.mem.is_some_and(|m| m >= MEM_HIGH) {
                true => Level::Warn,
                false => Level::Ok,
            },
            load: match (self.load, self.cores) {
                (Some(l), Some(c)) if l > c * LOAD_PER_CORE => Level::Warn,
                _ => Level::Ok,
            },
            temp: match self.temp.is_some_and(|t| t >= crate::host_now::HOT_C) {
                true => Level::Warn,
                false => Level::Ok,
            },
            disk: match self.disk {
                None if self.place == "cloud" => Level::Warn,
                None => Level::Neutral,
                Some(f) if f < DISK_CRIT => Level::Bad,
                Some(f) if f < DISK_LOW => Level::Warn,
                Some(_) => Level::Ok,
            },
            booked: match self.off > 0 || self.booked.is_some_and(|b| b.share() >= 1.0) {
                true => Level::Warn,
                false => Level::Ok,
            },
        }
    }

    /// It is a CI node, has a fixed slot, or runs a job.
    pub fn carries_ci(&self) -> bool {
        self.booked.is_some() || self.slots > 0 || !self.running.is_empty()
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

    /// `5.1/32 4.0G/92G`, what its job pods book of its CPU and memory, or `-` on no CI node.
    pub fn booked_cell(&self) -> String {
        self.booked.map_or("-".into(), |b| b.cell())
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
    /// Jobs it finished in the last hour and five hours (`cc:pool_done_1h`, `_5h`, by finish
    /// time): None before the exporter reports the window, 0 for a quiet one. Beside `done`.
    pub done_1h: Option<f64>,
    pub done_5h: Option<f64>,
    pub done: Option<f64>,
    /// Seconds a finished job of the kind usually runs: the exporter's 24h median over every
    /// workflow (`cc:pool_run_seconds_24h`). None for the local gates and before it reports.
    pub usual: Option<f64>,
    pub pass: Option<f64>,
    /// Its pass rate's hue (`vocab::pass_level`), set by `pools`.
    pub pass_level: Level,
    /// The machines with a runner that takes its cap, the most online slots first.
    pub machines: Vec<Seat>,
}

/// A machine that takes a kind, and how many of its slots for it are online (running or idle); 0
/// when every one is offline or missing.
#[derive(Serialize, Clone, Debug, PartialEq)]
pub struct Seat {
    pub host: String,
    pub slots: u32,
    /// Its machine page; the web gets it as its href.
    #[serde(rename = "href")]
    pub link: Link,
}

impl Pool {
    /// `deskslim-2 5, ms-a2 4, aws-spot-1 0`: where its slots are, each machine's online ones.
    fn machines_cell(&self) -> Val {
        let m: Vec<String> = self
            .machines
            .iter()
            .map(|s| format!("{} {}", s.host, s.slots))
            .collect();
        Val::word(&m.join(", "))
    }

    pub fn hosts(&self) -> impl Iterator<Item = &str> {
        self.machines.iter().map(|s| s.host.as_str())
    }
}

/// The machines table on both surfaces.
impl Row for Machine {
    const COLUMNS: &'static [&'static str] = &[
        "machine", "state", "booked", "cpu", "6h", "load", "mem", "temp", "disk", "running",
        "next", "up",
    ];
    const STATES: &'static [&'static str] = &["all", "busy", "idle", NO_DATA, "cloud"];
    const FACETS: &'static [&'static str] = &["state"];
    const HIDE_EMPTY: bool = true;
    const LEAD: &'static str = "machine";
    const GLANCE: &'static [&'static str] = &["booked", "cpu", "temp"];

    fn val(&self, col: &str) -> Val {
        match col {
            "machine" => Val::word(&self.host),
            "state" => Val::word(&self.state),
            "booked" => self.booked.map(|b| b.share()).into(),
            "cpu" => self.cpu.into(),
            "6h" => self.cpu6h.into(),
            "load" => self.load.into(),
            "mem" => self.mem.into(),
            "temp" => self.temp.into(),
            "disk" => self.disk.into(),
            "running" => Val::word(&self.running.join(", ")),
            "next" => self
                .next
                .as_ref()
                .map_or(Val::None, |n| Val::Text(n.line(crate::display::fmt::age))),
            "up" => self.boot.into(),
            _ => Val::None,
        }
    }
    fn in_state(&self, s: &str) -> bool {
        match s {
            "busy" => self.busy > 0,
            "idle" => (self.slots > 0 || self.booked.is_some()) && self.busy == 0,
            NO_DATA => self.state == NO_DATA,
            "cloud" => self.place == "cloud",
            // A node state (`NotReady`, `quarantined`, `cordoned`), alone or joined.
            _ => self.state.split(", ").any(|p| p == s),
        }
    }
    /// A bare word finds a machine by its name, what its slots do and its jobs.
    fn text(&self) -> String {
        let mut t = vec![self.host.clone(), self.place.clone(), self.state.clone()];
        t.extend(self.running.iter().cloned());
        if let Some(n) = &self.next {
            t.push(n.job.clone());
            t.push(n.repo.clone());
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
        "pool", "running", "waiting", "oldest", "done_1h", "done_5h", "done", "usual", "pass",
        "machines",
    ];
    const STATES: &'static [&'static str] = &["all", "waiting"];
    const FACETS: &'static [&'static str] = &[];
    const HIDE_EMPTY: bool = true;
    const LEAD: &'static str = "pool";
    const GLANCE: &'static [&'static str] = &["waiting", "oldest", "pass"];
    const LEGEND: &'static [(&'static str, &'static str)] = &[(
        "usual",
        "how long a finished job of the kind usually runs, the median over the last 24h",
    )];

    fn val(&self, col: &str) -> Val {
        match col {
            "pool" => Val::word(&self.pool),
            "running" => self.running.into(),
            "waiting" => self.waiting.into(),
            "oldest" => self.oldest.into(),
            "done_1h" => self.done_1h.into(),
            "done_5h" => self.done_5h.into(),
            "done" => self.done.into(),
            "usual" => self.usual.into(),
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
    let gone = crate::ci::gone_runners(infra);
    for s in infra.get("runners") {
        if gone.contains(s.label("name")) {
            continue;
        }
        let mm = at(&mut by, infra.runner_host(&alias, s));
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
    // Off is the Down list's count here, so a stale runner the Down list leaves out never reads
    // `+N off` on its machine.
    for s in &infra.down {
        at(&mut by, host(s)).off += 1;
    }
    for (h, (b, n)) in crate::ci::slots_by_host(infra) {
        let mm = at(&mut by, h);
        (mm.busy, mm.slots) = (b, n);
    }
    for (h, b) in crate::jobpods::booked(infra, &infra.pods) {
        at(&mut by, h).booked = Some(b);
    }
    for p in infra
        .pods
        .iter()
        .filter(|p| p.running && !p.reserved && !p.node.is_empty())
    {
        at(&mut by, p.node.clone()).busy += 1;
    }
    let node_state = crate::jobpods::node_states(infra);
    for (h, jobs) in crate::ci::running_by_host(infra) {
        at(&mut by, h).running = jobs;
    }
    for (h, n) in crate::ci::next_by_host(infra) {
        at(&mut by, h).next = Some(n);
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
            mm.state = match node_state.get(&h) {
                Some(n) => n.clone(),
                None if [mm.cpu, mm.load, mm.cores, mm.mem]
                    .iter()
                    .any(Option::is_some) =>
                {
                    "up".into()
                }
                None => NO_DATA.into(),
            };
            mm.level = mm.levels();
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
/// that run them; the longest queue first.
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
        *n += match s.label("state") {
            "running" => 1,
            "idle" => 1,
            _ => 0,
        };
    }
    let get = |rule: &str, k: &str| cc.get(&format!("{rule}/{k}")).copied();
    let mut out: Vec<Pool> = names
        .into_iter()
        .map(|p| Pool {
            running: get("cc:pool_busy", &p),
            waiting: get("cc:pool_waiting", &p),
            oldest: get("cc:pool_oldest_wait_seconds", &p),
            done_1h: get("cc:pool_done_1h", &p),
            done_5h: get("cc:pool_done_5h", &p),
            done: get("cc:pool_done_24h", &p),
            usual: get("cc:pool_run_seconds_24h", &p),
            pass: get("cc:pool_pass_ratio_24h", &p),
            pass_level: Level::Neutral,
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
    // The machines running local gates: the ledger's `cc:host_local_done_24h`, or a gate running now.
    let mut local: BTreeSet<String> = cc
        .keys()
        .filter_map(|k| k.strip_prefix("cc:host_local_done_24h/").map(String::from))
        .collect();
    local.extend(
        infra
            .get("gates")
            .iter()
            .map(|g| infra::host(alias, g.label("host"))),
    );
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
        // Running is the gates running now. No series counts a waiting gate, and a machine has
        // one seat: its slots.sh flock runs one gate at a time.
        out.push(Pool {
            pool: LOCAL_POOL.into(),
            running: Some(infra.get("gates").len() as f64),
            done: sum("cc:host_local_done_24h"),
            pass: (ran > 0.0).then(|| passed / ran),
            machines: seats(local.iter().map(|h| (h, 1))),
            ..Default::default()
        });
    }
    for p in &mut out {
        p.pass_level = pass_level(p.pass);
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

    /// The workstation as Prometheus names it and its runners by its hostname, a Pi with
    /// readings and no CI, and a laptop with a runner and no exporter.
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
                cc("cc:host_local_done_24h", "host", "workstation", "4"),
                cc("cc:host_local_pass_ratio_24h", "host", "workstation", "0.5"),
                cc("cc:host_cores", "host", "raspberrypi", "4"),
                cc("cc:host_cpu_busy_ratio", "host", "raspberrypi", "0.05"),
                cc("cc:pool_slots", "pool", "unity", "3"),
                cc("cc:pool_busy", "pool", "unity", "1"),
                cc("cc:pool_waiting", "pool", "unity", "2"),
                cc("cc:pool_oldest_wait_seconds", "pool", "unity", "900"),
                cc("cc:pool_run_seconds_24h", "pool", "unity", "420"),
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
                ("mac-mini", "mini-1", "idle", "macos", "home"),
            ],
        );
        i
    }

    fn machine<'a>(ms: &'a [Machine], h: &str) -> &'a Machine {
        ms.iter()
            .find(|m| m.host == h)
            .unwrap_or_else(|| panic!("no {h}"))
    }

    #[test]
    fn a_runner_by_hostname_joins_the_machine_prometheus_names() {
        let (ms, _) = build(&fleet());
        assert!(!ms.iter().any(|m| m.host == "cachyos-x8664-main"));
        let ws = machine(&ms, "workstation");
        assert_eq!(ws.place, "local");
        assert_eq!(ws.state, "up");
        // One running runner and one idle; a local gate is no slot.
        assert_eq!((ws.busy, ws.slots, ws.off), (1, 2, 0));
        assert_eq!(ws.running, ["[unity]"], "an idle slot says nothing");
        // A standing Forgejo seat is a slot of its own; its job says forgejo, the kind the
        // exporter gives a busy Forgejo seat.
        let mut f = fleet();
        let mut rows = f.get("runners").to_vec();
        rows.extend(series(vec![json!({"__name__": "github_runner_state",
            "host": "cachyos-x8664-main", "name": "ws-unity-2-forgejo", "state": "running",
            "site": "local", "forge": "forgejo", "v": "1"})]));
        f.instant.insert("runners", rows);
        f.instant.get_mut("job_kind").unwrap().extend(series(vec![json!({
            "__name__": "ci_runner_job", "runner": "ws-unity-2-forgejo", "kind": "forgejo", "v": "1"})]));
        let (ms, _) = build(&f);
        let ws = machine(&ms, "workstation");
        assert_eq!(ws.running, ["[forgejo]", "[unity]"]);
        assert_eq!((ws.busy, ws.slots), (2, 3));
        // The seat idle is a slot like any other, so busy/slots agrees and it runs nothing.
        let mut rows = f.get("runners").to_vec();
        rows.retain(|s| s.label("name") != "ws-unity-2-forgejo");
        rows.extend(series(vec![json!({"__name__": "github_runner_state",
            "host": "cachyos-x8664-main", "name": "ws-unity-2-forgejo", "state": "idle",
            "site": "local", "forge": "forgejo", "v": "1"})]));
        f.instant.insert("runners", rows);
        let (ms, _) = build(&f);
        let ws = machine(&ms, "workstation");
        assert_eq!(ws.running, ["[unity]"]);
        assert_eq!((ws.busy, ws.slots), (1, 3));
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
    fn a_cloud_runner_and_a_host_without_an_exporter_still_get_a_row() {
        let mut f = fleet();
        let mut rows = f.get("runners").to_vec();
        rows.extend(series(vec![json!({"__name__": "github_runner_state",
            "host": "aws-burst-1", "name": "burst-1", "state": "offline", "site": "cloud", "v": "1"})]));
        f.instant.insert("runners", rows);
        // An offline runner is on the Down list, its machine's off.
        f.down = series(vec![json!({"__name__": "github_runner_state",
            "host": "aws-burst-1", "name": "burst-1", "state": "offline", "v": "1"})]);
        let (ms, _) = build(&f);
        let burst = machine(&ms, "aws-burst-1");
        assert_eq!(
            (burst.place.as_str(), burst.state.as_str()),
            ("cloud", NO_DATA)
        );
        assert_eq!((burst.busy, burst.slots, burst.off), (0, 0, 1));
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
    fn a_gate_is_no_slot() {
        let mut i = fleet();
        let gate = json!({"__name__": "cc:host_local_gate", "host": "raspberrypi", "v": "5"});
        i.instant.insert("gates", series(vec![gate]));
        let (ms, pools) = build(&i);
        let pi = machine(&ms, "raspberrypi");
        assert_eq!((pi.busy, pi.slots), (0, 0));
        let local = pools.iter().find(|p| p.pool == LOCAL_POOL).unwrap();
        assert_eq!(local.running, Some(1.0));
    }

    #[test]
    fn the_machine_table_has_its_chips_facets_and_links() {
        let mut f = fleet();
        let mut rows = f.get("runners").to_vec();
        rows.extend(series(vec![json!({"__name__": "github_runner_state",
            "host": "aws-burst-1", "name": "burst-1", "state": "offline", "site": "cloud", "v": "1"})]));
        f.instant.insert("runners", rows);
        let (ms, _) = build(&f);
        let (rows, s) = View::new::<Machine>("", "", "", "").summary(&ms);
        assert_eq!(rows.len(), 4);
        let chip = |n: &str| s.states.iter().find(|c| c.name == n).map(|c| c.n);
        assert_eq!(chip("busy"), Some(1));
        assert_eq!(chip("idle"), Some(1));
        assert_eq!(chip(NO_DATA), Some(2));
        assert_eq!(chip("cloud"), Some(1));
        assert!(s.states.iter().all(|c| c.name != "governed"));
        let facet = |k: &str| -> Vec<String> {
            let f = s.facets.iter().find(|f| f.key == k).unwrap();
            f.values.iter().map(|v| v.value.clone()).collect()
        };
        assert_eq!(facet("state"), [NO_DATA, "up"]);
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
        let (found, _) = View::new::<Machine>("unity", "", "", "").summary(&ms);
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
    fn a_machine_row_judges_each_cell_once() {
        let calm = Machine {
            cpu: Some(0.5),
            mem: Some(0.5),
            load: Some(3.0),
            cores: Some(4.0),
            temp: Some(60.0),
            disk: Some(0.5),
            ..Machine::default()
        };
        assert_eq!(calm.levels(), Levels::default());
        let hot = Machine {
            cpu: Some(0.95),
            mem: Some(0.9),
            load: Some(6.1),
            temp: Some(85.0),
            disk: Some(0.15),
            off: 1,
            ..calm.clone()
        };
        let l = hot.levels();
        assert_eq!(
            [l.cpu, l.mem, l.load, l.temp, l.disk, l.booked],
            [Level::Warn; 6]
        );
        let full = Machine {
            disk: Some(0.09),
            ..calm.clone()
        };
        assert_eq!(full.levels().disk, Level::Bad);
        // No disk reading: amber for a cloud host nothing scrapes, muted for any other.
        let none = Machine {
            disk: None,
            ..calm.clone()
        };
        assert_eq!(none.levels().disk, Level::Neutral);
        let cloud = Machine {
            place: "cloud".into(),
            ..none
        };
        assert_eq!(cloud.levels().disk, Level::Warn);
    }

    #[test]
    fn a_built_row_carries_its_levels_and_a_pool_its_pass_hue() {
        let mut i = fleet();
        i.derive();
        assert!(i.machines.iter().all(|m| m.level == m.levels()));
        assert!(i.pools.iter().all(|p| p.pass_level == pass_level(p.pass)));
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
        let mut i = fleet();
        let gate = json!({"__name__": "cc:host_local_gate", "host": "workstation",
            "worktree": "unity-core-playground", "v": "60"});
        i.instant.insert("gates", series(vec![gate]));
        let (_, ps) = build(&i);
        let names: Vec<&str> = ps.iter().map(|p| p.pool.as_str()).collect();
        assert_eq!(names, ["unity", LOCAL_POOL, "macos"]);
        let seats = |p: &Pool| p.val("machines");
        assert_eq!(seats(&ps[0]), Val::word("workstation 2"));
        // The slots.sh flock runs one gate at a time: one seat, and no series counts a wait.
        let local = &ps[1];
        assert_eq!(seats(local), Val::word("workstation 1"));
        assert_eq!(
            (local.running, local.waiting, local.pass),
            (Some(1.0), None, Some(0.5))
        );
        // Only unity waits: the local gates read no waiting.
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
                cc("cc:pool_waiting", "light", "4"),
                cc("cc:pool_run_seconds_24h", "light", "240"),
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
        // Its slot count is no cell.
        assert_eq!(light.running, Some(3.0));
        // How long one usually runs is the exporter's median; a kind it has none for reads none.
        assert_eq!(
            (light.val("usual"), kind("heavy").usual),
            (Val::Num(240.0), None)
        );
        let heavy = kind("heavy");
        assert_eq!(
            heavy.val("running"),
            Val::Num(0.0),
            "slots busy with another kind's jobs are not its running"
        );
        assert_eq!(
            light.val("machines"),
            Val::word("b 5, a 3"),
            "online slots, most first"
        );
        assert_eq!(kind("macos").val("machines"), Val::word("mac-mini 1"));
        assert_eq!(kind("macos").running, Some(0.0));
        // A kind with no online runner names where its slots would be, and no count.
        let win = kind("windows");
        assert_eq!(
            (win.running, win.val("machines")),
            (None, Val::word("win 0"))
        );
        // Every machine with a runner for a kind, and none without one.
        assert!(!light.hosts().any(|h| h == "mac-mini"));
        assert_eq!(kind("macos").hosts().collect::<Vec<_>>(), ["mac-mini"]);
        assert_eq!(
            serde_json::to_value(&light.machines[0]).unwrap()["href"],
            "#infra/machines/b",
            "each machine opens its page"
        );
    }
}
