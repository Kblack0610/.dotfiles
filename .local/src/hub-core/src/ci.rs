//! The CI runners board: every machine's slots, the job each is running and the jobs waiting,
//! each with the runners that can take it. Both surfaces draw this one answer (the TUI's Infra
//! `ci` section and agent-web's), and `fleet-bench` reads `pool_match` through `hub ci`, so
//! there is one copy of the label join. It judges from the runner-exporter series `infra`
//! already read and asks Prometheus for nothing.
//!
//! A job runs only on a runner holding all its labels, compared without case (GitHub does the
//! same). A queued job no online runner can take is `Queued::missing`, the labels none holds:
//! the board draws it red, so a label standing in for a place (2026-11-10: `lan`) shows at a
//! glance instead of as an hour of queue.

use std::collections::{BTreeMap, BTreeSet, HashMap, HashSet};

use serde::Serialize;

use crate::home::Level;
use crate::infra::Infra;
use crate::jobpods::{Booked, Pending};
use crate::links::{Kind, Link};
use crate::prom::Series;
use crate::table::{Row, Val};

/// A running job past this is amber whatever its usual: playground `ci.md` calls a gate that
/// runs past about an hour a bug to fix, not a wait.
const LONG_RUN_SECS: i64 = 3600;

/// Labels every runner and job carries, left out of NEEDS: they say where, not what.
const COMMON: &[&str] = &["self-hosted", "linux"];

/// Waiting groups the glance names under NEXT.
const NEXT: usize = 5;

/// One row of the machines table: a job running in a slot, or a run of slots in one state.
#[derive(Serialize, Default, Clone, Debug, PartialEq)]
pub struct Slot {
    pub host: String,
    /// `3`, or `2-5` for a run of slots in the same state.
    pub slot: String,
    /// The kind of job a busy slot runs, in the pool names `cc:pool_*` use (`ci_runner_job`'s
    /// kind); `gates` for a local gate; for a slot with no job its one cap, empty when it takes several.
    pub pool: String,
    /// `busy`, `idle`, `lent` (its pair is using its cores), `withheld` (the governor holds it
    /// back), `off` (offline or missing) or `standby` (its host is powered off by the governor).
    pub state: String,
    pub job: String,
    pub repo: String,
    pub pr: String,
    pub branch: String,
    /// Seconds the job has run.
    pub ran: Option<i64>,
    /// The workflow's usual job time over the last day (the exporter's median).
    pub usual: Option<i64>,
    /// Past its usual p90, or past `LONG_RUN_SECS`.
    pub late: bool,
    /// What the governor says of a standby host.
    pub note: String,
    /// Its runner is a CI job pod (an ARC runner), which `jobpods` counts on its node.
    #[serde(skip)]
    pub pod: bool,
}

/// A host that can take a job, and whether a slot is free there now.
#[derive(Serialize, Clone, Debug, PartialEq)]
pub struct Fit {
    pub host: String,
    /// `idle`, `busy`, `lent`, `withheld` or `standby` (`now_of`).
    pub state: String,
}

/// One group of waiting jobs: the same job of the same run.
#[derive(Serialize, Default, Clone, Debug, PartialEq)]
pub struct Queued {
    pub job: String,
    /// The pool the exporter files it under.
    pub pool: String,
    pub repo: String,
    pub pr: String,
    pub branch: String,
    pub n: u32,
    /// Seconds the oldest has waited.
    pub wait: i64,
    /// The labels it needs, less `COMMON`.
    pub needs: Vec<String>,
    /// Hosts with an online runner holding every label, free ones first. Empty: nobody can.
    pub can: Vec<Fit>,
    /// The labels no online runner holds, when nobody can take it.
    pub missing: Vec<String>,
    /// No online runner can take it: a label none of them holds, or no one runner holding all.
    pub stuck: bool,
    /// Where it starts first (`starts`' slot), else the first host that can take it.
    pub at: String,
    /// Seconds until a fitting slot frees: 0 with one idle, else the soonest busy one's usual
    /// time (the exporter median, `Slot::usual`) less what it has run. None: no fitting slot
    /// has a usual time, so nobody can say.
    pub starts: Option<i64>,
}

impl Queued {
    /// The red line for a job nobody can take.
    pub fn problem(&self) -> String {
        let what = if self.repo.is_empty() {
            self.job.clone()
        } else {
            format!("{} ({})", self.job, self.repo)
        };
        let has = if self.missing.is_empty() {
            "no one online runner holds all of them".to_string()
        } else {
            format!("no online runner holds {}", self.missing.join(", "))
        };
        format!("{what} needs [{}]: {has}", self.needs.join(", "))
    }
}

#[derive(Serialize, Default, Clone, Debug, PartialEq)]
pub struct Ci {
    pub hosts: u32,
    /// Each physical slot once (`slots_by_host`), summed over the machines.
    pub slots: u32,
    pub busy: u32,
    pub queued: u32,
    pub oldest: i64,
    pub rows: Vec<Slot>,
    pub queue: Vec<Queued>,
    /// The last day's local Unity gate failures, one row per branch and platform, newest first.
    pub local: Vec<LocalFail>,
    /// One red line per kind of job no online runner can take (`Queued::problem`), oldest first,
    /// with the count of waiting jobs when more than one. Both surfaces draw these as they are.
    pub red: Vec<String>,
    /// The view every CI surface opens on (`glance`), filled once the machines are built.
    pub glance: Glance,
    /// CI runs and local Unity gates that finished since local midnight: the Runners "CI runs
    /// finished today" tiles, counted here so the browser draws them and adds nothing.
    pub day: Day,
}

/// CI runs and local Unity gate runs finished since local midnight. A run that ended neither
/// passed, failed nor was cancelled (skipped, neutral) is in no field; `pass` is passed of
/// passed and failed (a cancel is neither), None with none of either.
#[derive(Serialize, Default, Clone, Debug, PartialEq)]
pub struct Day {
    /// Passed, failed and cancelled CI runs.
    pub runs: u32,
    pub pass: Option<f64>,
    pub failed_main: u32,
    pub failed_branch: u32,
    pub cancelled: u32,
    pub local: u32,
    pub local_pass: Option<f64>,
    /// Whether either hourly series answered; false reads "No hourly data yet".
    pub read: bool,
}

/// `Day` from the two hourly series (`github_runs_by_hour`, `fleet_local_gate_by_hour`), each
/// row's `hour` label the epoch second its hour began; only hours from `midnight` count.
pub fn day(infra: &Infra, midnight: i64) -> Day {
    let rows = |name: &str| -> Vec<(&Series, u32)> {
        infra
            .get(name)
            .iter()
            .filter(|s| s.label("hour").parse::<i64>().is_ok_and(|h| h >= midnight))
            .map(|s| (s, s.value.unwrap_or(0.0).max(0.0).round() as u32))
            .collect()
    };
    let (ci, local) = (rows("hourly"), rows("local_hourly"));
    let sum = |v: &[(&Series, u32)], keep: &dyn Fn(&Series) -> bool| {
        v.iter()
            .filter(|(s, _)| keep(s))
            .map(|(_, n)| n)
            .sum::<u32>()
    };
    let conc = |c: &'static str| move |s: &Series| s.label("conclusion") == c;
    let ok = sum(&ci, &conc("success"));
    let bad_of = |scope: Option<&str>| {
        sum(&ci, &|s| {
            matches!(s.label("conclusion"), "failure" | "timed_out")
                && scope.is_none_or(|sc| s.label("scope") == sc)
        })
    };
    let (bad, cancelled) = (bad_of(None), sum(&ci, &conc("cancelled")));
    let (lok, lbad) = (
        sum(&local, &|s| s.label("result") == "pass"),
        sum(&local, &|s| s.label("result") != "pass"),
    );
    let share = |ok: u32, bad: u32| (ok + bad > 0).then(|| f64::from(ok) / f64::from(ok + bad));
    Day {
        runs: ok + bad + cancelled,
        pass: share(ok, bad),
        failed_main: bad_of(Some("main")),
        failed_branch: bad_of(Some("branch")),
        cancelled,
        local: lok + lbad,
        local_pass: share(lok, lbad),
        read: !infra.get("hourly").is_empty() || !infra.get("local_hourly").is_empty(),
    }
}

/// One kind of CI job: unity, unity-build, light, heavy, forgejo, macos, gates (the local Unity
/// gates) or github-hosted, with its jobs running, its queue and its last day.
#[derive(Serialize, Default, Clone, Debug, PartialEq)]
pub struct JobKind {
    pub kind: String,
    pub running: Option<f64>,
    pub waiting: Option<f64>,
    /// Seconds the oldest waiting job has waited.
    pub oldest: Option<f64>,
    pub done: Option<f64>,
    pub pass: Option<f64>,
    /// The share of a slot one of its jobs takes, as text (`Pool::weight`).
    pub weight: Option<String>,
}

/// One CI machine: the CPU and memory its job pods book against allocatable, its real CPU use,
/// the jobs running on it by kind, the oldest waiting job that fits it, and its load.
#[derive(Serialize, Default, Clone, Debug, PartialEq)]
pub struct Host {
    pub host: String,
    /// Jobs running there (`Machine::busy`).
    pub busy: u32,
    /// What its job pods book (`Machine::booked`); None for a machine that is no CI node (an
    /// old Unity slot host until hc-954).
    pub booked: Option<Booked>,
    /// Its CPU busy share (`Machine::cpu`).
    pub cpu: Option<f64>,
    /// Each job running there by kind and repo (`Machine::running`).
    pub running: Vec<String>,
    /// The oldest waiting job that fits it (`Machine::next`).
    pub next: Option<Next>,
    /// 1-minute load per core (`Machine::load` over `cores`); the chip paints the row red past
    /// its hot ratio. None when either reading is missing.
    pub load: Option<f64>,
}

/// The oldest waiting job a machine can take (`next_by_host`): the same label join that says
/// where a queued job starts.
#[derive(Serialize, Default, Clone, Debug, PartialEq)]
pub struct Next {
    pub job: String,
    pub repo: String,
    /// Jobs waiting in the group, and the seconds its oldest has waited.
    pub n: u32,
    pub wait: i64,
}

impl Next {
    /// `Multi game (playground) 21m`: the job, its repo and how long it has waited.
    pub fn line(&self, dur: impl Fn(i64) -> String) -> String {
        let what = if self.repo.is_empty() {
            self.job.clone()
        } else {
            format!("{} ({})", self.job, self.repo)
        };
        format!("{what} {}", dur(self.wait))
    }
}

