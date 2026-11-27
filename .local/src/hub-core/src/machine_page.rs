//! One machine's page on both surfaces (`#infra/machines/<host>`): its Machines row as labelled
//! parts, its fixed runners and the CI job pods on it by kind, the CI jobs running there, its last `DAYS` days
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
use crate::workload::{self, HostSplit};

/// What the page says for a name the Machines table does not have.
pub const NO_MACHINE: &str = "no machine named";
/// The Grafana board one machine's link opens, by its uid; `var-host` picks the machine.
pub const BOARD: &str = "kb-fleet";
/// The most recent CI jobs the page lists.
pub const RECENT: usize = 50;
const GIB: f64 = 1024.0 * 1024.0 * 1024.0;

/// One fixed runner on the machine, one kind of CI job pod placed on it (`JobPod::kind`, the
/// scale set or ScaledJob), or one class of the rest of the machine (`workload`: apps, agents,
/// docker, other, free). No series gives one runner or pod's real use (hc-1127), so a pod row
/// says what its pods request and a runner row says no cores; the node's real use is the Space
/// part.
#[derive(Serialize, Debug, PartialEq, Clone, Default)]
pub struct SlotUse {
    /// The runner's name, the pod kind, or a class of `workload::CLASSES`.
    pub slot: String,
    /// A runner as `ci::runners_now` says it (busy, idle or off); a pod kind `busy` while one of
    /// its pods runs a job, `starting` while placed and not yet running, `reserved` for a
    /// reservation pod (`JobPod::reserved`).
    pub now: String,
    /// A runner's job, or how many pods of the kind: `3 pods`.
    pub job: String,
    /// The cores and bytes the kind's pods request there, or a class uses.
    pub cores: Option<f64>,
    pub mem: Option<f64>,
}

/// `0`, `2.8`, `140`: a reading as the slots table and the Space line say it. Halves round up,
/// as the web's `toFixed` and `Math.round` do (Rust's `{:.0}` rounds a tie to even).
pub(crate) fn short(v: f64) -> String {
    if v == 0.0 {
        "0".into()
    } else if v < 100.0 {
        format!("{:.1}", (v * 10.0).round() / 10.0)
    } else {
        whole(v)
    }
}

