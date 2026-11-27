//! The infra board's questions to Prometheus, asked once for both surfaces: the `hub`
//! TUI's Infra tab (and Home's health line) and agent-web's Infra tab. Both read the `cc:*` recording rules (home-config
//! `apps/monitoring/prometheus-rules-command-center.yaml`) and the runner-exporter series, as
//! Grafana's kb-command-center does, so none of them judges anything itself. Alertmanager is
//! asked in the same gather (`alertmanager::read`), so the Alerts tab's rules ride this cadence.

use std::collections::{BTreeMap, HashMap};

use serde::Serialize;

use crate::alertmanager::{self, Firing};
use crate::ci::{self, Ci};
use crate::home::{Chip, Level, ALWAYS, DOMAINS};
use crate::jobpods::{self, JobPod};
use crate::machines::{self, Machine, Pool};

use crate::prom::{self, Series, W};
use crate::run_detail::Rates;
use crate::workload::{self, Space};

/// Keeps a machine's run ledger series only while its textfile is fresh, as `cc:host_local_done_24h`.
const LOCAL_FRESH: &str =
    r#"and on (instance) (time() - node_textfile_mtime_seconds{file=~".*fleet_local.prom"} < 180)"#;

/// The board's queries, by name. All but `OPTIONAL` must answer or the tab shows the
/// error instead of numbers: a board blanks rather than leave stale values up.
/// fleet-bench's gauges, in one query so `vitals::fetch` can ask for them alone.
pub const BENCH_QUERY: &str =
    r#"{__name__=~"agent_bench_(waiting_hours|kpi|kpi_limit|kpi_past|kpi_subject|vital)"}"#;

