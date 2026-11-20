//! One machine's page on both surfaces (`#infra/machines/<host>`): its Machines row as labelled
//! parts, the cores each kind of CI job uses there, the CI jobs running there, its last `DAYS` days
//! and downtime (`host_history`), the CI jobs that ran there (the jobs archive), the alerts that
//! name it and its Grafana board. hub-core reads it; agent-web and the TUI only draw it.

use std::cmp::Reverse;
use std::collections::HashSet;
use std::path::Path;

use chrono::{Local, TimeZone};
use serde::Serialize;

use crate::alerts::Alert;
use crate::ci::Slot;
use crate::host_history::{self, HostHistory};
use crate::host_now::{self, HostNow};
use crate::infra::{self, Infra};
use crate::links::{Kind, Link};
use crate::machines::Machine;
use crate::run_detail;
use crate::session_page::Part;
use crate::table::{Row, Val};

/// What the page says for a name the Machines table does not have.
pub const NO_MACHINE: &str = "no machine named";
/// The Grafana board one machine's link opens, by its uid; `var-host` picks the machine.
pub const BOARD: &str = "kb-fleet";
/// The most recent CI jobs the page lists.
pub const RECENT: usize = 50;
/// The slots rows that are no runner: busy cores no runner's job uses, and idle cores.
pub const OTHER: &str = "not a runner";
pub const IDLE: &str = "idle";
const GIB: f64 = 1024.0 * 1024.0 * 1024.0;

/// One runner on the machine and what it takes of it, or a row of cores no runner uses
/// (`OTHER`, `IDLE`). A reading a runner has no series for is `None`, said as no data.
#[derive(Serialize, Debug, PartialEq, Clone, Default)]
pub struct SlotUse {
    /// The runner's name, or `OTHER` or `IDLE`.
    pub slot: String,
    /// Every cap it takes (`github_runner_pool_slot`), in the exporter's order.
    pub takes: Vec<String>,
    /// As `ci::runners_now` says it: busy, idle, lent, withheld, standby or off.
    pub now: String,
    pub job: String,
    /// Cores its job uses and the cores it may use (`cc:runner_cores_{busy,allowed}`).
    pub cores: Option<f64>,
    pub cores_max: Option<f64>,
    /// Memory it uses and its limit, bytes (`cc:runner_mem_{bytes,max_bytes}`).
    pub mem: Option<f64>,
    pub mem_max: Option<f64>,
    /// Its work directory, bytes, and that reading's age, seconds (`cc:runner_disk_*`).
    pub disk: Option<f64>,
    pub disk_age: Option<f64>,
    /// A runner's row, not `OTHER` or `IDLE`.
    pub runner: bool,
}

/// `0`, `2.8`, `140`: a reading as the slots table and the Space line say it. Halves round up,
/// as the web's `toFixed` and `Math.round` do (Rust's `{:.0}` rounds a tie to even).
fn short(v: f64) -> String {
    if v == 0.0 {
        "0".into()
    } else if v < 100.0 {
        format!("{:.1}", (v * 10.0).round() / 10.0)
    } else {
        whole(v)
    }
}

/// A whole number, a half rounded up: `12.5` is `13` on both surfaces.
fn whole(v: f64) -> String {
    format!("{:.0}", v.round())
}

/// The Space line's amber: free disk under this share (the Machines disk cell's amber line),
/// memory at or past this share used.
const DISK_LOW: f64 = 0.2;
const MEM_HIGH: f64 = 0.9;

/// `ws-unity-2` before `ws-unity-10`: a name's trailing number sorts as a number.
fn natural(name: &str) -> (&str, u64) {
    let head = name.trim_end_matches(|c: char| c.is_ascii_digit());
    (head, name[head.len()..].parse().unwrap_or(0))
}

/// `2.8/3`, `11.2/14G`; `2.8` with no limit; no data with no reading.
pub fn used_of(used: Option<f64>, max: Option<f64>, scale: f64, unit: &str) -> String {
    match (used, max) {
        (None, _) => crate::reading::NO_DATA.into(),
        (Some(u), Some(m)) => format!("{}/{}{unit}", short(u / scale), whole(m / scale)),
        (Some(u), None) => format!("{}{unit}", short(u / scale)),
    }
}