/// Runners down on one machine, by state.
#[derive(Serialize, Default, Clone, Debug, PartialEq)]
pub struct Down {
    pub host: String,
    pub state: String,
    pub n: u32,
}

/// A job running past `LONG_RUN_SECS`.
#[derive(Serialize, Default, Clone, Debug, PartialEq)]
pub struct Long {
    /// `ms-a2 Multi game#2210`.
    pub what: String,
    pub ran: i64,
}

/// A part of the ci domain's status (`cc:component_status{domain="ci"}`).
#[derive(Serialize, Clone, Debug, PartialEq)]
pub struct Part {
    pub name: String,
    pub level: Level,
}

/// What CI is doing at a glance, the same on the waybar hover (`hub ci --json`), the Infra
/// tab's CI head and agent-web's: the ci status, the jobs running, what they book of the CI
/// nodes, the queue and the pods waiting for room, the last day, one row per job kind and per CI
/// machine, the cloud hosts that are off, and the runners down.
#[derive(Serialize, Default, Clone, Debug, PartialEq)]
pub struct Glance {
    /// `cc:domain_status{domain="ci"}`: the whole domain, queue waits and pass rate too. The
    /// System health strip reads it; the CI card surfaces read `alert`.
    pub level: Level,
    /// The one CI alert: Red while a runner is down (`Infra::runners_down`) or a queued job has
    /// no online runner that can take it (`Ci::red`), Nodata with no runner read, else Ok. Queue
    /// depth, drain and pass rate are information, never this.
    pub alert: Level,
    /// Runners up (`Infra::runners_up`) of the roster: up plus the ones down.
    pub up: u32,
    pub expected: u32,
    pub parts: Vec<Part>,
    /// `Infra::feed`: why runner rows may be missing.
    pub feed: Option<String>,
    /// Jobs running now: the machine rows' `busy` summed.
    pub busy: u32,
    /// The first waiting groups (`Ci::queue`, oldest first), with where and about when each
    /// starts: the hover's NEXT.
    pub next: Vec<Queued>,
    /// Waiting jobs over every kind: the sum of the Job kinds rows, so the head and the table agree.
    pub queued: u32,
    pub oldest: Option<f64>,
    /// Jobs finished in the last day, and their pass share weighed by each kind's count.
    pub done: u32,
    pub pass: Option<f64>,
    pub kinds: Vec<JobKind>,
    /// Every CI node, and any other machine running a job, the most booked first.
    pub machines: Vec<Host>,
    /// Cloud hosts the governor holds off, or with nothing online: one line, not one row each.
    pub off: Vec<String>,
    pub down: Vec<Down>,
    pub long: Vec<Long>,
    /// The machine rows' bookings summed, so the total equals its rows; None with no CI node read.
    pub booked: Option<Booked>,
    /// Job pods no node has room for, by kind and size (`jobpods::pending`).
    pub pending: Vec<Pending>,
}

impl Glance {
    /// `waiting for room: arc-org-light x3 (1.69 cpu 1.2G each)`; None when every pod has a node.
    pub fn pending_line(&self) -> Option<String> {
        (!self.pending.is_empty()).then(|| {
            let p: Vec<String> = self.pending.iter().map(Pending::line).collect();
            format!("waiting for room: {}", p.join(", "))
        })
    }

    /// `12/12`: runners up of the roster, `-/-` with no runner read (never a zero standing in).
    pub fn up_line(&self) -> String {
        if self.expected == 0 {
            return "-/-".into();
        }
        format!("{}/{}", self.up, self.expected)
    }

    /// `4 running, 23 queued (oldest 21m), booked 18.2/144 cpu, 12/12 runners up, 759 done 24h,
    /// 91% passed`: jobs running and waiting, what the job pods book of every CI node's CPU,
    /// then runner liveness. A slot held back or lent is no count here, and a job it makes wait
    /// is in queued.
    pub fn head(&self, dur: impl Fn(i64) -> String) -> String {
        let mut s = format!("{} running, {} queued", self.busy, self.queued);
        if let Some(o) = self.oldest.filter(|_| self.queued > 0) {
            s += &format!(" (oldest {})", dur(o as i64));
        }
        if let Some(b) = self.booked {
            s += &format!(", booked {:.1}/{:.0} cpu", b.cpu, b.cpu_alloc);
        }
        s += &format!(", {} runners up", self.up_line());
        if self.done > 0 {
            s += &format!(", {} done 24h", self.done);
            if let Some(p) = self.pass {
                s += &format!(", {:.0}% passed", p * 100.0);
            }
        }
        s
    }

    /// `cloud: 4 hosts off`: the cloud hosts the governor holds off, one line in place of a
    /// row each (agent-web's `offLine` and the waybar chip say the same).
    pub fn off_line(&self) -> Option<String> {
        match self.off.len() {
            0 => None,
            1 => Some("cloud: 1 host off".into()),
            n => Some(format!("cloud: {n} hosts off")),
        }
    }
}

/// The glance, from the board `infra` has built (`Infra::derive`): its machines and pools.
pub fn glance(infra: &Infra) -> Glance {
    let v = infra.cc_values();
    let mut g = Glance {
        level: Level::of(v.get("cc:domain_status/ci").copied()),
        feed: infra.feed().map(String::from),
        ..Default::default()
    };
    for s in infra.get("cc") {
        if s.label("__name__") == "cc:component_status" && s.label("domain") == "ci" {
            g.parts.push(Part {
                name: s.label("component").into(),
                level: Level::of(s.value),
            });
        }
    }
    g.parts.sort_by(|a, b| a.name.cmp(&b.name));
    let (mut passed, mut ran) = (0.0, 0.0);
    for p in &infra.pools {
        g.queued += p.waiting.unwrap_or(0.0) as u32;
        if let Some(o) = p.oldest.filter(|_| p.waiting.unwrap_or(0.0) > 0.0) {
            g.oldest = Some(g.oldest.map_or(o, |x| x.max(o)));
        }
        let done = p.done.unwrap_or(0.0);
        g.done += done as u32;
        if let Some(r) = p.pass {
            passed += r * done;
            ran += done;
        }
        g.kinds.push(JobKind {
            kind: p.pool.clone(),
            running: p.running,
            waiting: p.waiting,
            oldest: p.oldest,
            done: p.done,
            pass: p.pass,
            weight: p.weight.clone(),
        });
    }
    g.pass = (ran > 0.0).then(|| passed / ran);
    g.pending = crate::jobpods::pending(&infra.pods);
    let alias = infra.aliases();
    let mut off: Vec<String> = infra
        .powered_off()
        .keys()
        .map(|h| crate::infra::host(&alias, h))
        .collect();
    // A host the governor reads as off but that still holds a slot is not off: show its row.
    off.retain(|h| !infra.machines.iter().any(|m| &m.host == h && m.slots > 0));
    off.sort();
    // A host whose every runner the governor holds back keeps its row: no slot, no queue of its
    // own, but still a CI machine, so it does not drop off the bar while held.
    let poff = infra.powered_off();
    let held: BTreeSet<String> = runners(infra)
        .into_iter()
        .filter(|r| matches!(now_of(r, &poff), "withheld" | "lent"))
        .map(|r| r.host)
        .collect();
    for m in &infra.machines {
        let idle = m.booked.is_none()
            && m.busy + m.slots == 0
            && m.running.is_empty()
            && !held.contains(&m.host);
        if idle || off.contains(&m.host) {
            continue;
        }
        g.busy += m.busy;
        if let Some(b) = &m.booked {
            g.booked.get_or_insert_with(Booked::default).add(b);
        }
        g.machines.push(Host {
            host: m.host.clone(),
            busy: m.busy,
            booked: m.booked,
            cpu: m.cpu,
            running: m.running.clone(),
            next: m.next.clone(),
            load: m
                .load
                .zip(m.cores)
                .filter(|(_, c)| *c > 0.0)
                .map(|(l, c)| l / c),
        });
    }
    let share = |h: &Host| h.booked.map_or(-1.0, |b| b.share());
    g.machines.sort_by(|a, b| {
        share(b)
            .total_cmp(&share(a))
            .then_with(|| b.busy.cmp(&a.busy))
            .then_with(|| a.host.cmp(&b.host))
    });
    g.off = off;
    g.next = infra.ci.queue.iter().take(NEXT).cloned().collect();
    let mut down: BTreeMap<(String, String), u32> = BTreeMap::new();
    for s in &infra.down {
        *down
            .entry((
                crate::infra::host(&alias, s.label("host")),
                s.label("state").into(),
            ))
            .or_default() += 1;
    }
    g.down = down
        .into_iter()
        .map(|((host, state), n)| Down { host, state, n })
        .collect();
    g.up = infra.runners_up();
    g.expected = g.up + infra.down.len() as u32;
    g.alert = if !infra.down.is_empty() || !infra.ci.red.is_empty() {
        Level::Red
    } else if g.expected == 0 {
        Level::Nodata
    } else {
        Level::Ok
    };
    let mut long: Vec<Long> = infra
        .ci
        .rows
        .iter()
        .filter(|r| r.state == "busy" && r.ran.is_some_and(|t| t > LONG_RUN_SECS))
        .map(|r| Long {
            what: [r.host.as_str(), r.job.as_str(), &r.reference()]
                .into_iter()
                .filter(|x| !x.is_empty())
                .collect::<Vec<_>>()
                .join(" "),
            ran: r.ran.unwrap_or(0),
        })
        .collect();
    long.sort_by_key(|a| std::cmp::Reverse(a.ran));
    g.long = long;
    g
}

/// Each machine's busy and slots, each physical slot once: a running runner, or an idle one not
/// withheld. A local gate is no runner, so it is no slot: the governor's local seats count it.
/// An ARC runner is its job pod, no slot: `jobpods` counts it on its node.
pub fn slots_by_host(infra: &Infra) -> BTreeMap<String, (u32, u32)> {
    let off = infra.powered_off();
    let mut by: BTreeMap<String, (u32, u32)> = BTreeMap::new();
    for r in runners(infra) {
        if infra.pod(r.s.label("name")).is_some() {
            continue;
        }
        let e = by.entry(r.host.clone()).or_default();
        match now_of(&r, &off) {
            "busy" => *e = (e.0 + 1, e.1 + 1),
            "idle" => e.1 += 1,
            _ => {}
        }
    }
    by
}

