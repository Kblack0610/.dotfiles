//! One machine's page on both surfaces (`#infra/machines/<host>`): its Machines row as labelled
//! parts, the cores each runner pool uses there, the CI jobs running there, its last `DAYS` days
//! and downtime (`host_history`), the CI jobs that ran there (the jobs archive), the alerts that
//! name it and its Grafana board. hub-core reads it; agent-web and the TUI only draw it.

use std::collections::{BTreeMap, HashMap, HashSet};
use std::path::Path;

use chrono::{Local, TimeZone};
use serde::Serialize;

use crate::alerts::Alert;
use crate::ci::Slot;
use crate::host_history::{self, HostHistory};
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
/// The share rows that are no pool.
pub const OTHER: &str = "other";
pub const IDLE: &str = "idle";

/// Cores one runner pool's jobs use there now, or `other` (busy, not a runner's) or `idle`.
#[derive(Serialize, Debug, PartialEq, Clone, Default)]
pub struct Share {
    pub what: String,
    pub cores: f64,
    pub link: Option<Link>,
}

/// One CI job that ran there, from the jobs archive.
#[derive(Serialize, Debug, PartialEq, Clone, Default)]
pub struct RecentJob {
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
    /// Its cores, which the share rows add up to when it has a reading.
    pub cores: Option<f64>,
    pub share: Vec<Share>,
    /// Its busy CI slots and local gates, as the slots table has them.
    pub running: Vec<Slot>,
    pub history: Option<HostHistory>,
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
    let history = host_history::read(&names, powered, now);
    let archive = std::fs::read_to_string(jobs).map_err(|e| format!("{}: {e}", jobs.display()));
    Ok(build(infra, m, names, history, archive, alerts, now))
}

/// The page from what was read: pure, for the tests.
pub fn build(
    infra: &Infra,
    m: &Machine,
    names: Vec<String>,
    history: Result<HostHistory, String>,
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
        parts: parts(m, infra.grafana.as_deref()),
        cores: m.cores,
        share: share(m, &runners),
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
        recent,
        alerts,
        errors,
    }
}

/// Its runners, each with its pool, from the runner series.
fn runners(infra: &Infra, host: &str) -> HashMap<String, String> {
    let alias = infra.aliases();
    infra
        .get("runners")
        .iter()
        .filter(|s| infra::host(&alias, s.label("host")) == host)
        .map(|s| (s.label("name").to_string(), s.label("pool").to_string()))
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
fn parts(m: &Machine, grafana: Option<&str>) -> Vec<Part> {
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
            bits.extend(m.mem.map(|v| format!("mem {}", pct(v))));
            bits.extend(m.temp.map(|v| format!("{v:.0}C")));
            bits.extend(m.disk.map(|v| format!("disk {} free", pct(v))));
            Part::new("Now", bits.join(", ")).warn(cpu >= 0.9)
        }
        None => Part::new("Now", format!("no reading: {}", why_no_reading(m))).warn(true),
    };
    out.push(now);
    if m.carries_ci() || m.off > 0 {
        let mut t = format!("{} busy", m.busy_cell());
        if !m.pools.is_empty() {
            t = format!("{t}: {}", m.pools.join(", "));
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
        out.push(Part::new("Up since", when(b as i64)));
    }
    if let Some(g) = grafana {
        out.push(
            Part::new("Grafana", "its fleet board")
                .link(Link::Url(format!("{g}/d/{BOARD}?var-host={}", m.host))),
        );
    }
    out
}