impl SlotUse {
    pub fn cores_text(&self) -> String {
        if !self.runner {
            return self.cores.map(short).unwrap_or_default();
        }
        used_of(self.cores, self.cores_max, 1.0, "")
    }
    /// Empty on a row of cores, which has no memory or disk of its own.
    pub fn mem_text(&self) -> String {
        if !self.runner {
            return String::new();
        }
        used_of(self.mem, self.mem_max, GIB, "G")
    }
    pub fn disk_text(&self) -> String {
        match (self.runner, self.disk) {
            (false, _) => String::new(),
            (true, None) => crate::reading::NO_DATA.into(),
            (true, Some(d)) => host_now::bytes(d),
        }
    }
}

/// The slots table on both surfaces: each runner by name, then the cores no runner uses.
impl Row for SlotUse {
    const COLUMNS: &'static [&'static str] =
        &["slot", "takes", "now", "job", "cores", "mem", "disk"];
    const STATES: &'static [&'static str] =
        &["all", "busy", "idle", "lent", "withheld", "standby", "off"];
    const FACETS: &'static [&'static str] = &["now"];
    const HIDE_EMPTY: bool = true;
    const LEAD: &'static str = "slot";
    const GLANCE: &'static [&'static str] = &["now", "cores", "mem"];

    fn val(&self, col: &str) -> Val {
        let text = |s: &str| match s {
            "" => Val::None,
            s => Val::Text(s.to_string()),
        };
        match col {
            "slot" => text(&self.slot),
            "takes" => text(&self.takes.join(" ")),
            "now" => text(&self.now),
            "job" => text(&self.job),
            "cores" => self.cores.into(),
            "mem" => self.mem.into(),
            "disk" => self.disk.into(),
            _ => Val::None,
        }
    }
    fn in_state(&self, s: &str) -> bool {
        self.now == s
    }
}

/// One CI job that ran there, from the jobs archive.
#[derive(Serialize, Debug, PartialEq, Clone, Default)]
pub struct RecentJob {
    /// GitHub's job id: one job in two archive records is one row.
    #[serde(skip)]
    pub id: u64,
    pub run_id: u64,
    pub repo: String,
    pub job: String,
    pub runner: String,
    /// `success`, `failure`, `cancelled`, or empty while it runs.
    pub conclusion: String,
    pub started: Option<i64>,
    pub took: Option<i64>,
    pub url: Option<String>,
}

/// The recent CI jobs table on both surfaces, newest first.
impl Row for RecentJob {
    const COLUMNS: &'static [&'static str] =
        &["started", "repo", "job", "runner", "conclusion", "took"];
    const STATES: &'static [&'static str] = &["all", "failure", "success"];
    const FACETS: &'static [&'static str] = &["repo", "runner", "conclusion"];
    const LEAD: &'static str = "job";
    const GLANCE: &'static [&'static str] = &["conclusion", "took"];

    fn val(&self, col: &str) -> Val {
        let text = |s: &str| match s {
            "" => Val::None,
            s => Val::Text(s.to_string()),
        };
        match col {
            "started" => self.started.map(|t| t as f64).into(),
            "repo" => text(&self.repo),
            "job" => text(&self.job),
            "runner" => text(&self.runner),
            "conclusion" => text(&self.conclusion),
            "took" => self.took.map(|t| t as f64).into(),
            _ => Val::None,
        }
    }
    fn in_state(&self, s: &str) -> bool {
        self.conclusion == s
    }
    fn link(&self, col: &str) -> Option<Link> {
        match col {
            "job" => self.url.clone().map(Link::Url),
            _ => Some(Link::to(Kind::CiRun, self.run_id.to_string())),
        }
    }
}

/// One machine's page.
#[derive(Serialize, Debug, Clone, Default)]
pub struct MachinePage {
    pub host: String,
    /// When it was read, unix seconds.
    pub at: u64,
    /// Every name it goes by, its Prometheus host first: the history and alerts match on these.
    pub names: Vec<String>,
    /// The header line: `workstation, local, up`.
    pub head: String,
    pub machine: Machine,
    pub parts: Vec<Part>,
    /// Its cores, which the slots rows' cores add up to when it has a reading.
    pub cores: Option<f64>,
    pub slots: Vec<SlotUse>,
    /// Its busy CI slots and local gates, as the slots table has them.
    pub running: Vec<Slot>,
    pub history: Option<HostHistory>,
    /// Its sensors, fans, pods, services, containers and busiest processes now.
    pub live: Option<HostNow>,
    pub recent: Vec<RecentJob>,
    pub alerts: Vec<Alert>,
    /// `<part>: <why>` for each part that could not be read; the rest still show.
    pub errors: Vec<String>,
}