/// Each machine's local seats: the governor's `ci_governor_capacity_units{host}`, which the
/// Local Unity kind's MACHINES reads until the seats leave the governor (hc-858). The CI board's
/// machine rows read the cluster (`jobpods`), never these units.
pub(crate) fn seat_units(infra: &Infra) -> HashMap<String, f64> {
    let alias = infra.aliases();
    let mut by: HashMap<String, f64> = HashMap::new();
    for s in infra.get("governor") {
        if s.label("__name__") == "ci_governor_capacity_units" {
            *by.entry(crate::infra::host(&alias, s.label("host")))
                .or_default() += s.value.unwrap_or(0.0);
        }
    }
    by
}

/// The jobs running on each machine, each by kind and repo, the most of a kind first:
/// `[arc-org-light] x3, [unity] unity-core-playground`. A job pod is its scale set
/// (`jobpods::running_by_node`); a running fixed slot says the kind of job it runs (`Slot::pool`),
/// `job` when that is not known; a local gate is `[gates]`. Only running jobs: a slot held back,
/// lent or idle says nothing, and the runners table keeps each slot's state.
pub fn running_by_host(infra: &Infra) -> BTreeMap<String, Vec<String>> {
    let mut by = crate::jobpods::running_by_node(&infra.pods);
    for r in infra.ci.rows.iter().filter(|r| r.state == "busy" && !r.pod) {
        let kind = if r.pool.is_empty() { "job" } else { &r.pool };
        let what = if r.repo.is_empty() {
            format!("[{kind}]")
        } else {
            format!("[{kind}] {}", r.repo)
        };
        *by.entry(r.host.clone())
            .or_default()
            .entry(what)
            .or_default() += 1;
    }
    by.into_iter()
        .map(|(h, jobs)| {
            let mut jobs: Vec<(String, u32)> = jobs.into_iter().collect();
            jobs.sort_by(|a, b| b.1.cmp(&a.1).then_with(|| a.0.cmp(&b.0)));
            (
                h,
                jobs.into_iter()
                    .map(|(w, n)| if n > 1 { format!("{w} x{n}") } else { w })
                    .collect(),
            )
        })
        .collect()
}

/// The oldest waiting job each machine can take: the queue (oldest first) joined to the hosts
/// its labels fit (`Queued::can`, `fits`), the same subset rule GitHub uses to hand a job to a
/// runner. A job no runner can take (`stuck`) fits nowhere and is on no machine's row.
pub fn next_by_host(infra: &Infra) -> BTreeMap<String, Next> {
    let mut by: BTreeMap<String, Next> = BTreeMap::new();
    for q in &infra.ci.queue {
        for f in &q.can {
            by.entry(f.host.clone()).or_insert_with(|| Next {
                job: q.job.clone(),
                repo: q.repo.clone(),
                n: q.n,
                wait: q.wait,
            });
        }
    }
    by
}

impl Ci {
    fn red_lines(&self) -> Vec<String> {
        let mut by: Vec<(String, u32)> = vec![];
        for q in self.problems() {
            let line = q.problem();
            match by.iter_mut().find(|(l, _)| *l == line) {
                Some(e) => e.1 += q.n,
                None => by.push((line, q.n)),
            }
        }
        by.into_iter()
            .map(|(l, n)| if n > 1 { format!("{l} ({n} jobs)") } else { l })
            .collect()
    }

    /// The jobs no online runner can take, oldest first.
    pub fn problems(&self) -> Vec<&Queued> {
        let mut p: Vec<&Queued> = self.queue.iter().filter(|q| q.stuck).collect();
        p.sort_by_key(|q| std::cmp::Reverse(q.wait));
        p
    }
}

/// A runner as the exporter reports it, one per name.
struct Runner<'a> {
    s: &'a Series,
    /// Its machine's one name (`Infra::aliases`): the runner label can be the node's hostname.
    host: String,
    labels: Vec<String>,
    held: bool,
    /// Held because its pair is using its cores: to `tests` or `build` (`Infra::lent`).
    lent: Option<&'a str>,
    /// The kind of job it runs while busy (`Infra::job_kinds`). Its runner row has no pool: an
    /// agnostic slot takes every kind, so only `ci_runner_job` says which one it runs.
    kind: Option<&'a str>,
}

fn lower(csv: &str) -> Vec<String> {
    csv.split(',')
        .map(|l| l.trim().to_lowercase())
        .filter(|l| !l.is_empty())
        .collect()
}

fn holds(have: &[String], need: &[String]) -> bool {
    need.iter().all(|x| have.contains(x))
}

/// One row per runner name, a running one winning when two exporter pods disagree during a
/// rollout.
fn runners(infra: &Infra) -> Vec<Runner<'_>> {
    let alias = infra.aliases();
    let held: HashSet<&str> = infra
        .get("withheld")
        .iter()
        .map(|s| s.label("name"))
        .collect();
    let lent = infra.lent();
    let kinds = infra.job_kinds();
    let mut by: BTreeMap<&str, &Series> = BTreeMap::new();
    for s in infra.get("runners") {
        let e = by.entry(s.label("name")).or_insert(s);
        if s.label("state") == "running" && e.label("state") != "running" {
            *e = s;
        }
    }
    by.into_iter()
        .map(|(n, s)| Runner {
            s,
            host: infra.runner_host(&alias, s),
            labels: lower(s.label("labels")),
            held: held.contains(n),
            lent: lent.get(n).copied(),
            kind: kinds.get(n).copied(),
        })
        .collect()
}

/// A runner's state now, as every CI table says it: `busy`, `lent`, `withheld`, `idle`,
/// `standby` (its host powered off by the governor) or `off`; an offline runner is down
/// (`Infra::runners_down`).
fn now_of(r: &Runner, off: &HashMap<&str, &str>) -> &'static str {
    match r.s.label("state") {
        "running" => "busy",
        "idle" if r.held && r.lent.is_some() => "lent",
        "idle" if r.held => "withheld",
        "idle" => "idle",
        _ if off.contains_key(r.s.label("host")) => "standby",
        _ => "off",
    }
}

/// One runner on its machine now, once per name: what a machine page's slots list.
#[derive(Serialize, Default, Clone, Debug, PartialEq)]
pub struct RunnerNow {
    pub name: String,
    /// Its machine's one name (`Infra::aliases`).
    pub host: String,
    /// As `now_of` says it.
    pub state: String,
    /// The job it runs (`repo / job`), `-> tests` for one lent to its pair, else empty.
    pub job: String,
}

/// Every runner now, by name.
pub fn runners_now(infra: &Infra) -> Vec<RunnerNow> {
    let off = infra.powered_off();
    runners(infra)
        .iter()
        .map(|r| {
            let state = now_of(r, &off);
            let job = match (state, r.lent) {
                ("busy", _) => match r.s.label("repo") {
                    "" => job_name(r.s),
                    repo => format!("{repo} / {}", job_name(r.s)),
                },
                ("lent", Some(to)) => format!("-> {to}"),
                _ => String::new(),
            };
            RunnerNow {
                name: r.s.label("name").into(),
                host: r.host.clone(),
                state: state.into(),
                job,
            }
        })
        .collect()
}

/// A runner's slot number: the digits after its last `-` or `/`, else its name less the host.
fn slot_of(name: &str, host: &str) -> String {
    let tail = name.rsplit(['-', '/']).next().unwrap_or(name);
    if !tail.is_empty() && tail.chars().all(|c| c.is_ascii_digit()) {
        tail.to_string()
    } else {
        name.strip_prefix(host)
            .map(|s| s.trim_start_matches('-'))
            .filter(|s| !s.is_empty())
            .unwrap_or(name)
            .to_string()
    }
}

/// Slot numbers as ranges: `1,3-5`. A name that is no number is listed as it is.
fn ranges(mut slots: Vec<String>) -> String {
    slots.sort_by_key(|s| (s.parse::<u32>().unwrap_or(u32::MAX), s.clone()));
    let mut out: Vec<String> = vec![];
    let mut run: Option<(u32, u32)> = None;
    let flush = |run: &mut Option<(u32, u32)>, out: &mut Vec<String>| {
        if let Some((a, b)) = run.take() {
            out.push(if a == b {
                a.to_string()
            } else {
                format!("{a}-{b}")
            });
        }
    };
    for s in slots {
        match (s.parse::<u32>(), run) {
            (Ok(n), Some((a, b))) if n == b + 1 => run = Some((a, n)),
            (Ok(n), _) => {
                flush(&mut run, &mut out);
                run = Some((n, n));
            }
            (Err(_), _) => {
                flush(&mut run, &mut out);
                out.push(s);
            }
        }
    }
    flush(&mut run, &mut out);
    out.join(",")
}

/// The usual job time per (pool, workflow) from the exporter's day of finished jobs, as
/// (median, p90).
fn usual(infra: &Infra) -> HashMap<(String, String), (i64, Option<i64>)> {
    let mut by: HashMap<(String, String), (Option<i64>, Option<i64>)> = HashMap::new();
    for s in infra.get("job_usual") {
        let Some(v) = s.value.map(|v| v as i64) else {
            continue;
        };
        let e = by
            .entry((s.label("pool").into(), s.label("workflow").into()))
            .or_default();
        match s.label("quantile") {
            "0.5" => e.0 = Some(v),
            "0.9" => e.1 = Some(v),
            _ => {}
        }
    }
    by.into_iter()
        .filter_map(|(k, (m, p))| Some((k, (m?, p))))
        .collect()
}

/// A busy runner's usual job time: its job's kind and workflow in `usual`, none while the kind is
/// not known.
fn usual_of(
    usual: &HashMap<(String, String), (i64, Option<i64>)>,
    r: &Runner,
) -> Option<(i64, Option<i64>)> {
    usual
        .get(&(r.kind?.into(), r.s.label("workflow").into()))
        .copied()
}

fn job_name(s: &Series) -> String {
    ["job_name", "workflow"]
        .into_iter()
        .map(|k| s.label(k))
        .find(|v| !v.is_empty())
        .unwrap_or("-")
        .to_string()
}