/// Cores per pool from the runners' busy cores, then other (busy, no runner's), then idle.
fn share(m: &Machine, runners: &HashMap<String, String>) -> Vec<Share> {
    let mut by: BTreeMap<&str, f64> = BTreeMap::new();
    for (r, c) in &m.runner_cores {
        let pool = runners.get(r).map_or("", String::as_str);
        *by.entry(pool).or_default() += c;
    }
    let ci: f64 = by.values().sum();
    let mut out: Vec<Share> = by
        .into_iter()
        .filter(|(_, c)| *c > 0.0)
        .map(|(p, c)| Share {
            what: if p.is_empty() {
                "no pool".into()
            } else {
                p.into()
            },
            cores: c,
            link: (!p.is_empty()).then(|| Link::to(Kind::Pool, p)),
        })
        .collect();
    out.sort_by(|a, b| b.cores.total_cmp(&a.cores));
    if let (Some(cores), Some(cpu)) = (m.cores, m.cpu) {
        let busy = (cores * cpu).max(ci);
        out.push(Share {
            what: OTHER.into(),
            cores: busy - ci,
            link: None,
        });
        out.push(Share {
            what: IDLE.into(),
            cores: (cores - busy).max(0.0),
            link: None,
        });
    }
    out
}

/// The CI jobs that ran on one of `runners`, or on a runner named after one of `names`
/// (`<name>-...`), newest first, the first `RECENT`.
fn recent(text: &str, runners: &HashMap<String, String>, names: &[String]) -> Vec<RecentJob> {
    let mine = |r: &str| {
        runners.contains_key(r)
            || names.iter().any(|n| {
                r.strip_prefix(n.as_str())
                    .is_some_and(|x| x.starts_with('-'))
            })
    };
    let probes: Vec<&str> = runners
        .keys()
        .map(String::as_str)
        .chain(names.iter().map(String::as_str))
        .collect();
    let (records, _) = run_detail::archive(text, |line| probes.iter().any(|p| line.contains(p)));
    let mut seen = HashSet::new();
    let mut out: Vec<RecentJob> = records
        .into_values()
        .flat_map(|r| {
            let (run_id, repo) = (r.run_id, r.repo.clone());
            r.jobs.into_iter().map(move |j| (run_id, repo.clone(), j))
        })
        .filter(|(_, _, j)| j.runner_name.as_deref().is_some_and(mine))
        .filter(|(_, _, j)| seen.insert(j.id))
        .map(|(run_id, repo, j)| {
            let started = run_detail::ts(&j.started_at);
            RecentJob {
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
    out.sort_by(|a, b| b.started.cmp(&a.started).then(b.run_id.cmp(&a.run_id)));
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
            "runner_cores",
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
            "no reading: Prometheus has no node exporter series for it"
        );
        assert!(p.parts[0].warn);
        let p = page(&i, "aws-burst-1", "", &[]);
        assert_eq!(p.parts[0].text, "no reading: the governor has it stopped");
        assert!(p.parts.iter().any(|x| x.label == "Power"));
        // No reading, so no other or idle: only what the runners say.
        assert!(p.share.is_empty());
    }

    #[test]
    fn the_page_reads_its_row_and_links_its_board() {
        let p = page(&infra(), "workstation", "", &[]);
        assert_eq!(p.head, "workstation, local, up");
        let now = &p.parts[0];
        assert!(now.text.starts_with("cpu 62%, "), "{}", now.text);
        assert!(now.text.contains("71C"));
        let gov = p.parts.iter().find(|x| x.label == "Governor").unwrap();
        assert_eq!(gov.text, "live, withhold (hot)");
        let g = p.parts.iter().find(|x| x.label == "Grafana").unwrap();
        assert_eq!(
            g.link,
            Some(Link::Url(
                "https://grafana.example/d/kb-fleet?var-host=workstation".into()
            ))
        );
        assert_eq!(p.errors, ["history: prometheus down"]);
    }

    #[test]
    fn share_is_pools_then_other_then_idle_adding_to_its_cores() {
        let i = infra();
        let m = find(&i, "workstation").unwrap();
        let s = share(m, &runners(&i, "workstation"));
        let what: Vec<&str> = s.iter().map(|x| x.what.as_str()).collect();
        let total: f64 = s.iter().map(|x| x.cores).sum();
        // 24 cores at 62% is 14.88 busy: 6 of them unity's.
        assert_eq!(what, ["unity", OTHER, IDLE]);
        assert_eq!(s[0].link, Some(Link::to(Kind::Pool, "unity")));
        assert!((s[1].cores - 8.88).abs() < 1e-9);
        assert!((total - 24.0).abs() < 1e-9);
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