/// The machine `host` names, as the Machines table has it, through `Infra::aliases`.
pub fn find<'a>(infra: &'a Infra, host: &str) -> Result<&'a Machine, String> {
    let h = infra::host(&infra.aliases(), host);
    infra
        .machines
        .iter()
        .find(|m| m.host == h)
        .ok_or_else(|| format!("{NO_MACHINE} {host}"))
}

/// Its host, then every other name a series gives it: the hostnames `Infra::aliases` maps to it
/// and the hosts its runners and governor report.
pub fn names(infra: &Infra, host: &str) -> Vec<String> {
    let alias = infra.aliases();
    let mut out = vec![host.to_string()];
    let mut more: Vec<&str> = alias
        .iter()
        .filter(|(_, h)| h.as_str() == host)
        .map(|(n, _)| n.as_str())
        .collect();
    more.sort();
    for n in more {
        if !out.iter().any(|o| o == n) {
            out.push(n.to_string());
        }
    }
    out
}

/// Read the page; the one error is a name no machine has. The machine comes from `infra`, its history from Prometheus, its recent jobs from
/// the archive at `jobs`, its alerts from the firing ones in `alerts`, or why they were not read.
pub fn read(
    infra: &Infra,
    host: &str,
    alerts: Result<&[Alert], String>,
    jobs: &Path,
    now: u64,
) -> Result<MachinePage, String> {
    let m = find(infra, host)?;
    let names = names(infra, &m.host);
    let powered = m.power.as_ref().map(|p| p.host.as_str());
    let (history, live) = std::thread::scope(|s| {
        let live = s.spawn(|| host_now::read(&names));
        let history = host_history::read(&names, powered, now);
        (
            history,
            live.join().unwrap_or_else(|_| Err("panicked".into())),
        )
    });
    let archive = std::fs::read_to_string(jobs).map_err(|e| format!("{}: {e}", jobs.display()));
    Ok(build(infra, m, names, history, live, archive, alerts, now))
}

/// The page from what was read: pure, for the tests.
#[allow(clippy::too_many_arguments)]
pub fn build(
    infra: &Infra,
    m: &Machine,
    names: Vec<String>,
    history: Result<HostHistory, String>,
    live: Result<HostNow, String>,
    archive: Result<String, String>,
    alerts: Result<&[Alert], String>,
    now: u64,
) -> MachinePage {
    let mut errors = vec![];
    let runners = runners(infra, &m.host);
    let history = history
        .map(|mut h| {
            errors.append(&mut h.errors);
            h
        })
        .map_err(|e| errors.push(format!("history: {e}")))
        .ok();
    let live = live
        .inspect(|h| errors.extend(h.unread.iter().map(|(part, why)| format!("{part}: {why}"))))
        .map_err(|e| errors.push(format!("now: {e}")))
        .ok();
    let recent = archive
        .map(|text| recent(&text, &runners, &names))
        .map_err(|e| errors.push(format!("ci jobs: {e}")))
        .unwrap_or_default();
    let alerts = alerts
        .map(|a| naming(a, &names))
        .map_err(|e| errors.push(format!("alerts: {e}")))
        .unwrap_or_default();
    MachinePage {
        host: m.host.clone(),
        at: now,
        head: format!("{}, {}, {}", m.host, m.place, m.state),
        parts: parts(m, infra.grafana.as_deref(), now),
        cores: m.cores,
        slots: slots(infra, m),
        running: infra
            .ci
            .rows
            .iter()
            .filter(|s| s.host == m.host && s.state == "busy")
            .cloned()
            .collect(),
        names,
        machine: m.clone(),
        history,
        live,
        recent,
        alerts,
        errors,
    }
}

/// Its runners' names, from the runner series.
fn runners(infra: &Infra, host: &str) -> HashSet<String> {
    let alias = infra.aliases();
    infra
        .get("runners")
        .iter()
        .filter(|s| infra::host(&alias, s.label("host")) == host)
        .map(|s| s.label("name").to_string())
        .collect()
}

/// `45%`.
fn pct(r: f64) -> String {
    format!("{:.0}%", r * 100.0)
}