/// A whole number, a half rounded up: `12.5` is `13` on both surfaces.
pub(crate) fn whole(v: f64) -> String {
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

impl SlotUse {
    /// Its cores, empty where it has none.
    pub fn cores_text(&self) -> String {
        self.cores.map(short).unwrap_or_default()
    }
    /// Its memory, empty where it has none.
    pub fn mem_text(&self) -> String {
        self.mem
            .map(|m| format!("{}G", short(m / GIB)))
            .unwrap_or_default()
    }
}

/// The slots table on both surfaces: each fixed runner by name, the job pods by kind, then the
/// rest of the machine by class.
impl Row for SlotUse {
    const COLUMNS: &'static [&'static str] = &["slot", "now", "job", "cores", "mem"];
    const STATES: &'static [&'static str] = &["all", "busy", "idle", "starting", "reserved", "off"];
    const FACETS: &'static [&'static str] = &["now"];
    const HIDE_EMPTY: bool = true;
    const LEAD: &'static str = "slot";
    const GLANCE: &'static [&'static str] = &["now", "cores", "mem"];

    fn val(&self, col: &str) -> Val {
        let text = Val::word;
        match col {
            "slot" => text(&self.slot),
            "now" => text(&self.now),
            "job" => text(&self.job),
            "cores" => self.cores.into(),
            "mem" => self.mem.into(),
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
        let text = Val::word;
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
    /// The slots heading on both surfaces (`slots_head`): `1 of 2 runners busy, 4 pods`.
    pub slots_head: String,
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
/// and the hosts its runners report.
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
    let (history, live) = std::thread::scope(|s| {
        let live = s.spawn(|| host_now::read(&names));
        let history = host_history::read(&names, now);
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
            errors.extend(h.down_unread.iter().map(|why| format!("down: {why}")));
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
    let (slots, slots_head) = slots(infra, m);
    MachinePage {
        host: m.host.clone(),
        at: now,
        head: format!("{}, {}, {}", m.host, m.place, m.state),
        parts: parts(m, infra.space.host(&m.host), infra.grafana.as_deref(), now),
        cores: m.cores,
        slots,
        slots_head,
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

/// Its row as labelled parts: Now, Space, CI, Up since, Grafana.
fn parts(m: &Machine, split: Option<&HostSplit>, grafana: Option<&str>, at: u64) -> Vec<Part> {
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
            format!(
                "{}: Prometheus has no node exporter series for it",
                crate::reading::NO_DATA
            ),
        )
        .warn(true),
    };
    out.push(now);
    out.extend(space(m, split));
    if m.carries_ci() || m.off > 0 {
        let mut t = match m.booked {
            Some(b) => format!("{} booked, {} running", b.cell(), m.busy),
            None => format!("{} running", m.busy),
        };
        if !m.running.is_empty() {
            t = format!("{t}: {}", m.running.join(", "));
        }
        if let Some(n) = &m.next {
            t = format!("{t}; next {}", n.line(crate::display::fmt::age));
        }
        if m.off > 0 {
            t = format!("{t}; {} off", m.off);
        }
        out.push(Part::new("CI", t).warn(m.off > 0));
    }
    if let Some(b) = m.boot {
        let up = crate::display::fmt::age(at as i64 - b as i64);
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

/// The Space part: `cores 6.9 of 16 busy (ci 5.8, apps 0.4), mem 39 of 64G, disk 190 of 500G
/// free`, the classes being the machine's split (`workload`) and each reading it lacks said as
/// no data; none for a machine with no reading at all.
fn space(m: &Machine, split: Option<&HostSplit>) -> Option<Part> {
    if [m.cpu, m.mem_used, m.disk_avail]
        .iter()
        .all(Option::is_none)
    {
        return None;
    }
    let no = crate::reading::NO_DATA;
    // Each class using cores, the free ones left out: what the busy cores are.
    let used: Vec<String> = split
        .into_iter()
        .flat_map(|h| &h.classes)
        .filter(|u| u.class != "free")
        .filter_map(|u| {
            Some(format!(
                "{} {}",
                u.class,
                short(u.cores.filter(|c| *c > 0.0)?)
            ))
        })
        .collect();
    let cores = match (workload::busy_cores(m), m.cores) {
        (Some(b), Some(c)) if used.is_empty() => format!("cores {} of {c:.0} busy", short(b)),
        (Some(b), Some(c)) => format!("cores {} of {c:.0} busy ({})", short(b), used.join(", ")),
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

/// Each fixed runner on it by name (an ARC runner is its pod, so it is no row of its own), then
/// its job pods by kind with what they request, then the rest of the machine by class
/// (`workload`), the CI class being the rows above; no class rows when it has no split. With
/// them, their heading (`slots_head`).
fn slots(infra: &Infra, m: &Machine) -> (Vec<SlotUse>, String) {
    let mut out: Vec<SlotUse> = crate::ci::runners_now(infra)
        .into_iter()
        .filter(|r| r.host == m.host && infra.pod(&r.name).is_none())
        .map(|r| SlotUse {
            now: r.state,
            job: r.job,
            slot: r.name,
            ..SlotUse::default()
        })
        .collect();
    out.sort_by(|a, b| {
        natural(&a.slot)
            .cmp(&natural(&b.slot))
            .then_with(|| a.slot.cmp(&b.slot))
    });
    let runners = out.len();
    let busy = out.iter().filter(|s| s.now == "busy").count();
    // (kind, now) -> pods, cores, bytes.
    let mut pods: std::collections::BTreeMap<(&str, &str), (u32, f64, f64)> = Default::default();
    for p in infra.pods.iter().filter(|p| p.node == m.host) {
        let now = match (p.reserved, p.running) {
            (true, _) => "reserved",
            (false, true) => "busy",
            (false, false) => "starting",
        };
        let e = pods.entry((p.kind.as_str(), now)).or_default();
        *e = (e.0 + 1, e.1 + p.cpu, e.2 + p.mem);
    }
    let placed = pods.values().map(|(n, ..)| *n as usize).sum();
    for ((kind, now), (n, cpu, mem)) in pods {
        out.push(SlotUse {
            slot: kind.into(),
            now: now.into(),
            job: crate::display::fmt::counted(n as usize, "pod"),
            cores: Some(cpu),
            mem: Some(mem),
        });
    }
    for u in infra
        .space
        .host(&m.host)
        .into_iter()
        .flat_map(|h| &h.classes)
        .filter(|u| u.class != "ci")
    {
        out.push(SlotUse {
            slot: u.class.into(),
            cores: u.cores,
            mem: u.mem,
            ..SlotUse::default()
        });
    }
    (out, slots_head(runners, busy, placed))
}

/// The slots heading: the fixed runners busy of all of them, then the job pods placed there
/// (`1 of 2 runners busy, 4 pods`); empty with neither. A pod kind's row is its pods, never a
/// runner.
fn slots_head(runners: usize, busy: usize, pods: usize) -> String {
    use crate::display::fmt::counted;
    let mut out = vec![];
    if runners > 0 {
        out.push(format!("{busy} of {} busy", counted(runners, "runner")));
    }
    if pods > 0 {
        out.push(counted(pods, "pod"));
    }
    out.join(", ")
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
        // No reading, so no other or idle: only its runner, which requests nothing.
        let p = page(&i, "aws-burst-1", "", &[]);
        let slots: Vec<(&str, &str)> = p
            .slots
            .iter()
            .map(|x| (x.slot.as_str(), x.now.as_str()))
            .collect();
        assert_eq!(slots, [("burst-1", "off")]);
        assert_eq!(p.slots[0].cores_text(), "");
    }

    #[test]
    fn the_page_reads_its_row_and_links_its_board() {
        let p = page(&infra(), "workstation", "", &[]);
        assert_eq!(p.head, "workstation, local, up");
        let now = &p.parts[0];
        assert!(now.text.starts_with("cpu 62%, "), "{}", now.text);
        assert!(now.text.contains("71C"));
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

    #[test]
    fn downtime_records_not_read_are_a_page_error_and_stay_on_the_history() {
        let i = infra();
        let m = find(&i, "workstation").unwrap();
        let h = HostHistory {
            down_unread: Some("Loki answer 503".into()),
            ..HostHistory::default()
        };
        let p = build(
            &i,
            m,
            names(&i, &m.host),
            Ok(h),
            Err("prometheus down".into()),
            Ok(String::new()),
            Ok(&[]),
            1000,
        );
        assert_eq!(p.errors, ["down: Loki answer 503", "now: prometheus down"]);
        let h = p.history.unwrap();
        assert_eq!(h.down_unread.as_deref(), Some("Loki answer 503"));
    }

    const G: f64 = GIB;

    /// The fleet with two light job pods and the Unity slot's reservation on the workstation,
    /// one light pod still starting there, one placed on another node, and the workstation's
    /// memory and disk in bytes.
    fn used() -> Infra {
        let mut i = infra();
        let pod = |name: &str, kind: &str, node: &str, running: bool, reserved: bool, cpu: f64| {
            crate::jobpods::JobPod {
                name: name.into(),
                kind: kind.into(),
                node: node.into(),
                running,
                reserved,
                cpu,
                mem: 4.0 * G,
            }
        };
        i.pods = vec![
            pod("light-a", "arc-org-light", "workstation", true, false, 1.5),
            pod("light-b", "arc-org-light", "workstation", true, false, 1.5),
            pod("slot", "ci-build-slot", "workstation", true, true, 3.0),
            pod("light-c", "arc-org-light", "workstation", false, false, 1.5),
            pod("light-d", "arc-org-light", "tuf-b550", true, false, 1.5),
        ];
        let host = |rule: &str, v: f64| json!({"__name__": rule, "host": "workstation", "v": v.to_string()});
        i.instant.get_mut("cc").unwrap().extend(series(vec![
            host("cc:host_mem_used_bytes", 39.0 * G),
            host("cc:host_mem_total_bytes", 64.0 * G),
            host("cc:host_disk_avail_bytes", 190.0 * G),
            host("cc:host_disk_size_bytes", 500.0 * G),
        ]));
        // The split `workload` reads: 14.88 cores busy, CI's 6 among them.
        let class = |rule: &str, class: &str, v: f64| json!({"__name__": rule, "host": "workstation", "class": class, "v": v.to_string()});
        i.instant.get_mut("cc").unwrap().extend(series(vec![
            class("cc:host_class_cores", "ci", 6.0),
            class("cc:host_class_cores", "apps", 1.0),
            class("cc:host_class_mem_bytes", "apps", 4.0 * G),
            class("cc:host_class_cores", "agents", 0.8),
            class("cc:host_class_cores", "other", 7.08),
            class("cc:host_class_cores", "free", 9.12),
        ]));
        (i.machines, i.pools) = machines(&i);
        i.space = workload::build(&i, &i.machines);
        i
    }

    #[test]
    fn slots_are_each_fixed_runner_then_the_job_pods_by_kind_then_the_other_classes() {
        let i = used();
        let p = page(&i, "workstation", "", &[]);
        let s = &p.slots;
        let rows: Vec<(&str, &str, &str)> = s
            .iter()
            .map(|x| (x.slot.as_str(), x.now.as_str(), x.job.as_str()))
            .collect();
        assert_eq!(
            rows,
            [
                ("ws-unity-1", "busy", "-"),
                ("ws-unity-2", "idle", ""),
                ("arc-org-light", "busy", "2 pods"),
                ("arc-org-light", "starting", "1 pod"),
                ("ci-build-slot", "reserved", "1 pod"),
                ("apps", "", ""),
                ("agents", "", ""),
                ("other", "", ""),
                ("free", "", "")
            ]
        );
        assert_eq!(p.slots_head, "1 of 2 runners busy, 4 pods");
        // A fixed runner requests nothing; a kind's row is what its pods request.
        assert_eq!(
            (s[0].cores_text(), s[0].mem_text()),
            (String::new(), String::new())
        );
        assert_eq!(
            (s[2].cores_text(), s[2].mem_text()),
            ("3.0".into(), "8.0G".into())
        );
        // The classes and the pods placed and running add to the machine's 24.
        let total: f64 = s
            .iter()
            .filter(|x| x.now != "starting")
            .filter_map(|x| x.cores)
            .sum();
        assert!((total - 24.0).abs() < 1e-9);
        assert_eq!(
            (s[5].cores_text(), s[5].mem_text()),
            ("1.0".into(), "4.0G".into())
        );
        assert_eq!(
            (s[8].cores_text(), s[8].mem_text()),
            ("9.1".into(), String::new())
        );
    }

    #[test]
    fn space_says_cores_mem_and_disk_in_gigabytes_and_no_data_for_what_it_lacks() {
        let i = used();
        let p = page(&i, "workstation", "", &[]);
        let sp = p.parts.iter().find(|x| x.label == "Space").unwrap();
        assert_eq!(
            sp.text,
            "cores 14.9 of 24 busy (ci 6.0, apps 1.0, agents 0.8, other 7.1), mem 39 of 64G, disk 190 of 500G free"
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
        assert!(!space(&m(38.0, 0.05), None).unwrap().warn);
        // 10% free on the printed disk: amber, whatever the fullest one says.
        assert!(space(&m(10.0, 0.5), None).unwrap().warn);
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