pub fn build(infra: &Infra) -> Ci {
    let all = runners(infra);
    let off = infra.powered_off();
    let usual = usual(infra);
    let alias = infra.aliases();
    let mut ci = Ci::default();
    let mut hosts: BTreeSet<String> = BTreeSet::new();
    let mut rows: Vec<Slot> = vec![];
    // Slots with no job to say, by host, state, whom a lent one is lent to and pool: they fold
    // into one row each. A slot with no job names its pool only when it takes one cap; one that
    // takes several (unity, light, heavy) has no one pool until a job gives it a kind.
    let caps = infra.caps();
    let mut quiet: BTreeMap<(String, &str, &str, &str), Vec<String>> = BTreeMap::new();
    for r in &all {
        let s = r.s;
        let host = r.host.clone();
        hosts.insert(host.clone());
        let slot = slot_of(s.label("name"), s.label("host"));
        let state = now_of(r, &off);
        match state {
            "busy" => {
                let ran = s.value.map(|v| v as i64).filter(|v| *v > 0);
                let u = usual_of(&usual, r);
                let title = s.label("title");
                rows.push(Slot {
                    host,
                    slot,
                    pool: r.kind.unwrap_or_default().into(),
                    state: "busy".into(),
                    job: job_name(s),
                    repo: s.label("repo").into(),
                    pr: s.label("pr").into(),
                    branch: if !title.is_empty() && title != s.label("workflow") {
                        title.into()
                    } else {
                        s.label("branch").into()
                    },
                    ran,
                    usual: u.map(|u| u.0),
                    late: ran.is_some_and(|t| {
                        t > LONG_RUN_SECS || u.and_then(|u| u.1).is_some_and(|p| t > p)
                    }),
                    note: String::new(),
                    pod: infra.pod(s.label("name")).is_some(),
                });
            }
            _ => {
                let to = r.lent.filter(|_| state == "lent").unwrap_or_default();
                let pool = match caps.get(s.label("name")).map(Vec::as_slice) {
                    Some([one]) => *one,
                    _ => "",
                };
                quiet.entry((host, state, to, pool)).or_default().push(slot)
            }
        }
    }
    // A machine that is not a runner runs its gates locally: one busy row each, no slot number.
    for g in infra.get("gates") {
        let host = crate::infra::host(&alias, g.label("host"));
        hosts.insert(host.clone());
        let repo = match g.label("repo") {
            "" => g.label("worktree"),
            r => r,
        };
        let branch = g.label("branch");
        let pr = infra
            .get("runners")
            .iter()
            .chain(infra.get("waiting"))
            .find(|s| {
                s.label("repo") == repo && s.label("branch") == branch && !s.label("pr").is_empty()
            })
            .map_or("", |s| s.label("pr"));
        let ran = g.value.map(|v| v as i64).filter(|v| *v > 0);
        rows.push(Slot {
            host,
            slot: "-".into(),
            pool: crate::machines::LOCAL_POOL.into(),
            state: "busy".into(),
            job: format!("{} (local)", g.label("platform")),
            repo: repo.into(),
            pr: pr.into(),
            branch: branch.into(),
            ran,
            late: ran.is_some_and(|t| t > LONG_RUN_SECS),
            ..Default::default()
        });
    }
    for ((host, state, to, pool), slots) in quiet {
        let note = match state {
            "standby" => format!(
                "governor {}",
                off.get(host.as_str()).copied().unwrap_or("off")
            ),
            "lent" if to == "build" => "lent to the build that shares its cores".into(),
            "lent" => "cores lent to tests until a build waits".into(),
            "withheld" => "the governor holds it back".into(),
            _ => String::new(),
        };
        rows.push(Slot {
            host,
            slot: ranges(slots),
            pool: pool.into(),
            state: state.into(),
            note,
            ..Default::default()
        });
    }
    // Busy hosts first, then by name; on a host the longest job first, then idle, held, off.
    let busy_on = |h: &str| {
        rows.iter()
            .filter(|r| r.host == h && r.state == "busy")
            .count()
    };
    let order = |s: &str| {
        ["busy", "idle", "lent", "withheld", "standby", "off"]
            .iter()
            .position(|x| *x == s)
    };
    let host_rank: HashMap<String, usize> = hosts.iter().map(|h| (h.clone(), busy_on(h))).collect();
    rows.sort_by(|a, b| {
        host_rank[&b.host]
            .cmp(&host_rank[&a.host])
            .then_with(|| a.host.cmp(&b.host))
            .then_with(|| order(&a.state).cmp(&order(&b.state)))
            .then_with(|| a.pool.cmp(&b.pool))
            .then_with(|| b.ran.cmp(&a.ran))
            .then_with(|| a.slot.cmp(&b.slot))
    });
    for (b, s) in slots_by_host(infra).into_values() {
        ci.busy += b;
        ci.slots += s;
    }
    ci.hosts = hosts.len() as u32;
    ci.rows = rows;
    ci.queue = queue(infra, &all, &off);
    ci.queued = ci.queue.iter().map(|q| q.n).sum();
    ci.oldest = ci.queue.iter().map(|q| q.wait).max().unwrap_or(0);
    ci.red = ci.red_lines();
    ci.local = local(infra);
    ci.day = day(infra, crate::text::local_day_start(infra.at as i64));
    ci
}

/// Waiting jobs grouped by job and run, oldest first. A stuck run (queued with no jobs) is RED
/// NOW's, so it cannot pass for the queue's age.
fn queue(infra: &Infra, all: &[Runner], off: &HashMap<&str, &str>) -> Vec<Queued> {
    let mut by: BTreeMap<[String; 5], Queued> = BTreeMap::new();
    for s in infra.get("waiting") {
        if s.label("stuck") == "true" {
            continue;
        }
        let labels = lower(s.label("labels"));
        let wait = s.value.map_or(0, |v| v as i64);
        let q = by
            .entry([
                job_name(s),
                s.label("repo").into(),
                s.label("pr").into(),
                s.label("branch").into(),
                labels.join(","),
            ])
            .or_insert_with(|| Queued {
                job: job_name(s),
                pool: s.label("pool").into(),
                repo: s.label("repo").into(),
                pr: s.label("pr").into(),
                branch: s.label("branch").into(),
                needs: s
                    .label("labels")
                    .split(',')
                    .map(str::trim)
                    .filter(|l| !l.is_empty() && !COMMON.contains(&l.to_lowercase().as_str()))
                    .map(String::from)
                    .collect(),
                ..Default::default()
            });
        q.n += 1;
        q.wait = q.wait.max(wait);
    }
    let online: Vec<&Runner> = all
        .iter()
        .filter(|r| {
            matches!(r.s.label("state"), "running" | "idle") || off.contains_key(r.s.label("host"))
        })
        .collect();
    let usual = usual(infra);
    let mut out: Vec<Queued> = by
        .into_iter()
        .map(|([.., labels], mut q)| {
            let need = lower(&labels);
            if !need.is_empty() {
                q.can = fits(all, off, &need);
                (q.at, q.starts) = starts(all, off, &usual, &need);
                if q.at.is_empty() {
                    q.at = q.can.first().map(|f| f.host.clone()).unwrap_or_default();
                }
            }
            q
        })
        .collect();
    for q in &mut out {
        q.stuck = q.can.is_empty() && !q.needs.is_empty();
        if q.stuck {
            // The labels no online runner holds; empty when each is held but never together.
            q.missing = q
                .needs
                .iter()
                .filter(|n| !online.iter().any(|r| r.labels.contains(&n.to_lowercase())))
                .cloned()
                .collect();
        }
    }
    out.sort_by(|a, b| b.wait.cmp(&a.wait).then_with(|| a.job.cmp(&b.job)));
    out
}

/// Where a job holding `need` starts first and in how many seconds: an idle fitting slot now,
/// else the busy fitting slot whose usual time less its run is least. Empty and None when no
/// fitting slot is idle or busy with a usual time.
fn starts(
    all: &[Runner],
    off: &HashMap<&str, &str>,
    usual: &HashMap<(String, String), (i64, Option<i64>)>,
    need: &[String],
) -> (String, Option<i64>) {
    let mut best: Option<(i64, &str)> = None;
    for r in all.iter().filter(|r| holds(&r.labels, need)) {
        let left = match now_of(r, off) {
            "idle" => 0,
            "busy" => {
                let Some((median, _)) = usual_of(usual, r) else {
                    continue;
                };
                (median - r.s.value.map_or(0, |v| v as i64)).max(0)
            }
            _ => continue,
        };
        if best.is_none_or(|(b, h)| (left, r.host.as_str()) < (b, h)) {
            best = Some((left, r.host.as_str()));
        }
    }
    best.map_or((String::new(), None), |(t, h)| (h.to_string(), Some(t)))
}

/// The hosts with an online runner (or one waiting on a powered-off host) holding every label
/// (`now_of`).
fn fits(all: &[Runner], off: &HashMap<&str, &str>, need: &[String]) -> Vec<Fit> {
    let mut by: BTreeMap<&str, &str> = BTreeMap::new();
    let rank = |s: &str| {
        ["idle", "busy", "lent", "withheld", "standby"]
            .iter()
            .position(|x| *x == s)
            .unwrap_or(9)
    };
    for r in all.iter().filter(|r| holds(&r.labels, need)) {
        let state = match now_of(r, off) {
            "off" => continue,
            s => s,
        };
        let e = by.entry(r.host.as_str()).or_insert(state);
        if rank(state) < rank(e) {
            *e = state;
        }
    }
    let mut out: Vec<Fit> = by
        .into_iter()
        .map(|(host, state)| Fit {
            host: host.into(),
            state: state.into(),
        })
        .collect();
    out.sort_by_key(|f| (rank(&f.state), f.host.clone()));
    out
}

/// The slots in one pool that can take the jobs it has long waited on.
#[derive(Serialize, Default, Clone, Debug, PartialEq)]
pub struct PoolMatch {
    pub pool: String,
    /// Runners running or idle and not withheld, each once.
    pub slots: u32,
    pub busy: u32,
    /// Runners in any state: no slot because they are down reads differently from no runner
    /// with the labels.
    pub runners: u32,
    /// `<pool>/<label set> | <label set>`, each set sorted, as fleet-bench's finding names it.
    pub labels: String,
}

/// Per pool, the runners that can take the jobs waiting `min_wait` seconds or longer: a pool's
/// total busy/slots says nothing about a job that fits two of its ten runners (2026-11-05:
/// razer-laptop-unity-pool-1/2 were the only ones that matched while mac-studio slots sat idle).
/// Nothing when no job waits that long, or no runner is read: the finding then falls back to the
/// pool's own totals.
pub fn pool_match(infra: &Infra, min_wait: i64) -> Vec<PoolMatch> {
    let all = runners(infra);
    if all.is_empty() {
        return vec![];
    }
    let mut sets: BTreeMap<String, BTreeSet<Vec<String>>> = BTreeMap::new();
    for s in infra.get("waiting") {
        let mut labels = lower(s.label("labels"));
        labels.sort();
        if s.label("stuck") != "true"
            && s.value.is_some_and(|v| v as i64 >= min_wait)
            && !s.label("pool").is_empty()
            && !labels.is_empty()
        {
            sets.entry(s.label("pool").into())
                .or_default()
                .insert(labels);
        }
    }
    sets.into_iter()
        .map(|(pool, sets)| {
            let fit: Vec<&Runner> = all
                .iter()
                .filter(|r| sets.iter().any(|set| holds(&r.labels, set)))
                .collect();
            let slot = |r: &&&Runner| {
                r.s.label("state") == "running" || (r.s.label("state") == "idle" && !r.held)
            };
            PoolMatch {
                slots: fit.iter().filter(slot).count() as u32,
                busy: fit
                    .iter()
                    .filter(|r| r.s.label("state") == "running")
                    .count() as u32,
                runners: fit.len() as u32,
                labels: format!(
                    "{pool}/{}",
                    sets.iter()
                        .map(|s| s.join(","))
                        .collect::<Vec<_>>()
                        .join(" | ")
                ),
                pool,
            }
        })
        .collect()
}