/// A unix time as a date and clock: `Nov 11 18:15`.
fn when(epoch: i64) -> String {
    Local
        .timestamp_opt(epoch, 0)
        .single()
        .map_or("?".into(), |t| t.format("%b %d %H:%M").to_string())
}

/// Why a machine has no reading, as the Now part says it.
fn why_no_reading(m: &Machine) -> String {
    match m.power.as_ref().map(|p| p.state.as_str()) {
        Some(s) if !s.is_empty() && s != "running" => format!("the governor has it {s}"),
        _ => "Prometheus has no node exporter series for it".into(),
    }
}

/// Its row as labelled parts: Now, Slots, Governor, Power, Up since, Grafana.
fn parts(m: &Machine, grafana: Option<&str>, at: u64) -> Vec<Part> {
    let mut out = vec![];
    let now = match m.cpu {
        Some(cpu) => {
            let mut bits = vec![format!("cpu {}", pct(cpu))];
            if let Some(l) = m.load {
                bits.push(match m.cores {
                    Some(c) => format!("load {l:.1} of {c:.0} cores"),
                    None => format!("load {l:.1}"),
                });
            }
            bits.extend(m.temp.map(|v| format!("{v:.0}C")));
            Part::new("Now", bits.join(", ")).warn(cpu >= 0.9)
        }
        None => Part::new(
            "Now",
            format!("{}: {}", crate::reading::NO_DATA, why_no_reading(m)),
        )
        .warn(true),
    };
    out.push(now);
    out.extend(space(m));
    if m.carries_ci() || m.off > 0 {
        let mut t = format!("{} busy", m.busy_cell());
        if !m.doing.is_empty() {
            t = format!("{t}: {}", m.doing.join(", "));
        }
        if m.off > 0 {
            t = format!("{t}; {} off", m.off);
        }
        out.push(Part::new("Slots", t).warn(m.off > 0));
    }
    if let Some(g) = &m.governor {
        let mut t = g.says();
        if !g.verdict.is_empty() {
            t = format!("{t} ({})", g.verdict);
        }
        if let Some(a) = g.admitted {
            t = format!("{t}, admits {a:.0}");
        }
        out.push(Part::new("Governor", t));
    }
    if let Some(p) = &m.power {
        let mut t = p.state.clone();
        if !p.reason.is_empty() && p.reason != "none" {
            t = format!("{t} ({})", p.reason);
        }
        t = match p.max {
            Some(max) => format!("{t}, {:.1}h of {max:.0}h today", p.hours),
            None => format!("{t}, {:.1}h today", p.hours),
        };
        if let Some(usd) = p.usd_per_hour {
            t = format!("{t} at ${usd:.2}/h");
        }
        if !p.hold.is_empty() {
            let until = p.until.map(|u| format!(" until {}", when(u as i64)));
            t = format!("{t}; held {}{}", p.hold, until.unwrap_or_default());
        }
        if !p.rule.is_empty() {
            t = format!("{t}; {}", p.rule);
        }
        out.push(Part::new("Power", t).warn(!p.hold.is_empty()));
    }
    if let Some(b) = m.boot {
        let up = crate::text::age(at as i64 - b as i64);
        out.push(Part::new(
            "Up since",
            format!("{}, up {up}", when(b as i64)),
        ));
    }
    if let Some(g) = grafana {
        out.push(
            Part::new("Grafana", "its fleet board")
                .link(Link::Url(format!("{g}/d/{BOARD}?var-host={}", m.host))),
        );
    }
    out
}

/// Cores its CI jobs use, by the runners' busy cores.
fn ci_cores(m: &Machine) -> f64 {
    m.runner_cores.iter().map(|(_, c)| c).sum()
}

/// Its cores busy, never fewer than its CI jobs use (the two are read a scrape apart).
fn busy_cores(m: &Machine) -> Option<f64> {
    Some((m.cores? * m.cpu?).max(ci_cores(m)))
}