pub fn instant_queries() -> Vec<(&'static str, String)> {
    vec![
        ("cc", r#"{__name__=~"cc:.+",__name__!~"cc:host_instance|cc:host_local_gate|cc:host_core_busy_ratio"}"#.into()),
        ("runners", format!("{W} (github_runner_state)")),
        // The kind of job each busy runner runs (unity, unity-build, light, heavy, forgejo, ...),
        // by `runner`. No row for an idle runner, or for a job whose labels name no kind.
        ("job_kind", "max by (runner, kind) (ci_runner_job)".into()),
        ("waiting", format!("{W} (github_actions_job_waiting)")),
        // The ephemeral pools (ARC scale sets, the KEDA forgejo-runner job) with their labels: no
        // runner of theirs is registered between jobs, so these hold the labels a waiting job asks
        // for (`ci::Pool`).
        ("pools", format!("{W} (ci_runner_pool)")),
        // GitHub answering the exporter's runner reads. The per-repo run-list sources are left
        // out: one failed call there leaves every runner row intact, so it is no reason to say
        // runner rows may be missing.
        ("api", r#"min(github_runner_exporter_api_ok{kind="runners"})"#.into()),
        // The exporter's last scrape. 0 or absent means every exporter series went stale, which
        // is a missed scrape, not GitHub down.
        ("exporter_up", r#"max(up{job="github-runner-exporter"})"#.into()),
        // Calls GitHub says the exporter's token has left this hour, its emptiest bucket. The
        // budget is per user, shared with every gh session, so 0 is the usual reason GitHub
        // stops answering (2026-11-03: repos at 0 from 21:25Z, every job unattributed).
        ("rate_left", "min(github_runner_exporter_rate_remaining)".into()),
        ("gates", "cc:host_local_gate".into()),
        // Each core's busy share, keyed by host and cpu, so it stays out of `cc` (keyed by host).
        ("cores", "cc:host_core_busy_ratio".into()),
        // The GitHub slots the topology gives each host (home-config ci-topology): a host with
        // none is no CI host, so its offline registrations are stale, not down.
        ("expected", format!("{W} (github_runner_pool_expected)")),
        // Each host's emptiest real filesystem, free share: the NodeDisk* alerts' recording
        // rule, keyed by host through cc:host_instance. A CI host with no row here (the AWS
        // hosts, never scraped) has no disk reading at all, and the machines table says so.
        ("disk", "min by (host) (device:node_filesystem_avail:ratio * on (instance) group_left (host) cc:host_instance)".into()),
        // What a workflow's job usually takes: the exporter's median and p90 over a day of finished
        // jobs, for the CI runners table's USUAL column.
        ("job_usual", r#"github_job_duration_seconds{forge!="forgejo"}"#.into()),
        // The CI job pods (ARC runners, the forgejo-runner jobs) with their phase, node and owner,
        // their requests, and each CI node's allocatable: the machine rows' booked CPU and memory and
        // the pods waiting for room (`jobpods`).
        ("job_pods", crate::jobpods::pods_query()),
        ("job_requests", crate::jobpods::requests_query()),
        ("ci_alloc", crate::jobpods::alloc_query()),
        // What the pods of other namespaces request on each CI node: taken units too.
        ("ci_other", crate::jobpods::other_query()),
        // Each node NotReady, quarantined (the degraded taint) or cordoned, for the machine rows'
        // state.
        ("node_state", crate::jobpods::node_state_query()),
        // Done today's hours, and the local Unity gate failures (Runners' Local Unity table). An
        // absent metric is an empty answer, so the tab says "no data" rather than an error until
        // the exporters publish them.
        ("hourly", format!("sum by (hour, conclusion, scope) ({W} (github_runs_by_hour))")),
        ("local_hourly", format!("sum by (hour, result) (fleet_local_gate_by_hour {LOCAL_FRESH})")),
        ("local_failed", format!("sum by (hour, repo, branch, platform, result) (fleet_local_gate_failed {LOCAL_FRESH})")),
        // What is red right now, one row per item: the home-config `cc:red_now` recording rule,
        // which the dashboard's "What is red" table and the waybar day chip also read.
        ("red", "cc:red_now".into()),
        // fleet-bench's window and KPIs, as it judged them, and which of them are the vitals: the
        // phone's agent lines and Home's Vitals.
        ("bench", BENCH_QUERY.into()),
        // Each node's hostname, keyed by host: a runner can name a machine by
        // its hostname (`cachyos-x8664-main`) where node_exporter names it `workstation`, so
        // `aliases` joins the two.
        ("uname", "group by (host, nodename) (node_uname_info * on (instance) group_left (host) cc:host_instance)".into()),
        // When each node last booted, for the machines table's UP column.
        ("boot", "max by (host) (node_boot_time_seconds * on (instance) group_left (host) cc:host_instance)".into()),
    ]
}
pub const OPTIONAL: &[&str] = &[
    "red",
    "bench",
    "exporter_up",
    "rate_left",
    "cores",
    "job_kind",
    "pools",
    "expected",
    "disk",
    "job_pods",
    "job_requests",
    "ci_alloc",
    "ci_other",
    "node_state",
    "job_usual",
    "uname",
    "boot",
];

#[derive(Serialize, Default, Clone, Debug)]
pub struct Infra {
    pub ok: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
    /// When Prometheus was asked, unix seconds.
    pub at: u64,
    /// Grafana's base URL, for the boards' links: `CC_GRAFANA_URL` is a dashboard link (the
    /// waybar chip opens it as is), so everything from `/d/` on is dropped here, once.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub grafana: Option<String>,
    pub instant: BTreeMap<&'static str, Vec<Series>>,
    /// `runners_down()` as `gather` found it, for the browser, which only draws it.
    pub down: Vec<Series>,
    /// The CI runners board, built once here for both surfaces (`ci::build`).
    pub ci: Ci,
    /// Every machine and pool, built once here for both surfaces (`machines::build`). agent-web
    /// sends them as their tables' rows, so the board's JSON leaves them out.
    #[serde(skip)]
    pub machines: Vec<Machine>,
    #[serde(skip)]
    pub pools: Vec<Pool>,
    /// The CI job pods (`jobpods::read`), read first so a runner row can name its pod's node.
    #[serde(skip)]
    pub pods: Vec<JobPod>,
    /// Where the cluster's cores and memory go, built once here (`workload::build`).
    pub space: Space,
    /// What Alertmanager says is firing, asked beside the queries so it is cached with them;
    /// none when it was not asked. Only the Alerts join reads it, so the Infra tab's JSON
    /// leaves it out.
    #[serde(skip)]
    pub alertmanager: Option<Result<Vec<Firing>, String>>,
}

/// Grafana's base URL from `CC_GRAFANA_URL`, for any board's dashboard link.
pub fn grafana() -> Option<String> {
    prom::config("CC_GRAFANA_URL").map(|g| grafana_base(&g))
}

fn grafana_base(url: &str) -> String {
    url.split("/d/")
        .next()
        .unwrap_or(url)
        .trim_end_matches('/')
        .to_string()
}

/// Ask every query at once (each is a curl with its own timeout) and keep what answered.
/// Any required query failing, or no `cc:overall_status`, makes the whole answer an error.
pub fn gather() -> Infra {
    // Alertmanager is asked beside Prometheus, and even when Prometheus cannot be, since the
    // Alerts tab shows each source's answer on its own.
    let (am, mut out) = std::thread::scope(|s| {
        let am = s.spawn(alertmanager::read);
        let out = prometheus();
        (am.join().unwrap_or_else(|_| Err("panicked".into())), out)
    });
    out.alertmanager = Some(am);
    out
}

fn prometheus() -> Infra {
    let mut out = Infra {
        at: crate::jobs::now().max(0) as u64,
        grafana: grafana(),
        ..Default::default()
    };
    let base = match prom::base() {
        Ok(b) => b,
        Err(e) => {
            out.error = Some(e);
            return out;
        }
    };
    let answers: Vec<_> = std::thread::scope(|s| {
        let handles: Vec<_> = instant_queries()
            .into_iter()
            .map(|(name, q)| {
                let base = &base;
                (name, s.spawn(move || prom::instant(base, &q)))
            })
            .collect();
        handles
            .into_iter()
            .map(|(name, h)| (name, h.join().unwrap_or_else(|_| Err("panicked".into()))))
            .collect()
    });
    let mut errors = vec![];
    for (name, res) in answers {
        match res {
            Ok(s) => _ = out.instant.insert(name, s),
            Err(e) if !OPTIONAL.contains(&name) => errors.push(e),
            Err(_) => {}
        }
    }
    judge(&mut out, errors);
    out.derive();
    out
}

/// A machine's one name: `host` as `Infra::aliases` maps it, else as it is.
pub fn host(alias: &HashMap<String, String>, host: &str) -> String {
    alias.get(host).cloned().unwrap_or_else(|| host.to_string())
}

/// Set `ok` and `error` from the failed required queries, and fail an answer with no
/// `cc:overall_status`: rules not loaded is not an empty green board.
pub fn judge(out: &mut Infra, mut errors: Vec<String>) {
    errors.sort();
    errors.dedup();
    if errors.is_empty()
        && !out
            .instant
            .get("cc")
            .is_some_and(|s| s.iter().any(|x| x.label("__name__") == "cc:overall_status"))
    {
        errors.push("no cc:* series (recording rules not loaded?)".into());
    }
    out.ok = errors.is_empty();
    out.error = (!errors.is_empty()).then(|| errors.join("; "));
}

impl Infra {
    /// Build what both surfaces draw from the answers, in order: the job pods, the runners down, the CI
    /// board, the machines and pools, the space over both (it counts the pools' jobs done and each
    /// machine's split), then the glance over them.
    pub fn derive(&mut self) {
        self.pods = jobpods::read(self);
        self.down = self.runners_down().into_iter().cloned().collect();
        self.ci = ci::build(self);
        (self.machines, self.pools) = machines::build(self);
        self.space = workload::build(self, &self.machines);
        for m in &mut self.machines {
            m.split = self.space.host(&m.host).map_or_else(Vec::new, |h| {
                h.classes.iter().map(workload::Use::line).collect()
            });
        }
        self.ci.glance = ci::glance(self);
    }

    /// The rates file, with the node of each job pod running now: what CI runs are priced with.
    pub fn rates(&self) -> Rates {
        Rates::read(
            self.pods
                .iter()
                .filter(|p| !p.node.is_empty())
                .map(|p| (p.name.clone(), p.node.clone()))
                .collect(),
        )
    }

    /// Hostname -> node name, for a machine whose runner series carry its
    /// hostname while node_exporter's `host` is another name (this workstation is
    /// `cachyos-x8664-main` to its runner and `workstation` to Prometheus). Only a hostname one
    /// node alone has: several Pis are all `raspberrypi`, and none of them is the other.
    pub fn aliases(&self) -> HashMap<String, String> {
        let mut by: HashMap<&str, Vec<&str>> = HashMap::new();
        for s in self.get("uname") {
            let (host, name) = (s.label("host"), s.label("nodename"));
            if !host.is_empty() && !name.is_empty() && host != name {
                by.entry(name).or_default().push(host);
            }
        }
        let hosts: std::collections::HashSet<&str> =
            self.get("uname").iter().map(|s| s.label("host")).collect();
        by.into_iter()
            .filter(|(name, h)| h.len() == 1 && !hosts.contains(name))
            .map(|(name, h)| (name.to_string(), h[0].to_string()))
            .collect()
    }

    /// A runner's machine: the node of the job pod it runs in (an ARC runner is its pod, and
    /// the exporter names only its scale set's owner, `arc-org`), else its `host` label.
    pub fn runner_host(&self, alias: &HashMap<String, String>, s: &Series) -> String {
        match self.pod(s.label("name")) {
            Some(p) if !p.node.is_empty() => p.node.clone(),
            _ => host(alias, s.label("host")),
        }
    }

    /// The job pod by this name, if a runner is one.
    pub fn pod(&self, name: &str) -> Option<&JobPod> {
        self.pods.iter().find(|p| p.name == name)
    }

    /// One query's series, or none.
    pub fn get(&self, name: &str) -> &[Series] {
        self.instant.get(name).map(Vec::as_slice).unwrap_or(&[])
    }

    /// The kind of job each busy runner runs, by name (`job_kind`): what a busy slot says it
    /// runs, and the pool whose usual job time it is judged by. A runner with two kinds at once
    /// has none, so no hash order picks one.
    pub fn job_kinds(&self) -> HashMap<&str, &str> {
        let mut by: HashMap<&str, Option<&str>> = HashMap::new();
        for s in self
            .get("job_kind")
            .iter()
            .filter(|s| !s.label("kind").is_empty())
        {
            let k = s.label("kind");
            by.entry(s.label("runner"))
                .and_modify(|e| *e = e.filter(|x| *x == k))
                .or_insert(Some(k));
        }
        by.into_iter().filter_map(|(r, k)| Some((r, k?))).collect()
    }

    /// The hosts the topology gives GitHub slots (`github_runner_pool_expected`), or none when
    /// that series did not answer.
    pub fn ci_hosts(&self) -> Option<std::collections::HashSet<&str>> {
        let e = self.get("expected");
        (!e.is_empty()).then(|| e.iter().map(|s| s.label("host")).collect())
    }

    /// The runners whose liveness CI judges: every registration but a Forgejo seat (offline by
    /// design between jobs) and one on a host the topology lists no slot for (stale, not down).
    /// `runners_down` and `runners_up` both read this, so up plus down is the roster.
    fn judged(&self) -> Vec<&Series> {
        let alias = self.aliases();
        let hosts: Option<std::collections::HashSet<String>> = self
            .ci_hosts()
            .map(|h| h.into_iter().map(|x| host(&alias, x)).collect());
        self.get("runners")
            .iter()
            .filter(|s| s.label("forge") != "forgejo")
            .filter(|s| {
                hosts
                    .as_ref()
                    .is_none_or(|h| h.contains(&host(&alias, s.label("host"))))
            })
            .collect()
    }

    /// The runners that are down: the judged ones offline or missing whose name no other series
    /// reports up, each name once (two exporter pods report one runner twice during a rollout,
    /// one of them stale). RED NOW on every surface and the phone's CI line read this, so none of
    /// them judges a runner itself. By host, then name.
    pub fn runners_down(&self) -> Vec<&Series> {
        let judged = self.judged();
        let up: std::collections::HashSet<&str> = judged
            .iter()
            .filter(|s| is_up(s))
            .map(|s| s.label("name"))
            .filter(|n| !n.is_empty())
            .collect();
        let mut down: Vec<&Series> = judged
            .into_iter()
            .filter(|s| matches!(s.label("state"), "offline" | "missing"))
            .filter(|s| !up.contains(s.label("name")))
            .collect();
        down.sort_by_key(|s| (s.label("host"), s.label("name")));
        let mut seen = std::collections::HashSet::new();
        down.retain(|s| s.label("name").is_empty() || seen.insert(s.label("name")));
        down
    }

    /// How many judged runners are up (running or idle), each name once by the same rule as
    /// `runners_down`, so up plus down is the roster. A series with no name label is one runner.
    pub fn runners_up(&self) -> u32 {
        let up: Vec<&Series> = self.judged().into_iter().filter(|s| is_up(s)).collect();
        let unnamed = up.iter().filter(|s| s.label("name").is_empty()).count();
        let named: std::collections::HashSet<&str> = up
            .iter()
            .map(|s| s.label("name"))
            .filter(|n| !n.is_empty())
            .collect();
        (named.len() + unnamed) as u32
    }

    /// Why the runner rows may be short, worst first: a missed exporter scrape, GitHub's rate
    /// limit spent, or GitHub not answering the exporter. Every CI surface says this one line.
    pub fn feed(&self) -> Option<&'static str> {
        let one = |q: &str| self.get(q).first().and_then(|s| s.value);
        if one("exporter_up") != Some(1.0) {
            Some("runner exporter missed its last scrape: runner rows may be missing")
        } else if one("rate_left") == Some(0.0) {
            Some("GitHub rate limit spent: runner jobs and history unread until it resets")
        } else if one("api") != Some(1.0) {
            Some("GitHub not answering the exporter: runner rows may be missing")
        } else {
            None
        }
    }

    /// The `cc` series keyed as the boards key them: `name` or `name/<domain|host|pool|site>`.
    pub fn cc_values(&self) -> HashMap<String, f64> {
        let mut v = HashMap::new();
        for s in self.get("cc") {
            let name = s.label("__name__");
            let sub = if name == "cc:domain_status" {
                s.label("domain")
            } else {
                ["host", "pool", "site"]
                    .into_iter()
                    .map(|k| s.label(k))
                    .find(|x| !x.is_empty())
                    .unwrap_or("")
            };
            let key = if sub.is_empty() {
                name.to_string()
            } else {
                format!("{name}/{sub}")
            };
            if let Some(x) = s.value {
                v.insert(key, x);
            }
        }
        v
    }

    /// The health chips (`cc:domain_status`) in strip order, for Home's HEALTH line, Infra's
    /// health section and the Domains figures; the ALWAYS domains show even with no status, as
    /// no data, and a domain DOMAINS does not name (a new rule's, printer's) follows by name, so
    /// every domain Prometheus has is a chip.
    pub fn health(&self) -> Vec<Chip> {
        let v = self.cc_values();
        let chip = |d: &str, s: Option<f64>| Chip {
            name: d.into(),
            level: Level::of(s),
        };
        let known = DOMAINS.iter().filter_map(|d| {
            let s = v.get(&format!("cc:domain_status/{d}")).copied();
            (s.is_some() || ALWAYS.contains(d)).then(|| chip(d, s))
        });
        let mut new: Vec<(&str, f64)> = v
            .iter()
            .filter_map(|(k, x)| Some((k.strip_prefix("cc:domain_status/")?, *x)))
            .filter(|(d, _)| !DOMAINS.contains(d))
            .collect();
        new.sort_by(|a, b| a.0.cmp(b.0));
        known
            .chain(new.into_iter().map(|(d, x)| chip(d, Some(x))))
            .collect()
    }

    /// The domains down, warn and up (`cc:domain_status` 2, 1, 0), the System figures; an
    /// ALWAYS domain with no status is none of them.
    pub fn domains(&self) -> (usize, usize, usize) {
        let h = self.health();
        let n = |l: Level| h.iter().filter(|c| c.level == l).count();
        (n(Level::Red), n(Level::Warn), n(Level::Ok))
    }
}

/// A runner series that can take a job now.
fn is_up(s: &Series) -> bool {
    matches!(s.label("state"), "running" | "idle")
}

#[cfg(test)]
mod tests {
    use super::*;

    fn cc(name: &str, label: (&str, &str), v: f64) -> Series {
        let mut labels = std::collections::BTreeMap::new();
        labels.insert("__name__".to_string(), name.to_string());
        labels.insert(label.0.to_string(), label.1.to_string());
        Series {
            labels,
            value: Some(v),
            points: vec![],
        }
    }

    #[test]
    fn health_keeps_strip_order_and_always_shows_k3s_ci_and_projects() {
        let mut i = Infra::default();
        i.instant.insert(
            "cc",
            vec![
                cc("cc:domain_status", ("domain", "prod"), 1.0),
                cc("cc:domain_status", ("domain", "ci"), 2.0),
                cc("cc:pool_status", ("pool", "unity"), 1.0),
                cc("cc:domain_status", ("domain", "printer"), 0.0),
            ],
        );
        let h = i.health();
        let names: Vec<_> = h.iter().map(|c| c.name.as_str()).collect();
        // printer is no DOMAINS entry: it follows the strip rather than going missing.
        assert_eq!(names, ["k3s", "ci", "projects", "prod", "printer"]);
        assert_eq!(h[4].level, Level::Ok);
        assert_eq!(
            i.domains(),
            (1, 1, 1),
            "no data is neither down, warn nor up"
        );
        assert_eq!(h[0].level, Level::Nodata);
        assert_eq!(h[1].level, Level::Red);
        assert_eq!(h[2].level, Level::Nodata);
        assert_eq!(h[3].level, Level::Warn);
        assert_eq!(i.cc_values().get("cc:pool_status/unity"), Some(&1.0));
    }

    fn runner(name: &str, host: &str, state: &str) -> Series {
        let mut s = cc("github_runner_state", ("name", name), 0.0);
        s.labels.insert("host".into(), host.into());
        s.labels.insert("state".into(), state.into());
        s
    }

    #[test]
    fn only_a_runner_the_topology_expects_is_down() {
        let mut i = Infra::default();
        let mut cloud = runner("aws-spot-1-unity-pool-1", "aws-spot-1", "offline");
        cloud.labels.insert("site".into(), "cloud".into());
        let mut seat = runner("ms-a2-unity-pool-2-forgejo", "ms-a2", "offline");
        seat.labels.insert("forge".into(), "forgejo".into());
        i.instant.insert(
            "runners",
            vec![
                cloud,
                seat,
                runner("ms-a2-unity-pool-3", "ms-a2", "offline"),
                runner("old-box-1", "old-box", "offline"),
            ],
        );
        let names = |i: &Infra| -> Vec<String> {
            i.runners_down()
                .iter()
                .map(|s| s.label("name").to_string())
                .collect()
        };
        // A Forgejo seat is offline between jobs; with no topology answer every other one is
        // down, a cloud host's too.
        assert_eq!(
            names(&i),
            ["aws-spot-1-unity-pool-1", "ms-a2-unity-pool-3", "old-box-1"]
        );
        // A host the topology gives no slot is a stale registration, not down.
        i.instant.insert(
            "expected",
            vec![cc("github_runner_pool_expected", ("host", "ms-a2"), 4.0)],
        );
        assert_eq!(names(&i), ["ms-a2-unity-pool-3"]);
        // The topology names a host by its node name; a runner registered under the hostname
        // is the same machine.
        let mut uname = runner("", "workstation", "");
        uname
            .labels
            .insert("nodename".into(), "cachyos-x8664-main".into());
        i.instant.insert("uname", vec![uname]);
        i.instant.get_mut("runners").unwrap().push(runner(
            "gates-1",
            "cachyos-x8664-main",
            "offline",
        ));
        i.instant.get_mut("expected").unwrap().push(cc(
            "github_runner_pool_expected",
            ("host", "workstation"),
            2.0,
        ));
        assert_eq!(names(&i), ["gates-1", "ms-a2-unity-pool-3"]);
    }

    #[test]
    fn the_feed_line_names_the_likeliest_cause_first() {
        let mut i = Infra::default();
        let one = |n: &str, v: f64| vec![cc(n, ("job", "x"), v)];
        assert_eq!(
            i.feed(),
            Some("runner exporter missed its last scrape: runner rows may be missing")
        );
        i.instant.insert("exporter_up", one("up", 1.0));
        i.instant.insert("rate_left", one("rate", 0.0));
        assert!(i.feed().unwrap().starts_with("GitHub rate limit spent"));
        i.instant.insert("rate_left", one("rate", 40.0));
        i.instant.insert("api", one("api", 1.0));
        assert_eq!(i.feed(), None);
    }

    #[test]
    fn the_grafana_link_is_cut_to_its_base() {
        assert_eq!(
            grafana_base("https://g.lan/d/kb-ci-runners"),
            "https://g.lan"
        );
        assert_eq!(grafana_base("https://g.lan/"), "https://g.lan");
    }

    #[test]
    fn only_the_extras_are_optional() {
        let names: Vec<_> = instant_queries().into_iter().map(|(n, _)| n).collect();
        assert!(OPTIONAL.iter().all(|o| names.contains(o)));
        assert_eq!(
            OPTIONAL,
            [
                "red",
                "bench",
                "exporter_up",
                "rate_left",
                "cores",
                "job_kind",
                "pools",
                "expected",
                "disk",
                "job_pods",
                "job_requests",
                "ci_alloc",
                "ci_other",
                "node_state",
                "job_usual",
                "uname",
                "boot"
            ]
        );
    }
}