/// `pool_match` as the tab-separated rows fleet-bench reads: metric, label, value.
pub fn pool_match_rows(infra: &Infra, min_wait: i64) -> String {
    pool_match(infra, min_wait)
        .iter()
        .flat_map(|m| {
            [
                format!("cc:pool_match_slots\t{}\t{}", m.pool, m.slots),
                format!("cc:pool_match_busy\t{}\t{}", m.pool, m.busy),
                format!("cc:pool_match_runners\t{}\t{}", m.pool, m.runners),
                format!("cc:pool_match_labels\t{}\t1", m.labels),
            ]
        })
        .map(|l| l + "\n")
        .collect()
}

/// A local Unity gate's failures (`fleet_local_gate_failed`) over the ledger's last day: GitHub's
/// runs are the Runs tab's, but a gate run on a workstation never reaches GitHub, so this is the
/// one place a red one shows.
#[derive(Serialize, Default, Clone, Debug, PartialEq)]
pub struct LocalFail {
    pub repo: String,
    pub branch: String,
    pub platform: String,
    pub result: String,
    pub n: u32,
    /// The start (unix seconds) of the last hour one failed in.
    pub last: i64,
}

/// The ledger counts per hour, so a day folds one branch's runs into one row: the newest first,
/// then the most.
fn local(infra: &Infra) -> Vec<LocalFail> {
    let mut by: BTreeMap<[String; 4], LocalFail> = BTreeMap::new();
    for s in infra.get("local_failed") {
        let key = ["repo", "branch", "platform", "result"].map(|k| s.label(k).to_string());
        let f = by.entry(key.clone()).or_insert_with(|| {
            let [repo, branch, platform, result] = key;
            LocalFail {
                repo,
                branch,
                platform,
                result,
                ..Default::default()
            }
        });
        f.n += s.value.unwrap_or(0.0).round().max(0.0) as u32;
        f.last = f.last.max(s.label("hour").parse().unwrap_or(0));
    }
    let mut out: Vec<LocalFail> = by.into_values().filter(|f| f.n > 0).collect();
    out.sort_by(|a, b| b.last.cmp(&a.last).then_with(|| b.n.cmp(&a.n)));
    out
}

fn opt(v: Option<i64>) -> Val {
    v.map_or(Val::None, |n| Val::Num(n as f64))
}

/// What a job or slot runs for: `repo#pr`, else its branch, else its repo.
fn reference(repo: &str, pr: &str, branch: &str) -> String {
    if !pr.is_empty() {
        format!("{repo}#{pr}")
    } else if !branch.is_empty() {
        branch.to_string()
    } else {
        repo.to_string()
    }
}

impl Slot {
    pub fn reference(&self) -> String {
        reference(&self.repo, &self.pr, &self.branch)
    }
}

impl Queued {
    pub fn reference(&self) -> String {
        reference(&self.repo, &self.pr, &self.branch)
    }
}

/// The CI runners table on both surfaces: each slot with the job it runs, idle and held runs of
/// slots folded to one row each.
impl Row for Slot {
    const COLUMNS: &'static [&'static str] = &[
        "host", "slot", "state", "pool", "ran", "usual", "job", "ref",
    ];
    const STATES: &'static [&'static str] = &[
        "all", "busy", "idle", "lent", "withheld", "standby", "off", "late",
    ];
    const FACETS: &'static [&'static str] = &["host", "state", "pool"];
    const HIDE_EMPTY: bool = true;
    const LEAD: &'static str = "host";
    const GLANCE: &'static [&'static str] = &["state", "ran", "job"];

    fn val(&self, col: &str) -> Val {
        let text = |s: &str| {
            if s.is_empty() {
                Val::None
            } else {
                Val::Text(s.to_string())
            }
        };
        match col {
            "host" => text(&self.host),
            "slot" => text(&self.slot),
            "state" => text(&self.state),
            "pool" => text(&self.pool),
            "ran" => opt(self.ran),
            "usual" => opt(self.usual),
            "job" if self.state == "busy" => text(&self.job),
            "job" => text(&self.note),
            "ref" => text(&self.reference()),
            _ => Val::None,
        }
    }
    fn in_state(&self, s: &str) -> bool {
        match s {
            "late" => self.late,
            s => self.state == s,
        }
    }
    fn rank(&self, col: &str) -> Val {
        match col {
            // `2-5` sorts by its first slot.
            "slot" => self
                .slot
                .split(['-', ','])
                .next()
                .and_then(|n| n.parse::<f64>().ok())
                .map_or_else(|| self.val(col), Val::Num),
            c => self.val(c),
        }
    }
    fn link(&self, col: &str) -> Option<Link> {
        match col {
            "host" => Some(Link::to(Kind::Machine, &self.host)),
            "pool" if !self.pool.is_empty() => Some(Link::to(Kind::Pool, &self.pool)),
            _ => None,
        }
    }
}

/// The queued jobs on both surfaces: what each needs and the hosts that can take it, the ones no
/// online runner can take under `stuck`.
impl Row for Queued {
    const COLUMNS: &'static [&'static str] = &["job", "pool", "ref", "n", "wait", "needs", "can"];
    const STATES: &'static [&'static str] = &["all", "stuck", "free"];
    const FACETS: &'static [&'static str] = &["pool", "needs", "can"];
    const LEAD: &'static str = "job";
    const GLANCE: &'static [&'static str] = &["wait", "can"];
    const LEGEND: &'static [(&'static str, &'static str)] = crate::vocab::CI;

    fn val(&self, col: &str) -> Val {
        match col {
            "job" => Val::Text(self.job.clone()),
            "pool" if self.pool.is_empty() => Val::None,
            "pool" => Val::Text(self.pool.clone()),
            "ref" => Val::Text(self.reference()),
            "n" => Val::Num(self.n as f64),
            "wait" => Val::Num(self.wait as f64),
            "needs" => Val::Text(self.needs.join(", ")),
            "can" if self.can.is_empty() => Val::None,
            "can" => Val::Text(
                self.can
                    .iter()
                    .map(|f| format!("{} {}", f.host, f.state))
                    .collect::<Vec<_>>()
                    .join(", "),
            ),
            _ => Val::None,
        }
    }
    fn vals(&self, col: &str) -> Vec<Val> {
        match col {
            "needs" => self.needs.iter().map(|n| Val::Text(n.clone())).collect(),
            "can" => self.can.iter().map(|f| Val::Text(f.host.clone())).collect(),
            c => vec![self.val(c)],
        }
    }
    fn in_state(&self, s: &str) -> bool {
        match s {
            "stuck" => self.stuck,
            "free" => self.can.iter().any(|f| f.state == "idle"),
            _ => false,
        }
    }
    fn link(&self, col: &str) -> Option<Link> {
        match col {
            "pool" if !self.pool.is_empty() => Some(Link::to(Kind::Pool, &self.pool)),
            _ => None,
        }
    }
}