/// The Space part: `cores 6.9 of 16 busy (CI 5.8), mem 39 of 64G, disk 190 of 500G free`, each
/// reading it lacks said as no data; none for a machine with no reading at all.
fn space(m: &Machine) -> Option<Part> {
    if [m.cpu, m.mem_used, m.disk_avail]
        .iter()
        .all(Option::is_none)
    {
        return None;
    }
    let no = crate::reading::NO_DATA;
    let cores = match (busy_cores(m), m.cores) {
        (Some(b), Some(c)) if m.runner_cores.is_empty() => {
            format!("cores {} of {c:.0} busy", short(b))
        }
        (Some(b), Some(c)) => format!(
            "cores {} of {c:.0} busy (CI {})",
            short(b),
            short(ci_cores(m))
        ),
        _ => format!("cores {no}"),
    };
    let mem = match (m.mem_used, m.mem_total) {
        (Some(u), Some(t)) => format!("mem {} of {}G", whole(u / GIB), whole(t / GIB)),
        _ => format!("mem {no}"),
    };
    let disk = match (m.disk_avail, m.disk_size) {
        (Some(a), Some(s)) => format!("disk {} of {}G free", whole(a / GIB), whole(s / GIB)),
        _ => format!("disk {no}"),
    };
    // Amber on the disk and memory it prints, so the colour and the numbers are one reading.
    let low = matches!((m.disk_avail, m.disk_size), (Some(a), Some(s)) if s > 0.0 && a / s < DISK_LOW)
        || matches!((m.mem_used, m.mem_total), (Some(u), Some(t)) if t > 0.0 && u / t >= MEM_HIGH);
    Some(Part::new("Space", format!("{cores}, {mem}, {disk}")).warn(low))
}

/// Each runner on it by name, with its caps and what it uses, then the busy cores no runner
/// uses and the idle ones when it has a reading.
fn slots(infra: &Infra, m: &Machine) -> Vec<SlotUse> {
    let mut takes = infra.caps();
    let rule = |r: &str| infra.runner_use(r);
    let (busy, allowed) = (
        rule("cc:runner_cores_busy"),
        rule("cc:runner_cores_allowed"),
    );
    let (mem, mem_max) = (rule("cc:runner_mem_bytes"), rule("cc:runner_mem_max_bytes"));
    let (disk, age) = (
        rule("cc:runner_disk_bytes"),
        rule("cc:runner_disk_age_seconds"),
    );
    let mut out: Vec<SlotUse> = crate::ci::runners_now(infra)
        .into_iter()
        .filter(|r| r.host == m.host)
        .map(|r| {
            let n = r.name.as_str();
            SlotUse {
                takes: takes
                    .remove(n)
                    .unwrap_or_default()
                    .into_iter()
                    .map(String::from)
                    .collect(),
                cores: busy.get(n).copied(),
                cores_max: allowed.get(n).copied(),
                mem: mem.get(n).copied(),
                mem_max: mem_max.get(n).copied(),
                disk: disk.get(n).copied(),
                disk_age: age.get(n).copied(),
                now: r.state,
                job: r.job,
                slot: r.name,
                runner: true,
            }
        })
        .collect();
    out.sort_by(|a, b| {
        natural(&a.slot)
            .cmp(&natural(&b.slot))
            .then_with(|| a.slot.cmp(&b.slot))
    });
    if let (Some(cores), Some(busy)) = (m.cores, busy_cores(m)) {
        for (what, c) in [(OTHER, busy - ci_cores(m)), (IDLE, (cores - busy).max(0.0))] {
            out.push(SlotUse {
                slot: what.into(),
                cores: Some(c),
                ..SlotUse::default()
            });
        }
    }
    out
}

/// The CI jobs that ran on one of `runners`, or on a runner named after one of `names`
/// (`<name>-...`), newest first, the first `RECENT`.
fn recent(text: &str, runners: &HashSet<String>, names: &[String]) -> Vec<RecentJob> {
    let mine = |r: &str| {
        runners.contains(r)
            || names.iter().any(|n| {
                r.strip_prefix(n.as_str())
                    .is_some_and(|x| x.starts_with('-'))
            })
    };
    let probes: Vec<&str> = runners
        .iter()
        .map(String::as_str)
        .chain(names.iter().map(String::as_str))
        .collect();
    let (records, _) = run_detail::archive(text, |line| probes.iter().any(|p| line.contains(p)));
    let mut out: Vec<RecentJob> = records
        .into_values()
        .flat_map(|r| {
            let (run_id, repo) = (r.run_id, r.repo.clone());
            r.jobs.into_iter().map(move |j| (run_id, repo.clone(), j))
        })
        .filter(|(_, _, j)| j.runner_name.as_deref().is_some_and(mine))
        .map(|(run_id, repo, j)| {
            let started = run_detail::ts(&j.started_at);
            RecentJob {
                id: j.id,
                run_id,
                repo,
                job: j.name,
                runner: j.runner_name.unwrap_or_default(),
                conclusion: j.conclusion.unwrap_or_default(),
                started,
                took: run_detail::span(started, run_detail::ts(&j.completed_at)),
                url: j.url,
            }
        })
        .collect();
    out.sort_by(|a, b| {
        let key = |j: &RecentJob| {
            (
                Reverse(j.started),
                Reverse(j.run_id),
                j.id,
                j.took.is_none(),
            )
        };
        key(a).cmp(&key(b))
    });
    // A job in two records is one row, its finished copy when one has finished.
    let mut seen = HashSet::new();
    out.retain(|j| seen.insert(j.id));
    out.truncate(RECENT);
    out
}

/// `name` stands alone in `text`: not part of a longer name (`mini` is not in `mac-mini-2`).
fn names_word(text: &str, name: &str) -> bool {
    let part = |c: char| c.is_ascii_alphanumeric() || matches!(c, '-' | '_');
    text.match_indices(name).any(|(i, _)| {
        text[..i].chars().next_back().is_none_or(|c| !part(c))
            && text[i + name.len()..]
                .chars()
                .next()
                .is_none_or(|c| !part(c))
    })
}

/// The alerts that name the machine in what, where, about or evidence.
fn naming(alerts: &[Alert], names: &[String]) -> Vec<Alert> {
    alerts
        .iter()
        .filter(|a| {
            [&a.what, &a.place, &a.about, &a.evidence]
                .iter()
                .any(|t| names.iter().any(|n| names_word(t, n)))
        })
        .cloned()
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::machines::build as machines;
    use crate::machines::tests::{fleet, series};
    use serde_json::json;

    fn infra() -> Infra {
        let mut i = fleet();
        i.grafana = Some("https://grafana.example".into());
        i.instant.insert(
            "runner_use",
            series(vec![
                json!({"__name__": "cc:runner_cores_busy", "runner": "ws-unity-1", "v": "6"}),
            ]),
        );
        (i.machines, i.pools) = machines(&i);
        i
    }

    fn page(i: &Infra, host: &str, archive: &str, alerts: &[Alert]) -> MachinePage {
        let m = find(i, host).unwrap();
        let names = names(i, &m.host);
        build(
            i,
            m,
            names,
            Err("prometheus down".into()),
            Err("prometheus down".into()),
            Ok(archive.into()),
            Ok(alerts),
            1000,
        )
    }

    #[test]
    fn an_unknown_name_is_no_machine() {
        assert_eq!(find(&infra(), "nope").unwrap_err(), "no machine named nope");
    }

    #[test]
    fn a_hostname_finds_the_machine_prometheus_names() {
        let i = infra();
        assert_eq!(find(&i, "cachyos-x8664-main").unwrap().host, "workstation");
        assert_eq!(
            names(&i, "workstation"),
            ["workstation", "cachyos-x8664-main"]
        );
    }

    #[test]
    fn a_host_with_no_exporter_says_why_it_has_no_reading() {
        let i = infra();
        let p = page(&i, "mac-mini", "", &[]);
        assert_eq!(p.parts[0].label, "Now");
        assert_eq!(
            p.parts[0].text,
            "no data: Prometheus has no node exporter series for it"
        );
        assert!(p.parts[0].warn);
        let p = page(&i, "aws-burst-1", "", &[]);
        assert_eq!(p.parts[0].text, "no data: the governor has it stopped");
        assert!(p.parts.iter().any(|x| x.label == "Power"));
        // No reading, so no other or idle: only its runner, its use no data.
        let names: Vec<&str> = p.slots.iter().map(|x| x.slot.as_str()).collect();
        assert_eq!(names, ["burst-1"]);
        assert_eq!(p.slots[0].cores_text(), crate::reading::NO_DATA);
    }

    #[test]
    fn the_page_reads_its_row_and_links_its_board() {
        let p = page(&infra(), "workstation", "", &[]);
        assert_eq!(p.head, "workstation, local, up");
        let now = &p.parts[0];
        assert!(now.text.starts_with("cpu 62%, "), "{}", now.text);
        assert!(now.text.contains("71C"));
        let gov = p.parts.iter().find(|x| x.label == "Governor").unwrap();
        assert_eq!(gov.text, "withhold (hot)");
        let g = p.parts.iter().find(|x| x.label == "Grafana").unwrap();
        assert_eq!(
            g.link,
            Some(Link::Url(
                "https://grafana.example/d/kb-fleet?var-host=workstation".into()
            ))
        );
        assert_eq!(
            p.errors,
            ["history: prometheus down", "now: prometheus down"]
        );
    }

    const G: f64 = GIB;

    /// The fleet with ws-unity-1's use read and taking two caps, ws-unity-2 read for nothing,
    /// and the workstation's memory and disk in bytes.
    fn used() -> Infra {
        let mut i = infra();
        let use_of = |rule: &str, v: f64| json!({"__name__": rule, "host": "workstation", "runner": "ws-unity-1", "v": v.to_string()});
        i.instant.insert(
            "runner_use",
            series(vec![
                use_of("cc:runner_cores_busy", 6.0),
                use_of("cc:runner_cores_allowed", 8.0),
                use_of("cc:runner_mem_bytes", 2.0 * G),
                use_of("cc:runner_mem_max_bytes", 14.0 * G),
                use_of("cc:runner_disk_bytes", 58.0 * G),
                use_of("cc:runner_disk_age_seconds", 600.0),
            ]),
        );
        let cap = |name: &str, pool: &str| {
            json!({"__name__": "github_runner_pool_slot", "host": "cachyos-x8664-main",
                "name": name, "pool": pool, "state": "running"})
        };
        i.instant
            .get_mut("runner_caps")
            .unwrap()
            .extend(series(vec![cap("ws-unity-1", "light")]));
        let host = |rule: &str, v: f64| json!({"__name__": rule, "host": "workstation", "v": v.to_string()});
        i.instant.get_mut("cc").unwrap().extend(series(vec![
            host("cc:host_mem_used_bytes", 39.0 * G),
            host("cc:host_mem_total_bytes", 64.0 * G),
            host("cc:host_disk_avail_bytes", 190.0 * G),
            host("cc:host_disk_size_bytes", 500.0 * G),
        ]));
        (i.machines, i.pools) = machines(&i);
        i
    }

    #[test]
    fn slots_are_each_runner_by_name_then_other_then_idle_adding_to_its_cores() {
        let i = used();
        let p = page(&i, "workstation", "", &[]);
        let s = &p.slots;
        let names: Vec<&str> = s.iter().map(|x| x.slot.as_str()).collect();
        assert_eq!(names, ["ws-unity-1", "ws-unity-2", OTHER, IDLE]);
        // The Machines row's runners hover reads the same memory.
        assert_eq!(p.machine.runner_mem, [("ws-unity-1".to_string(), 2.0 * G)]);
        assert_eq!(s[0].takes, ["unity", "light"]);
        assert_eq!((s[0].now.as_str(), s[1].now.as_str()), ("busy", "withheld"));
        assert_eq!(
            (s[0].cores_text(), s[0].mem_text(), s[0].disk_text()),
            ("6.0/8".into(), "2.0/14G".into(), "58G".into())
        );
        // 24 cores at 62% is 14.88 busy: 6 of them the runner's.
        assert!((s[2].cores.unwrap() - 8.88).abs() < 1e-9);
        let total: f64 = s.iter().filter_map(|x| x.cores).sum();
        assert!((total - 24.0).abs() < 1e-9);
        assert_eq!(
            (s[3].cores_text(), s[3].mem_text()),
            ("9.1".into(), String::new())
        );
    }

    /// The negative control: a runner with no series reads no data, never 0.
    #[test]
    fn a_runner_with_no_use_series_reads_no_data_never_zero() {
        let p = page(&used(), "workstation", "", &[]);
        let r = p.slots.iter().find(|x| x.slot == "ws-unity-2").unwrap();
        assert_eq!((r.cores, r.mem, r.disk), (None, None, None));
        for t in [r.cores_text(), r.mem_text(), r.disk_text()] {
            assert_eq!(t, crate::reading::NO_DATA);
        }
        // A runner series of 0 is a reading, and says 0.
        let mut i = used();
        i.instant.insert(
            "runner_use",
            series(vec![
                json!({"__name__": "cc:runner_mem_bytes", "runner": "ws-unity-2", "v": "0"}),
            ]),
        );
        let p = page(&i, "workstation", "", &[]);
        let r = p.slots.iter().find(|x| x.slot == "ws-unity-2").unwrap();
        assert_eq!(r.mem_text(), "0G");
    }

    #[test]
    fn space_says_cores_mem_and_disk_in_gigabytes_and_no_data_for_what_it_lacks() {
        let i = used();
        let p = page(&i, "workstation", "", &[]);
        let sp = p.parts.iter().find(|x| x.label == "Space").unwrap();
        assert_eq!(
            sp.text,
            "cores 14.9 of 24 busy (CI 6.0), mem 39 of 64G, disk 190 of 500G free"
        );
        assert!(!p.parts[0].text.contains("mem"), "{}", p.parts[0].text);
        let p = page(&i, "raspberrypi", "", &[]);
        let sp = p.parts.iter().find(|x| x.label == "Space").unwrap();
        assert_eq!(sp.text, "cores 0.2 of 4 busy, mem no data, disk no data");
        // No reading at all: Now says why, and there is no Space part.
        let p = page(&i, "mac-mini", "", &[]);
        assert!(p.parts.iter().all(|x| x.label != "Space"));
    }

    #[test]
    fn a_half_rounds_up_as_the_web_does_and_slot_ten_sorts_after_slot_two() {
        assert_eq!(used_of(Some(2.8), Some(2.5), 1.0, ""), "2.8/3");
        assert_eq!(used_of(Some(2.25), None, 1.0, ""), "2.3");
        assert_eq!(whole(12.5), "13");
        let mut names = ["ws-unity-10", "ws-unity-2", "ws-light-1", "ws-unity-1"];
        names.sort_by(|a, b| natural(a).cmp(&natural(b)));
        assert_eq!(
            names,
            ["ws-light-1", "ws-unity-1", "ws-unity-2", "ws-unity-10"]
        );
    }

    #[test]
    fn space_is_amber_on_the_disk_it_prints_not_another_disk() {
        let m = |avail: f64, fullest: f64| Machine {
            host: "h".into(),
            cpu: Some(0.1),
            cores: Some(4.0),
            disk_avail: Some(avail * GIB),
            disk_size: Some(100.0 * GIB),
            disk: Some(fullest),
            ..Machine::default()
        };
        // 38% free on the printed disk while another disk is at 5%: plain.
        assert!(!space(&m(38.0, 0.05)).unwrap().warn);
        // 10% free on the printed disk: amber, whatever the fullest one says.
        assert!(space(&m(10.0, 0.5)).unwrap().warn);
    }

    #[test]
    fn recent_jobs_are_the_hosts_runners_newest_first() {
        let i = infra();
        let line = |run: u64, runner: &str, start: &str| {
            format!(
                r#"{{"forge":"github","repo":"o/r","run_id":{run},"attempt":1,"jobs":[{{"id":{run}0,"name":"Tests","conclusion":"success","runner_name":"{runner}","started_at":"{start}","completed_at":"2026-11-11T10:10:00Z","url":"https://gh/j/{run}"}}]}}"#
            )
        };
        let text = [
            line(1, "ws-unity-1", "2026-11-11T10:00:00Z"),
            line(2, "mini-1", "2026-11-11T10:01:00Z"),
            line(3, "ws-unity-2", "2026-11-11T10:05:00Z"),
            line(4, "cachyos-x8664-main-gate", "2026-11-11T10:02:00Z"),
        ]
        .join("\n");
        let p = page(&i, "workstation", &text, &[]);
        let ids: Vec<u64> = p.recent.iter().map(|j| j.run_id).collect();
        assert_eq!(ids, [3, 4, 1]);
        assert_eq!(p.recent[2].took, Some(600));
        assert_eq!(
            p.recent[0].link("job"),
            Some(Link::Url("https://gh/j/3".into()))
        );
        assert_eq!(p.recent[0].link("repo"), Some(Link::to(Kind::CiRun, "3")));
    }

    #[test]
    fn alerts_are_the_ones_naming_it_as_a_whole_word() {
        let a = |what: &str| Alert {
            what: what.into(),
            ..Default::default()
        };
        let alerts = [
            a("workstation is hot"),
            a("workstation-2 is hot"),
            a("disk full on cachyos-x8664-main."),
            a("all quiet"),
        ];
        let p = page(&infra(), "workstation", "", &alerts);
        let what: Vec<&str> = p.alerts.iter().map(|x| x.what.as_str()).collect();
        assert_eq!(
            what,
            ["workstation is hot", "disk full on cachyos-x8664-main."]
        );
    }
}