/// The local Unity failures on both surfaces, under Runners.
impl Row for LocalFail {
    const COLUMNS: &'static [&'static str] =
        &["last", "repo", "branch", "platform", "result", "failed"];
    const STATES: &'static [&'static str] = &["all"];
    const FACETS: &'static [&'static str] = &["repo", "platform", "result"];
    const LEAD: &'static str = "branch";
    const GLANCE: &'static [&'static str] = &["last", "failed"];

    fn val(&self, col: &str) -> Val {
        match col {
            "last" => Val::Num(self.last as f64),
            "repo" => Val::Text(self.repo.clone()),
            "branch" => Val::Text(self.branch.clone()),
            "platform" => Val::Text(self.platform.clone()),
            "result" => Val::Text(self.result.clone()),
            "failed" => Val::Num(self.n as f64),
            _ => Val::None,
        }
    }
    fn in_state(&self, _: &str) -> bool {
        false
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::{json, Value};

    fn series(rows: Vec<(Value, &str)>) -> Vec<Series> {
        let res: Vec<Value> = rows
            .into_iter()
            .map(|(m, v)| json!({"metric": m, "value": [0, v]}))
            .collect();
        crate::prom::flatten(&json!({"status": "success", "data": {"result": res}})).unwrap()
    }

    fn runner(
        host: &str,
        name: &str,
        state: &str,
        v: &'static str,
        labels: &str,
        kw: Value,
    ) -> (Value, &'static str) {
        let mut m = json!({"host": host, "name": name, "state": state, "labels": labels});
        for (k, x) in kw.as_object().unwrap() {
            m[k] = x.clone();
        }
        (m, v)
    }

    fn waiting(job: &str, labels: &str, v: &'static str) -> (Value, &'static str) {
        (
            json!({"pool": "unity", "repo": "game", "branch": "main", "stuck": "false", "job_name": job,
                "workflow": "Soak", "labels": labels}),
            v,
        )
    }

    const FULL: &str = "self-hosted,linux,unity-full,lan";
    const WIDE: &str = "self-hosted,Linux,unity-full";

    fn board() -> Infra {
        let mut i = Infra {
            ok: true,
            ..Default::default()
        };
        i.instant.insert(
            "runners",
            series(vec![
                runner("razer", "razer-unity-pool-1", "running", "6000", FULL,
                    json!({"repo": "game", "branch": "main", "job_name": "Multi", "workflow": "Multi"})),
                runner("razer", "razer-unity-pool-2", "running", "1320", FULL,
                    json!({"repo": "game", "pr": "2210", "job_name": "Tests shard 2/3", "workflow": "Tests"})),
                runner("aws", "aws-unity-pool-1", "idle", "0", WIDE, json!({})),
                runner("aws", "aws-unity-pool-2", "idle", "0", WIDE, json!({})),
                runner("aws", "aws-unity-pool-3", "idle", "0", WIDE, json!({})),
                runner("aws", "aws-unity-pool-4", "idle", "0", WIDE, json!({})),
                runner("spot", "spot-unity-pool-1", "offline", "0", WIDE, json!({})),
                runner("spot", "spot-unity-pool-2", "offline", "0", WIDE, json!({})),
            ]),
        );
        i.instant.insert(
            "job_kind",
            series(vec![
                (
                    json!({"runner": "razer-unity-pool-1", "kind": "unity"}),
                    "1",
                ),
                (
                    json!({"runner": "razer-unity-pool-2", "kind": "unity"}),
                    "1",
                ),
            ]),
        );
        i.instant.insert(
            "waiting",
            series(vec![
                waiting(
                    "HD tests",
                    "self-hosted,linux,unity-full,hd-library",
                    "4320",
                ),
                waiting("HD tests", "self-hosted,linux,unity-full,hd-library", "100"),
                waiting("Soak", FULL, "3480"),
                waiting("Wide", WIDE, "30"),
                (
                    json!({"pool": "other", "repo": "x", "stuck": "true"}),
                    "999999",
                ),
            ]),
        );
        i.instant.insert(
            "job_usual",
            series(vec![
                (
                    json!({"pool": "unity", "workflow": "Multi", "quantile": "0.5"}),
                    "9180",
                ),
                (
                    json!({"pool": "unity", "workflow": "Multi", "quantile": "0.9"}),
                    "10000",
                ),
                (
                    json!({"pool": "unity", "workflow": "Tests", "quantile": "0.5"}),
                    "2640",
                ),
                (
                    json!({"pool": "unity", "workflow": "Tests", "quantile": "0.9"}),
                    "3000",
                ),
            ]),
        );
        i.instant.insert(
            "power",
            series(vec![(
                json!({"__name__": "ci_governor_power_state", "host": "spot", "state": "stopped"}),
                "1",
            )]),
        );
        i
    }

    #[test]
    fn a_host_is_its_busy_slots_longest_first_then_its_idle_ones_folded_to_a_range() {
        let ci = build(&board());
        let at: Vec<_> = ci
            .rows
            .iter()
            .map(|r| (r.host.as_str(), r.slot.as_str(), r.state.as_str()))
            .collect();
        assert_eq!(
            at,
            [
                ("razer", "1", "busy"),
                ("razer", "2", "busy"),
                ("aws", "1-4", "idle"),
                ("spot", "1-2", "standby"),
            ]
        );
        let multi = &ci.rows[0];
        assert_eq!(
            (multi.job.as_str(), multi.ran, multi.usual),
            ("Multi", Some(6000), Some(9180))
        );
        assert!(multi.late, "past the hour is amber whatever its usual");
        assert!(!ci.rows[1].late, "22m is under its 3000s p90");
        assert_eq!(ci.rows[3].note, "governor stopped");
        assert_eq!((ci.hosts, ci.slots, ci.busy), (3, 6, 2));
    }

    /// An agnostic slot takes the unity, light and heavy caps, so its runner row names no
    /// kind: the job's kind is `ci_runner_job`'s.
    #[test]
    fn a_light_job_on_a_unity_slot_reads_light_and_is_judged_by_lights_usual() {
        let mut i = board();
        i.instant
            .get_mut("runners")
            .unwrap()
            .extend(series(vec![runner(
                "razer",
                "razer-unity-pool-3",
                "running",
                "900",
                "self-hosted,linux,unity,light,heavy",
                json!({"repo": "web", "pr": "77", "job_name": "Checks", "workflow": "Checks"}),
            )]));
        i.instant.get_mut("job_kind").unwrap().extend(series(vec![(
            json!({"runner": "razer-unity-pool-3", "kind": "light"}),
            "1",
        )]));
        i.instant.get_mut("job_usual").unwrap().extend(series(vec![
            (
                json!({"pool": "light", "workflow": "Checks", "quantile": "0.5"}),
                "600",
            ),
            (
                json!({"pool": "light", "workflow": "Checks", "quantile": "0.9"}),
                "800",
            ),
            (
                json!({"pool": "unity", "workflow": "Checks", "quantile": "0.5"}),
                "5000",
            ),
            (
                json!({"pool": "unity", "workflow": "Checks", "quantile": "0.9"}),
                "6000",
            ),
        ]));
        i.ci = build(&i);
        let ci = &i.ci;
        let checks = ci.rows.iter().find(|r| r.job == "Checks").unwrap();
        assert_eq!(
            (checks.pool.as_str(), checks.usual, checks.late),
            ("light", Some(600), true),
            "light's usual, and 900s is past light's 800s p90"
        );
        assert_eq!(
            checks.link("pool"),
            Some(Link::to(Kind::Pool, "light")),
            "the row opens the light pool's page"
        );
        assert_eq!(
            running_by_host(&i)["razer"],
            ["[unity] game x2", "[light] web"]
        );
        // A slot with no job takes every kind it has caps for: no pool when it has several, its
        // one cap when it has one, and the two fold apart.
        let cap = |name: &str, pool: &str| (json!({"name": name, "pool": pool}), "1");
        i.instant.insert(
            "runner_caps",
            series(vec![
                cap("aws-unity-pool-1", "unity"),
                cap("aws-unity-pool-1", "light"),
                cap("aws-unity-pool-2", "unity"),
                cap("aws-unity-pool-2", "light"),
                cap("aws-unity-pool-3", "macos"),
                cap("aws-unity-pool-4", "macos"),
            ]),
        );
        let idle: Vec<_> = build(&i)
            .rows
            .into_iter()
            .filter(|r| r.state == "idle")
            .map(|r| (r.slot, r.pool))
            .collect();
        assert_eq!(
            idle,
            [
                ("1-2".into(), String::new()),
                ("3-4".into(), "macos".into())
            ]
        );
        // A runner read with two kinds at once is neither, so hash order never picks one.
        i.instant.get_mut("job_kind").unwrap().extend(series(vec![(
            json!({"runner": "razer-unity-pool-3", "kind": "unity"}),
            "1",
        )]));
        let checks = build(&i)
            .rows
            .into_iter()
            .find(|r| r.job == "Checks")
            .unwrap();
        assert_eq!((checks.pool.as_str(), checks.usual), ("", None));
    }

    #[test]
    fn a_queued_job_names_the_hosts_that_can_take_it_free_ones_first() {
        let ci = build(&board());
        let soak = ci.queue.iter().find(|q| q.job == "Soak").unwrap();
        assert_eq!(soak.needs, ["unity-full", "lan"]);
        assert_eq!(
            soak.can,
            [Fit {
                host: "razer".into(),
                state: "busy".into()
            }]
        );
        assert!(!soak.stuck);
        // Matched without regard to case: aws holds `Linux`, the job asks `linux`.
        let wide = ci.queue.iter().find(|q| q.job == "Wide").unwrap();
        assert_eq!(
            wide.can[0],
            Fit {
                host: "aws".into(),
                state: "idle".into()
            }
        );
        // A busy host after the free one, and a powered-off host last: the governor wakes it.
        assert_eq!(
            wide.can[1],
            Fit {
                host: "razer".into(),
                state: "busy".into()
            }
        );
        assert_eq!(
            wide.can[2],
            Fit {
                host: "spot".into(),
                state: "standby".into()
            }
        );
        assert_eq!(
            (ci.queued, ci.oldest),
            (4, 4320),
            "the stuck run is no queue"
        );
    }

    #[test]
    fn a_job_no_online_runner_can_take_is_a_problem_naming_the_missing_label() {
        let ci = build(&board());
        let hd = &ci.problems()[0];
        assert_eq!((hd.job.as_str(), hd.n, hd.wait), ("HD tests", 2, 4320));
        assert_eq!(hd.missing, ["hd-library"]);
        assert_eq!(
            hd.problem(),
            "HD tests (game) needs [unity-full, hd-library]: no online runner holds hd-library"
        );
        assert_eq!(ci.problems().len(), 1, "Soak fits razer");
        // The red line carries the count of waiting jobs of that kind.
        assert_eq!(
            ci.red,
            ["HD tests (game) needs [unity-full, hd-library]: no online runner holds hd-library (2 jobs)"]
        );
        // A label held by a runner that is offline is still missing: it cannot take the job.
        let mut i = board();
        i.instant.insert(
            "runners",
            series(vec![runner(
                "razer",
                "razer-unity-pool-1",
                "offline",
                "0",
                FULL,
                json!({}),
            )]),
        );
        let ci = build(&i);
        let soak = ci.queue.iter().find(|q| q.job == "Soak").unwrap();
        assert_eq!(soak.missing, ["unity-full", "lan"]);
    }

    #[test]
    fn each_label_held_but_never_together_says_so() {
        let mut i = board();
        i.instant.insert(
            "runners",
            series(vec![
                runner("a", "a-1", "idle", "0", "self-hosted,unity-full", json!({})),
                runner("b", "b-1", "idle", "0", "self-hosted,lan", json!({})),
            ]),
        );
        i.instant
            .insert("waiting", series(vec![waiting("Soak", FULL, "10")]));
        let q = &build(&i).queue[0];
        assert!(q.missing.is_empty() && q.stuck);
        assert!(q
            .problem()
            .contains("no one online runner holds all of them"));
    }

    #[test]
    fn a_withheld_idle_runner_is_no_slot_and_takes_no_job() {
        let mut i = board();
        i.instant.insert(
            "withheld",
            series(vec![(json!({"name": "aws-unity-pool-1"}), "1")]),
        );
        let ci = build(&i);
        let held: Vec<_> = ci.rows.iter().filter(|r| r.state == "withheld").collect();
        assert_eq!((held.len(), held[0].slot.as_str()), (1, "1"));
        assert_eq!(ci.slots, 5);
        let idle = ci.rows.iter().find(|r| r.state == "idle").unwrap();
        assert_eq!(idle.slot, "2-4");
    }

    #[test]
    fn a_slot_lent_to_its_pair_reads_lent_and_one_held_for_load_still_withheld() {
        let mut i = board();
        i.instant.insert(
            "withheld",
            series(vec![
                (json!({"name": "aws-unity-pool-1"}), "1"),
                (json!({"name": "aws-unity-pool-2"}), "1"),
            ]),
        );
        // A lent row for a runner that is not withheld (the governor a cycle behind) is ignored.
        i.instant.insert(
            "lent",
            series(vec![
                (json!({"name": "aws-unity-pool-1", "to": "tests"}), "1"),
                (json!({"name": "aws-unity-pool-3", "to": "tests"}), "1"),
            ]),
        );
        let ci = build(&i);
        let row = |state: &str| ci.rows.iter().find(|r| r.state == state).unwrap();
        assert_eq!(
            (row("lent").slot.as_str(), row("lent").note.as_str()),
            ("1", "cores lent to tests until a build waits")
        );
        assert_eq!(
            (row("withheld").slot.as_str(), row("withheld").note.as_str()),
            ("2", "the governor holds it back")
        );
        assert_eq!(row("idle").slot, "3-4");
        assert_eq!(ci.slots, 4);
    }

    /// The human, 2026-11-19: the summary views say running and queued only. A held or lent slot
    /// says nothing on its machine row; the runners table keeps its state.
    #[test]
    fn a_held_or_lent_slot_says_nothing_on_its_machine_row() {
        let mut i = board();
        i.instant.insert(
            "withheld",
            series(vec![
                (json!({"name": "aws-unity-pool-1"}), "1"),
                (json!({"name": "aws-unity-pool-2"}), "1"),
                (json!({"name": "aws-unity-pool-3"}), "1"),
            ]),
        );
        i.instant.insert(
            "lent",
            series(vec![(
                json!({"name": "aws-unity-pool-1", "to": "tests"}),
                "1",
            )]),
        );
        assert!(
            !running_by_host(&i).contains_key("aws"),
            "a held or lent slot runs nothing"
        );
        let ci = build(&i);
        let states: Vec<&str> = ci.rows.iter().map(|r| r.state.as_str()).collect();
        assert!(
            states.contains(&"lent") && states.contains(&"withheld"),
            "{states:?}"
        );
    }

    /// NEXT: an idle fitting slot starts it now; else the busy one that frees first by its usual
    /// time less its run; no fitting slot with a usual time says nothing.
    #[test]
    fn a_queued_job_starts_on_the_fitting_slot_that_frees_first() {
        let ci = build(&board());
        let q = |job: &str| ci.queue.iter().find(|q| q.job == job).unwrap();
        // razer-1 runs Multi 6000s of a 9180s usual, razer-2 Tests 1320s of 2640s: 1320 left.
        assert_eq!(
            (q("Soak").at.as_str(), q("Soak").starts),
            ("razer", Some(1320))
        );
        assert_eq!((q("Wide").at.as_str(), q("Wide").starts), ("aws", Some(0)));
        assert_eq!(
            (q("HD tests").at.as_str(), q("HD tests").starts),
            ("", None)
        );
    }

    #[test]
    fn a_local_gate_is_a_busy_row_with_the_pr_of_its_branch() {
        let mut i = board();
        i.instant.insert(
            "gates",
            series(vec![(
                json!({"host": "workstation", "repo": "game", "branch": "main", "platform": "unity"}),
                "300",
            )]),
        );
        let ci = build(&i);
        let g = ci.rows.iter().find(|r| r.host == "workstation").unwrap();
        assert_eq!(
            (g.job.as_str(), g.slot.as_str(), g.ran),
            ("unity (local)", "-", Some(300))
        );
        assert_eq!(ci.hosts, 4);
    }

    #[test]
    fn a_local_gate_by_the_nodes_hostname_is_its_machines_row() {
        let mut i = board();
        i.instant.insert(
            "uname",
            series(vec![(
                json!({"host": "workstation", "nodename": "cachyos-x8664-main"}),
                "1",
            )]),
        );
        i.instant.insert(
            "gates",
            series(vec![(
                json!({"host": "cachyos-x8664-main", "repo": "game", "branch": "main", "platform": "unity"}),
                "300",
            )]),
        );
        let ci = build(&i);
        assert!(ci.rows.iter().any(|r| r.host == "workstation"));
        assert!(!ci.rows.iter().any(|r| r.host == "cachyos-x8664-main"));
        assert_eq!(ci.hosts, 4);
    }

    #[test]
    fn local_failures_fold_by_branch_and_platform_newest_first() {
        let mut i = board();
        let fail = |branch: &str, platform: &str, hour: &str, v: &'static str| {
            (
                json!({"repo": "game", "branch": branch, "platform": platform,
                    "result": "fail", "hour": hour}),
                v,
            )
        };
        i.instant.insert(
            "local_failed",
            series(vec![
                fail("feat/a", "linux", "7200", "2"),
                fail("feat/a", "linux", "3600", "1"),
                fail("feat/b", "android", "3600", "4"),
                fail("feat/c", "linux", "10800", "-1"),
            ]),
        );
        let ci = build(&i);
        let got: Vec<(&str, u32, i64)> = ci
            .local
            .iter()
            .map(|f| (f.branch.as_str(), f.n, f.last))
            .collect();
        // feat/c counted nothing, so it is no row.
        assert_eq!(got, [("feat/a", 3, 7200), ("feat/b", 4, 3600)]);
    }

    #[test]
    fn two_pods_reporting_one_runner_count_it_once_the_running_one_winning() {
        let mut i = board();
        i.instant.insert(
            "runners",
            series(vec![
                runner("razer", "razer-unity-pool-1", "idle", "0", FULL, json!({})),
                runner(
                    "razer",
                    "razer-unity-pool-1",
                    "running",
                    "5",
                    FULL,
                    json!({"pod": "b"}),
                ),
            ]),
        );
        let ci = build(&i);
        assert_eq!((ci.slots, ci.busy), (1, 1));
    }

    #[test]
    fn slots_are_numbered_by_the_runners_trailing_digits() {
        assert_eq!(slot_of("razer-laptop-unity-pool-2", "razer-laptop"), "2");
        assert_eq!(slot_of("forgejo-runner/3", "forgejo"), "3");
        assert_eq!(slot_of("mac-mini-builder", "mac-mini"), "builder");
        assert_eq!(
            ranges(vec!["5".into(), "1".into(), "2".into(), "9".into()]),
            "1-2,5,9"
        );
        assert_eq!(ranges(vec!["b".into(), "1".into()]), "1,b");
    }

    /// fleet-bench's `prom_match_rows` bats case, moved here with the join.
    #[test]
    fn pool_match_counts_the_runners_that_fit_the_long_waiting_jobs_withheld_and_offline_out() {
        let l = "self-hosted,linux,unity-full";
        let mut i = Infra::default();
        i.instant.insert(
            "waiting",
            series(vec![
                (json!({"pool": "unity", "stuck": "false", "labels": "self-hosted,Linux,unity-full"}), "7200"),
                (json!({"pool": "unity", "stuck": "false", "labels": l}), "7000"),
                (json!({"pool": "unity", "stuck": "false", "labels": "self-hosted,macOS"}), "60"),
            ]),
        );
        let r = |name: &str, state: &str, labels: &str, kw: Value| {
            runner("h", name, state, "5", labels, kw)
        };
        i.instant.insert(
            "runners",
            series(vec![
                r("razer-1", "running", l, json!({})),
                r("razer-1", "running", l, json!({"pod": "b"})),
                r("razer-2", "idle", l, json!({})),
                r("razer-3", "idle", l, json!({})),
                r("razer-4", "offline", l, json!({})),
                r("mac-1", "idle", "macOS,unity-full", json!({})),
                r("cachy-1", "idle", "self-hosted,linux", json!({})),
            ]),
        );
        i.instant
            .insert("withheld", series(vec![(json!({"name": "razer-3"}), "1")]));
        let m = pool_match(&i, 3600);
        assert_eq!(
            m,
            [PoolMatch {
                pool: "unity".into(),
                slots: 2,
                busy: 1,
                runners: 4,
                labels: "unity/linux,self-hosted,unity-full".into()
            }]
        );
        assert!(pool_match_rows(&i, 3600)
            .contains("cc:pool_match_labels\tunity/linux,self-hosted,unity-full\t1\n"));
        assert!(pool_match(&i, 9000).is_empty(), "nothing waits that long");
        i.instant.remove("runners");
        assert!(
            pool_match(&i, 3600).is_empty(),
            "no runner read, so no match"
        );
    }

    /// NEXT is the oldest waiting group a machine fits (`Queued::can`), the same join that says
    /// where a job starts: a stuck job fits nowhere and is no machine's next.
    #[test]
    fn each_machine_s_next_is_the_oldest_waiting_job_it_fits() {
        let mut i = board();
        i.ci = build(&i);
        let next = next_by_host(&i);
        let first = |h: &str| {
            i.ci.queue
                .iter()
                .find(|q| q.can.iter().any(|f| f.host == h))
        };
        let razer = first("razer").expect("a queued job fits razer");
        assert_eq!(
            next["razer"].line(|s| format!("{}m", s / 60)),
            format!("{} ({}) {}m", razer.job, razer.repo, razer.wait / 60)
        );
        assert!(
            next.keys().all(|h| first(h).is_some()),
            "a machine with a next fits that job"
        );
        let stuck = i.ci.queue.iter().filter(|q| q.can.is_empty()).count();
        assert!(stuck > 0, "the board has a job no runner can take");
    }

    #[test]
    fn slots_and_queued_jobs_link_their_machine_and_pool() {
        let ci = build(&board());
        let (rows, s) = crate::table::View::new::<Slot>("", "busy", "", "").summary(&ci.rows);
        assert_eq!(rows.len(), 2);
        assert_eq!(s.links[0]["host"], "#infra/machines/razer");
        assert_eq!(s.links[0]["pool"], "#infra/pools/unity");
        let (_, s) = crate::table::View::new::<Queued>("", "", "", "").summary(&ci.queue);
        assert!(s.links.iter().all(|l| l["pool"] == "#infra/pools/unity"));
        let can: Vec<String> = s
            .facets
            .iter()
            .find(|f| f.key == "can")
            .unwrap()
            .values
            .iter()
            .map(|v| v.value.clone())
            .collect();
        assert!(
            can.iter()
                .all(|h| ["razer", "aws", "spot"].contains(&h.as_str())),
            "{can:?}"
        );
    }

    /// The fleet plus the cluster (`jobpods::tests::cluster`): two light pods and a forgejo job
    /// on ms-a2, tuf-b550 an idle CI node, one light pod with no room, and the exporter's row for
    /// one of the ms-a2 pods under its scale set's owner, `arc-org`.
    fn clustered() -> Infra {
        let mut i = crate::machines::tests::fleet();
        for (k, s) in crate::jobpods::tests::cluster() {
            i.instant.insert(k, s);
        }
        i.instant
            .entry("runners")
            .or_default()
            .extend(series(vec![runner(
                "arc-org",
                "arc-org-light-runner-z5wfp",
                "running",
                "40",
                "self-hosted,linux,light",
                json!({"repo": "home-config", "job_name": "lint"}),
            )]));
        i
    }

    /// ar-5304: a CI node's row is what its job pods book of its allocatable, every CI node has
    /// one, an ARC runner is its pod on its node (no `arc-org` row, no slot, counted once), the
    /// old Unity slot's job stays a job in its machine's row, and the pods with no room wait.
    #[test]
    fn each_ci_node_reads_what_its_job_pods_book_and_the_slots_jobs_share_the_rows() {
        let mut i = clustered();
        i.derive();
        let g = &i.ci.glance;
        let rows: Vec<(&str, u32, String, String)> = g
            .machines
            .iter()
            .map(|h| {
                let b = h.booked.map_or("-".into(), |b| b.cell());
                (h.host.as_str(), h.busy, b, h.running.join(", "))
            })
            .collect();
        assert_eq!(
            rows,
            [
                (
                    "ms-a2",
                    3,
                    "4.4/32 2.5G/92G".into(),
                    "[arc-org-light] x2, [forgejo-runner]".into()
                ),
                ("tuf-b550", 0, "0.0/32 0B/63G".into(), String::new()),
                ("workstation", 1, "-".into(), "[unity]".into()),
                ("mac-mini", 0, "-".into(), String::new()),
            ]
        );
        assert!(i.machines.iter().all(|m| m.host != "arc-org"));
        let arc = i.ci.rows.iter().find(|r| r.job == "lint").unwrap();
        assert_eq!((arc.host.as_str(), arc.pod), ("ms-a2", true));
        assert_eq!(g.busy, 4);
        let b = g.booked.unwrap();
        assert_eq!(
            (format!("{:.2}", b.cpu), b.cpu_alloc),
            ("4.38".into(), 64.0)
        );
        assert_eq!(
            g.pending_line().as_deref(),
            Some("waiting for room: arc-org-light (1.69 cpu 1.2G)")
        );
        assert_eq!(
            g.head(|s| format!("{}m", s / 60)),
            "4 running, 2 queued (oldest 15m), booked 4.4/64 cpu, 4/4 runners up, 4 done 24h, 50% passed"
        );
    }

    /// A host whose every runner is held back still has a row, so it stays on the bar and
    /// the hover.
    #[test]
    fn a_host_with_every_runner_held_keeps_its_row() {
        let mut i = crate::machines::tests::fleet();
        i.instant
            .entry("withheld")
            .or_default()
            .extend(series(vec![(json!({"name": "mini-1"}), "1")]));
        i.derive();
        let g = &i.ci.glance;
        let rows: Vec<(&str, u32)> = g
            .machines
            .iter()
            .map(|h| (h.host.as_str(), h.busy))
            .collect();
        assert_eq!(rows, [("workstation", 1), ("mac-mini", 0)]);
    }

    /// The CI alert is runner liveness alone: an offline Forgejo seat (lent by design) and a
    /// tripped domain watch leave it ok, one GitHub runner down turns it red, and up plus down
    /// is the roster every time.
    #[test]
    fn the_ci_alert_is_red_only_while_a_runner_is_down() {
        let mut i = crate::machines::tests::fleet();
        let mut rows = i.get("runners").to_vec();
        rows.extend(series(vec![(
            json!({"__name__": "github_runner_state",
            "host": "cachyos-x8664-main", "name": "ws-forgejo", "state": "offline",
            "site": "local", "forge": "forgejo"}),
            "1",
        )]));
        i.instant.insert("runners", rows);
        i.instant.entry("cc").or_default().extend(series(vec![(
            json!({"__name__": "cc:domain_status", "domain": "ci"}),
            "1",
        )]));
        i.derive();
        let g = &i.ci.glance;
        assert_eq!((g.level, g.alert), (Level::Warn, Level::Ok));
        assert_eq!((g.up, g.expected), (3, 3));
        // A rollout's stale second report of an idle runner is not a runner down, and a runner
        // reported up twice counts once.
        let mut rows = i.get("runners").to_vec();
        rows.extend(series(vec![
            (
                json!({"__name__": "github_runner_state",
                "host": "cachyos-x8664-main", "name": "ws-unity-2", "state": "missing",
                "site": "home"}),
                "1",
            ),
            (
                json!({"__name__": "github_runner_state",
                "host": "cachyos-x8664-main", "name": "ws-unity-2", "state": "idle",
                "site": "home"}),
                "1",
            ),
        ]));
        i.instant.insert("runners", rows);
        i.derive();
        let g = &i.ci.glance;
        assert_eq!((g.up, g.expected, g.alert), (3, 3, Level::Ok));
        let mut rows = i.get("runners").to_vec();
        rows.extend(series(vec![(
            json!({"__name__": "github_runner_state",
            "host": "cachyos-x8664-main", "name": "ws-gate-9", "state": "offline",
            "site": "local"}),
            "1",
        )]));
        i.instant.insert("runners", rows);
        i.derive();
        let g = &i.ci.glance;
        assert_eq!(g.alert, Level::Red);
        assert_eq!((g.up, g.expected), (3, 4));
        assert!(g.head(|s| format!("{s}s")).contains("3/4 runners up"));
        // No runner read at all: no verdict, never ok.
        i.instant.insert("runners", vec![]);
        i.derive();
        assert_eq!(i.ci.glance.alert, Level::Nodata);
    }

    /// ar-3326: the glance every surface renders counts each slot once, names what the slots
    /// are doing, folds the stopped cloud host to one name, and lists no runner of it as down.
    #[test]
    fn the_glance_counts_each_slot_once_and_folds_a_stopped_cloud_host() {
        let mut i = crate::machines::tests::fleet();
        i.derive();
        let g = &i.ci.glance;
        // The fleet's withheld slot is no count: running and queued only.
        assert_eq!((g.busy, g.queued, g.done), (1, 2, 4));
        // No CI node read: nothing booked, and the head says nothing of it.
        assert_eq!(
            g.head(|s| format!("{}m", s / 60)),
            "1 running, 2 queued (oldest 15m), 3/3 runners up, 4 done 24h, 50% passed"
        );
        assert!(g.booked.is_none() && g.machines.iter().all(|h| h.booked.is_none()));
        let hosts: Vec<(&str, String)> = g
            .machines
            .iter()
            .map(|h| (h.host.as_str(), h.running.join(", ")))
            .collect();
        assert_eq!(
            hosts,
            [
                ("workstation", "[unity]".to_string()),
                ("mac-mini", String::new())
            ]
        );
        assert_eq!(g.off, ["aws-burst-1"]);
        // The Machines table folds it to that line; its page still finds it.
        assert!(i.machine_rows().iter().all(|m| m.host != "aws-burst-1"));
        assert!(i.machines.iter().any(|m| m.host == "aws-burst-1"));
        assert!(g.down.is_empty(), "{:?}", g.down);
        // The stopped host's runners are neither up nor down, so every runner is up and CI is ok.
        assert_eq!((g.up, g.expected, g.alert), (3, 3, Level::Ok));
        let kinds: Vec<&str> = g.kinds.iter().map(|k| k.kind.as_str()).collect();
        assert_eq!(kinds, ["unity", "gates", "macos"]);
        // The waybar chip (.config/waybar/ci_runners.sh) reads these JSON keys by name, and its
        // bats suite feeds a fixture, so a renamed field shows here first.
        let v = serde_json::to_value(g).unwrap();
        let keys = |v: &Value| v.as_object().unwrap().keys().cloned().collect::<Vec<_>>();
        assert_eq!(
            keys(&v),
            [
                "alert", "booked", "busy", "done", "down", "expected", "feed", "kinds", "level",
                "long", "machines", "next", "off", "oldest", "parts", "pass", "pending", "queued",
                "up"
            ]
        );
        assert_eq!(
            keys(&v["kinds"][0]),
            ["done", "kind", "oldest", "pass", "running", "waiting", "weight"]
        );
        assert_eq!(
            keys(&v["machines"][0]),
            ["booked", "busy", "cpu", "host", "load", "next", "running"]
        );
        // No status series: the lowercase word the chip maps to "no data".
        assert_eq!(v["level"], "nodata");
        // A cloud host that still holds a slot is not off.
        for m in i.machines.iter_mut() {
            match m.host.as_str() {
                "aws-burst-1" => m.slots = 1,
                "workstation" => (m.load, m.cores) = (Some(36.0), Some(24.0)),
                _ => {}
            }
        }
        let g = glance(&i);
        assert!(g.off.is_empty(), "{:?}", g.off);
        // Load per core, for the chip's hot row; a host missing a reading has none.
        let load = |h: &str| g.machines.iter().find(|m| m.host == h).unwrap().load;
        assert_eq!(
            (load("workstation"), load("aws-burst-1")),
            (Some(1.5), None)
        );
        let hosts: Vec<&str> = g.machines.iter().map(|h| h.host.as_str()).collect();
        assert!(
            hosts.contains(&"aws-burst-1") && hosts.contains(&"mac-mini"),
            "{hosts:?}"
        );
    }

    #[test]
    fn the_day_counts_runs_since_midnight_by_outcome_and_a_cancel_or_skip_is_no_pass_or_fail() {
        let mut i = Infra::default();
        let h = |hour: i64, conc: &str, scope: &str| json!({"hour": hour.to_string(), "conclusion": conc, "scope": scope});
        i.instant.insert(
            "hourly",
            series(vec![
                (h(1000, "success", "main"), "6"),
                (h(1000, "failure", "main"), "1"),
                (h(1000, "timed_out", "branch"), "2"),
                (h(1000, "cancelled", "branch"), "3"),
                (h(1000, "skipped", "branch"), "9"),
                (h(900, "success", "main"), "50"),
            ]),
        );
        i.instant.insert(
            "local_hourly",
            series(vec![
                (json!({"hour": "1000", "result": "pass"}), "1"),
                (json!({"hour": "1000", "result": "fail"}), "1"),
            ]),
        );
        let d = day(&i, 1000);
        assert_eq!(
            (d.runs, d.failed_main, d.failed_branch, d.cancelled),
            (12, 1, 2, 3)
        );
        assert_eq!(
            d.pass,
            Some(6.0 / 9.0),
            "passed of passed and failed; a cancel is neither"
        );
        assert_eq!((d.local, d.local_pass, d.read), (2, Some(0.5), true));
        assert_eq!(
            day(&Infra::default(), 1000),
            Day::default(),
            "nothing read is not a zero day"
        );
    }
}
